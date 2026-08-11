# LocalLLM

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078d4)
![No Docker](https://img.shields.io/badge/Docker-not%20required-lightgrey)

**Run large language models on your own Windows machine — and hand your Claude Code sessions over
to them when your quota runs out.** Nothing leaves the box.

Download, extract, double-click. No Docker, no WSL, no Python or Node install, nothing added to
your PATH or your registry.

<!-- SCREENSHOT: the control panel's Dashboard tab, full window.
     Suggested filename: docs/img/dashboard.png  (~1040x720, the panel's native size) -->
![The LocalLLM control panel](docs/img/dashboard.png)

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
- **Hands Claude Code to a local model**, resuming the exact conversation you were in, with four
  non-obvious client bugs already worked around.
- **Verifies instead of assuming.** Launches are health-checked, configs are validated against
  disk, and a model is only offered to a coding agent after it has actually driven one.

## Getting started

1. **Download** this repo as a ZIP (green **Code** button → *Download ZIP*) and extract it.

   Extract somewhere plain, like `C:\LocalLLM`. Avoid `C:\Program Files (x86)\...` — it needs
   admin rights to write to, and the parentheses in the path break the chat UI's JavaScript build.

2. **Double-click `LocalLLM.cmd`.**

The panel opens and walks you through three steps.

| | |
| --- | --- |
| **1. Press Start** | Downloads the inference engine, the router and the chat UI (~1.5 GB). Several minutes, once. |
| **2. Add a model** | Press **Suggest models** — it ranks known models against your actual RAM, VRAM and memory bandwidth and lists only ones that can call tools, each with a Download button. Already know what you want? Paste its Hugging Face GGUF repo and press **Inspect**. |
| **3. Open the chat** | The **Open** button next to open-webui. Your first message loads the model, which takes a few seconds. |

<!-- SCREENSHOT: the Models tab with "Suggest models" results showing, so the fit/speed columns are visible.
     Suggested filename: docs/img/models.png -->
![Choosing a model that fits](docs/img/models.png)

Closing the panel window doesn't stop anything — it minimises to a tray icon and the models keep
serving. Right-click the tray icon to stop the stack for real.

## What you need

- **Windows 10 or 11.**
- **An NVIDIA GPU is strongly recommended.** The installer picks a CUDA build when it finds one and
  falls back to CPU-only otherwise, which works but is slow. 8 GB of VRAM runs a useful model;
  12 GB runs a good one.
- **Disk:** about 3 GB for the stack, plus model weights (2–20 GB each).
- Everything else — Python, Node — is fetched into the install folder. Nothing is installed
  system-wide, and your existing Python and Node are never touched.

## Running out of Claude quota mid-project

Claude Code can be pointed at a model running here instead of at Anthropic, on the same repo, with
your files and history intact and nothing uploaded.

The **Coding agents** tab lists your recent Claude Code projects — read from Claude Code's own
session history, so there's no path to remember — and **Hand over** reopens that exact
conversation on a local model.

<!-- SCREENSHOT: the Coding agents tab showing the session list with Hand over buttons.
     Blur or crop the paths if any are private. Suggested filename: docs/img/coding-agents.png -->
![Handing a project to a local model](docs/img/coding-agents.png)

Only that process is redirected; your normal `claude` sessions still go to Anthropic. Press
**Test it** before you rely on a model — it runs Claude Code for real, makes it use a tool, and
remembers the answer. A model that happily answers a chat message can still fail the moment tools
are involved, and the tab only offers ones that have actually passed.

**What to expect.** Measured here, a 30B sparse-MoE model read a file with a tool and answered
correctly in 74 seconds at about 40 tokens/sec. Slower than the hosted model, and it won't carry a
long unattended refactor — but it keeps a session moving.

Getting there meant working around four things that are not the model's fault, and are documented
in [CLAUDE.md](CLAUDE.md) so you don't have to rediscover them:

- Claude Code injects a per-request billing header **at the front of the system prompt**, which
  invalidates llama.cpp's prompt cache and re-processes the entire context every turn. Turn times
  went from **3m58s to 2.1s** once it was disabled.
- Its built-in `Workflow` tool declares `maxLength: 524288`, which llama.cpp turns into a GBNF
  repetition that blows its own grammar parser — every request 400s, and it reads like a broken
  model.
- It assumes a 200k context window for models it doesn't recognise, and compacts against that.
- Its background requests go to a Haiku model id that doesn't exist locally unless you map it.

The other direction works too: keep Claude Code on the cloud model and hand only the token-heavy
reading to a local one, so a 200k-token log costs nothing against your quota.

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
`suggest`, `install-llmfit`, `install-prism` and `uninstall`. `-Action status` shows what's
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
