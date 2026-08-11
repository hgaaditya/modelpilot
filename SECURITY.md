# Security

## What this software assumes

LocalLLM is a single-user desktop tool. It assumes **you trust everything running as your user
account on your own machine**. Within that assumption it is reasonably careful; outside it, it
offers no protection at all. If that assumption doesn't hold for you, this is the wrong tool.

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
LocalLLM panel, which a failed bind reveals anyway.

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

It does not phone home. Nothing is uploaded, no telemetry is collected, and no analytics exist. The
only outbound requests are: model downloads you ask for, GitHub and nodejs.org release lookups when
installing or when you press *Check for updates*, and Hugging Face metadata when you inspect a
model. Conversations and files never leave the machine — that is the entire point of the project.

## Reporting a vulnerability

Open an issue for anything already public or low risk. For something that would put users at risk
if disclosed before a fix, use GitHub's **Report a vulnerability** button on the Security tab
(private advisory) rather than a public issue.

Please include the version (`.\start.ps1 -Action status`), what you did, and what happened. A
proof of concept helps enormously — the CSRF issue above was fixed the day it was found because it
came with a reproducible request.
