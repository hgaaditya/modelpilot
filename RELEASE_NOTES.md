# Model Pilot 0.1.15

## Operations update

- The panel checks GitHub for new Model Pilot releases and can download, SHA-256 verify, install,
  and restart into an update while keeping models, chats, and settings.
- Settings now creates a local backup ZIP for configuration, panel preferences, and Open WebUI
  users/chats/settings. It deliberately excludes GGUF weights, runtime binaries, logs, and caches.
- A readiness check reports available disk, RAM, and accelerator memory before install or upgrade.
- Model state now distinguishes files that are merely configured from a model whose local text
  response was verified.
- Structured GitHub bug and installation-recovery reports now enter automated issue triage.
- `supply-chain.json` is included in the installer and published with every release.

# Model Pilot 0.1.14


## Install

Download `Model-Pilot-Setup.exe` and `SHA256SUMS.txt` from this GitHub Release. The installer is
per-user and installs the Model Pilot launcher and scripts; the first **Start** downloads the runtime
components and any model weights are selected by the user.

## Important trust notice

This installer is intentionally **unsigned**. Windows may identify its publisher as unknown or show a
SmartScreen warning. Download only from this project's GitHub Releases page and verify the installer
against the attached `SHA256SUMS.txt`. The checksum detects an altered file only when the checksum
itself came from the trusted release page; it does not identify the publisher or replace code signing.

## Scope and known limitations

- Supported product surface: Windows 10/11 desktop. The installer, panel and tray are not supported
  on macOS, Linux, phones or tablets.
- The first run downloads llama.cpp, llama-swap, Open WebUI, Node.js, Python packages and any chosen
  model weights from their upstream sources. Read [SECURITY.md](SECURITY.md) and
  [THIRD-PARTY.md](THIRD-PARTY.md) before installing optional components.
- Models, chat data and configuration remain local by default. Model weights have their own terms.
- GitHub private vulnerability reporting is unavailable. Report vulnerabilities privately to
  modelpilot.app@gmail.com with **Security** in the subject; use public issues only for non-sensitive
  reports.
