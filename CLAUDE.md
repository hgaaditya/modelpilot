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

- The `llama-server` macro at the top already carries `--host 127.0.0.1 --port ${PORT} -fa on -ngl 99` (flash attention on, full GPU offload). Don't repeat those flags per-model.
- `${PORT}` is assigned automatically by llama-swap per model instance — never hardcode a port in a model's `cmd`.
- MoE models can use `--n-cpu-moe <N>` to offload N expert layers to CPU (see the `scout-moe` entry) when VRAM is tight.
- Model `.gguf` files referenced in `config.yaml` must already exist under `llama.cpp\models\`.

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
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action add-model -Url '<direct .gguf url>'
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action uninstall
```

- **stop** / **restart** — kills `llama-swap`, any spawned `llama-server`, and the open-webui backend. The backend is matched by `python.exe` whose `ExecutablePath` is under the repo root, so a machine's other interpreters are never touched.
- **tray** — (re)starts just the notification-area indicator, `tray.ps1`. It comes up automatically after a successful launch; `-NoTray` suppresses that. A coloured dot polls `/health` on both services every 5s — green for both up, yellow for one, red for neither — with the currently loaded model in the tooltip (from llama-swap's `/running`). Double-click opens the chat UI; right-click gives open/restart/stop/logs. It raises a balloon when the stack drops on its own, which is the point: a backend that dies unattended is otherwise invisible until you next try to use it. Icons are drawn at runtime rather than shipped as `.ico` files, and a named mutex keeps it to one instance no matter how often `start.ps1` fires it off. Exiting the tray leaves the stack running; `uninstall` kills it.
- **add-model** — resumable `.gguf` download into `llama.cpp\models\` via `curl.exe -L -C -` (ships with Windows 10+; `Invoke-WebRequest` has neither resume nor progress, which makes it useless for a multi-GB file). Writes to `<name>.part` and only renames on success, so an interrupted pull resumes on re-run and a partial file is never mistaken for a complete model. `-Name` overrides the filename. On success it prints the `config.yaml` block to paste. Hugging Face URLs must be the `/resolve/` form, not `/blob/` — the failure message says so.
- **status** — installed vs. pinned versions; `-Latest` adds the newest upstream release of each component (GitHub releases API + nodejs.org dist index).
- **upgrade** — moves to the versions in the `$VER` table at the top of `start.ps1`, or to the newest upstream releases with `-Latest`. Stops the stack, deletes only the artifacts whose version actually changed, re-runs the deploy steps, relaunches. `llama.cpp\models\` and `llamaswap\config.yaml` are never touched. An open-webui version bump lands in a new `open-webui-<ver>\` directory with `backend\data\` (the `webui.db` holding users/chats/settings) and `.env` (holding `WEBUI_SECRET_KEY`) copied over; the previous directory is parked as `_old-open-webui-<ver>\` rather than deleted, so delete it manually once the upgrade is confirmed good.
- **uninstall** — prints exactly what it will delete, then requires typing `yes` (`-Force` skips). Removes binaries, the open-webui tree, logs, the version stamp and the download cache. Keeps `.gguf` weights unless `-IncludeModels` is passed, and always keeps `start.ps1`, `CLAUDE.md`, `llamaswap\config.yaml`.

Which versions are actually installed is tracked in `.stack-versions.json` (gitignored, written after each successful deploy/upgrade). Without it, `upgrade` treats every component as stale and re-provisions the lot. Bare `-Action deploy` deliberately *ignores* `$VER` when a stamp exists — bumping the pins requires `-Action upgrade`, so a routine relaunch can never surprise you with a re-download.

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
