# Security

## What this software assumes

Model Pilot is a single-user Windows desktop tool. It assumes **you trust everything running as
your user account on your own machine**. Within that assumption it is reasonably careful; outside
it, it offers no protection at all. If that assumption doesn't hold for you, this is the wrong tool.

Three things are worth understanding before you run it.

### The control panel has no password

`ui.ps1` binds `127.0.0.1` only, so nothing on your network can reach it. It is **not** protected
from other programs running as you on the same machine — any of them can read the page and drive
the panel, and the panel can stop services, rewrite `config.yaml` and delete model weights.

It *is* protected from websites you visit, which is a different and easier mistake to make.
Binding to loopback does not stop a web page from POSTing to it: a form-style request is a "simple
request" that skips the CORS preflight entirely. This was verified exploitable during development
— a cross-origin `POST` with `Origin: https://evil.example` changed panel settings and returned
`200`, and the same shape reached the endpoint that deletes multi-GB weight files. Two mitigations
are in place:

1. a per-run token the page must echo in a custom header — a custom header forces a preflight,
   which this server never answers, so cross-origin requests die there;
2. an `Origin` check, since browsers always attach `Origin` to cross-origin requests.

`/api/ping` is deliberately exempt: it returns a fixed literal, does no work, and is how a second
launch discovers an existing panel before any token exists. It leaks only that the port is a
Model Pilot panel, which a failed bind reveals anyway.

### The benchmark can run code the model writes

`bench/run.py` grades a model's Python by **executing it**, as you, sandboxed only by a timeout and
a temporary directory. That is the only way to tell whether generated code works, so there is no
version of that grader which doesn't execute.

It is therefore off until you say otherwise. Run from a terminal it explains what will happen and
requires typing `yes`; the answer is remembered in `bench/.code-exec-consent`. With no terminal to
ask — every path through `start.ps1` and the panel runs detached — the answer is **no** and those
tasks are skipped. `--allow-code-execution` covers scripted runs and deliberately does not write
the consent file. The other graders (JSON, regex, long-context recall) never execute anything.

### Models are downloaded from the internet

`-Action add-model` fetches `.gguf` files from Hugging Face over HTTPS. A GGUF is data, not code,
and llama.cpp parses it — but it is still an untrusted file from a third party, and a malicious or
malformed one is parser input. Prefer publishers you recognise.

## What it does not do

Model Pilot does not include a telemetry or analytics service. That is not a claim that every
upstream component or optional integration has no telemetry. With the default configuration,
inference requests go to the local llama-swap endpoint and chat data stays on this PC. If you
connect Open WebUI or another client to a remote provider, that provider receives the requests
you send to it.

Network requests happen when you choose an operation that needs them:

- First-run setup downloads pinned components from GitHub releases/source archives and Node.js
  from nodejs.org. It uses uv to install a private Python runtime and resolve Open WebUI's
  Python dependencies from PyPI by default, and npm dependencies from its configured registry
  (registry.npmjs.org by default).
- The first Open WebUI boot may fetch its embedding model. Model discovery reads Hugging Face
  metadata; model files are downloaded only when you request them, from the publisher or URL you
  chose.
- Checking latest versions contacts GitHub's release API and nodejs.org. Optional ComfyUI setup
  downloads its source and Python packages; on Windows its CUDA-enabled PyTorch wheels come from
  `download.pytorch.org`.

The downloader checks GitHub's published SHA-256 digest for release assets when that digest is
available in the release API. A mismatch is rejected and the staged file is discarded; if the API
is unavailable or the publisher supplied no digest, installation continues with a warning.
That digest is delivered by the same GitHub service as the asset, so it detects corruption or an
asset mismatch but is not an independent publisher signature. It does not cover generated GitHub
source archives, nodejs.org, Hugging Face model files, PyPI/npm package resolution, ComfyUI source,
or every optional download.

Version pins and transport are therefore not full supply-chain verification: Model Pilot does not
verify an independent trusted checksum or signature for every upstream runtime/package download.
A pinned version identifies the selected release URL, not necessarily the publisher or the bytes
served from it. Treat upstream installers and dependencies as software you are choosing to trust.
Python and npm dependency installation may also execute upstream build or install hooks as your
user. Review package sources and their own security/licence notices before enabling optional
components or distributing broadly.
The current setup EXE is unsigned. Its SHA-256 checksum can detect a mismatch only when compared
with a checksum obtained from a trusted release location; it does not identify the publisher.
Windows may show an unknown-publisher warning.

These requests send the normal connection metadata required by those upstream services. Model Pilot
does not upload chat prompts or files as part of its default local inference route. Review any
remote provider, custom node, or extension you choose before enabling it.

### Optional extensions can execute code

ComfyUI custom nodes are third-party code imported at startup. Installing one is equivalent to
running that project's code as your Windows user; use only sources you trust. The default setup
does not install custom nodes.

## Reporting a vulnerability

For a public or low-risk issue **after a public release exists**, use its public issue tracker. For
an unresolved vulnerability, do **not** publish exploit details. Report it privately to
[modelpilot.app@gmail.com](mailto:modelpilot.app@gmail.com), with **“Security”** in the subject.
Do not send passwords, API keys, private chat history, or model weights. The repository is public,
but GitHub private vulnerability reporting is unavailable for it; email is the available private
route.

Please include the version (`.\start.ps1 -Action status`), what you did, and what happened. A
proof of concept helps enormously — the CSRF issue above was fixed the day it was found because it
came with a reproducible request.
