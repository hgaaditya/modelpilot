#!/bin/bash
# macOS double-click entry point for Model Pilot. Finder runs a `.command` in Terminal, which is
# why it is this and not a `.sh`: double-clicking a `.sh` opens it in an editor, exactly like a
# `.ps1` does on Windows.
#
# It exists because the rest of this project is PowerShell and macOS ships none. Rather than tell
# people to install PowerShell first - a system-wide change, for a tool that installs nothing
# system-wide - this fetches a self-contained pwsh into .pwsh/ inside the install directory. Same
# reasoning that replaced `winget install Python` with a vendored uv: no admin, no Homebrew, no
# package manager, and `-Action uninstall` can actually remove it again.
#
# Everything after the bootstrap is the same start.ps1 that runs on Windows.

set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
PWSH_DIR="$ROOT/.pwsh"
PWSH="$PWSH_DIR/pwsh"

# Single source of truth for the version: start.ps1's own $VER table. A second literal here would
# be one more thing to keep in step, and this project already has a version stamp to answer to.
PWSH_VER="$(grep -oE "pwsh[[:space:]]*=[[:space:]]*'[^']+'" start.ps1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [ -z "$PWSH_VER" ]; then
  echo "Could not read the pinned PowerShell version out of start.ps1 (\$VER.pwsh)." >&2
  exit 1
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
  echo "Model Pilot targets Apple Silicon. This Mac reports '$ARCH'." >&2
  echo "Intel Macs are not supported yet - see README.md." >&2
  exit 1
fi

if [ ! -x "$PWSH" ]; then
  echo "First run: fetching PowerShell $PWSH_VER (68 MB, into $PWSH_DIR - nothing is installed system-wide)..."
  TARBALL="powershell-$PWSH_VER-osx-arm64.tar.gz"
  URL="https://github.com/PowerShell/PowerShell/releases/download/v$PWSH_VER/$TARBALL"
  mkdir -p "$PWSH_DIR"
  # Staged to .part and moved only on success, so an interrupted download can never be mistaken
  # for a complete one - the same rule the weight downloads follow.
  curl -fL --progress-bar -o "$PWSH_DIR/$TARBALL.part" "$URL"
  mv "$PWSH_DIR/$TARBALL.part" "$PWSH_DIR/$TARBALL"
  tar -xzf "$PWSH_DIR/$TARBALL" -C "$PWSH_DIR"
  rm -f "$PWSH_DIR/$TARBALL"
  chmod +x "$PWSH"
  # Downloaded archives carry the quarantine attribute, and Gatekeeper will refuse to run the
  # binary until it is cleared. This build is unsigned by decision (see README), so clearing it
  # here is the difference between "it works" and a dialog with no obvious way forward.
  xattr -dr com.apple.quarantine "$PWSH_DIR" 2>/dev/null || true
fi

exec "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/start.ps1" "$@"
