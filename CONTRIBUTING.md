# Contributing

## What this project is

Mostly configuration and supervision, not much code. `llama.cpp`, `llama-swap` and `Open WebUI` are
downloaded, not vendored — so a change here is usually to `start.ps1` (the CLI that does the work)
or `ui.ps1` (the panel, which is a face on that CLI and should never become a second
implementation).

Read [CLAUDE.md](CLAUDE.md) before changing anything. It is long, and it is the good kind of long:
almost every paragraph exists because something failed and the reason wasn't obvious. It will save
you from re-discovering that `--context-shift` defaults off, that `Start-Process -ArgumentList`
doesn't quote spaces, or that `localhost` and `127.0.0.1` are not interchangeable here.

## Ground rules that aren't obvious

- **`127.0.0.1`, never `localhost`.** On Windows `localhost` can resolve to `::1` first, and these
  servers bind IPv4 only. This repo's own logs contain `dial tcp [::1]:5800 ... actively refused`.
- **Don't re-skin Open WebUI.** Its licence forbids altering its branding. See
  [THIRD-PARTY.md](THIRD-PARTY.md).
- **Measure before you claim.** Several confident statements in this project's history turned out
  to be harness bugs — a model declared incapable three separate times was fine each time. If a
  local model appears to misbehave, reproduce it outside the tooling first.
- **The panel is single-threaded.** Anything added to the 3s poll competes with everything else;
  a service that is down burns its full timeout. Cache, or poll on a slower timer.

## Before opening a pull request

CI runs on each pull request and checks PowerShell parsing/lint, the benchmark consent gate,
platform-layer boundaries, documentation links and installer compilation. It cannot exercise
hardware or model completions, so run these against a deployed machine before release:

```powershell
.\start.ps1 -Action check-config     # config parses and every model can actually start
.\start.ps1 -Action status           # versions resolve
.\start.ps1 -Action check-ui         # embedded panel JavaScript parses
```

```bash
python bench/test_consent.py         # the code-execution gate still refuses by default
```

If you touched the panel, open it and click through every tab — most of its failures are visual or
show up only in the browser console, and neither is caught by anything above.
For the panel, also verify keyboard-only navigation, visible focus, dialog focus containment and
return, and accessible names on forms. Check a narrow window for page-level horizontal overflow.
Automated accessibility scans do not replace Windows Narrator or native Forced Colors checks; mark
those checks unavailable rather than implying they passed.

If changing download handling, verify that an advertised SHA-256 is checked before promotion and a mismatch deletes both the staged file and progress sidecar. Also keep the documentation clear that missing or same-host digests do not authenticate the publisher.

## Things that would genuinely help

- **A concurrent listener for `ui.ps1`.** The single-threaded `HttpListener` loop is the panel's
  main ceiling: one slow probe delays everything queued behind it.
- **Keep the shipping product Windows-only.** The panel, tray and installer target Windows 10/11;
  existing macOS backend code is not a supported installable product. Do not expand the release
  matrix without a separate product decision.
- **Tests.** `bench/test_consent.py` is currently the only one.

## Commit messages

Say what changed and *why it wasn't obvious*. The existing history is the house style: if a fix
took an hour to find, the commit message should save the next person that hour.
