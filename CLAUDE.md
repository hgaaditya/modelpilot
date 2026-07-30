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
- **llamaswap/** — `llama-swap.exe` (pre-built) + `config.yaml`. This is the only file that normally needs editing in this repo. It defines named model entries, each with the exact `llama-server` command line to spawn, context size/quantization flags, and idle-unload `ttl`. llama-swap watches incoming OpenAI/Anthropic-style requests, reads the `model` field, and hot-swaps the backend `llama-server` process to match.
- **open-webui-0.11.0/** — full vendored source of the Open WebUI chat frontend/backend (SvelteKit + FastAPI), pointed at llama-swap as its OpenAI-compatible backend. Has its own build/lint/test tooling (see below) — treat it as an upstream project, not house code; avoid unrelated refactors inside it.

## Editing `llamaswap/config.yaml`

This is the primary day-to-day file in this repo. Convention baked into the file's own header comment: **add new models here, nothing else changes**.

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
- **llama-swap only reads this file at startup.** After editing it, `-Action restart -Component swap` makes the change live without bouncing open-webui.
- Context costs VRAM. On a 12 GB card, weights plus KV cache plus compute buffers have to fit, so a Q6_K quant of a 9 GB model leaves almost nothing for `-c`; dropping to Q4_K_M buys back roughly 3 GB of context headroom. `-ctk`/`-ctv` at `q4_0` halve the KV cache versus `q8_0` at some cost to long-context recall.

## Running the stack

`start.ps1` at the repo root is the single entry point — idempotent, safe to re-run on a fresh clone or an already-set-up machine:

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

On a clean machine it bootstraps everything (skipping any step whose artifact already exists), pinned to exact versions so a wipe-and-reclone reproduces the same stack:

1. Downloads llama.cpp `b10155` (CUDA build if `nvidia-smi` is found, else CPU) into `llama.cpp\`
2. Downloads llama-swap `v244` into `llamaswap\`
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
- **bench** — runs `bench\run.py` against the live llama-swap (see below). Anything after `-Action bench` is forwarded to the script verbatim, which is why the param block sets `PositionalBinding = $false`; without it PowerShell binds trailing values to whichever parameter is next in declaration order.
- **status** — installed vs. pinned versions; `-Latest` adds the newest upstream release of each component (GitHub releases API + nodejs.org dist index).
- **upgrade** — moves to the versions in the `$VER` table at the top of `start.ps1`, or to the newest upstream releases with `-Latest`. Stops the stack, deletes only the artifacts whose version actually changed, re-runs the deploy steps, relaunches. `llama.cpp\models\` and `llamaswap\config.yaml` are never touched. An open-webui version bump lands in a new `open-webui-<ver>\` directory with `backend\data\` (the `webui.db` holding users/chats/settings) and `.env` (holding `WEBUI_SECRET_KEY`) copied over; the previous directory is parked as `_old-open-webui-<ver>\` rather than deleted, so delete it manually once the upgrade is confirmed good.
- **uninstall** — prints exactly what it will delete, then requires typing `yes` (`-Force` skips). Removes binaries, the open-webui tree, logs, the version stamp and the download cache. Keeps `.gguf` weights unless `-IncludeModels` is passed, and always keeps `start.ps1`, `CLAUDE.md`, `llamaswap\config.yaml`.

Which versions are actually installed is tracked in `.stack-versions.json` (gitignored, written after each successful deploy/upgrade). Without it, `upgrade` treats every component as stale and re-provisions the lot. Bare `-Action deploy` deliberately *ignores* `$VER` when a stamp exists — bumping the pins requires `-Action upgrade`, so a routine relaunch can never surprise you with a re-download.

## Benchmarking and evaluating models — `bench/`

Compares the models in `config.yaml` against each other on both speed and correctness. Everything is graded locally by `bench\run.py`; there is no LLM judge and no external API call, so a full run costs nothing but GPU time and can be re-run as often as you like.

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action bench
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action bench --models qwen3-14b gemma4-v2
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action bench --tasks code json --repeat 3
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action bench --compare bench\results\<earlier>.json
```

The constraint that shapes everything: **tasks must be machine-gradeable**, since an LLM judge would defeat the point. `bench\tasks.jsonl` holds one task per line, each with a `type` naming its grader:

- `python` — extracts the code block and runs it against the task's `tests` in a subprocess. **This executes model-generated code on your machine**, sandboxed only by a timeout and a temp directory. Fine for models you chose to download; exclude these with `--tasks` if that isn't acceptable.
- `json` — output must parse as JSON and carry the expected keys. Catches models that wrap JSON in prose or fences.
- `regex` / `contains` — exact-format and exact-answer checks.
- `needle` — the harness generates a long deterministic haystack, buries a fact at a given `depth`, and asks for it back. This is the one that actually exercises the context sizes configured in `config.yaml`.

Speed numbers come from llama.cpp's own `timings` block in the response (`predicted_per_second`, `prompt_per_second`), so they measure the model rather than the harness. Reasoning models' `<think>` blocks are stripped before grading — otherwise every exact-match task would fail on output format rather than capability, which measures the wrong thing.

Results land in `bench\results\<timestamp>.json` (gitignored). `--compare` diffs a run against an earlier one, which is the point of keeping them: it's how you tell whether a quant change or a context change actually helped. `--repeat N` runs each task N times and reports the median, for when a single sample is too noisy to trust.

Adding a task is one line in `tasks.jsonl` — no code change, as long as an existing grader covers it.

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
