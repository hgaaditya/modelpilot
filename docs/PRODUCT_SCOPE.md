# Product scope

Model Pilot is a Windows desktop product for running private local chat models. Its supported path is:

1. Start the local services.
2. Find or import a GGUF model.
3. Verify a real response.
4. Open the local chat interface.

## Deliberate exclusions

Model Pilot does not ship, install, configure, update, or support coding agents, Claude Code handoff scripts, OpenCode, or other external agent CLIs. A detected executable is not a supported product integration. Do not add controls for an external CLI unless Model Pilot owns its installation, configuration, update, recovery, and user-facing support path.

The local API endpoints remain available under **More → System** for advanced compatible-client integrations. They are not a coding-agent feature.

## Interface priorities

- **Home** shows one state-driven next action: set up, start, choose a model, verify a response, or open chat.
- **Models** defaults to an everyday-chat recommendation. Existing GGUF import and manual source entry are secondary paths.
- **Activity** explains long-running work.
- **Settings** owns updates, private backups, restore, preflight, redacted diagnostics, storage, and startup behavior.
- **System** and **Monitoring** are advanced views under More; technical implementation names stay out of normal setup copy.

## Recovery contract

Backups include Model Pilot configuration, panel preferences, and Open WebUI data, including its session key. They exclude model weights, logs, download caches, and runtime binaries. Restore accepts only Model Pilot backups stored in the local backups folder, creates a fresh safety backup before making changes, then stops the stack so restored state applies cleanly on the next start.

The diagnostic export contains only product version, Windows version, local service reachability, and preflight results. It excludes chats, prompts, logs, local paths, usernames, machine name, tokens, model names, and model weights. Users must still review an exported ZIP before sharing it.
