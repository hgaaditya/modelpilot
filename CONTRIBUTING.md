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

There is no CI yet, so please run these by hand:

```powershell
.\start.ps1 -Action check-config     # config parses and every model can actually start
.\start.ps1 -Action status           # versions resolve
```

```bash
python bench/test_consent.py         # the code-execution gate still refuses by default
```

If you touched the panel, open it and click through every tab — most of its failures are visual or
show up only in the browser console, and neither is caught by anything above.

## Things that would genuinely help

- **A concurrent listener for `ui.ps1`.** The single-threaded `HttpListener` loop is the panel's
  main ceiling: one slow probe delays everything queued behind it.
- **macOS support.** The upstream stack already ports — llama-swap ships darwin builds, llama.cpp
  ships macos-arm64, Open WebUI is Python. What doesn't port is this project's own automation:
  WMI, `nvidia-smi`, WinForms in `tray.ps1`. The deeper problem is that Apple Silicon has unified
  memory, so the VRAM-budget model behind `autotune` and `inspect` needs a hardware abstraction
  rather than a translation.
- **Tests.** `bench/test_consent.py` is currently the only one.

## Commit messages

Say what changed and *why it wasn't obvious*. The existing history is the house style: if a fix
took an hour to find, the commit message should save the next person that hour.
