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

- The `llama-server` macro at the top already carries `--host 127.0.0.1 --port ${PORT} -fa on -np 1 --context-shift` (flash attention, one slot, sliding context). Don't repeat those flags per-model. `-ngl` is deliberately **not** in the macro: pinning it at 99 forces every layer onto the GPU, which for a model that doesn't fit is an impossible placement rather than an instruction. This build defaults to `auto` and fits what the card holds; a model wanting a specific split sets `-ngl` or `--n-cpu-moe` in its own `cmd` (which is what `-Action autotune` measures and writes).
- `--context-shift` matters: it defaults to **disabled** in this llama.cpp build, and without it `llama-server` hard-errors the moment a conversation exceeds `-c` instead of dropping the oldest tokens. That surfaces in a client as "context limit exceeded" a few messages into a session. It's a safety net, not the fix — the client should prune first, which it can only do if it knows the budget (`contextLength` in continue.dev, and the equivalent in open-webui) and that budget matches the model's `-c` here.
- `${PORT}` is assigned automatically by llama-swap per model instance — never hardcode a port in a model's `cmd`.
- MoE models can use `--n-cpu-moe <N>` to offload N expert layers to CPU (see the `scout-moe` entry) when VRAM is tight.
- Model `.gguf` files referenced in `config.yaml` must already exist under `llama.cpp\models\`.
- **llama-swap re-reads this file on its own.** It is launched with `-watch-config`, which polls the file every 2s and reloads it in place — verified against v244, a model appended while it was running appeared in `/v1/models` within 5s. No restart is needed to add, remove or retune a model. What a reload does *not* do is re-spawn a `llama-server` that is already up: that process keeps the `-c`/`-ctk` it was started with until it unloads, so evict it (the panel does this for you, or `POST /api/models/unload`) if you changed the model you are currently using. Check an edit with `-Action check-config` — most config mistakes don't fail at load, they fail as a connection error the first time you pick that model.
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
4. Fetches **uv** (one 18 MB static binary), which installs its own CPython 3.12 into `.python\`, creates `open-webui-0.11.0\.venv` and installs `backend\requirements.txt`

   This replaced `winget install Python.Python.3.12`, which was the most fragile step in the bootstrap: winget is absent on LTSC and Server, absent on images with the Store stripped, can demand interactive elevation, and installs machine-wide so an uninstall left Python behind. uv needs none of that. Measured on a clean run: 8s to fetch uv, 5s to install Python, 1s for the venv, and **6s to resolve open-webui's 127 pinned packages** (340 with transitive deps) — a job pip spends minutes on.

   `UV_PYTHON_INSTALL_DIR` and `UV_CACHE_DIR` point inside the install so `-Action uninstall` can actually remove them. `python install --no-bin` is deliberate: without it uv also drops a `python3.12.exe` shim into `~\.local\bin`, which is a write outside the install and warns when something unmanaged is already there.
5. Downloads an isolated Node.js v22.23.1 into `open-webui-0.11.0\.node-runtime\` — open-webui's `.npmrc` has `engine-strict=true` pinning `<=22.x.x`, so this never touches or depends on a machine's global Node version
6. `npm install` + `npm run build` for the frontend (production build, served by the backend from one port)
7. Writes `open-webui-0.11.0\.env` from `.env.example` with `OPENAI_API_BASE_URL` pointed at llama-swap and `ENABLE_OLLAMA_API=false` (this stack doesn't use Ollama, despite `.env.example`'s default framing around it)
8. Launches `llama-swap.exe` (`:9292`) and the open-webui backend (`:8080`), both detached with output redirected to `logs\`

**The first-run path is separately fragile, and was measured by wiping this install and rebuilding
it.** Every deploy step is guarded by *skip if the artifact exists*, so a machine that is already
deployed never runs them again - which is exactly how five bugs survived in the path every new user
takes, and none in the path developers take. Found by deploying a clean clone, then by
`-Action uninstall` (weights kept) followed by a full rebuild:

| what broke | why it never showed up here |
| --- | --- |
| the asset regex `-bin-win-cuda-.*-x64.zip$` also matched `cudart-llama-bin-win-cuda-12.4-x64.zip`, which sorts first - so deploy fetched cudart twice (746 MB) and never fetched the binaries at all | `llama-server.exe` already existed, so step 1 was skipped |
| `vite build` peaked at 3.8 GB and hit node's ~4 GB default heap cap | `build\` already existed, so step 7 was skipped |
| `Invoke-Deploy` ended with `$webui`, but a PowerShell function returns its whole output stream - and it runs npm, uv and tar | on a re-run those steps print nothing, so the caller received just the path |
| `-Action uninstall` printed `uv\`, `.python\` and `.uv-cache\` in its "will permanently delete" list and never deleted them | nobody had run uninstall and then looked |
| open-webui's health budget was a flat 180s; a first boot runs ~60 alembic migrations on an empty database and fetches embedding weights, and was killed mid-migration by the rollback | every later boot has both already, and answers in seconds |

Measured on the rebuild, weights kept: **20 minutes to deploy, 2 minutes to first boot, ~850 MB
downloaded, 4,103 MB on disk** excluding `.gguf` files - the figure the README now quotes, and it
is after the `.uv-cache` prune reclaims 2.2 GB. Re-run that rebuild before a release; nothing else
exercises these paths.

**Run again 2026-08-17, and it found three more.** The gate keeps paying, and all three were
invisible on this machine five minutes earlier:

| what broke | why it never showed up here |
| --- | --- |
| `tar -xzf ... -C $root` resolved to Git for Windows' **GNU** tar when its `usr\bin` is ahead on PATH, which reads `C:\LocalLLM` as `host:path` and fails with `Cannot connect to C: resolve failed` - the open-webui extract died and the deploy stopped | `open-webui-0.11.0\` already existed, so the extract was skipped; and from Explorer or a plain PowerShell the bare name resolves to `System32\tar.exe`, which handles the path fine. Now called by absolute path |
| `llmfit\` (23 MB) survived `-Action uninstall` entirely - no target entry, no delete | same as the `uv`/`.python` row above: nobody had uninstalled and then looked, and `install-llmfit` is opt-in so most installs don't have it |
| deploy wrote `Write-Stamp $target`, the **whole** `$VER` table - including `prism` and `llmfit`, which deploy never installs. A fresh rebuild reported `prism fork  prism-b9599-9ca265a` in status's *installed* column with no `llama.cpp-prism\` on disk | the stamp is only written by deploy/upgrade, and on this box prism genuinely was installed every time anyone looked. Its own prose line two rows down said "not installed" - the table and the prose disagreed and nobody read both |

That last one is the one to remember: **the version stamp is what `upgrade` uses to decide which
artifacts are stale**, so a stamp claiming a component is installed is not a cosmetic error. Deploy
now merges only the keys it provisions, and the status table checks disk before believing the
stamp - every stamp written before this fix still carries the wrong claim.

This run measured **8m54s from wipe to both services healthy**, against the 20 minutes above; the
open-webui tarball was already in the download cache from the failed first attempt, and nothing
else was. Verified afterwards with a real completion rather than `/health`, per the v250 lesson
below: `gemma4-v2` answered correctly, cold, in 24s.

**llama-swap is pinned to v244 deliberately - v250 does not work here.** Bumping the pin and
running `-Action upgrade` installed v250 cleanly and both services passed their health checks, so
everything *looked* right. The first real completion killed it: llama-swap crashed outright, and
its last words were

```
[INFO] <qwen2.5-0.5b-...> Health check passed on http://localhost:5804/health
http: proxy error: dial tcp [::1]:5804: connectex: ... actively refused
```

v250 addresses its upstreams as `localhost`, which resolves to `::1` first on Windows, while the
`llama-server` macro binds `--host 127.0.0.1`. That is the same IPv6 mismatch this file warns about
for every URL here, arriving this time from inside a dependency. Re-test with a real completion,
not `/health`, before moving the pin again.

The wider lesson, and the reason this was found four hours late: **`/health` returning 200 proves a
process is listening, not that a model can answer.** A wipe, a rebuild, an upgrade and a retune all
passed on health checks alone while the stack could not actually serve a token.

Version pins live in the `$VER` hashtable at the top of `start.ps1` — that's the one place to edit them. Ports are `$swapPort` / `$webuiPort` right below it; changing `$swapPort` only affects a `.env` that doesn't exist yet, so an already-provisioned install also needs its `OPENAI_API_BASE_URL` updated by hand.

Launching is verified, not assumed. Before starting anything it warns about every model in `config.yaml` whose `.gguf` is missing (otherwise the only symptom is a `connection refused` proxy error when that model is first selected, because its `llama-server` died on spawn). After starting, it polls `/health` on both services — 20s for llama-swap, 180s for open-webui, whose first boot downloads sentence-transformers embedding weights — and bails early if a process exits. On failure it prints the tail of that component's logs (**both** `.log` and `.err.log`: llama-swap writes everything to stdout, so a stderr-only tail is empty exactly when it matters), tears down whatever did start, and exits non-zero. Re-running while the stack is up refuses rather than spawning a duplicate that loses the port bind.

Re-running after the first successful setup just relaunches those last two processes — steps 1–7 are skipped once their target files exist. To force a re-provision of a given step, delete its artifact (e.g. `open-webui-0.11.0\.venv`, `\.node-runtime`, `\build`, or a `.gguf` file) and re-run.

### Other actions

Same script, `-Action`:

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action stop
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action restart
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action autostart          # start at logon
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action autostart -Remove
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action tray
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action status -Latest
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action upgrade
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action add-model -Model '<hf repo, hf url, or .gguf url>'
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action uninstall
```

