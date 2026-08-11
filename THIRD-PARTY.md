# Third-party software

LocalLLM is a small amount of PowerShell that installs, configures and supervises other people's
software. **None of it is redistributed here** — `start.ps1` downloads each component from its own
release page at run time, pinned to an exact version (see the `$VER` table at the top of
`start.ps1`). This repository contains no third-party code or binaries.

That keeps obligations light, but they aren't zero, and one of them has a clause people miss.

| Component | Licence | How it gets here |
| --- | --- | --- |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | MIT | Prebuilt Windows release, downloaded by `-Action deploy` |
| [llama-swap](https://github.com/mostlygeek/llama-swap) | MIT | Prebuilt Windows release, downloaded by `-Action deploy` |
| [Open WebUI](https://github.com/open-webui/open-webui) | BSD-3-Clause **plus a branding clause** — see below | Source release, downloaded by `-Action deploy` |
| [llmfit](https://github.com/AlexsJones/llmfit) | MIT | Prebuilt Windows release, downloaded by `-Action install-llmfit` |
| [PrismML llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp) | MIT (llama.cpp's) | Prebuilt Windows release, downloaded by `-Action install-prism` |
| [Node.js](https://nodejs.org) | MIT | Official build, downloaded into `open-webui-*/.node-runtime/` |
| [Python](https://www.python.org) | PSF | Installed via winget if no 3.11/3.12 is present |

Model weights are **not** covered by any of the above. Each `.gguf` carries its own licence from
whoever published it — Llama, Gemma and Qwen models all have their own terms, and some restrict
commercial use. `-Action inspect` and `-Action suggest` report a model's licence field where the
publisher set one; check it before relying on a model for anything that matters.

## The Open WebUI branding clause

Clause 4 of Open WebUI's licence prohibits altering, removing or obscuring its branding — name,
logo, or any identifier — in any deployment or distribution, unless you have fewer than 50 users
in a rolling 30-day window, or written permission, or an enterprise licence.

LocalLLM installs Open WebUI unmodified and links to it. It does not re-skin it, rename it, or
present it as its own. **Keep it that way**: a change that strips "Open WebUI" from the chat UI
would breach their licence, and it would do so quietly, because the app would still work.

If you are deploying this for more than 50 people, read their licence yourself rather than
trusting this summary.
