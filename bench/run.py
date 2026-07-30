#!/usr/bin/env python3
"""
Benchmark and evaluate the models in llamaswap/config.yaml against each other.

Everything is graded locally by this script - no LLM judge, no API calls to anything but
llama-swap - so a full run costs nothing but GPU time. Tasks therefore have to be gradeable
by machine: exact answers, parseable JSON, code that either passes its tests or doesn't.

    python bench/run.py                          # every model in config.yaml, every task
    python bench/run.py --models qwen3-14b gemma4-v2
    python bench/run.py --tasks code json --repeat 3
    python bench/run.py --compare bench/results/2026-07-30T18-00-00.json

Speed numbers come from llama.cpp's own `timings` block, so they measure the model rather
than this script's overhead.
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "llamaswap" / "config.yaml"
TASKS = Path(__file__).resolve().parent / "tasks.jsonl"
RESULTS = Path(__file__).resolve().parent / "results"

THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)
CODE_RE = re.compile(r"```(?:python)?\s*\n(.*?)```", re.DOTALL)


# ---------------------------------------------------------------- infrastructure

def post(url, payload, timeout):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def vram_used_mib():
    """Current GPU memory in MiB, or None when nvidia-smi isn't there (CPU-only box)."""
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10,
        )
        return int(out.stdout.strip().splitlines()[0])
    except Exception:
        return None


def models_from_config(path):
    """Model ids from config.yaml. A real YAML parse would need a dependency; the file's
    shape is fixed by convention (two-space indented quoted id at the top of each entry)."""
    ids = []
    in_models = False
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if re.match(r"^models:\s*$", line):
            in_models = True
            continue
        if in_models:
            if re.match(r"^\S", line):        # dedented back out of the models block
                break
            m = re.match(r'^\s{2}"([^"]+)"\s*:\s*$', line)
            if m:
                ids.append(m.group(1))
    return ids


def strip_reasoning(text):
    """Reasoning models emit <think> blocks that would otherwise fail every exact-match
    grader, which measures output format rather than capability."""
    return THINK_RE.sub("", text).strip()


# ---------------------------------------------------------------- graders

def grade_contains(task, text):
    hay = text.lower()
    missing = [n for n in task["expect"] if n.lower() not in hay]
    return (not missing), ("missing " + ", ".join(missing) if missing else "")


def grade_regex(task, text):
    ok = bool(re.search(task["expect"], text, re.IGNORECASE | re.DOTALL))
    return ok, ("" if ok else "no match for /%s/" % task["expect"])


def grade_json(task, text):
    blob = text[text.find("{"): text.rfind("}") + 1] if "{" in text else ""
    try:
        obj = json.loads(blob)
    except Exception as e:
        return False, "not valid JSON (%s)" % e
    missing = [k for k in task["expect"] if k not in obj]
    return (not missing), ("missing keys " + ", ".join(missing) if missing else "")


def grade_python(task, text):
    """Run the model's code against the task's asserts.

    NOTE: this executes model-generated code on this machine. It's sandboxed only by a
    timeout and a temp directory - fine for benchmarking models you chose to download,
    not something to point at untrusted output. Skip these with --tasks to avoid it.
    """
    m = CODE_RE.search(text)
    code = m.group(1) if m else text
    src = code + "\n\n" + task["tests"] + "\nprint('PASS')\n"
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "cand.py"
        f.write_text(src, encoding="utf-8")
        try:
            out = subprocess.run([sys.executable, str(f)], capture_output=True, text=True,
                                 timeout=task.get("timeout", 15), cwd=d)
        except subprocess.TimeoutExpired:
            return False, "timed out"
    if "PASS" in out.stdout:
        return True, ""
    err = (out.stderr or out.stdout).strip().splitlines()
    return False, (err[-1][:90] if err else "no output")


GRADERS = {"contains": grade_contains, "regex": grade_regex, "json": grade_json, "python": grade_python}


FILLER = ("The archive contains routine maintenance records. "
          "Nothing in this paragraph is relevant to the question. ")


def build_prompt(task):
    """Needle tasks generate their own haystack so long-context behaviour is measured
    rather than assumed - the filler is deterministic so every model sees the same input.

    Sizing matters: English GGUF tokenisers land near 4 characters per token, and an earlier
    version used a 12-chars-per-token guess that built 22.7k tokens for a task asking for 16k.
    Every model then failed the task on a 400 for exceeding its context, which measured the
    harness rather than the model.
    """
    if task["type"] != "needle":
        return task["prompt"]
    approx_tokens = task.get("context_tokens", 8000)
    reps = max(1, int(approx_tokens * 4 / len(FILLER)))
    body = FILLER * reps
    cut = int(len(body) * task.get("depth", 0.5))
    return (body[:cut] + "\n\n" + task["needle"] + "\n\n" + body[cut:] +
            "\n\n" + task["prompt"])


# ---------------------------------------------------------------- run