- **stop** / **restart** — kills `llama-swap`, any spawned `llama-server`, and the open-webui backend. The backend is matched by `python.exe` whose `ExecutablePath` is under the repo root, so a machine's other interpreters are never touched. `-Component swap|webui` acts on one half only — `swap` also takes down the `llama-server` processes it spawned, since they're its children. `-Component swap` exists for a genuinely wedged router, not for config edits — those are picked up by `-watch-config` without a restart. A failed health check rolls back only what that call started.
- **tray** — (re)starts just the notification-area indicator, `tray.ps1`. It comes up automatically after a successful launch; `-NoTray` suppresses that. A coloured dot polls `/health` on both services every 5s — green for both up, yellow for one, red for neither — with the currently loaded model in the tooltip (from llama-swap's `/running`). Double-click opens the chat UI; right-click gives open/logs, **Restart** and **Stop** submenus offering whole-stack or either component alone, plus a **Models** submenu listing everything in `config.yaml` — the loaded one marked, any whose `.gguf` is missing greyed out with the absent path in the tooltip, and a click on any other sending a one-token completion to swap it in (fire-and-forget, since waiting on a multi-GB load would freeze the tray). The submenu is rebuilt when the menu opens rather than on the status timer, so models added by `add-model` while the tray is running show up without a restart. It raises a balloon when the stack drops on its own, which is the point: a backend that dies unattended is otherwise invisible until you next try to use it. Icons are drawn at runtime rather than shipped as `.ico` files, and a named mutex keeps it to one instance no matter how often `start.ps1` fires it off. Exiting the tray leaves the stack running; `uninstall` kills it.
- **add-model** — fetch a model and register it, in one command. `-Model` takes whatever you have to hand: a Hugging Face repo id (`bartowski/Qwen_Qwen3-8B-GGUF`, optionally suffixed `:Q4_K_M`), a `huggingface.co` URL of either a repo or a single file (`/blob/` and `/resolve/` both work), or any other direct `.gguf` URL.

  ```powershell
  .\start.ps1 -Action add-model -Model 'Qwen/Qwen2.5-0.5B-Instruct-GGUF'
  .\start.ps1 -Action add-model -Model 'bartowski/Qwen_Qwen3-8B-GGUF:Q5_K_M' -Context 32768
  ```

  For a repo it reads the file tree from the HF API, groups the `.gguf` files into one entry per variant, and picks the one matching `-Quant` (default `Q4_K_M`). No match or an ambiguous one prints every available quant with its size and exits, so `-Quant NOPE` is a usable way to browse a repo. Split models published as `-00001-of-000NN.gguf` are grouped by their stem and downloaded as a complete set — pulling part 1 alone yields a model that won't load. Parts live in subfolders upstream but are flattened locally, since llama.cpp finds the rest from the first part.

  Downloads run through `curl.exe -L -C -` (ships with Windows 10+; `Invoke-WebRequest` has neither resume nor progress, which makes it useless for a multi-GB file), staging to `<name>.part` and renaming only on success, so an interrupted pull resumes on re-run and a partial file is never mistaken for a complete model.

  On success it appends an entry to `llamaswap\config.yaml` in the file's existing style, saving the previous version as `config.yaml.bak`. The id defaults to the file name lowercased (`-Id` overrides), context to 16384 (`-Context`). An id that already exists is left untouched rather than duplicated. `-NoConfig` downloads without touching the config. llama-swap picks the new entry up within a couple of seconds via `-watch-config`, so it is routable without a restart.
- **install-prism** — installs [PrismML's llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp) into `llama.cpp-prism\`, **alongside** the stock build, never over it. Deliberately not part of `deploy`: it's ~620 MB of downloads that only matters if you run a low-bit model, and every other model in `config.yaml` depends on the stock binary. Prebuilt Windows CUDA binaries come straight off the fork's releases (`-Latest` takes the newest, otherwise `$VER.prism`), so no CMake/CUDA-toolkit/MSVC install is needed. The Windows CUDA asset is named off the kernel build (`llama-prism-b1-…`) rather than the release tag, so the asset is matched by shape, not by tag string. Point a model at it with the `llama-server-prism` macro in `config.yaml`.

  Why it exists: ternary/low-bit GGUFs such as `prism-ml/Ternary-Bonsai-27B-gguf` store weights in ggml tensor types **42** (`Q2_0`, `Q2_g64`) or **142** (`PQ2_0`), and stock llama.cpp b10155 stops at type 41 — those models fail at load on the normal binary regardless of configuration. The repo's `dspark-*` files are a separate thing again: a speculative-decoding drafter with its own architecture (`dspark`), which stock llama.cpp rejects as an unknown architecture.

  Nothing else in the stack needs to change to use it. llama-swap spawns whatever a model's `cmd` names, `Stop-Stack` matches `llama-server.exe` by process name regardless of which directory it came from, and the tray's model list is parsed out of `config.yaml` — so start/stop/restart and the tray menu all work for prism-backed models with no extra wiring.
- **bench** — runs `bench\run.py` against the live llama-swap (see below). Anything after `-Action bench` is forwarded to the script verbatim, which is why the param block sets `PositionalBinding = $false`; without it PowerShell binds trailing values to whichever parameter is next in declaration order.
- **install-llmfit** / **suggest** — [llmfit](https://github.com/AlexsJones/llmfit) (MIT, Rust, one 24 MB exe) answers the question this stack couldn't: *which model should I get at all*. `-Action inspect` sizes a repo you already chose; `suggest` ranks known models against this machine's RAM, VRAM and memory bandwidth. They're complementary — keep both.

  ```powershell
  .\start.ps1 -Action install-llmfit          # 5 MB download, pinned in $VER.llmfit
  .\start.ps1 -Action suggest -UseCase coding
  ```

  Three filters are applied for us and are the reason the output is usable:
  - `--runtime llamacpp` — llmfit also ranks vLLM/AWQ and MLX builds, which this stack cannot load.
  - `--capability tool_use` (the `-Capability` default) — a model that can't call tools is useless for the coding-agent path, and it's the property people otherwise discover last.
  - `--no-dashboard` — **llmfit starts a background web server otherwise.** Never drop this flag.

  Rows with no `gguf_sources` are then dropped, because there'd be nothing to download. What's left carries `gguf_sources[0].repo` and `best_quant`, which are exactly `add-model`'s `-Model` and `-Quant` — so the panel's **What should I run?** table has a working Download button per row, and `-Json` is the same data for it. Speeds are llmfit's memory-bandwidth estimate, not a measurement; `-Action bench` measures. Note that its context figure is the model's *trained* maximum, not what fits here — a downloaded model still needs `-c` set (32768+ for Claude Code), which is `set-tuning` or `autotune`.
- **Vision models (`--mmproj`)** — a multimodal GGUF needs its projector passed alongside the weights: add `--mmproj "<path>.gguf"` to the model's `cmd`. `add-model` does not fetch it (it picks one file per quant, and the projector is a separate `bf16` entry that would be ambiguous), so pull it by direct URL with `-NoConfig -Name <model>-mmproj.gguf` and add the flag by hand. Give it a name tied to the model — every repo calls its own `mmproj-model-bf16.gguf`, so a generic name collides the moment a second vision model arrives. Measured for `gemma4-12b-abliterated` on this box: the projector costs **~730 MiB** of VRAM on top of the weights (10204 MiB used against gemma4-v2's 9476 at the same `-c 131072`), and it is GPU-offloaded by default. Two things follow. Context is *not* the lever for reclaiming that — 98304 measured 10222 MiB against 131072's 10204, identical within noise, because only 8 of gemma4's 48 layers grow KV. And open-webui will not offer an image button until Vision is ticked for that model under Admin → Settings → Models, since `/v1/models` carries no capability information.
- **set-tuning** — write `-c` and `-ctk`/`-ctv` for one model directly, without measuring: `-Id <model> -Context <n> -Kv <type>`. Same `Set-ModelTuning` that `autotune -Apply` uses, so a hand-picked number and a measured one land identically and neither disturbs the rest of the file. `-NCpuMoe` defaults to `-1` meaning *leave the entry's existing value alone*, which is not the same as `0` (offload nothing) — a plain `[int]` can't express "unset", and silently dropping the flag would change how an MoE model runs. Backs the panel's Models → Edit.
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
- **autostart** — write a `LocalLLM.lnk` into the user's Startup folder so the stack comes back at logon; `-Remove` takes it away. Deliberately a Startup shortcut rather than a scheduled task or a service: no admin, nothing to migrate on upgrade, and it appears in **Task Manager > Startup apps**, which is where people already go to turn a startup item off. It launches `start.ps1` (which brings the tray up with it), **not** the control panel — the panel is on demand, and what's missed after an unplanned reboot is a stack that answers on its ports. Re-running it while the stack is already up is safe: `Start-Stack`'s own double-launch guard refuses rather than spawning a second llama-swap.

  A `.lnk` that exists can still be switched off in Task Manager, which records that in `HKCU\...\Explorer\StartupApproved\StartupFolder` and leaves the file alone — so `Test-Path` on its own would report autostart as on for a machine where it will never run. `-Action status` reads both and says `set, but switched off in Task Manager > Startup apps` for that case. `uninstall` deletes the shortcut; left behind it runs a deleted `start.ps1` at every logon.

  This matters more here than on a healthy box: `.\diagnose.ps1` records 40 unexpected shutdowns, five of them after the 2026-08-11 stability fix, and nothing brought the stack back on its own.
- **status** — installed vs. pinned versions; `-Latest` adds the newest upstream release of each component (GitHub releases API + nodejs.org dist index). Also reports whether autostart is set.
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

- **One window, enforced by `EnumWindows`.** Chromium runs every `--app` window of a browser
  inside one process tree, and only one process in that tree reports a `MainWindowTitle` — so
  `Get-Process` reports one window whether there is one or seven, and the old single-instance check
  passed on that evidence and opened another every time. Seven accumulated in one session.
  `Get-PanelWindows` enumerates real top-level windows instead, filtered to browser-owned ones
  (this repo lives in `C:\LocalLLM`, so an Explorer window on that folder is *also* titled
  `LocalLLM`). `Open-PanelWindow` is now the only place a window is opened, and both launch paths
  route through it — because the server being down does **not** mean no window is open: restarting
  the server leaves the old window pointing at a dead port, and it reconnects by itself once the
  server is back. Extras found are collapsed to one rather than left for the user to close by hand.
- **The page reloads itself when the server's code changes.** Closing the panel window is a
  minimise, so one window can outlive many server restarts — and it kept running the markup and JS
  it was first served, which is why an edit to `ui.ps1` only showed up after reopening it by hand.
  Worse, and silently: `$script:csrfToken` is a fresh guid per server start, so an old window's
  token is dead after a restart and *every* `/api/*` call it makes 403s. `/api/status` now carries
  a `build` stamp (this file's mtime); the page remembers the first one it sees and calls
  `location.reload()` when the server reports a different one. During the restart itself `tick()`
  bails on the failed fetch, so the reload lands on the first tick after the server is back.
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
  The same fieldset's **Start the stack when I log in** tick box is `-Action autostart` behind
  `/api/autostart`, which reads state on every visit to the tab rather than remembering it — the
  shortcut can be deleted in Explorer or switched off in Task Manager without this page hearing
  about it. `-Install` used to *print* a `schtasks` command for the user to run by hand, which is
  exactly the friction this rule is about, and it pointed at the panel rather than the stack.
- **`127.0.0.1`, never `localhost`.** Not interchangeable on Windows: `localhost` can resolve to
  `::1` first, and llama-swap and open-webui bind IPv4 only. This repo's own logs carry
  `dial tcp [::1]:5800 ... actively refused` from exactly that mismatch. Keep the literal IP in
  every URL, env var and doc.
- **Dialogs are in-page, not `alert`/`confirm`/`prompt`.** The browser titles its own dialogs with
  the origin — *"127.0.0.1:9300 says"* — which names nothing the user recognises and gives the
  panel away as a web page. `msg` / `ask` / `askText` are promise-based replacements over one
  modal, so call sites just `await` them; `ask` takes `danger:true` to colour a destructive
  confirm, and a real verb on the button ("Delete 6.9 GB") instead of OK/Cancel.
- **The Engine tab lists the endpoints** llama-swap serves, because one port answers both the
  OpenAI and Anthropic shapes and routes by the `model` field — anything that takes a base URL and
  a model name works, and nothing in the panel used to say so.
- **Busy buttons.** Every action here starts a detached job and returns immediately, so a click had
  no visible effect until the next 3s poll — which reads as the click not registering. State comes
  from two places: `/api/jobs` reports `running` per job (from a `.pid` written next to the log,
  which is what makes "still going?" answerable at all), and an optimistic local mark covers the
  gap before the first poll sees it. A mark records *when* it was made, so a leftover log from the
  same action ten minutes ago can't clear a mark made a moment ago, and it's dropped as soon as a
  job that started after it finishes — a llama-swap restart takes ~2s and the spinner has to stop
  then, not at the generous ceiling that exists for the job which never starts. Panels re-render
  every poll, so per-button state is re-derived at render time via `B()` rather than set on the
  element; the header buttons are static markup and are synced by hand in `tick()`.
- **The Monitoring tab used to make the whole panel stutter, and it was one WMI call.** Measured:
  `/api/sensors` took **1,128-1,641 ms**, and the tab polled it on a fixed `setInterval(mon,1000)` -
  asking for work faster than it could ever be finished, so requests piled up and everything else
  (the 3s status poll, the health dot, every button) queued behind the backlog. `/api/ping` spiked
  to 730-1,158 ms.

  The cost was not nvidia-smi, which reads all twelve GPU sensors in **55 ms**. It was
  `Get-CimInstance Win32_Processor` for one number, CPU load: **1,031-1,047 ms, every call**.
  `Win32_PerfFormattedData_PerfOS_Processor` answers the same question in 275 ms. Two fixes, both
  needed: the counter swap took the endpoint to **352-495 ms**, and sampling now schedules the next
  read only when the last has returned (floor of one second), so a slow card can never build a
  queue. `/api/ping` under a live Monitoring poll is now **max 127 ms, median 1 ms**.

  Worth knowing for anything else polled here: a bad client is *not* the hazard. A half-open
  request and a client that never reads the response were both tried against this listener and
  neither delayed it past 58 ms - HTTP.sys buffers both. The hazard is always work done inside the
  request.

- **Monitoring tab** — GPU-Z's sensor layout (name, current, min, max, average) over one
  `nvidia-smi` call plus a WMI read. Min/max/average are accumulated in the page, not the server:
  the samples are already there and the server would otherwise hold per-session history for a
  window that can be closed. It polls at 1 Hz **only while that tab is in front** — this listener
  is single-threaded, and a process spawn every second in the background would crowd out
  everything else. Unreported sensors (`[N/A]` from nvidia-smi — fan speed on some cards) render
  as "not reported" rather than 0, which would drag an average toward a value never measured.
- **Models → Edit** changes `-c` and `-ctk`/`-ctv` through `start.ps1 -Action set-tuning`, the same
  `Set-ModelTuning` that `autotune -Apply` writes with. Weight quantisation (Q4_K_M vs Q6_K) is
  deliberately *not* editable here: that's a different file and means a download, not a flag.
  It used to end by asking for a llama-swap restart; with `-watch-config` it doesn't, and the only
  thing left to handle is the model that is loaded *right now* — a config reload doesn't re-spawn a
  live `llama-server` — so that one is unloaded and the dialog says so.
- **The service tick boxes are a selection, not a power switch.** They decide what Start, Stop and
  the header health dot act on. Unticking a service therefore leaves it serving on its port *and*
  drops it out of the summary, which is the one state nobody expects — an install was found with
  `useWebui: false` and open-webui answering on :8080 regardless. So a running-but-unticked service
  now reads `running (not selected)` rather than plain `running`, and unticking one that is up
  offers to stop it instead of the checkbox silently doing half of what it looks like it does.
- **Nothing slow runs inside a request, and jobs run below normal priority.** The listener is
  single-threaded, so `/api/suggest` (30–60s of llmfit scoring) and `/api/inspect` (~40s of network
  metadata reads) blocked *everything* while they ran — the 3s poll, the header health dot,
  `/api/ping`, and the activity card that exists to describe the very action in progress. The
  window froze at exactly the moment it was meant to be reassuring.

  Both now start a job and answer `{"running":true}`; the page polls until the answer is there.
  `Start-Async`/`Get-Async` key the job by the question asked, so a stale answer to a different
  question is never handed back, and `run=1` distinguishes the button press from the polls.

  That alone was not enough. With the work out of the request, a CPU-bound job still starved the
  listener: `/api/ping` measured **3–6 seconds, or outright timeouts**, while llmfit scored. One
  line — `$p.PriorityClass = 'BelowNormal'` in `Start-Job2` — took the same measurement to **max
  9 ms, median 1 ms**. Both halves are needed; either alone leaves the panel feeling hung.

- **Anything slow says what it is doing, in a card that appears on the click.** Every long action
  in this panel starts a detached job and returns immediately, so the answer to "did that work"
  used to be a disabled button and, minutes later, a log tail under Activity. A fixed card now
  names the action in the user's terms, says how long it usually takes, shows the job's latest
  output line, and carries a progress bar — a real one for downloads, which know their size, and a
  moving one for everything else, which says *alive* without claiming to know how far along it is.

  It renders from `busy()`, the same state the buttons already use, so it appears on the click that
  starts something rather than on the poll that eventually notices — and adding an action means
  adding one line to `JOBS_SAY`, not a second bookkeeping system. Dismissing it is per-action: the
  next `spin()` clears the dismissal, because silencing one job should not silence the next.

- **`-Action check-ui` parses the panel's JavaScript.** The whole page is one PowerShell
  here-string, so a JS typo is invisible to PowerShell's parser — `ui.ps1` starts, serves, the page
  renders, and every button is dead. Two such typos shipped in a single editing session: a quote
  that closed an `onclick` attribute early, and a real newline where `'
'` was meant. Node is
  already vendored for the frontend build, so the check is free. Run it after touching the page.

- **Downloads report progress, not a log tail.** `Get-BigFile` stages every weight to
  `<name>.part` and now writes `<name>.part.json` beside it carrying the expected size (the HF file
  tree already knows it; a bare `.gguf` URL doesn't, and that case renders as bytes-so-far rather
  than an invented percentage). `Get-Downloads` reads the pair, so progress is bytes-on-disk over
  total. The alternative — parsing curl's `--progress-bar` output — is carriage-return redraws on
  stderr, which is exactly why a 5 GB download used to render in Activity as `running` plus noise
  for ten minutes with no percent, no speed and no way to tell a slow download from a dead one.
  Speed and ETA are derived in the page from consecutive polls, like the Monitoring tab's min/max,
  so the server keeps no per-session history. A `.part` untouched for 90s is called out as probably
  dead, since re-running resumes it.

  The sidecar deliberately survives a failed download: a resumed run still knows what it is aiming
  at. It is deleted on success, along with the rename.

- **The Models table speaks English by default.** `-c`, `-ctk`/`-ctv` and `--n-cpu-moe` are now
  behind *Show the raw llama.cpp settings* (remembered in `localStorage`); what's left is Model,
  Size, **Conversation length** and State. Context is rendered as a band plus a word count
  (`very long ~98k words`) because a token budget means nothing to someone picking their first
  model, and words are the unit they think in. `Tune` is the button that sets it properly.

- **First run ends at a model, not at instructions.** Step 2 of the dashboard walkthrough used to
  read "open Models, paste a Hugging Face GGUF repo, press Inspect, download a variant it says fits
  your card" — five manual steps ending in the judgement call a first-time user is least equipped
  to make. It is now one button that switches to Models and runs the picker against this machine's
  own VRAM.

  Two fixes were needed under it. `--capability tool_use` was llmfit's default here because this
  stack used to sell a coding-agent handoff, which it no longer does, so it became a tick box that
  is off by default. And "install llmfit first" was an error string telling you to go and run a CLI
  action, which is the friction the panel exists to remove; `/api/suggest` returns
  `{"needInstall":true}` and the page offers the button that does it.

  **The filters are not monotonic, and an empty result is usually one of them rather than the
  hardware.** Measured across the full grid on this box:

  | use case | tool filter off | on |
  | --- | --- | --- |
  | (any) | 4 | 4 |
  | coding | 2 | 2 |
  | reasoning | 2 | 1 |
  | general | **0** | 1 |
  | chat | 2 | 3 |

  `general` with the tool filter *off* is the empty one — turning a filter **on** produces results
  where off produced none, because each filter changes llmfit's ranking rather than just narrowing
  its output. So "Nothing fits this machine with those filters" was both a dead end and misleading:
  it named the hardware for what is a filter artifact. The empty state now says so and carries the
  buttons that undo each filter, plus `-MinFit marginal` behind *Include tighter fits*. `-MinFit`
  is whitelisted server-side to `good|marginal|poor`, since it lands on a command line.

  `-Capability any` is how the filter is dropped, not `-Capability ''`: an empty string through
  `powershell -File` is a parameter with no value, and it took the whole call down as a 500.

- **Coding agents tab — the Claude Code handoff was removed from it.** Measured on this box, and
  the measurement is the whole reason: a *fresh* session (no resume, no images, plugins off, MCP
  off, `project docs: ~109 tokens`), gemma4-v2 at `-c 131072`, asked to make `load_items` skip
  blank lines in a 12-line file. It ran **219 tool calls over 29 minutes** — 101 `Bash`, 59 `Grep`,
  23 `Read`, 12 `Edit` — emitted **zero assistant text blocks**, left the file byte-identical, and
  died when the model unloaded. Every previous failure here had a harness cause (resume, images,
  plugins, `Start-Process` quoting, the attribution header); this one had none left. It does not
  converge, so the tab no longer offers a session it cannot finish.

  Second finding, worth more than the first: **`-Check` passes this same model in 33 seconds.** One
  tool call and one answer does not predict an agent loop, so the probe — and the
  `.agent-compat.json` verdict built on it — was measuring something that doesn't generalise. That
  is the third time a confident verdict about a model came from the harness rather than the model,
  and the first time it pointed the optimistic way.

  Gone with it: the model dropdown, `Test it`, the session list, `/api/sessions`,
  `/api/launch-claude`, `/api/agent-check` and `Get-ClaudeSessions`. What stays is **Delegate the
  reading** (`local-llm.ps1`), which is one request and one answer with no loop, and opencode.
  `claude-local.ps1` is still installed for `-Prompt` questions from a terminal.

## Using the local models from Claude Code

Three different things, often confused. The panel's **Coding agents** tab is the front end for all of them.

**Full local mode — `claude-local.ps1`.** Runs Claude Code entirely against llama-swap instead of Anthropic. llama-swap implements the Anthropic endpoints Claude Code needs (`v1/messages`, `v1/messages/count_tokens`), so it's just three environment variables. The script sets them **for its own process only** — putting `ANTHROPIC_BASE_URL` in the user environment would silently redirect *every* Claude Code session on the machine, which is almost never wanted.

The use case that shapes it: you are mid-project, your quota is gone, and you want to keep going on the same repo. So it validates the whole path *before* handing over, and names the part that's wrong when one is:

```powershell
.\claude-local.ps1 -Check                                   # would a handoff work right now?
.\claude-local.ps1 -Directory C:\work\api -Resume           # continue that project's session
.\claude-local.ps1 -Prompt "what does build.ps1 do?"        # one-shot, prints and exits
```

- **Context is a gate, but a softer one than this file used to claim.** Claude Code's own overhead measured **~1.1k tokens per request**, not the 15–25k asserted here before (see the measurement below). `$MIN_AGENT_CTX` is 32768 as a "you won't spend the session compacting" line — a coding session fills a window fast with file contents and tool output — not as a measured requirement; 32768 passes the probe directly. With no `-Model` the script picks the **largest context among runnable models**, deliberately not the biggest model — but ranked by compatibility first: a model `.agent-compat.json` records as failing is never picked, and a verified one beats an untested one at equal standing. Context alone was the whole ranking, and since llama-swap lists models alphabetically, that handed every session to whichever id sorted first among those tied at the top.
- **The launch says what it is waiting on.** After the cheap checks it sends one `/v1/messages` request, and *that* request is what makes llama-swap spawn `llama-server` and read the weights — so on a cold start it is where all the time goes. It printed nothing, so the console the handoff had just opened sat blank for tens of seconds and read as hung. Its timeout is 300s, matching `healthCheckTimeout` in `config.yaml`, not the 60s it was: a 27B loading from a cold page cache overran that and the launch aborted reporting a broken endpoint for a model that was simply still loading.
- **Inherited Claude Code session markers are cleared, or the handoff leaves no trace.** Claude Code stamps every process it spawns with `CLAUDE_CODE_CHILD_SESSION`, and a session carrying that marker **does not write a transcript** — it warns `Transcript saving is off - inherited CLAUDE_CODE_CHILD_SESSION marker`. The marker is inherited by anything launched from a Claude Code session, so it reaches this script, the control panel, and the terminal the panel opens. That is not an edge case: launching the handoff *from the session whose quota just ran out* is the exact scenario this exists for. And the panel's **Hand over** list is read from those `.jsonl` transcripts, so a local session started that way silently never appears in it — the next handoff cannot resume the work the last one did. `Set-LocalEnv` clears it, along with `CLAUDE_CODE_SESSION_ID` / `CLAUDE_CODE_HOST_SESSION_ID`, since a new independent session must not claim the id of the one that launched it. Cleared for this process only, like everything else there.
- **A resumed conversation containing an image cannot run on these models, and the error names nothing.** Claude Code replays the whole history on resume. These GGUFs are text-only, so llama-server answers `500 image input is not supported` and the client **retries it ten times**, because a 500 reads as transient. The session never recovers either — the images are in the history, so every turn resends them. Found the first time **Hand over** was pointed at a real conversation: this repo's own latest session, which had 11 pasted screenshots in it. Any cloud session you pasted a screenshot into has the same problem, which makes it common rather than exotic. `-SessionId` now scans that transcript for image blocks (a line scan, not a parse — these files are megabytes of tool output and the only question is whether the marker appears; 173 ms on a 12 MB transcript) and warns before handing over, pointing at **Start a session** in the same directory instead: same files, only the chat history is lost. The session id alone locates the file, so the unreversible `:`/`\`-to-`-` directory encoding never has to be reconstructed.
- **Runnable means weights on disk and an engine to run them**, not just "listed by `/v1/models`" — llama-swap lists every configured id whether or not it can start. Caught in testing: the first pick was a model with no `.gguf`, which fails as a 500 a minute later.
- **`-Check` runs Claude Code itself and makes it use a tool**, after the cheap checks pass. The tool part is not optional: an earlier probe asked only *"reply with the word ok"*, which needs no tool, so it never reached the code that builds the tool-call grammar — and it stamped a model **verified** that then died instantly on real work. A false "verified" is worse than no check. The probe now writes a scratch file with a deliberately unguessable function name and requires Claude Code to read it and return that name, under a timeout, so all three failure modes are caught: template rejection, grammar failure, and never converging. It is also the only probe that tells the truth about *which* model works — `bonsai-27b` answers *every* synthetic payload (plain, system as string, system as two blocks, `cache_control`, tools, content as blocks, a prior assistant turn, echoed `thinking`, a full `tool_use`/`tool_result` round trip — all 200, and the round trip answers correctly) and then fails Claude Code with `400 ... Jinja Exception: System message must be at the beginning`. Whatever llama-swap produces from Claude Code's real request isn't reachable from the obvious shapes, so guessing was abandoned in favour of running the real thing. Costs a model load and ~30–75s; catches both known failures.
- **The verdict is remembered** in `.agent-compat.json` (gitignored — it depends on the local build and installed models). The panel drops a model that has failed from its dropdown entirely rather than offering it with a caveat, keeps untested ones marked so a fresh install still offers something, and prefers a verified one when selecting a default.

  **A near miss is not a failure, and treating it as one cost the best model on this box.** Run against `gemma4-v2` after the rebuild, the probe came back `marmalade_spacket` — one character off — and `Set-Compat` wrote that down as a hard failure, which drops the only 131072-context model from the panel's dropdown for good. Re-run immediately afterwards, the same model answered `marmalade_sprocket` exactly: it was a sampling slip, not an incapacity. The probe exists to catch template rejection, grammar failure and never converging, and **all three of those leave no answer at all** — so an answer that names the function almost right has already proved every one of them worked. A reply still containing `marmalade` is now reported as inexact and deliberately *not* written to `.agent-compat.json`, because recording nothing is better than recording a verdict a re-run contradicts.

  Two smaller bugs in the same path, both of which made a model look worse than it was: the probe graded `stdout` and `stderr` merged, so a clean one-word answer was quoted back as ``marmalade_spacket [claude-code:unrecognized_model] {"model":"qwen2.5-0.5b…`` — Claude Code writes that benign line to stderr for **every** id llama-swap serves, since none are in its catalogue. And the quoted excerpt took `Substring(0, Min(120, $text.Length))` against the length of the *pre*-whitespace-collapse string, which throws on any answer that shortens past the cut. Grade stdout, quote stdout, measure the string you are actually cutting.
- **A real session costs far more than the probe, and `-Bare` is the lever.** Every overhead figure this file publishes for Claude Code (~1.1k tokens per request) came from `-Check`, which runs `--bare` — so all of them exclude precisely what a real session loads. Measured against this repo through `/v1/messages/count_tokens`: the `CLAUDE.md` chain alone is **13,742 tokens — 34% of `qwen3-30b-moe`'s 40960 window**, and there are 136 `SKILL.md` files on this machine whose descriptions come to another ~7,000. A handoff into this repo therefore opened with roughly 40–55% of the window already spent and reported `Context limit reached` before its first message — which reads as the model, or the handoff, being broken. It is neither.

  So the launch now **counts it and says so**, warning above 25%, and `-Bare` passes `--bare` to leave the whole lot out (`CLAUDE.md`, hooks, plugins, skills) for when the window is tight. Two things worth knowing about that measurement: `@imports` inside a `CLAUDE.md` are not followed, so the number is a floor; and the body goes over the wire as explicit UTF-8 bytes, because PowerShell 5.1 encodes a string body as Latin-1 and a `CLAUDE.md` full of em dashes then arrives as ill-formed UTF-8 — llama-swap answers **500 with an error object rather than an HTTP failure**, so it doesn't even throw, it just yields a null count. `local-llm.ps1` already carried the fix; this is the second place to need it.
- **Third-party plugins are off by default (`-NoPlugins`), and this is a correctness fix before it is a context one.** A local session was asked about this repo and answered with a July crash-triage walkthrough — MemTest86, PSU rails, `Win32_PnpController` — none of which had been mentioned. It was not confusion: the `claude-mem` plugin's `SessionStart` hook injects an index of **every past conversation on this machine**, 18,407 tokens by its own banner, and a 27B model cannot reliably tell background context from the task in front of it. `caveman` and `ponytail` add their whole style documents on top. Seven plugins are enabled here machine-wide.

  The lever is `--setting-sources project,local`, which drops the **user** settings file — that is where `enabledPlugins` lives. Deliberately *not* `--bare` or `--safe-mode`: both also throw out the project's `CLAUDE.md`, which is the thing a handoff most needs. Verified by capturing the real `/v1/messages` with a local recording listener and counting it through llama-swap's own `count_tokens`, in this repo, with the other defaults (`--strict-mcp-config` and the `-Tools` list) already applied:

  | | tokens before you type | of `gemma4-v2`'s 131072 |
  | --- | --- | --- |
  | plugins on | 44,284 | 34% |
  | **plugins off** | **29,231** | **22%** |

  The captured request confirms what goes: the project `CLAUDE.md` is still in it, `caveman`/`ponytail`/`RTK.md` are not. The global `~/.claude/CLAUDE.md` goes too, since it rides on the same settings source — that file is this machine's preferences for cloud sessions, not anything about the repo. Built-in tools and skills are untouched. `-NoPlugins:$false` restores everything.

- **`-Resume` and `-Prompt` are switches, not passthrough**, and that's not stylistic. `powershell -File script.ps1 -- --continue` fails before the script runs — `--` parses as an empty parameter name — and PowerShell prefix-matches, so claude's own `-p` binds to this script's `-Port` and dies with a type error about `Int32`. Both were live bugs in the documented invocation. `-ClaudeArgs` still exists for anything else but is only reliable from a PowerShell session.
- `-SmallModel` (default `qwen2.5-0.5b-instruct-q4_k_m`) backs `ANTHROPIC_SMALL_FAST_MODEL`, which Claude Code uses for background work like conversation titles. Pointing it at the main model makes every trivial call trigger a multi-GB swap. If it isn't configured the script warns and falls back to the main model rather than refusing to start — it's a convenience, not a requirement.
- **`CLAUDE_CODE_ATTRIBUTION_HEADER=0`, passed via `--settings`. This is the single biggest thing on this page.** Claude Code injects an `x-anthropic-billing-header` string as a text block at the *front* of the system prompt, and its `cch=` segment changes on every request. llama.cpp's prompt cache matches on a prefix, so a prefix that differs every turn means the cache never hits and the whole 20k+ token system prompt is reprocessed from scratch **every turn**. Measured here, same model and same task, before and after: turns of `3m58s, 3m54s, 37s, 31s, 31s, 13s, 9s` became `2.1s, 1.8s, 1.6s, 1.7s, 1.4s, 2.5s`. Every earlier conclusion in this repo about local models being "too slow for agentic work" was really this.

  It **must** be a settings file — `export CLAUDE_CODE_ATTRIBUTION_HEADER=0` is ignored when routing through `ANTHROPIC_BASE_URL`. `New-SessionSettings` writes it per run and passes `--settings`, rather than editing `~/.claude/settings.json`, for the same reason this script sets `ANTHROPIC_BASE_URL` for one process only.
- **`-Tools` excludes Claude Code's `Workflow` tool**, and that's a workaround for a hard llama.cpp limit, not a preference. `Workflow` declares its `script` parameter with `maxLength: 524288`; llama.cpp turns a `maxLength` into a GBNF repetition `char{0,N}`, and 524288 blows the repetition ceiling its own grammar parser enforces. The entire tool-call grammar then fails to compile and every request 400s with `Failed to initialize samplers: failed to parse grammar` — which reads as a broken model when no model is involved. `--disallowedTools` does **not** help: it withholds permission but still sends the schema. Still open upstream ([#25746](https://github.com/ggml-org/llama.cpp/issues/25746), [#25923](https://github.com/ggml-org/llama.cpp/issues/25923), [#25895](https://github.com/ggml-org/llama.cpp/issues/25895)), so upgrading llama.cpp does not fix it. Pass `-Tools ''` to check whether it has been.
- **Model tiers are all mapped.** Claude Code fires background requests at `claude-haiku-4-5-*` for titles and tool checks — dozens before your first real turn. Unmapped they reach llama-swap as an unknown model, so `ANTHROPIC_DEFAULT_HAIKU_MODEL` points at the small model and `SONNET`/`OPUS` at the main one. Related: Claude Code bursts concurrent requests, and a single-slot llama-server can segfault under that — the `-np 1` already in the macro is what keeps one request per slot.
- **`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is set from the model's own `-c`.** Claude Code doesn't recognise these model ids, so it assumes a **200k** window and runs auto-compact against that assumption while the model behind it holds 65536. Measured with it unset: a one-word question became **84 requests over 27 minutes** and never answered, with single responses of 3.6 MB — the client kept feeding back a history the model couldn't hold, so it never converged. With it set: 14 requests. Same failure the stack already documents for open-webui and continue.dev — the client can only prune if it knows the real budget — and the number is parsed straight out of `config.yaml`.

### What a local model can and can't do as an agent — measured

On this box, with every fix above in place:

| model | result |
| --- | --- |
| `qwen3-30b-moe` at `-c 40960` | **works** — real tool call, right answer, 74s. `--n-cpu-moe 14`, 40.3 tok/s, 10648 MiB. |
| `qwen3-30b-moe` at `-c 32768` | **works** — 110s, `--n-cpu-moe 13`, 29.1 tok/s. |
| `gemma4-v2` at `-c 131072` | **works** — 9476 MiB, 2535 MiB free, loads in 6s. The window that makes a real session viable. |
| `gemma4-v2` at `-c 65536` | **works** — 33s. |
| `bonsai-27b` at `-c 65536` | **works.** |

**Every model on this box works.** Worth stating loudly, because each of the three was at some point confidently declared incapable during development — one for "not converging", one for a "wrong answer", one for a chat-template rejection that looked completely unambiguous. All three verdicts were harness bugs. `bonsai-27b`'s `Jinja Exception: System message must be at the beginning` was the most convincing of them, and it disappeared once the probe stopped dragging the user's own `CLAUDE.md` and `SessionStart` hook output into the request.

### Context is the constraint, and gemma4 is why it's solvable

The handoff kept dying with `Context limit reached` before its first message, and the instinct — *get a model with a bigger window* — is right but points at the wrong model. `llmfit -Action suggest` offers 7B coders at a **trained** 32768; that is worse than what is already installed. The window was here all along:

| `-c` | VRAM used | free | `CLAUDE.md` as % of window |
| --- | --- | --- | --- |
| 40960 (`qwen3-30b-moe`) | 10648 MiB | — | **33.5%** |
| 65536 (`gemma4-v2`, the old default) | — | — | 21.0% |
| **131072 (`gemma4-v2`, now)** | **9476 MiB** | **2535 MiB** | **10.5%** |
| 196608 (`gemma4-v2`) | 10213 MiB | 1798 MiB | 7.0% |

`gemma4-v2` was pinned at 65536 as a speed/headroom choice, never a limit. Measured here, **65536 more tokens of context cost only 737 MiB** — 5 of every 6 gemma4 layers use a 1024-token sliding window, so only 8 of its 48 layers grow KV at all. 196608 loads and runs, but the config's own budget note records the Windows desktop using 970–1463 MiB, and 1798 MiB of headroom does not survive that with a browser open. **131072 is the number**: it triples the room for actual work versus 40960, with a margin that holds.

The lesson generalises past this box: on a 12 GB card the useful lever was **attention architecture, not parameter count or a download**. Sliding-window models buy context at a fraction of what full-attention models charge — `qwen3-14b` costs ~7x more per token than gemma4 for exactly this reason, and it is why the answer to "I need a bigger window" was a one-line config edit rather than a new model.

One caveat found while measuring: gemma4 logs `KV cache shifting is not supported for this context, disabling KV cache shifting`, so `--context-shift` — this stack's safety net against a hard error past `-c` — **does not apply to it**. That makes `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (set from the model's own `-c`) load-bearing rather than merely helpful: the client pruning first is the only thing standing between a long session and a hard failure.

### How much context Claude Code actually costs — measured

Counted with llama-swap's own `/v1/messages/count_tokens` against payloads captured from a real session through a recording proxy:

| request | tokens |
| --- | --- |
| background/housekeeping (to the small model) | **379** |
| main model, first real request (3 tools, 1 message) | **1,091** |

**~1.1k of fixed overhead per request, not the 15–25k this file used to claim.** The API is stateless so it *is* re-sent every turn, but at that size it's noise: `-c 40960` leaves ~39k for conversation history and file contents, which is what actually consumes a window.

"32K is the floor" is widely repeated and **is not supported by anything measured here** — 32768 was tested directly and passed. This file previously asserted the opposite on the strength of a `Prompt is too long` that came from the word-split-prompt bug below: the model looped, history piled up, and the overflow was read as a property of Claude Code.

Not measured: the overhead with a user's own `CLAUDE.md`, plugins and MCP servers loaded. The probe passes `--bare` to stay reproducible across machines, so these numbers are a floor, not a typical session. Measure it before relying on a small window for long sessions.

Three lessons, all of them about the harness rather than the models:

1. **Model choice is not just about context**, which is why the panel offers a dropdown rather than auto-picking: the auto-pick sorts on `-c` and cannot know any of the above.
2. **Three separate harness bugs each produced a confident, wrong "this model can't do agentic work" verdict**, and all three failed in the direction of blaming the model:
   - the probe asked a question needing no tool, so it never reached the code that breaks — and stamped a model *verified* that failed instantly on real work;
   - the probe inherited the user's own `CLAUDE.md`, plugins and hooks, so a `SessionStart` hook's output came back as the model's answer (fixed with `--bare`);
   - `Start-Process -ArgumentList` does **not** quote elements containing spaces, so the prompt arrived word-split — Claude Code got `-p "Read"` plus five stray arguments, and models sensibly replied "which file did you mean?". Proved by passing the same array to a script that prints `$args`.

   Every one of these failed in the same direction: blaming the model. A local model producing odd behaviour is the *expected* answer, which is exactly what makes it the dangerous one — it explains any result, so it gets accepted without the evidence a surprising claim would need. Before concluding a model can't do something here, reproduce it outside this harness.

`bonsai-27b` is worth understanding before trusting `-Check`. Its chat template rejects Claude Code's real payload, but **every synthetic shape passes** — plain user, system as string, system as a block array, tools, content as a block array, a prior assistant turn, and a complete `tool_use`/`tool_result` round trip were all tried and all returned 200. So whatever ordering llama-swap produces from Claude Code's actual request isn't reproducible from the obvious payloads, and `-Check` reports Ready for a model that then fails. **`-Check` is necessary, not sufficient** — it proves the endpoint and the model answer, not that a session will hold together.

The plumbing is sound and tool-calling is correctly formatted; what fails is a multi-step agent loop with the whole toolset in play. Treat the handoff as **usable for direct questions and one-shot work, not yet for unattended multi-step editing** — and don't read a long run as a wiring bug, because it isn't one. If a run stalls, `logs\llama-swap.log` shows a line per `/v1/messages` with its duration and response size; a turn count climbing past ~10 on a trivial task is the loop failing to converge, not a hang.

**Local agent — `local-agent.ps1`.** opencode driving a local model, with Anthropic not involved at all. See its own notes for what a local 27B does and doesn't get right about editing files.

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
