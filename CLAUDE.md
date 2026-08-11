# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A local LLM stack on Windows, made of three independently-vendored components glued together by one config file, plus `start.ps1` which bootstraps and launches the whole thing from a clean clone. This is not a monorepo of code you're expected to build from source — `llama.cpp` and `llama-swap` are pre-built binary drops (auto-downloaded by `start.ps1` if missing), and `open-webui` is a vendored upstream release (v0.11.0). Most work here is configuration, not development, unless the task is specifically inside `open-webui-0.11.0/`.

Lives at `C:\LocalLLM` deliberately — not under `Program Files (x86)`. That path requires admin ACLs to write, and its `(x86)` parentheses break glob-based JS build tooling (open-webui's `pyodide:fetch` / vite build silently mangle the path and fail). Don't move this back under Program Files.

```
Chat UI (open-webui, :8080)
   -> llama-swap (:9292 or configured port, OpenAI/Anthropic-compatible proxy)
        -> llama-server.exe (llama.cpp, spawned per-model on demand)
             -> models/*.gguf
```

- **llama.cpp/** — pre-built `llama-server.exe`, `llama-cli.exe`, etc. plus CUDA/CPU-variant DLLs (ggml-cpu-*.dll for different microarchitectures, ggml-cuda.dll). `llama.cpp/models/` holds the actual `.gguf` weight files (multi-GB). Nothing here is meant to be edited or rebuilt; treat it as a binary dependency.
- **llamaswap/** — `llama-swap.exe` (pre-built) + `config.yaml` (generated from the tracked `config.example.yaml` — see below). This is the only file that normally needs editing in this repo. It defines named model entries, each with the exact `llama-server` command line to spawn, context size/quantization flags, and idle-unload `ttl`. llama-swap watches incoming OpenAI/Anthropic-style requests, reads the `model` field, and hot-swaps the backend `llama-server` process to match.
- **open-webui-0.11.0/** — full vendored source of the Open WebUI chat frontend/backend (SvelteKit + FastAPI), pointed at llama-swap as its OpenAI-compatible backend. Has its own build/lint/test tooling (see below) — treat it as an upstream project, not house code; avoid unrelated refactors inside it.

## Editing `llamaswap/config.yaml`

This is the primary day-to-day file in this repo. Convention baked into the file's own header comment: **add new models here, nothing else changes**.

`config.yaml` itself is **generated and gitignored**. The tracked file is `config.example.yaml`, which carries a `{{LOCALLLM_ROOT}}` placeholder wherever a path appears; `start.ps1` writes `config.yaml` from it on first use (deploy, launch, or `add-model`, whichever comes first) with the placeholder replaced by this clone's actual directory, and never overwrites an existing one. Every path in the file is absolute — `llama-server.exe` and each `.gguf` — so a checked-in `config.yaml` would point at directories that only exist on the machine that wrote it. Edit `config.yaml` for day-to-day model work; edit `config.example.yaml` only to change what a *fresh install* starts with (which is: the two macros, and no models at all).

```yaml
models:
  "model-id":
    cmd: >
      ${llama-server}
      -m C:\LocalLLM\llama.cpp\models\<file>.gguf
      -c <context_size> -ctk <kv_type> -ctv <kv_type>
    ttl: 600   # seconds idle before auto-unload
```

- The `llama-server` macro at the top already carries `--host 127.0.0.1 --port ${PORT} -fa on -ngl 99 -np 1 --context-shift` (flash attention, full GPU offload, one slot, sliding context). Don't repeat those flags per-model.
- `--context-shift` matters: it defaults to **disabled** in this llama.cpp build, and without it `llama-server` hard-errors the moment a conversation exceeds `-c` instead of dropping the oldest tokens. That surfaces in a client as "context limit exceeded" a few messages into a session. It's a safety net, not the fix — the client should prune first, which it can only do if it knows the budget (`contextLength` in continue.dev, and the equivalent in open-webui) and that budget matches the model's `-c` here.
- `${PORT}` is assigned automatically by llama-swap per model instance — never hardcode a port in a model's `cmd`.
- MoE models can use `--n-cpu-moe <N>` to offload N expert layers to CPU (see the `scout-moe` entry) when VRAM is tight.
- Model `.gguf` files referenced in `config.yaml` must already exist under `llama.cpp\models\`.
- **llama-swap only reads this file at startup.** After editing it, `-Action restart -Component swap` makes the change live without bouncing open-webui. Check it first with `-Action check-config` — most config mistakes don't fail at startup, they fail as a connection error the first time you pick that model.
- Context costs VRAM. On a 12 GB card, weights plus KV cache plus compute buffers have to fit, so a Q6_K quant of a 9 GB model leaves almost nothing for `-c`; dropping to Q4_K_M buys back roughly 3 GB of context headroom. `-ctk`/`-ctv` at `q4_0` halve the KV cache versus `q8_0` at some cost to long-context recall.

## Running the stack

`start.ps1` at the repo root does all the work — idempotent, safe to re-run on a fresh clone or an already-set-up machine. (Double-clicking `LocalLLM.cmd` is the end-user route to the same thing through the control panel; see below.)

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

On a clean machine it bootstraps everything (skipping any step whose artifact already exists), pinned to exact versions so a wipe-and-reclone reproduces the same stack:

1. Downloads llama.cpp `b10155` (CUDA build if `nvidia-smi` is found, else CPU) into `llama.cpp\`
2. Downloads llama-swap `v244` into `llamaswap\`, and writes `llamaswap\config.yaml` from `config.example.yaml` if it isn't there yet, substituting this clone's path for `{{LOCALLLM_ROOT}}`
3. Ensures `llama.cpp\models\` exists — weights are **not** bootstrapped, since GGUF quant sources vary by provider and can't be guessed; fetch them with `-Action add-model` (below)
4. Installs Python 3.12 via winget if no 3.11/3.12 is found (open-webui pins `requires-python <3.13`), creates `open-webui-0.11.0\.venv`, installs `backend\requirements.txt`
5. Downloads an isolated Node.js v22.23.1 into `open-webui-0.11.0\.node-runtime\` — open-webui's `.npmrc` has `engine-strict=true` pinning `<=22.x.x`, so this never touches or depends on a machine's global Node version
6. `npm install` + `npm run build` for the frontend (production build, served by the backend from one port)
7. Writes `open-webui-0.11.0\.env` from `.env.example` with `OPENAI_API_BASE_URL` pointed at llama-swap and `ENABLE_OLLAMA_API=false` (this stack doesn't use Ollama, despite `.env.example`'s default framing around it)
8. Launches `llama-swap.exe` (`:9292`) and the open-webui backend (`:8080`), both detached with output redirected to `logs\`

Version pins live in the `$VER` hashtable at the top of `start.ps1` — that's the one place to edit them. Ports are `$swapPort` / `$webuiPort` right below it; changing `$swapPort` only affects a `.env` that doesn't exist yet, so an already-provisioned install also needs its `OPENAI_API_BASE_URL` updated by hand.

Launching is verified, not assumed. Before starting anything it warns about every model in `config.yaml` whose `.gguf` is missing (otherwise the only symptom is a `connection refused` proxy error when that model is first selected, because its `llama-server` died on spawn). After starting, it polls `/health` on both services — 20s for llama-swap, 180s for open-webui, whose first boot downloads sentence-transformers embedding weights — and bails early if a process exits. On failure it prints the tail of that component's logs (**both** `.log` and `.err.log`: llama-swap writes everything to stdout, so a stderr-only tail is empty exactly when it matters), tears down whatever did start, and exits non-zero. Re-running while the stack is up refuses rather than spawning a duplicate that loses the port bind.

Re-running after the first successful setup just relaunches those last two processes — steps 1–7 are skipped once their target files exist. To force a re-provision of a given step, delete its artifact (e.g. `open-webui-0.11.0\.venv`, `\.node-runtime`, `\build`, or a `.gguf` file) and re-run.

### Other actions

Same script, `-Action`:

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action stop
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action restart
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action tray
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action status -Latest
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action upgrade
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action add-model -Model '<hf repo, hf url, or .gguf url>'
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action uninstall
```

- **stop** / **restart** — kills `llama-swap`, any spawned `llama-server`, and the open-webui backend. The backend is matched by `python.exe` whose `ExecutablePath` is under the repo root, so a machine's other interpreters are never touched. `-Component swap|webui` acts on one half only — `swap` also takes down the `llama-server` processes it spawned, since they're its children. `-Action restart -Component swap` is the cheap way to pick up a `config.yaml` edit: llama-swap reads its config only at startup, and open-webui has no reason to bounce (nor to lose its warm embedding model). A failed health check rolls back only what that call started.
- **tray** — (re)starts just the notification-area indicator, `tray.ps1`. It comes up automatically after a successful launch; `-NoTray` suppresses that. A coloured dot polls `/health` on both services every 5s — green for both up, yellow for one, red for neither — with the currently loaded model in the tooltip (from llama-swap's `/running`). Double-click opens the chat UI; right-click gives open/logs, a top-level **Reload models (restart llama-swap)** for the common post-`add-model` case, **Restart** and **Stop** submenus offering whole-stack or either component alone, plus a **Models** submenu listing everything in `config.yaml` — the loaded one marked, any whose `.gguf` is missing greyed out with the absent path in the tooltip, and a click on any other sending a one-token completion to swap it in (fire-and-forget, since waiting on a multi-GB load would freeze the tray). The submenu is rebuilt when the menu opens rather than on the status timer, so models added by `add-model` while the tray is running show up without a restart. It raises a balloon when the stack drops on its own, which is the point: a backend that dies unattended is otherwise invisible until you next try to use it. Icons are drawn at runtime rather than shipped as `.ico` files, and a named mutex keeps it to one instance no matter how often `start.ps1` fires it off. Exiting the tray leaves the stack running; `uninstall` kills it.
- **add-model** — fetch a model and register it, in one command. `-Model` takes whatever you have to hand: a Hugging Face repo id (`bartowski/Qwen_Qwen3-8B-GGUF`, optionally suffixed `:Q4_K_M`), a `huggingface.co` URL of either a repo or a single file (`/blob/` and `/resolve/` both work), or any other direct `.gguf` URL.

  ```powershell
  .\start.ps1 -Action add-model -Model 'Qwen/Qwen2.5-0.5B-Instruct-GGUF'
  .\start.ps1 -Action add-model -Model 'bartowski/Qwen_Qwen3-8B-GGUF:Q5_K_M' -Context 32768
  ```

  For a repo it reads the file tree from the HF API, groups the `.gguf` files into one entry per variant, and picks the one matching `-Quant` (default `Q4_K_M`). No match or an ambiguous one prints every available quant with its size and exits, so `-Quant NOPE` is a usable way to browse a repo. Split models published as `-00001-of-000NN.gguf` are grouped by their stem and downloaded as a complete set — pulling part 1 alone yields a model that won't load. Parts live in subfolders upstream but are flattened locally, since llama.cpp finds the rest from the first part.

  Downloads run through `curl.exe -L -C -` (ships with Windows 10+; `Invoke-WebRequest` has neither resume nor progress, which makes it useless for a multi-GB file), staging to `<name>.part` and renaming only on success, so an interrupted pull resumes on re-run and a partial file is never mistaken for a complete model.

  On success it appends an entry to `llamaswap\config.yaml` in the file's existing style, saving the previous version as `config.yaml.bak`. The id defaults to the file name lowercased (`-Id` overrides), context to 16384 (`-Context`). An id that already exists is left untouched rather than duplicated. `-NoConfig` downloads without touching the config. llama-swap reads its config at startup, so the new model needs `-Action restart` before it's routable.
- **install-prism** — installs [PrismML's llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp) into `llama.cpp-prism\`, **alongside** the stock build, never over it. Deliberately not part of `deploy`: it's ~620 MB of downloads that only matters if you run a low-bit model, and every other model in `config.yaml` depends on the stock binary. Prebuilt Windows CUDA binaries come straight off the fork's releases (`-Latest` takes the newest, otherwise `$VER.prism`), so no CMake/CUDA-toolkit/MSVC install is needed. The Windows CUDA asset is named off the kernel build (`llama-prism-b1-…`) rather than the release tag, so the asset is matched by shape, not by tag string. Point a model at it with the `llama-server-prism` macro in `config.yaml`.

  Why it exists: ternary/low-bit GGUFs such as `prism-ml/Ternary-Bonsai-27B-gguf` store weights in ggml tensor types **42** (`Q2_0`, `Q2_g64`) or **142** (`PQ2_0`), and stock llama.cpp b10155 stops at type 41 — those models fail at load on the normal binary regardless of configuration. The repo's `dspark-*` files are a separate thing again: a speculative-decoding drafter with its own architecture (`dspark`), which stock llama.cpp rejects as an unknown architecture.

  Nothing else in the stack needs to change to use it. llama-swap spawns whatever a model's `cmd` names, `Stop-Stack` matches `llama-server.exe` by process name regardless of which directory it came from, and the tray's model list is parsed out of `config.yaml` — so start/stop/restart and the tray menu all work for prism-backed models with no extra wiring.
- **bench** — runs `bench\run.py` against the live llama-swap (see below). Anything after `-Action bench` is forwarded to the script verbatim, which is why the param block sets `PositionalBinding = $false`; without it PowerShell binds trailing values to whichever parameter is next in declaration order.
- **check-config** — the launch preflight (`Test-SwapConfig`) on its own, so a `config.yaml` edit can be checked without bouncing llama-swap to read the warnings on the way past. Every failure it looks for is one that llama-swap starts happily with, and that only shows up as `connection refused` from the proxy the first time that model is picked, because `llama-server` died on spawn:

  | check | why it's invisible otherwise |
  | --- | --- |
  | weights file missing | llama-swap has no idea the path is wrong until it spawns |
  | engine binary missing | a model on `${llama-server-prism}` without `-Action install-prism` can never start |
  | macro not defined in `macros:` | a typo'd macro name expands to nothing |
  | no `-m <file>.gguf` | llama-server starts with nothing to load |
  | `--port` hardcoded | llama-swap assigns the port via `${PORT}`; a literal one is two models racing for it, and is exactly the `dial tcp [::1]:5800 refused` this stack produced once |
  | duplicate model id | YAML keeps the last, so the earlier entry silently does nothing — including one you just edited |

  It **warns and never blocks**, including on the launch path. An entry whose weights or engine aren't installed yet is a legitimate state, and refusing to start over one bad entry would take the other nine models down with it. The panel shows the engine half of this as `engine missing` in the Models table.
- **status** — installed vs. pinned versions; `-Latest` adds the newest upstream release of each component (GitHub releases API + nodejs.org dist index).
- **upgrade** — moves to the versions in the `$VER` table at the top of `start.ps1`, or to the newest upstream releases with `-Latest`. Stops the stack, deletes only the artifacts whose version actually changed, re-runs the deploy steps, relaunches. `llama.cpp\models\` and `llamaswap\config.yaml` are never touched. An open-webui version bump lands in a new `open-webui-<ver>\` directory with `backend\data\` (the `webui.db` holding users/chats/settings) and `.env` (holding `WEBUI_SECRET_KEY`) copied over; the previous directory is parked as `_old-open-webui-<ver>\` rather than deleted, so delete it manually once the upgrade is confirmed good.
- **uninstall** — prints exactly what it will delete, then requires typing `yes` (`-Force` skips). Removes binaries, the open-webui tree, logs, the version stamp and the download cache. Keeps `.gguf` weights unless `-IncludeModels` is passed, and always keeps `start.ps1`, `CLAUDE.md`, `llamaswap\config.yaml`.

Which versions are actually installed is tracked in `.stack-versions.json` (gitignored, written after each successful deploy/upgrade). Without it, `upgrade` treats every component as stale and re-provisions the lot. Bare `-Action deploy` deliberately *ignores* `$VER` when a stamp exists — bumping the pins requires `-Action upgrade`, so a routine relaunch can never surprise you with a re-download.

## The control panel — `LocalLLM.cmd` / `ui.ps1`

The end-user entry point. `ui.ps1` serves a local web page on `127.0.0.1:9300` and opens it in a
Chromium `--app` window, so it looks like a desktop app with no address bar. Everything it does
shells out to `start.ps1` — the CLI stays the single source of truth and the panel is a face on it,
never a second implementation. New behaviour belongs in `start.ps1` with the panel calling it.

**`LocalLLM.cmd`** is the double-click shim, and the only file a new user has to touch: a `.ps1`
opens in Notepad when double-clicked, so it can't be the entry point. It runs `ui.ps1 -Launch`,
which clears mark-of-the-web from the `.ps1` files (they arrive blocked when extracted from a
downloaded zip), spawns the panel **detached**, and then polls `/api/ping` for 15s. The detachment
matters — closing the panel window is a minimise, not a quit, so the server has to outlive its
launcher. The polling matters just as much: without it a failure to start is completely invisible,
which is the worst possible first-run outcome. `README.md` is the user-facing version of this.

- `/api/ping` is **deliberately exempt** from the CSRF gate that covers every other `/api/*` path.
  It's how a second launch discovers a panel is already up, and that check runs before any token
  exists to send. Gating it broke single-instance detection outright — every launch believed
  nothing was running, then died failing to bind the port. It returns a fixed literal, so the only
  thing it tells a cross-origin caller is that this port is a LocalLLM panel, which a failed bind
  reveals anyway. Don't "fix" this by gating it again.
- The **Dashboard banner** is a three-step first-run walkthrough (install → add a model → open the
  chat), each step keyed on state and gone once done. Step 3 keys on *no model has ever been used*
  (`loads`/`lastUsed`), not on *nothing loaded right now* — models unload on their idle timer all
  day, and a banner that came back every time would be noise.
- `-Install`, and the **Settings → Desktop integration** button that calls the same
  `Install-Shortcuts`, write a desktop and start-menu `.lnk`. The panel exists so that nothing
  requires opening a terminal; a Settings tab that tells you to run a PowerShell command defeats it.

## Using the local models from Claude Code

Two different things, often confused:

**Full local mode — `claude-local.ps1`.** Runs Claude Code entirely against llama-swap instead of Anthropic. llama-swap implements the Anthropic endpoints Claude Code needs (`v1/messages`, `v1/messages/count_tokens`), so it's just three environment variables. The script sets them **for its own process only** — putting `ANTHROPIC_BASE_URL` in the user environment would silently redirect *every* Claude Code session on the machine, which is almost never wanted. It validates that llama-swap is up and that the model ids exist before launching, so a typo fails immediately rather than as a connection error inside Claude Code.

```powershell
.\claude-local.ps1                      # bonsai-27b
.\claude-local.ps1 -Model qwen3-14b
```

`-SmallModel` (default `qwen2.5-0.5b-instruct-q4_k_m`) backs `ANTHROPIC_SMALL_FAST_MODEL`, which Claude Code uses for background work like conversation titles. Pointing it at the main model makes every trivial call trigger a multi-GB swap.

**Hybrid delegation — `local-llm.ps1`.** Usually the better arrangement: keep Claude Code on the cloud model for reasoning, planning and orchestration, and hand off only the token-heavy grinding to a local model.

```powershell
.\local-llm.ps1 -Prompt "List every distinct error and its frequency" -File logs\app.log
Get-Content big.json | .\local-llm.ps1 -Prompt "Extract every user id, one per line"
```

Only the *answer* returns, so a 200k-token log costs nothing in cloud context. This is a script rather than a second backend because **`ANTHROPIC_BASE_URL` is global per process** — Claude Code cannot split its own traffic between two endpoints, so the local model has to be something it calls, not something it routes to.

Worth knowing when deciding whether an offload pays: prompt processing (the compute-bound phase that dominates when you feed in a large file) measured **~2290–2400 tok/s on `gemma4-v2`**, 2176 on `gemma4-coding-Q6_K`, 1906 on `qwen3-14b` — so ~50k tokens of input costs 20–25 seconds. Don't judge this from a short prompt: a 31-token request reports ~57 tok/s because fixed overhead dominates, which is measurement noise, not throughput.

Input larger than `-ChunkTokens` (default 40000) is split and each chunk answered independently, then concatenated. That is map-without-reduce: right for extract/filter/list work, wrong for "summarise this whole thing coherently" — for that, feed the output back through once more. Files are read as UTF-8 with invalid bytes and control characters stripped, because logs and dumps routinely contain bytes that would otherwise make llama-server reject the whole request as malformed JSON.

## Benchmarking and evaluating models — `bench/`

Compares the models in `config.yaml` against each other on both speed and correctness. Everything is graded locally by `bench\run.py`; there is no LLM judge and no external API call, so a full run costs nothing but GPU time and can be re-run as often as you like.

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action bench
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action bench --models qwen3-14b gemma4-v2
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action bench --tasks code json --repeat 3
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action bench --compare bench\results\<earlier>.json
```

The constraint that shapes everything: **tasks must be machine-gradeable**, since an LLM judge would defeat the point. `bench\tasks.jsonl` holds one task per line, each with a `type` naming its grader:

- `python` — extracts the code block and runs it against the task's `tests` in a subprocess. **This executes model-generated code on your machine**, as you, sandboxed only by a timeout and a temp directory. It is therefore **gated on consent** and skipped until granted; see below.
- `json` — output must parse as JSON and carry the expected keys. Catches models that wrap JSON in prose or fences.
- `regex` / `contains` — exact-format and exact-answer checks.
- `needle` — the harness generates a long deterministic haystack, buries a fact at a given `depth`, and asks for it back. This is the one that actually exercises the context sizes configured in `config.yaml`.

Speed numbers come from llama.cpp's own `timings` block in the response (`predicted_per_second`, `prompt_per_second`), so they measure the model rather than the harness. Reasoning models' `<think>` blocks are stripped before grading — otherwise every exact-match task would fail on output format rather than capability, which measures the wrong thing.

Results land in `bench\results\<timestamp>.json` (gitignored). `--compare` diffs a run against an earlier one, which is the point of keeping them: it's how you tell whether a quant change or a context change actually helped. `--repeat N` runs each task N times and reports the median, for when a single sample is too noisy to trust.

Adding a task is one line in `tasks.jsonl` — no code change, as long as an existing grader covers it.

### The code-execution gate

Running the model's code is the only way the `python` grader can tell whether it works, so there's no version of that task that doesn't execute. What there is, is a decision made explicitly:

- Run `bench\run.py` from a terminal and it explains what will happen and asks. Answering `yes` is recorded in `bench\.code-exec-consent` (gitignored — consent doesn't travel with a clone) so it's asked once and not on every run, which is what trains people to pass the flag reflexively.
- `--allow-code-execution` skips the question for scripted runs. It deliberately does **not** write the consent file: a flag is per-run, not a standing grant.
- With no terminal to ask — `-Action bench` from `start.ps1` or the panel both run detached — the answer is **no**, and the `python` tasks are dropped with a message saying how to enable them. Defaulting to yes when there's nobody there to object isn't consent.

`grade_python` re-checks the flag itself rather than trusting the task filter in `main()`, so a future caller that bypasses the filter fails closed instead of quietly executing. `bench\test_consent.py` asserts all of that, including that the grader writes no file when the gate is off; run it after touching any of this.

## Working inside `open-webui-0.11.0/`

Standard upstream Open WebUI tooling (npm scripts in `package.json`, Python deps in `pyproject.toml`):

```bash
npm run dev             # vite dev server (frontend), also runs pyodide:fetch
npm run build            # production frontend build
npm run check             # svelte-check type checking
npm run lint              # lint:frontend (eslint) + lint:types + lint:backend (pylint backend/)
npm run format             # prettier (frontend) — format:backend uses `ruff format`
npm run test:frontend        # vitest
npm run cy:open            # cypress e2e (interactive)
```

Backend (Python) is under `backend/open_webui/`; run via `backend\start_windows.bat` or `backend/start.sh` (WSL recommended). Ruff (`line-length = 120`, single quotes) and pylint govern backend style — see `pyproject.toml` `[tool.ruff]` / `[tool.black]` for exact settings. `requirements.txt` / `requirements-min.txt` in `backend/` list the pinned Python deps mirrored from `pyproject.toml`.

Docker-based workflow also exists (`docker-compose*.yaml`, `Makefile` targets `install`/`start`/`stop`/`update`) but assumes Ollama-style deployment; this repo's actual backend is llama-swap, not Ollama, so `OLLAMA_BASE_URL` in `.env.example` is not the relevant connection point here — configure an OpenAI-compatible connection to llama-swap instead.

Since `open-webui-0.11.0/` is a vendored upstream drop, prefer minimal, targeted diffs there and avoid house-style refactors that would fight future upstream merges.