def run_one(base, model, task, timeout):
    prompt = build_prompt(task)
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": task.get("max_tokens", 512),
        "temperature": 0,
    }
    t0 = time.time()
    try:
        resp = post(base + "/v1/chat/completions", payload, timeout)
    except urllib.error.HTTPError as e:
        body = e.read()[:200].decode("utf-8", "replace")
        # A prompt longer than this model's -c isn't a wrong answer, it's a task this model
        # can't be asked. Scoring it as a failure would punish a small context twice: once in
        # the config, again here.
        if e.code == 400 and "exceed" in body.lower():
            return {"skipped": True, "ok": False, "note": "context too small for this task"}
        return {"ok": False, "note": "HTTP %s %s" % (e.code, body[:120])}
    except Exception as e:
        return {"ok": False, "note": str(e)[:120]}
    wall = time.time() - t0

    raw = resp["choices"][0]["message"]["content"] or ""
    text = strip_reasoning(raw)
    ok, note = GRADERS[task["type"] if task["type"] in GRADERS else "contains"](task, text)

    t = resp.get("timings") or {}
    return {
        "ok": ok, "note": note, "wall_s": round(wall, 2),
        # Keep what a failing model actually said: a red cell you can't inspect tells you
        # nothing about whether the model is weak or the grader is too strict.
        "output": None if ok else text[:400],
        "gen_tps": round(t.get("predicted_per_second", 0), 1),
        "prompt_tps": round(t.get("prompt_per_second", 0), 1),
        "prompt_tokens": (resp.get("usage") or {}).get("prompt_tokens", 0),
        "completion_tokens": (resp.get("usage") or {}).get("completion_tokens", 0),
        "empty": not text.strip(),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:9292")
    ap.add_argument("--models", nargs="*", help="default: every model in config.yaml")
    ap.add_argument("--tasks", nargs="*", help="filter by task id or type")
    ap.add_argument("--repeat", type=int, default=1, help="runs per task; median is reported")
    ap.add_argument("--timeout", type=int, default=600, help="seconds per request (a cold model load is slow)")
    ap.add_argument("--compare", help="path to an earlier results .json to diff against")
    ap.add_argument("--cooldown", type=int, default=10,
                    help="seconds to idle between models, letting llama-swap free VRAM before the "
                         "next one loads (0 to disable)")
    args = ap.parse_args()

    all_tasks = [json.loads(l) for l in TASKS.read_text(encoding="utf-8").splitlines() if l.strip()]
    if args.tasks:
        want = set(args.tasks)
        all_tasks = [t for t in all_tasks if t["id"] in want or t["type"] in want]
    models = args.models or models_from_config(CONFIG)
    if not all_tasks or not models:
        sys.exit("nothing to run (tasks=%d models=%d)" % (len(all_tasks), len(models)))

    print("%d model(s) x %d task(s) x %d run(s)\n" % (len(models), len(all_tasks), args.repeat))
    results = {}

    # Checkpoint after every model. A long run drives the GPU hard for minutes at a time, and a
    # driver timeout (bugcheck 0x116) takes the whole machine with it - without this, an hour of
    # measurements is lost because the last model crashed.
    RESULTS.mkdir(parents=True, exist_ok=True)
    out = RESULTS / (datetime.now().strftime("%Y-%m-%dT%H-%M-%S") + ".json")

    for model in models:
        print("=== %s" % model)
        rows, peak = [], 0
        for task in all_tasks:
            attempts = [run_one(args.base, model, task, args.timeout) for _ in range(args.repeat)]
            v = vram_used_mib()
            if v:
                peak = max(peak, v)
            passed = sum(1 for a in attempts if a["ok"])
            best = max(attempts, key=lambda a: (a["ok"], a.get("gen_tps", 0)))
            skipped = all(a.get("skipped") for a in attempts)
            best["id"], best["passed"] = task["id"], passed
            best["of"] = 0 if skipped else len(attempts)   # 0 keeps it out of the pass rate
            rows.append(best)
            label = "skip" if skipped else ("pass" if passed == len(attempts) else "%d/%d" % (passed, len(attempts)))
            print("  %-24s %-5s %5.1f tok/s  %s" % (
                task["id"], label, best.get("gen_tps", 0), best.get("note", "")[:58]))
        gen = [r["gen_tps"] for r in rows if r.get("gen_tps")]
        pro = [r["prompt_tps"] for r in rows if r.get("prompt_tps")]
        results[model] = {
            "rows": rows,
            "pass_rate": sum(r["passed"] for r in rows) / max(1, sum(r["of"] for r in rows)),
            "skipped": sum(1 for r in rows if r["of"] == 0),
            "gen_tps": round(statistics.median(gen), 1) if gen else 0,
            "prompt_tps": round(statistics.median(pro), 1) if pro else 0,
            "peak_vram_mib": peak,
        }
        out.write_text(json.dumps(results, indent=2), encoding="utf-8")
        print()
        if args.cooldown and model != models[-1]:
            time.sleep(args.cooldown)

    print("%-28s %8s %10s %12s %10s" % ("model", "pass", "gen tok/s", "prompt tok/s", "peak VRAM"))
    print("-" * 72)
    for m, r in sorted(results.items(), key=lambda kv: -kv[1]["pass_rate"]):
        print("%-28s %7.0f%% %10.1f %12.1f %9s" % (
            m, r["pass_rate"] * 100, r["gen_tps"], r["prompt_tps"],
            ("%d MiB" % r["peak_vram_mib"]) if r["peak_vram_mib"] else "n/a"))

    print("\nwrote %s" % out)

    if args.compare:
        old = json.loads(Path(args.compare).read_text(encoding="utf-8"))
        print("\nvs %s" % args.compare)
        for m, r in results.items():
            if m in old:
                d_pass = (r["pass_rate"] - old[m]["pass_rate"]) * 100
                d_tps = r["gen_tps"] - old[m]["gen_tps"]
                print("  %-26s pass %+5.0f%%   gen %+6.1f tok/s" % (m, d_pass, d_tps))
            else:
                print("  %-26s (new)" % m)


if __name__ == "__main__":
    main()
