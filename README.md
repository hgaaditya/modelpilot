# LocalLLM

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078d4)
![No Docker](https://img.shields.io/badge/Docker-not%20required-lightgrey)

**Run large language models on your own Windows machine, without assembling the stack yourself.**
One download instead of four, and it picks the model, the quantisation and the settings to match
your card. Nothing leaves the box.

**Unzip it, double-click one file, press Start.** No Docker, no WSL, no Python or Node to install
first, no admin rights, and nothing added to your PATH or registry.

<!-- SCREENSHOT: the control panel's Dashboard tab, full window.
     Suggested filename: docs/img/dashboard.png  (~1040x720, the panel's native size) -->
![The LocalLLM control panel](docs/img/dashboard.png)

---

## How to install it

There is no installer and nothing to set up first. Three steps.

### 1. Download and unzip it

Click the green **Code** button at the top of this page, choose **Download ZIP**, and unzip it.

Put it somewhere simple like `C:\LocalLLM` or `D:\LocalLLM`. **Don't** put it in
`C:\Program Files` — Windows makes that folder read-only without admin rights, and the brackets in
`Program Files (x86)` break part of the build.

### 2. Double-click `LocalLLM.cmd`

That's the only file you need to touch. A window opens — this is the control panel, and it's how
you'll do everything from here on.

### 3. Press the **Start** button

This is the bit that installs everything: the engine that runs the models, the router that loads
them on demand, and the chat page. It's about **1.5 GB** and takes a few minutes on a normal
connection. You only ever do this once.

You don't need Python, Node, Docker, WSL, or a package manager. If they're missing, it fetches its
own private copies into its own folder. It never touches anything you already have installed, never
asks for admin, and never adds anything to your PATH or registry.

**Then pick a model.** Go to the **Models** tab and press **Suggest models** — it looks at your
actual RAM, graphics card and memory speed and shows only models that will genuinely run well, each
with a Download button. When one has finished downloading, open the chat from the **Open** button
on the Dashboard.

<!-- SCREENSHOT: the Models tab with "Suggest models" results showing, so the fit/speed columns are visible.
     Suggested filename: docs/img/models.png -->
![Choosing a model that fits](docs/img/models.png)

### Every time after that

Double-click `LocalLLM.cmd` and press **Start** again. It skips everything that's already
installed, so it just brings the servers up — a few seconds, not minutes.

Closing the panel window doesn't shut anything down. It minimises to an icon in the system tray and
your models keep serving. To actually stop everything, right-click that tray icon and choose Stop.

### If something goes wrong

Nothing is hidden. Every download and every start-up writes to the `logs` folder, and the
**Activity** tab in the panel shows the same output live. To remove it completely, run
`start.ps1 -Action uninstall` — because nothing was installed system-wide, that really does remove
all of it. Deleting the folder works too, though it leaves the downloaded models behind unless you
delete those as well.

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
- **An NVIDIA GPU is strongly recommended.** The installer picks a CUDA build when it finds one and
  falls back to CPU-only otherwise, which works but is slow. 8 GB of VRAM runs a useful model;
  12 GB runs a good one.
- **Disk:** about 3 GB for the stack, plus model weights (2–20 GB each).
- **Nothing needs to be preinstalled.** No Python, no Node, no Docker, no WSL, no package manager,
  no admin rights. Python arrives as a private copy inside the install folder (via
  [uv](https://github.com/astral-sh/uv)), Node is fetched the same way and deleted once the
  frontend is built. Your existing Python and Node are never touched, and `-Action uninstall`
  removes all of it because none of it was installed system-wide.

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

## If you prefer a terminal

The panel is a face on `start.ps1`, which does everything the panel does and more:

```bash
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

```bash
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action add-model -Model 'unsloth/gpt-oss-20b-GGUF:Q4_K_M'
```

`-Action` also takes `stop`, `restart`, `status`, `upgrade`, `autotune`, `bench`, `check-config`,
`check-ui`, `suggest`, `install-llmfit`, `install-prism` and `uninstall`. `-Action status` shows what's
installed against what's pinned; `-Action check-config` validates your model config before you
restart anything.

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
- **Models are downloaded from Hugging Face.** Nothing else phones home — no telemetry, no
  analytics. The only other outbound requests are release-version lookups when installing or when
  you press *Check for updates*.

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
