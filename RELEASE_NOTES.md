# Unreleased development status

- Dependency scans now prepare a next-patch `-deps.<run>` installer artifact for offline Windows/GPU
  testing. They do not create tags or GitHub Releases.
- Fresh setup now adds its downloaded private Node runtime to the frontend build process, so the
  Open WebUI build does not depend on Node or npm already being installed on Windows.
- The installer uninstaller now stops the local stack, panel and tray before it removes launcher
  files. Downloaded runtimes, models and local data remain intact.
- Home is a single four-step path: set up, choose a model, test a real response, then open chat.
  Start, stop and restart no longer compete with that path in the header; maintenance remains in
  **More → System** and the tray.
- Models separates recommended downloads from existing-GGUF import; Activity groups equivalent
  completed jobs; Settings visually separates removal actions.

# Model Pilot 0.1.16

## Simpler everyday workflow

- Home now guides one next step at a time: set up, start, choose a model, verify a real response, or open chat.
- Models now defaults to everyday-chat recommendations. Importing existing GGUF files and manual sources remain available as secondary paths.
- Technical component and endpoint details moved under **More → System**; hardware sensors remain under **More → Monitoring**.
- Settings is organized around updates, backup and restore, PC readiness, diagnostics, storage, startup, and removal.

## Supported product boundary

- Removed the unsupported coding-agent surface from the panel and installer: OpenCode integration, Claude Code handoff, and local delegation scripts no longer ship.
- Model Pilot still exposes local compatible API endpoints for advanced integrations, but does not install or support external agent CLIs.

## Recovery

- Settings can restore a selected local Model Pilot backup. It creates a fresh safety backup first and stops the stack before restored chats and settings apply.
- Settings can create a redacted diagnostic ZIP for support. It excludes chats, prompts, logs, local paths, usernames, machine name, tokens, model names, and model weights.

## Install

Download `Model-Pilot-Setup.exe` and `SHA256SUMS.txt` from this GitHub Release. The installer is per-user and installs the Model Pilot launcher and scripts; the first **Start** downloads runtime components and any model weights selected by the user.

## Important trust notice

This installer is intentionally **unsigned**. Windows may identify its publisher as unknown or show a SmartScreen warning. Download only from this project's GitHub Releases page and verify the installer against the attached `SHA256SUMS.txt`. The checksum detects an altered file only when the checksum itself came from the trusted release page; it does not identify the publisher or replace code signing.

## Scope and known limitations

- Supported product surface: Windows 10/11 desktop. The installer, panel and tray are not supported on macOS, Linux, phones or tablets.
- The first run downloads llama.cpp, llama-swap, Open WebUI, Node.js, Python packages and any chosen model weights from their upstream sources. Read [SECURITY.md](SECURITY.md) and [THIRD-PARTY.md](THIRD-PARTY.md) before installing optional components.
- Models, chat data and configuration remain local by default. Model weights have their own terms.
- GitHub private vulnerability reporting is unavailable. Report vulnerabilities privately to modelpilot.app@gmail.com with **Security** in the subject; use public issues only for non-sensitive reports.
