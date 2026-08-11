# LocalLLM

Run large language models on your own Windows machine, with a chat UI in the browser and nothing
leaving the box. It glues together three things — [llama.cpp](https://github.com/ggml-org/llama.cpp)
for inference, [llama-swap](https://github.com/mostlygeek/llama-swap) to load and unload models on
demand, and [Open WebUI](https://github.com/open-webui/open-webui) for chat — and adds a control
panel that installs, configures and monitors all of it.

## Getting started

1. Download this repo as a ZIP (green **Code** button → *Download ZIP*) and extract it.

   Extract it somewhere plain, like `C:\LocalLLM`. Avoid `C:\Program Files (x86)\...`: it needs
   admin rights to write to, and the parentheses in the path break the chat UI's JavaScript build.

2. Double-click **`LocalLLM.cmd`**.

The panel opens and walks you through three steps:

| | |
| --- | --- |
| **1. Press Start** | Downloads the inference engine, the router and the chat UI (~1.5 GB). Several minutes, once. |
| **2. Add a model** | On the **Models** tab, press **Suggest models** — it ranks known models against your actual RAM, VRAM and memory bandwidth and lists only ones that can call tools, each with a Download button. If you already know what you want, paste its Hugging Face GGUF repo and press **Inspect** to see which quant fits. |
| **3. Open the chat** | The **Open** button next to open-webui. Your first message loads the model, which takes a few seconds. |

Closing the panel window doesn't stop anything — it minimises to a tray icon, and the models keep
serving. Right-click the tray icon to stop the stack for real.

## What you need

- Windows 10 or 11.
- An NVIDIA GPU is strongly recommended — the installer picks a CUDA build when it finds one, and
  falls back to CPU-only otherwise, which works but is slow. 8 GB of VRAM runs a useful model;
  12 GB runs a good one.
- Disk: about 3 GB for the stack, plus whatever the model weights need (2–20 GB each).
- Everything else — Python, Node — is fetched into the install folder. Nothing is installed
  system-wide, and your existing Python and Node are never touched.

## Running out of Claude quota mid-project

Claude Code can be pointed at a model running here instead of at Anthropic, on the same repo, with
your files and session history intact and nothing uploaded. The panel's **Coding agents** tab has
the command ready to copy, and a **Test the handoff now** button that loads a model and calls the
real endpoint — worth pressing *before* you need it.

```bash
powershell -ExecutionPolicy Bypass -File .\claude-local.ps1 -Directory C:\your\project -Resume
```

Only that process is redirected; your normal `claude` sessions still go to Anthropic. Check it
first with `.\claude-local.ps1 -Check`, which runs Claude Code for real against the model and
names what's wrong rather than failing later inside a session.

Claude Code's own overhead is small — measured at about 1,100 tokens per request — so a 32k model
is fine to start with. What fills a window is file contents and tool output, so more context means
fewer interruptions to compact, not a different capability.

**What to expect.** Measured here, a 30B sparse-MoE model read a file with a tool and answered
correctly in 74 seconds, at about 40 tokens/sec. It is slower than the hosted model and it will not
carry a long unattended refactor, but it keeps a session moving.

Press **Test it** on the Coding agents tab before you rely on a model. It runs Claude Code for
real, makes it use a tool, and remembers the answer — a model that merely responds to a chat
message can still fail the moment tools are involved, and the tab only offers ones that have
actually passed.

The other direction also works: keep Claude Code on the cloud model and hand only the token-heavy
reading to a local one with `local-llm.ps1`, so a 200k-token log costs nothing against your quota.

## If you prefer a terminal

The panel is a face on `start.ps1`, which does everything the panel does and more:

```bash
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

```bash
powershell -ExecutionPolicy Bypass -File .\start.ps1 -Action add-model -Model 'unsloth/gpt-oss-20b-GGUF:Q4_K_M'
```

`-Action` also takes `stop`, `restart`, `status`, `upgrade`, `autotune`, `bench`, `check-config`
and `uninstall`. `-Action status` shows what's installed against what's pinned; `-Action
check-config` validates your model config before you restart anything.

## Things worth knowing before you run it

- **The control panel has no password.** It binds to `127.0.0.1` and rejects cross-origin requests,
  so websites you visit can't drive it — but any program running as you on this machine can. It
  assumes a single-user desktop.
- **`bench\run.py` can execute code the model writes**, in a temp directory under a timeout, in
  order to grade whether that code works. It asks first, and skips those tasks unless you say yes;
  nothing runs code because you happened to start a benchmark. The rest of the benchmark — JSON,
  regex, long-context recall — never executes anything.
- **Models are downloaded from Hugging Face** over the network. Nothing else phones home; the
  version checker queries GitHub only when you press *Check for updates*.

## Where things live

```
llama.cpp\          inference engine + llama.cpp\models\*.gguf   (downloaded)
llamaswap\          the router, and config.yaml - one entry per model
open-webui-*\       the chat UI                                  (downloaded)
logs\               everything's output, plus a log per download
start.ps1           the CLI that does all the work
ui.ps1              the control panel
```

`llamaswap\config.yaml` is the one file you'd ever hand-edit — it defines each model's context
size and how much of it goes on the GPU. It's generated on first run from `config.example.yaml`.
See [CLAUDE.md](CLAUDE.md) for how the whole thing fits together in detail.
