# Model Pilot

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078d4)
![No Docker](https://img.shields.io/badge/Docker-not%20required-lightgrey)

**One Windows desktop app to install, connect and run your local AI stack.**
Model Pilot brings the inference engine, model router, chat interface and hardware-fit recommender
together so you can use local models without wiring the components together yourself. You choose what
to download and can tune it for this PC. Inference and chat history stay local by default; runtime and
model downloads come from their upstream sources.

**The installable control-panel product targets Windows 10/11 desktop only.** PowerShell itself is cross-platform, and parts of the backend include macOS Apple Silicon support; that does not make the Windows installer, panel or tray a supported macOS product. Phones and tablets are not supported targets.

**Install it, double-click one file, press Start.** The installer is per-user by default: no admin
rights, no PATH changes, and a standard per-user Windows uninstall entry.

The setup EXE contains the launcher and project scripts only, not the large runtime or model
weights. The stack downloads its dependencies the first time you press **Start**.

<!-- SCREENSHOT: the control panel's Dashboard tab, full window.
     Suggested filename: docs/img/dashboard.png  (~1040x720, the panel's native size) -->
![The Model Pilot control panel](docs/img/dashboard.png)

---

## How to install it

### 1. Download and run the setup EXE

> **Release status:** `0.1.13-localqa` is an unsigned, unpublished Model Pilot QA candidate.
> Do not redistribute it; wait for an approved public release.

When an approved release is available, download `Model-Pilot-Setup.exe` and `SHA256SUMS.txt` from
the project's Releases page and run the installer. It installs into your user's Local AppData by
default and offers Start Menu and optional Desktop shortcuts. The checksum can detect a damaged or
altered download only if you obtain the checksum from a trusted release page; it does not verify the
publisher or replace code signing.

Upgrades from the earlier LocalLLM-branded build keep the existing `%LOCALAPPDATA%\LocalLLM`
installation folder in place so models, configuration and chat data do not need to move. The
shortcuts and installed-app display use the **Model Pilot** name.

The installer does not bundle the runtime; pressing **Start** in the panel downloads and sets up
the stack on first launch.

To build the installer yourself, install **Inno Setup 6** and run this from the repository root:

```powershell
ISCC.exe installer\ModelPilot.iss
```

The generated `installer\output\Model-Pilot-Setup.exe` is the distributable setup file.

### 2. Launch Model Pilot

Use the Start Menu shortcut (or the optional Desktop shortcut). The launcher opens the control
panel, where you can press **Start** to download and install the runtime.

The first setup downloads about **850 MB** and unpacks to roughly **4 GB** on disk, most of which
is the chat UI's Python dependencies. Budget **20-30 minutes** on a normal connection. You only
ever do this once.

You don't need Python, Node, Docker, WSL, or a package manager. If they're missing, it fetches its
own private copies into the install folder. It never touches anything you already have installed.

**Then pick a model.** Go to **Models** and press **Find models**. Recommendations show llmfit's
hardware-fit rating, quantisation, approximate download size, estimated speed and trained context.
These are estimates, not a promise of a successful load or benchmark; the chosen context may need
tuning for this PC. If there are no matches, relax a filter or scan for weights you already have.
The recommender is powered by optional **llmfit** (~5 MB to download). If it is missing, the panel offers to install it; chat and scanning existing files work without it.

To use existing weights, go to **Models → Find models on your drive**. Choose their folder and
press **Scan folder**. **Add to Models** adds a config entry at the existing path; it does not copy,
move or delete the file. Registered files are hidden from the scan. A filename that would duplicate
an existing model id is shown as a conflict instead of being added. If the folder is missing or
cannot be read, the panel reports an incomplete scan and asks you to choose an available folder or
check its access permissions; it does not present that scan as complete. New downloads go to the
selected folder.

When a model is present and llama-swap is running, Home offers **Test a real response**. It sends one
short completion, may cold-load the model and shows the reply and any failure. This proves only that
inference returned text; it does not assess accuracy or usefulness. Use **Open chat** to judge the
model on your own tasks.

**Home** summarizes service and hardware status. Long-running work appears under **Activity**.
Troubleshooting details, local tools and sensor monitoring are grouped under **More** so the main
navigation stays focused on everyday tasks.

<!-- SCREENSHOT: the Models page showing recommendations and the model-folder scanner.
     Suggested filename: docs/img/models.png -->
![Choosing and managing models](docs/img/models.png)

### Every time after that

Launch Model Pilot from the Start Menu or Desktop shortcut and press **Start** again. It skips
everything that's already installed, so it just brings the servers up — a few seconds, not minutes.
Closing the panel window doesn't shut anything down. It minimises to an icon in the system tray and
your models keep serving. To actually stop everything, right-click that tray icon and choose Stop.

### If something goes wrong

Downloads and start-up write to the `logs` folder, and the **Activity** tab shows the same output
live. Uninstalling the setup removes its launcher and shortcuts, but deliberately leaves the stack,
including an optional ComfyUI installation, model weights, configuration, chats and logs in place.
To remove downloaded components and local
chat data, use **Settings → Remove parts of the install → Everything** in the panel. That reset also
removes optional ComfyUI models, inputs, outputs and user settings. The model-weight checkbox applies
only to `llama.cpp\models` inside this Model Pilot installation; a model folder you selected elsewhere
is always kept.

### Getting help

This repository is currently private, so its issue tracker is available only to collaborators. The
local QA candidate is not for end-user distribution. For general support or release questions, email
[modelpilot.app@gmail.com](mailto:modelpilot.app@gmail.com). Include the app version, Windows
version, steps to reproduce and exact error. Review logs or diagnostics before attaching them: they
can contain computer name, hardware and drive details, event-log text, model names and local paths.
Redact anything identifying; do not attach weights, secrets or chat history unless you have
deliberately checked and need to share it. For security vulnerabilities, follow
[SECURITY.md](SECURITY.md) instead of posting exploit details publicly.


---

## Why this exists

Running a local model is easy. Running one *well* is a pile of fiddly, undocumented decisions —
which quantisation fits your card, how much context you can afford, how many expert layers to
push to the CPU, why the model that worked yesterday now returns HTTP 400. This does those for
you, and it measures rather than guesses.

- **Sizes models to your actual hardware.** Tells you which ones will run *before* you spend an
  hour downloading one that won't.
- **Tunes by measurement.** `-Action autotune` loads the model and times it. On the development
  machine, that setting was the difference between **15 and 47 tokens/sec** — the same model,
  the same card, one flag.
- **Never leaves you guessing.** Anything slow says what it is doing, how long it usually takes
  and how far along it is — a real percentage for downloads, which is the step you spend the most
  time watching.
- **Verifies instead of assuming.** Launches are health-checked and model configs are validated
  against what is actually on disk, so a broken entry is caught before it becomes a connection
  error mid-chat.

## What you need

- **Windows 10 or 11.**
- **An NVIDIA GPU is recommended for useful speed.** CPU-only mode works but is slow. Which models
  fit depends on available VRAM, quantisation, context length and the rest of this PC; there is no
  single VRAM threshold that guarantees a particular model.
- **Disk:** about 4 GB for the stack once installed, plus model weights (2-20 GB each).
- **Nothing needs to be preinstalled.** No Python, no Node, no Docker, no WSL, no package manager,
  no admin rights. Python arrives as a private copy inside the install folder (via
  [uv](https://github.com/astral-sh/uv)); Node is fetched the same way and deleted once the frontend
  is built. Your existing Python and Node are never touched. **Settings → Remove parts of the
  install** removes downloaded runtime and local state; model weights in this install are kept unless
  you select the checkbox. Model folders outside the install are always preserved.

## Offloading heavy reading from Claude Code

Keep Claude Code on the cloud model and hand only the token-heavy reading to a local one, so a
200,000-token log costs nothing against your quota:

```bash
powershell -ExecutionPolicy Bypass -File .\local-llm.ps1 -Prompt "List every distinct error and its frequency" -File logs\app.log
```

Only the answer comes back. The **Tools** tab in the panel does the same thing with two boxes.

**Running whole Claude Code sessions on a local model is not offered.** It was, and it was removed
after measuring it: on a 12 GB card, a fresh session asked to make a one-line change to a 12-line
file ran **219 tool calls over 29 minutes**, never replied, and changed nothing. The plumbing is
fine — single requests and single tool calls work — but a model this size does not converge on a
multi-step agent loop, and a button that cannot finish is worse than no button. `claude-local.ps1`
is still in the repo for one-shot questions; [CLAUDE.md](CLAUDE.md) has the measurements, and the
client bugs found along the way.

## Monitoring

A GPU-Z style sensor readout — clocks, temperature, power, VRAM, and the memory the inference
process is actually holding — sampled once a second while the tab is open, and not at all while
it isn't.

<!-- SCREENSHOT: the Monitoring tab after it has been open long enough to have min/max/avg values.
     Suggested filename: docs/img/monitoring.png -->
![Sensor readout](docs/img/monitoring.png)

## If you need a terminal

For normal use, manage Start, Stop and Restart from Home or the tray menu. Direct CLI lifecycle commands are deprecated for end users; the underlying actions remain as internal adapters for the panel/tray and for compatibility. The terminal is for advanced maintenance and model operations:

```bash
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

```bash
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action add-model -Model 'unsloth/gpt-oss-20b-GGUF:Q4_K_M'
```

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action test-model -Id 'your-model-id'
```

This sends a real short completion through llama-swap, may load the weights, and fails with a
specific message if the service, model entry or weights are unavailable.

Other maintenance actions include `status`, `upgrade`, `autotune`, `bench`, `check-config`, `check-ui`, `suggest`, `test-model`, `install-llmfit`, `install-prism`, `autostart` and `uninstall`. `status` compares installed and pinned versions; `check-config` validates model configuration. Use the panel for everyday lifecycle control.

To have the stack come back by itself after a restart, tick **Start the stack when I log in** in
Settings, or:

```bash
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action autostart
```

That drops a shortcut in your Startup folder — so it needs no admin rights, and you can switch it
off again in Task Manager > Startup apps like any other startup item. It starts llama-swap, the
chat UI and the tray indicator; the control panel stays on demand. `-Action autostart -Remove`
undoes it, and `uninstall` removes it for you.

## Using the models from other tools

llama-swap serves the OpenAI and Anthropic API shapes on the same port and routes by the `model`
field, so anything that takes a base URL and a model name works — continue.dev, Zed, aider, a
shell script. The **Engine** tab lists every endpoint with the model ids that are ready to use.

```
http://127.0.0.1:9292/v1/chat/completions    OpenAI shape
http://127.0.0.1:9292/v1/messages            Anthropic shape
```

Use the literal IP, not `localhost` — on Windows `localhost` can resolve to `::1` first, and these
servers bind IPv4 only.

## Things worth knowing before you run it

- **The control panel has no password.** It binds `127.0.0.1` and rejects cross-origin requests, so
  websites you visit can't drive it — but any program running as you on this machine can. It
  assumes a single-user desktop. See [SECURITY.md](SECURITY.md).
- **`bench\run.py` can execute code the model writes**, to grade whether that code works. It asks
  first and skips those tasks unless you agree; nothing runs code because you started a benchmark.
- Model Pilot does not add a telemetry or analytics service. First-run setup and optional installs
  contact component distributors and package indexes to fetch runtimes and dependencies; model
  and embedding weights come from their upstream providers. Default inference routes to the local
  llama-swap service. If you configure a remote provider or extension, that provider may receive
  the requests you send through it. See [SECURITY.md](SECURITY.md) for the network and trust
  boundaries.

## Where things live

```
llama.cpp\          inference engine + llama.cpp\models\*.gguf   (downloaded)
llamaswap\          the router, and config.yaml - one entry per model
open-webui-*\       the chat UI                                  (downloaded)
logs\               everything's output, plus a log per download
start.ps1           the CLI that does all the work
ui.ps1              the control panel
```

`llamaswap\config.yaml` is the one file you'd ever hand-edit — it defines each model's context size
and how much of it goes on the GPU. It's generated on first run from `config.example.yaml`.

## Licence and contributing

MIT — see [LICENSE](LICENSE). The name is a separate matter: fork it freely, but give your fork its
own name ([NAMING.md](NAMING.md)).

Nothing third-party is redistributed here; every component is downloaded from its own release page
at a pinned version. One of those licences has a clause people miss — see
[THIRD-PARTY.md](THIRD-PARTY.md). Model weights carry their own separate terms.

[CONTRIBUTING.md](CONTRIBUTING.md) has the ground rules that aren't guessable from the code, and
[CLAUDE.md](CLAUDE.md) explains how the whole thing fits together — it's long, and it's the good
kind of long: nearly every paragraph exists because something failed and the reason wasn't obvious.
