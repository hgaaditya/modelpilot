# Third-party software

Model Pilot is a small amount of PowerShell that installs, configures and supervises other people's
software. **The installer does not bundle the large runtime or model weights.** The setup script
downloads components on demand. Versions are pinned in `$VER` where the project controls an exact
version; Python is managed as 3.12 by uv, and package dependencies follow the upstream requirement
files and package indexes.

That keeps obligations light, but they aren't zero, and one of them has a clause people miss.

| Component | Licence | How it gets here |
| --- | --- | --- |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | MIT | Prebuilt Windows release, downloaded by `-Action deploy` |
| [llama-swap](https://github.com/mostlygeek/llama-swap) | MIT | Prebuilt Windows release, downloaded by `-Action deploy` |
| [Open WebUI](https://github.com/open-webui/open-webui) | BSD-3-Clause **plus a branding clause** — see below | Source release, downloaded by `-Action deploy` |
| [uv](https://github.com/astral-sh/uv) | MIT or Apache-2.0 | Pinned executable from GitHub Releases |
| Python 3.12 | PSF licence | Private managed runtime installed by uv; not installed system-wide |
| Open WebUI Python dependencies | Package-specific | Resolved from the upstream `backend/requirements.txt` using [PyPI](https://pypi.org/) by default |
| Open WebUI frontend dependencies | Package-specific | Installed from the upstream lockfile through the [npm registry](https://registry.npmjs.org/) to build the UI; build tooling is not part of the setup EXE |
| [Node.js](https://nodejs.org) | MIT | Official Windows build, downloaded for the frontend build |
| [llmfit](https://github.com/AlexsJones/llmfit) | MIT | Prebuilt Windows release, downloaded by the optional model-recommendation install |
| [PrismML llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp) | MIT (llama.cpp's) | Prebuilt Windows release, downloaded by the optional Prism install |
| [ComfyUI](https://github.com/Comfy-Org/ComfyUI) | See upstream licence and notices | Source and Python dependencies, installed only when you opt into image generation |
| PyTorch and ComfyUI Python dependencies | Package-specific | Installed only with ComfyUI; Windows CUDA wheels use `download.pytorch.org`, other packages use Python package indexes |
| Model and embedding weights | Publisher-specific | User-selected models come from their stated publisher/URL; Open WebUI may fetch its embedding model on first boot |

Model weights are **not** covered by any of the above. Each `.gguf` carries its own licence from
whoever published it — Llama, Gemma and Qwen models all have their own terms, and some restrict
commercial use. `-Action inspect` and `-Action suggest` report a model's licence field where the
publisher set one; check it before relying on a model for anything that matters.
The upstream license for each package, and the notices supplied with it, govern that package. This
table is an inventory, not a substitute for checking those notices. Optional ComfyUI dependencies
are a separate install and have their own transitive package licences.

## The Open WebUI branding clause

Clause 4 of Open WebUI's licence prohibits altering, removing or obscuring its branding — name,
logo, or any identifier — in any deployment or distribution, unless you have fewer than 50 users
in a rolling 30-day window, or written permission, or an enterprise licence.

Model Pilot installs Open WebUI unmodified and links to it. It does not re-skin it, rename it, or
present it as its own. **Keep it that way**: a change that strips "Open WebUI" from the chat UI
would breach their licence, and it would do so quietly, because the app would still work.

If you are deploying this for more than 50 people, read their licence yourself rather than
trusting this summary.
