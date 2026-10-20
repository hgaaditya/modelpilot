# Model Pilot desktop control panel - local UI served in a chromeless browser window.
#
#   .\ui.ps1                 # start the server and open the window
#   .\ui.ps1 -NoWindow       # server only (then browse to http://127.0.0.1:9300)
#   .\ui.ps1 -Launch         # spawn the server detached and wait for it (what ModelPilot.cmd runs)
#   .\ui.ps1 -Install        # desktop + start-menu shortcut, and the start-with-Windows command
#
# Why a local web page rather than WinForms: the same density CPU-Z gets from Win32 controls is
# far cheaper to build in HTML, and the whole UI moves to macOS unchanged when that comes up.
# --app mode makes the browser chromeless, so it still behaves like a native app - own taskbar
# entry, own icon, no address bar.
#
# It binds 127.0.0.1 only. This endpoint starts and stops processes and writes config, so it must
# never be reachable from the network.
#
# Everything it does shells out to start.ps1. The CLI stays the single source of truth; this is a
# face on it, not a second implementation.

[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 9300,
    [switch]$NoWindow,
    [switch]$Install,
    [switch]$Launch,
    [switch]$RestartPanel
)

$ErrorActionPreference = 'Stop'
$root       = $PSScriptRoot
# Platform differences live in platform.ps1 and nowhere else - see the header there.
. (Join-Path $root 'platform.ps1')
Migrate-LegacyDesktopShortcuts $root (Join-Path $root 'ui.ps1')
if ($Plat.IsWindows) { [void](Get-AutostartPath) }
$startPs    = Join-Path $root 'start.ps1'
$swapCfg    = Join-Path $root 'llamaswap\config.yaml'
$llamaCpp   = Join-Path $root 'llama.cpp'
$llamaPrism = Join-Path $root 'llama.cpp-prism'
$logDir     = Join-Path $root 'logs'
$jobDir     = Join-Path $logDir 'jobs'
$settingsFile = Join-Path $root '.ui-settings.json'
$usageFile  = Join-Path $root '.ui-usage.json'
$modelSupportFile = Join-Path $root '.model-support.json'
$backupDir  = Join-Path $root 'backups'
$swapPort   = 9292
$webuiPort  = 8080
New-Item -ItemType Directory -Force -Path $jobDir | Out-Null

# Version lookups hit the GitHub API, so they are fetched on demand and kept until refreshed.
$script:verInfo = $null

# Binding to 127.0.0.1 keeps the network out, but it does NOT keep websites out: any page the
# user visits can post to localhost, and a form-style POST (text/plain, no custom headers) is a
# "simple request" that skips the CORS preflight entirely. Without this, a visited page could
# silently call /api/delete-model and destroy multi-GB weights. Verified exploitable before the
# fix, so it is enforced two ways:
#   1. a per-run secret the page is given and must echo in a header - a custom header forces a
#      preflight, which this server never answers, so cross-origin requests die there;
#   2. an Origin check, since browsers always attach Origin to cross-origin requests.
$script:csrfToken = [guid]::NewGuid().ToString('N')
$script:selfOrigin = "http://127.0.0.1:$Port"

# Version strings cost a process launch each, so they're read once and kept.
$script:versionCache = @{}

# The page is served once and then lives in a window that is never closed - closing it is a
# minimise. So an edit to this file, or any restart onto new code, left the browser running the
# old markup and old JS until someone reopened it by hand. The build stamp is this file's mtime;
# the page remembers the first one it saw and reloads itself when the server reports a different
# one, which is exactly the case where its own code is stale.
$script:build = (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc.Ticks.ToString()

# ---------------------------------------------------------------- window management

# Chromium runs every --app window of a browser inside one process tree, and only one process in
# that tree reports a MainWindowTitle. So Get-Process can never count the panel's windows: with
# five of them open it still reports one, the check for "is a window already up" passes on the
# wrong evidence, and each launch adds another. Five identical panels, which is what happened.
#
# The browser title is Model Pilot. The legacy installation folder remains C:\LocalLLM, and
# Explorer windows there are still titled LocalLLM, so the owning browser process is checked too.

Add-Type -ErrorAction SilentlyContinue @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class PanelWin {
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern int  GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    public static List<IntPtr> Find(string title, string[] procNames) {
        var found = new List<IntPtr>();
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            int len = GetWindowTextLength(h);
            if (len == 0) return true;
            var sb = new StringBuilder(len + 1);
            GetWindowText(h, sb, sb.Capacity);
            if (sb.ToString() != title) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            try {
                string n = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName.ToLower();
                if (Array.IndexOf(procNames, n) >= 0) found.Add(h);
            } catch { }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static void Raise(IntPtr h) { ShowWindow(h, 9 /* SW_RESTORE */); SetForegroundWindow(h); }
    public static void Close(IntPtr h) { PostMessage(h, 0x0010 /* WM_CLOSE */, IntPtr.Zero, IntPtr.Zero); }
}
'@

$BROWSER_PROCS = @('chrome', 'msedge', 'brave')

function Get-PanelWindows { @([PanelWin]::Find('Model Pilot', $BROWSER_PROCS)) + @([PanelWin]::Find('LocalLLM', $BROWSER_PROCS)) }

# Bring the panel back rather than opening another one. Returns false when there is nothing to
# bring back, which is the only case where a new window should be launched.
function Show-PanelWindow {
    $w = Get-PanelWindows
    if (-not $w.Count) { return $false }
    # More than one already open is the bug this function exists to prevent; if it has already
    # happened (from a build before this fix, or a browser restoring its last session), collapse
    # them to one rather than leaving the user to close four identical windows by hand.
    for ($i = 1; $i -lt $w.Count; $i++) { [PanelWin]::Close($w[$i]) }
    [PanelWin]::Raise($w[0])
    $true
}

# The only place a panel window is ever opened. Both launch paths route through here, because the
# server being down does NOT mean no window is open - restarting the server (an upgrade, a crash,
# an edit during development) leaves the old window sitting there pointing at a dead port, and it
# reconnects on its own once the server is back. Opening another one then is what stacked them up.
function Open-PanelWindow {
    if (Show-PanelWindow) { return }
    $browser = Find-AppBrowser
    # Size the window to the content. Without this the browser opens at its own last-used
    # geometry, which is a large mostly-empty frame around a compact panel.
    if ($browser) { Start-Process $browser @("--app=http://127.0.0.1:$Port", '--window-size=1040,720') }
    else { Start-Process "http://127.0.0.1:$Port" }
}

# ---------------------------------------------------------------- shortcuts

function Find-AppBrowser {
    # Any Chromium supports --app, but which one matters for memory: joining a browser that is
    # ALREADY RUNNING costs ~106 MB across 2 processes, while cold-starting a different one spins
    # up its own browser, GPU, utility and renderer processes and measured 500 MB. Prefer live.
    $installed = [ordered]@{
        chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                   "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
        msedge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")
        brave  = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe")
    }
    $running = @(Get-Process -Name chrome, msedge, brave -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty ProcessName -Unique)
    foreach ($name in @($running + $installed.Keys)) {
        foreach ($p in $installed[$name]) { if ($p -and (Test-Path $p)) { return $p } }
    }
    $null
}

function Install-Shortcuts { New-DesktopLauncher $PSCommandPath $root }

if ($Install) {
    Install-Shortcuts | ForEach-Object { Write-Host "shortcut -> $_" }
    Write-Host ""
    Write-Host "Start the stack at logon:  .\start.ps1 -Action autostart   (or the tick box in Settings)"
    return
}

# Double-clicking ModelPilot.cmd lands here. The panel has to outlive its launcher - closing the
# browser window is a minimise, not a quit - so this spawns the server detached and then waits on
# its health endpoint. Without the wait, a failure to start (a taken port, a broken PowerShell
# policy) would be completely silent: no window, no message, nothing to act on.
if ($Launch) {
    # Files extracted from a downloaded .zip carry mark-of-the-web. -ExecutionPolicy Bypass already
    # ignores it, but clearing it stops the "do you want to run" prompt in every other entry point.
    if ($RestartPanel) {
        $otherPanelServers = @(Get-PanelServerProcesses $PSCommandPath $PID)
        foreach ($server in $otherPanelServers) {
            Stop-Process -Id $server.ProcessId -Force -ErrorAction Stop
        }
        if ($otherPanelServers) {
            $deadline = (Get-Date).AddSeconds(5)
            do {
                $responding = $false
                try {
                    $responding = (Invoke-WebRequest "http://127.0.0.1:$Port/api/ping" -UseBasicParsing -TimeoutSec 1).StatusCode -eq 200
                } catch { }
                if (-not $responding) { break }
                Start-Sleep -Milliseconds 250
            } while ((Get-Date) -lt $deadline)
            if ($responding) { throw 'The existing Model Pilot panel did not stop; close it and run the installer again.' }
        }
    }
    $launchArgs = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
                    '-File', $PSCommandPath, '-Port', $Port)
    $launchArgs = @($launchArgs | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) })
    Start-Process powershell -WindowStyle Hidden -ArgumentList $launchArgs
    Write-Host "Starting the Model Pilot panel..."
    foreach ($i in 1..30) {
        Start-Sleep -Milliseconds 500
        try {
            if ((Invoke-WebRequest "http://127.0.0.1:$Port/api/ping" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) {
                Write-Host "Panel is up on http://127.0.0.1:$Port - the window should be open."
                return
            }
        } catch { }
    }
    Write-Warning "The panel did not answer on port $Port within 15 seconds."
    Write-Host "Run this to see why:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Read-Host "Press Enter to close"
    return
}

# ---------------------------------------------------------------- settings

function Get-Settings {
    # useSwap/useWebui are the "part of my stack" switches. Start, Stop and Restart act on these
    # and nothing else, so someone who only wants the router doesn't get open-webui started, and
    # doesn't get told the stack is half-down because a service they deselected isn't running.
    $d = @{ modelsDir = (Join-Path $llamaCpp 'models'); swapPort = $swapPort; webuiPort = $webuiPort
            useSwap = $true; useWebui = $true; projectDir = ''; agentModel = '' }
    if (Test-Path $settingsFile) {
        $s = Get-Content $settingsFile -Raw | ConvertFrom-Json
        foreach ($k in $d.Keys.Clone()) { if ($s.PSObject.Properties.Name -contains $k) { $d[$k] = $s.$k } }
    }
    $d
}
function Set-Settings($patch) {
    $s = Get-Settings
    foreach ($p in $patch.PSObject.Properties) { $s[$p.Name] = $p.Value }
    $s | ConvertTo-Json | Set-Content $settingsFile -Encoding utf8
    $s
}

function Get-ModelSupport {
    if (-not (Test-Path $modelSupportFile)) { return @{} }
    try {
        $out = @{}
        $saved = Get-Content $modelSupportFile -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $out[$p.Name] = $p.Value }
        return $out
    } catch { return @{} }
}

# ---------------------------------------------------------------- probes

function Test-Endpoint($url) {
    # 1 second, not 2. This server handles requests serially, and a down service burns the whole
    # timeout - measured at 1015 ms against a stopped open-webui, on every poll. With the tick at
    # 3s that is a third of this server's only thread spent waiting on a service known to be down,
    # and everything else queues behind it.
    #
    # A TCP pre-check was tried to avoid that and made it decisively worse: a closed loopback port
    # here does not refuse promptly (the connect sits until the timeout), so every poll left a
    # pending socket behind, and /api/ping - which does no work at all - degraded from 1s to 8s as
    # they accumulated. Reverted. The real fix is a concurrent listener, not a cleverer probe.
    try { (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop).StatusCode -eq 200 }
    catch { $false }
}

function Get-ExeVersion($exe) {
    if (-not (Test-Path $exe)) { return $null }
    if ($script:versionCache.ContainsKey($exe)) { return $script:versionCache[$exe] }
    # llama-server prints its version to stderr. Under ErrorActionPreference='Stop', PowerShell
    # 5.1 turns a native command's stderr into a terminating NativeCommandError, so 2>&1 alone
    # made every lookup return "unknown". Drop the preference for the duration of the call.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $exe --version 2>&1 | ForEach-Object { "$_" }
        $line = $out | Where-Object { $_ -match 'version' } | Select-Object -First 1
        if (-not $line) { $line = $out | Select-Object -First 1 }
        $v = ("$line" -replace '^.*?version:\s*', '').Trim()
        if (-not $v) { $v = 'unknown' }
    } catch { $v = 'unknown' } finally { $ErrorActionPreference = $old }
    $script:versionCache[$exe] = $v
    $v
}

function Get-ConfiguredModels {
    if (-not (Test-Path $swapCfg)) { return @() }
    # Strip whole-line comments first. config.yaml documents its own tuning in prose, so a
    # comment explaining "--n-cpu-moe 3" above one model was being read as configuration for the
    # model above it - bonsai-27b reported an expert offload it does not have.
    $text = ((Get-Content $swapCfg) | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $parts = [regex]::Split($text, '(?m)^\s{2,}"([^"]+)"\s*:\s*$')
    $out = @()
    for ($i = 1; $i -lt $parts.Count; $i += 2) {
        $body = $parts[$i + 1]
        $m = [regex]::Match($body, '-m\s+"?([^"\r\n]+?\.gguf)"?')
        $path = if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null }
        $present = $path -and (Test-Path $path)
        $usage = Get-Usage
        $u = $usage[$parts[$i]]
        $out += [pscustomobject]@{
            id      = $parts[$i]
            path    = $path
            present = [bool]$present
            sizeGb  = if ($present) { [math]::Round((Get-Item $path).Length / 1GB, 1) } else { 0 }
            ctx     = if ($body -match '-c\s+(\d+)') { [int]$Matches[1] } else { 0 }
            kv      = if ($body -match '-ctk\s+(\S+)') { $Matches[1] } else { '' }
            moe     = if ($body -match '--n-cpu-moe\s+(\d+)') { [int]$Matches[1] } else { $null }
            prism   = [bool]($body -match 'llama-server-prism')
            # A prism-backed model with the fork not installed can never spawn, and the only
            # symptom is a connection-refused the first time you pick it. start.ps1's
            # -Action check-config says the same thing from the CLI.
            engineOk = Test-Path (Join-Path $(if ($body -match 'llama-server-prism') { $llamaPrism } else { $llamaCpp }) 'llama-server.exe')
            # NTFS last-access is enabled on this machine and updates when llama-server opens the
            # weights, so it gives a true "last used" with nothing to track. The load count has to
            # be counted here, and only advances while this panel is running - so it is a floor,
            # not a total.
            lastUsed = if ($present) { (Get-Item $path).LastAccessTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
            loads    = if ($u) { [int]$u.loads } else { 0 }
        }
    }
    $out
}

function Get-Usage {
    if (-not (Test-Path $usageFile)) { return @{} }
    try {
        $h = @{}
        (Get-Content $usageFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
        $h
    } catch { @{} }
}

# Called on every dashboard poll: when the loaded model changes, that is one load.
function Update-Usage($loaded) {
    if (-not $loaded) { return }
    if ($script:lastSeenModel -eq $loaded) { return }
    $script:lastSeenModel = $loaded
    $u = Get-Usage
    $entry = if ($u[$loaded]) { $u[$loaded] } else { [pscustomobject]@{ loads = 0 } }
    $u[$loaded] = [pscustomobject]@{ loads = [int]$entry.loads + 1 }
    try { $u | ConvertTo-Json | Set-Content $usageFile -Encoding utf8 } catch { }
}

# Weights on disk that no config entry points at - downloaded but not registered, which is
# otherwise invisible and looks like a missing model.
# Downloads in flight. start.ps1 stages every weight file to <name>.part and drops a
# <name>.part.json beside it carrying the expected size, so progress is bytes-on-disk over that
# total - no parsing of curl's carriage-return progress meter, which is what made a 5 GB download
# read as a stalled job. Speed and ETA are derived in the page from consecutive polls, the same
# way the Monitoring tab accumulates its own samples: the server holds no per-session history.
function Get-Downloads {
    $s = Get-Settings
    # Weights land in the models directory; the install downloads - open-webui's source, the
    # llama.cpp build, Node, uv - stage in a shared cache under TEMP. Both are things the user is
    # sitting and waiting for, and the first run is entirely the second kind.
    $dirs = @($s.modelsDir, (Join-Path $env:TEMP 'localllm-dl')) | Where-Object { $_ -and (Test-Path $_) }
    if (-not $dirs) { return @() }
    Get-ChildItem ($dirs | ForEach-Object { Join-Path $_ '*.part' }) -ErrorAction SilentlyContinue | ForEach-Object {
        $total = 0
        $meta = "$($_.FullName).json"
        if (Test-Path $meta) {
            try { $total = [long](Get-Content $meta -Raw | ConvertFrom-Json).total } catch { }
        }
        [pscustomobject]@{
            file  = $_.Name -replace '\.part$', ''
            bytes = $_.Length
            total = $total
            # A .part nobody has written to for a while is a dead download, not a slow one, and
            # saying so is the difference between waiting and re-running.
            idle  = [int]((Get-Date) - $_.LastWriteTime).TotalSeconds
        }
    }
}

function Get-Backups {
    if (-not (Test-Path $backupDir)) { return @() }
    @(Get-ChildItem -LiteralPath $backupDir -Filter 'model-pilot-user-data-*.zip' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            [pscustomobject]@{
                name = $_.Name
                path = $_.FullName
                bytes = $_.Length
                created = $_.LastWriteTime.ToString('o')
            }
        })
}

function Get-ModelIdFromFileName($path) {
    $id = [IO.Path]::GetFileNameWithoutExtension($path).ToLowerInvariant() -replace '[^a-z0-9_-]+', '-'
    $id.Trim('-')
}

function Get-OrphanModels {
    $s = Get-Settings
    if (-not (Test-Path $s.modelsDir)) { return @() }
    $known = @(Get-ConfiguredModels | Where-Object { $_.path } | ForEach-Object { (Split-Path $_.path -Leaf).ToLower() })
    Get-ChildItem (Join-Path $s.modelsDir '*.gguf') -ErrorAction SilentlyContinue |
        Where-Object { $known -notcontains $_.Name.ToLower() } |
        ForEach-Object { [pscustomobject]@{ file = $_.Name; sizeGb = [math]::Round($_.Length / 1GB, 1) } }
}

function Get-Dashboard {
    $gpu = @{ name = 'no GPU detected'; total = 0; used = 0; free = 0; temp = 0; util = 0 }
    $acc = Get-AcceleratorInfo
    if ($acc.Present) {
        $gpu = @{ name = $acc.Name; total = $acc.TotalMib; used = $acc.UsedMib; free = $acc.FreeMib
                  temp = $acc.TempC; util = $acc.UtilPct }
    }
    # Probe the router before asking for its loaded model. The listener's /running endpoint can
    # wait until its timeout when llama-swap is down; that state is already known from /health.
    $swapUp = Test-Endpoint "http://127.0.0.1:$swapPort/health"
    $webuiUp = Test-Endpoint "http://127.0.0.1:$webuiPort/health"
    $loaded = $null
    if ($swapUp) {
        try { $loaded = ((Invoke-RestMethod "http://127.0.0.1:$swapPort/running" -TimeoutSec 2).running |
                         Where-Object { $_.state -ne 'stopped' } | Select-Object -First 1).model } catch { }
    }
    Update-Usage $loaded
    # Cached for Get-Sensors, which is polled every second and must not add a second HTTP probe.
    $script:lastLoaded = $loaded
    $cfg = Get-Settings
    $mem = Get-SystemMemoryUsage
    @{
        services = @(
            @{ key = 'swap'; name = 'Model service'; role = 'loads and runs your local models'; managed = $true; selected = [bool]$cfg.useSwap
               up = $swapUp; url = "http://127.0.0.1:$swapPort/ui"
               installed = (Test-Path (Join-Path $root 'llamaswap\llama-swap.exe')) }
            @{ key = 'webui'; name = 'Chat'; role = 'the private chat interface in your browser'; managed = $true; selected = [bool]$cfg.useWebui
               up = $webuiUp; url = "http://127.0.0.1:$webuiPort"
               installed = [bool](Get-ChildItem $root -Directory -Filter 'open-webui-*' -ErrorAction SilentlyContinue) }
        )
        gpu     = $gpu
        loaded  = $loaded
        # Win32_OperatingSystem reports kilobytes, so KB -> GB is /1MB.
        ramUsed = $mem.UsedGb
        ramTot  = $mem.TotalGb
        build   = $script:build
    }
}

# One nvidia-smi call plus one WMI read, flattened into GPU-Z's sensor shape: a name, a number
# and a unit. Min/max/avg are accumulated in the page rather than here - the server would have to
# hold per-session history for a window that can be closed and reopened, and the browser already
# has the samples.
#
# ponytail: this is polled once a second while the Monitoring tab is open, on a single-threaded
# listener. nvidia-smi is a process spawn (~70ms) and Win32_Processor another ~40ms, so the tab
# costs roughly a tenth of a second per second. If that ever crowds out the other endpoints, the
# fix is to sample on a timer into a variable rather than to poll faster.
function Get-Sensors {
    # The GPU/CPU/RAM rows come from the platform layer; what stays here is the part that is
    # about this stack rather than this machine.
    $out = [Collections.ArrayList]@(Get-SensorReadings)
    # The inference process itself, which is the number that explains the rest of the table.
    $srv = @(Get-Process -Name llama-server -ErrorAction SilentlyContinue)
    [void]$out.Add(@{ name = 'llama-server Processes'; value = $srv.Count; unit = '' })
    [void]$out.Add(@{ name = 'llama-server Memory'
                      value = [int](($srv | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB); unit = 'MB' })
    @{ sensors = @($out); loaded = $script:lastLoaded }
}


# What this stack exposes to anything else on the machine. llama-swap speaks both the OpenAI and
# the Anthropic shapes on one port and routes by the "model" field, so any tool that can be given
# a base URL and a model name works - continue.dev, Zed, aider, a script. Worth stating outright,
# because nothing in the panel previously said the ports were usable from outside it.
#
# 127.0.0.1 is deliberate and not interchangeable with 'localhost': on Windows 'localhost' can
# resolve to ::1 first, and these servers bind IPv4 only. That is not hypothetical here - this
# repo's own logs carry "dial tcp [::1]:5800 ... actively refused" from exactly that mismatch.
function Get-Endpoints {
    $s = Get-Settings
    $swap = "http://127.0.0.1:$($s.swapPort)"
    @{
        swapUp = (Test-Endpoint "$swap/health")
        webuiUp = (Test-Endpoint "http://127.0.0.1:$($s.webuiPort)/health")
        models = @(Get-ConfiguredModels | Where-Object { $_.present -and $_.engineOk } | ForEach-Object { $_.id })
        rows = @(
            @{ what = 'OpenAI chat completions'; url = "$swap/v1/chat/completions"
               note = 'Most tools. Set the base URL to ' + $swap + '/v1 and pick a model id.' }
            @{ what = 'OpenAI models list'; url = "$swap/v1/models"; note = 'What ids are available.' }
            @{ what = 'Anthropic-compatible messages'; url = "$swap/v1/messages"
               note = 'For compatible clients. Set the base URL to ' + $swap }
            @{ what = 'llama-swap dashboard'; url = "$swap/ui"; note = 'Its own web UI: running models, logs.' }
            @{ what = 'Chat UI (open-webui)'; url = "http://127.0.0.1:$($s.webuiPort)"; note = 'The browser chat.' }
        )
    }
}

function Get-Engine {
    $swapExe = Join-Path $root 'llamaswap\llama-swap.exe'
    $servers = @(Get-Process -Name llama-server -ErrorAction SilentlyContinue |
                 ForEach-Object { @{ pid = $_.Id; mb = [int]($_.WorkingSet64 / 1MB) } })
    @{
        llamacpp = @{ path = $llamaCpp; installed = (Test-Path (Join-Path $llamaCpp 'llama-server.exe'))
                      version = (Get-ExeVersion (Join-Path $llamaCpp 'llama-server.exe')) }
        prism    = @{ path = $llamaPrism; installed = (Test-Path (Join-Path $llamaPrism 'llama-server.exe'))
                      version = (Get-ExeVersion (Join-Path $llamaPrism 'llama-server.exe')) }
        swap     = @{ installed = (Test-Path $swapExe); up = (Test-Endpoint "http://127.0.0.1:$swapPort/health")
                      procs = @(Get-Process -Name llama-swap -ErrorAction SilentlyContinue | ForEach-Object { @{ pid = $_.Id; mb = [int]($_.WorkingSet64/1MB) } }) }
        webui    = @{ up = (Test-Endpoint "http://127.0.0.1:$webuiPort/health") }
        servers  = $servers
    }
}

# ---------------------------------------------------------------- jobs
# Downloads and autotune runs take minutes. They run detached with output to a log, and the UI
# polls that log - so the HTTP thread never blocks and progress is visible while it happens.


function Start-Job2($name, $argList, $script) {
    if (-not $script) { $script = $startPs }
    $id = "{0}-{1}" -f $name, (Get-Date -Format 'HHmmss')
    $log = Join-Path $jobDir "$id.log"
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $argList
    $quotedArgs = @($a | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) })
    $p = Start-Process powershell -WindowStyle Hidden -ArgumentList $quotedArgs -PassThru `
             -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    # Below-normal priority so the panel keeps its own thread. Moving the work out of the request
    # stopped it blocking structurally, but a CPU-bound job (llmfit scoring, a model load) still
    # starved the listener enough to push /api/ping from under a millisecond to several seconds -
    # which the user sees as the whole window going unresponsive while something runs.
    try { $p.PriorityClass = 'BelowNormal' } catch { }
    # The pid is what makes "is this still running" answerable. Without it the page can only see
    # that a log file exists, which is true forever, so a button could never stop spinning.
    Set-Content -Path (Join-Path $jobDir "$id.pid") -Value $p.Id -Encoding ascii
    $id
}

# This listener handles one request at a time, so anything that shells out for tens of seconds
# blocks everything else while it runs - the page's 3s poll, the header health dot, /api/ping, and
# the activity card that is supposed to be describing the very action in progress. The UI freezes
# at exactly the moment it is meant to be reassuring. `-Action inspect` reads a model's metadata
# over the network (~40s) and `-Action suggest` scores the catalogue (~30-60s), so both run as
# jobs and the page polls for the answer.
#
# Keyed by the question asked, so a stale answer to a different question is never handed back.
$script:asyncJobs = @{}
function Start-Async($name, $key, $argList) {
    $id = Start-Job2 $name $argList
    $script:asyncJobs[$name] = @{ key = $key; id = $id }
}
# $null = nothing has been asked, or what is on file answers a different question.
function Get-Async($name, $key) {
    $j = $script:asyncJobs[$name]
    if (-not $j -or $j.key -ne $key) { return $null }
    $log = Join-Path $jobDir "$($j.id).log"
    $pidFile = Join-Path $jobDir "$($j.id).pid"
    if (Test-Path $pidFile) {
        $jobPid = (Get-Content $pidFile -Raw).Trim()
        if (Get-Process -Id $jobPid -ErrorAction SilentlyContinue) { return @{ running = $true } }
    }
    $err = if (Test-Path "$log.err") { (Get-Content "$log.err" -Raw) } else { '' }
    @{ running = $false
       # Windows PowerShell decorates Get-Content strings with provider metadata. Serializing
       # those objects produced JSON objects instead of strings, so UI response checks saw
       # "[object Object]" and graded a successful completion as a failure.
       out = $(if (Test-Path $log) { @(Get-Content $log | ForEach-Object { "$_" }) } else { @() })
       err = "$err" }
}

# Installed / pinned / newest-upstream, straight from `start.ps1 -Action status`. The -Latest
# form queries GitHub and nodejs.org, so it is only run when the user asks for it.
function Get-Versions([switch]$Refresh) {
    if ($script:verInfo -and -not $Refresh) { return $script:verInfo }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startPs, '-Action', 'status')
    if ($Refresh) { $a += '-Latest' }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = try { & powershell @a 2>&1 | ForEach-Object { "$_" } } catch { @() } finally { $ErrorActionPreference = $old }
    $rows = @()
    foreach ($l in $out) {
        if ($l -match '^\s*(llamaCpp|llamaSwap|openWebUI|node|prism fork)\s+(\S+)\s+(\S+)\s+(\S+)\s*$') {
            $rows += @{ component = $Matches[1]; installed = $Matches[2]; pinned = $Matches[3]
                        latest = $(if ($Matches[4] -eq '-') { '' } else { $Matches[4] }) }
        }
    }
    $script:verInfo = @{ rows = $rows; checked = (Get-Date -Format 'HH:mm:ss'); hasLatest = [bool]$Refresh }
    $script:verInfo
}

function Remove-ModelFiles($id, [bool]$alsoConfig) {
    $m = Get-ConfiguredModels | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $m) { throw "no model '$id' in config.yaml" }
    $freed = 0
    if ($m.path -and (Test-Path $m.path)) {
        $freed = [math]::Round((Get-Item $m.path).Length / 1GB, 1)
        # Split models are published as -00001-of-000NN; remove the whole set or the remainder is
        # dead weight that no entry points at.
        $stem = [regex]::Replace((Split-Path $m.path -Leaf), '-\d{5}-of-\d{5}\.gguf$', '')
        $dir = Split-Path $m.path -Parent
        Get-ChildItem $dir -Filter "$stem*.gguf" -ErrorAction SilentlyContinue | Remove-Item -Force
        Remove-Item $m.path -Force -ErrorAction SilentlyContinue
    }
    if ($alsoConfig -and (Test-Path $swapCfg)) {
        $text = Get-Content $swapCfg -Raw
        # Take the entry from its id line up to the next id line or end of file.
        $pat = "(?ms)^\s{2,}""$([regex]::Escape($id))""\s*:\s*$.*?(?=^\s{2}""|\z)"
        $new = [regex]::Replace($text, $pat, '')
        if ($new -ne $text) {
            Copy-Item $swapCfg "$swapCfg.bak" -Force
            Set-Content $swapCfg -Value $new -Encoding utf8 -NoNewline
        }
    }
    @{ ok = $true; freedGb = $freed }
}

function Get-Jobs {
    Get-ChildItem (Join-Path $jobDir '*.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
            $tail = (Get-Content $_.FullName -Tail 6 -ErrorAction SilentlyContinue |
                     Where-Object { $_.Trim() } | Select-Object -Last 3) -join "`n"
            $err = "$($_.FullName).err"
            if ((Test-Path $err) -and (Get-Item $err).Length -gt 0) {
                $etail = (Get-Content $err -Tail 3 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) -join "`n"
                if ($etail) { $tail = "$tail`n$etail" }
            }
            # name is the job id minus its -HHmmss stamp, and is what a button matches itself
            # against to know it is the thing currently running.
            $pidFile = Join-Path $jobDir "$($_.BaseName).pid"
            $running = $false
            if (Test-Path $pidFile) {
                $jobPid = (Get-Content $pidFile -Raw).Trim()
                $running = [bool](Get-Process -Id $jobPid -ErrorAction SilentlyContinue)
            }
            @{ id = $_.BaseName; name = ($_.BaseName -replace '-\d{6}$', '')
               age = [int]((Get-Date) - $_.LastWriteTime).TotalSeconds; tail = $tail; running = $running }
        }
}

# ---------------------------------------------------------------- page

$html = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Model Pilot</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect x='6.5' y='6.5' width='19' height='19' rx='3.5' fill='none' stroke='%232360c4' stroke-width='2'/%3E%3Cg stroke='%232360c4' stroke-width='2' stroke-linecap='round'%3E%3Cpath d='M12 6.5V3M16 6.5V3M20 6.5V3M12 25.5V29M16 25.5V29M20 25.5V29'/%3E%3Cpath d='M6.5 12H3M6.5 16H3M6.5 20H3M25.5 12H29M25.5 16H29M25.5 20H29'/%3E%3C/g%3E%3Cpath d='M12 12.5h8a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.5 1.5h-4.2L13 21v-2.5h-1a1.5 1.5 0 0 1-1.5-1.5v-3a1.5 1.5 0 0 1 1.5-1.5z' fill='%232360c4'/%3E%3C/svg%3E">
<style>
:root{--bg:#f5f7fb;--panel:#fff;--line:#e2e7f0;--fg:#1d2939;--dim:#536176;--ok:#147a54;--warn:#a86608;--bad:#bb3b46;--acc:#405dc8;--soft:#eef2f8;--tint:#eef3ff;--shadow:0 5px 18px rgba(26,42,74,.06)}
*{box-sizing:border-box}
:focus-visible{outline:2px solid var(--acc);outline-offset:2px}
@media(forced-colors:active){:focus-visible{outline-color:Highlight}.dot{border:1px solid CanvasText}.bar{border:1px solid CanvasText}.bar i{background:Highlight}}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 "Segoe UI",system-ui,sans-serif;user-select:none}
header{position:sticky;top:0;z-index:20;display:flex;align-items:center;gap:12px;padding:12px 26px;background:rgba(255,255,255,.96);border-bottom:1px solid var(--line);backdrop-filter:blur(12px)}
header b{font-size:16px;font-weight:650;letter-spacing:-.02em}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%}.up{background:var(--ok)}.down{background:var(--bad)}.part{background:var(--warn)}
nav{position:sticky;top:53px;z-index:19;display:flex;align-items:center;gap:5px;padding:8px 26px;background:rgba(255,255,255,.96);border-bottom:1px solid var(--line)}
nav button,nav summary{background:transparent;border:0;border-radius:7px;color:var(--dim);padding:8px 13px;font-size:13px;font-weight:550;cursor:pointer;list-style:none}
nav button:hover,nav summary:hover{background:var(--soft);color:var(--fg)}
nav button.on,nav summary.on{color:var(--acc);background:var(--tint);font-weight:650}
.nav-more{position:relative;margin-left:auto}
.nav-more summary::-webkit-details-marker{display:none}
 .nav-more summary:after{content:'';display:inline-block;width:6px;height:6px;border-right:1.5px solid currentColor;border-bottom:1.5px solid currentColor;transform:rotate(45deg);margin:0 0 3px 7px}
.nav-menu{position:absolute;right:0;top:42px;min-width:190px;padding:6px;background:var(--panel);border:1px solid var(--line);border-radius:10px;box-shadow:var(--shadow)}
.nav-menu button{display:block;width:100%;text-align:left}
main{width:min(1360px,100%);margin:0 auto;padding:26px 34px 48px}
.pane{display:none}.pane.on{display:block}
fieldset,.surface{border:1px solid var(--line);border-radius:13px;margin:0 0 16px;padding:18px 20px;background:var(--panel);box-shadow:var(--shadow)}
legend{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.08em;padding:0 5px;font-weight:700}
.section-head{display:flex;align-items:flex-end;justify-content:space-between;margin:0 0 20px}
.section-head h1{font-size:27px;line-height:1.2;letter-spacing:-.035em;margin:3px 0 4px}
.section-head p,.surface p{margin:4px 0 0;color:var(--dim)}
.eyebrow{font-size:10px;font-weight:750;letter-spacing:.12em;color:var(--acc)}
.surface h2{font-size:16px;line-height:1.3;letter-spacing:-.015em;margin:3px 0}
.surface h3{font-size:14px;margin:0 0 8px}
.surface-head{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-bottom:14px}
.home-grid{display:grid;grid-template-columns:minmax(0,1.35fr) minmax(270px,.85fr);gap:16px;align-items:start}
.service-grid{display:grid;gap:10px}
.service-card{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:8px 16px;padding:14px;border:1px solid var(--line);border-radius:10px;background:#fff}
.service-card h3{margin:0;font-size:14px}.service-card p{margin:3px 0 0;font-size:12px}
.service-meta{display:flex;align-items:center;gap:8px}
.service-card .service-choice{grid-column:1/-1;display:flex;align-items:center;gap:8px;margin-top:5px;color:var(--dim);font-size:12px}
.service-card .service-choice input{width:auto}
.status-pill{display:inline-flex;align-items:center;gap:6px;border-radius:20px;background:#f0f3f8;padding:4px 9px;font-size:11px;font-weight:650;color:var(--dim)}
.status-pill.good{background:#eaf6f0;color:var(--ok)}.status-pill.bad{background:#fff0f0;color:var(--bad)}.status-pill.warn{background:#fff6e7;color:var(--warn)}
.kv{display:grid;grid-template-columns:minmax(94px,.55fr) 1fr;gap:9px 12px;font-size:13px}
.kv span{color:var(--dim)}
table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.04em;font-weight:700;padding:9px 10px;border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:10px;border-bottom:1px solid #edf0f5;white-space:nowrap}
tr:last-child td{border-bottom:0}
.table-wrap{width:100%;overflow:auto}
button.act{background:var(--acc);color:#fff;border:0;border-radius:7px;padding:8px 14px;font-size:13px;font-weight:650;cursor:pointer;box-shadow:0 2px 5px rgba(64,93,200,.16)}
button.act:hover{background:#344faf}
button.gh{background:#fff;color:var(--fg);border:1px solid var(--line);border-radius:7px;padding:7px 12px;font-size:12px;font-weight:600;cursor:pointer}
button.gh:hover{background:var(--soft);border-color:#cad3e2}
button.dz{background:#fff;color:var(--bad);border:1px solid #ecc8ca;border-radius:7px;padding:6px 10px;font-size:12px;cursor:pointer}
button:disabled{opacity:.45;cursor:default}
/* A click that starts a background job has no other visible effect for up to three seconds -
   the next poll - so the button says so itself. The label stays readable; only a spinner is
   added, because a button whose text vanishes reads as broken rather than busy. */
@keyframes spin{to{transform:rotate(360deg)}}
button.busy{cursor:progress;opacity:1}
button.busy::before{content:'';display:inline-block;width:9px;height:9px;margin-right:5px;vertical-align:-1px;
 border:2px solid var(--dim);border-top-color:transparent;border-radius:50%;animation:spin .6s linear infinite}
button.act.busy::before{border-color:#fff;border-top-color:transparent}
button.busy:disabled{opacity:.85}
input,select{background:#fff;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:8px 10px;font-size:13px;user-select:text}
input{width:100%}
input[type=checkbox]{accent-color:var(--acc)}
.check-label{display:flex;align-items:center;gap:7px;color:var(--dim);font-size:12px}
.check-label input{width:auto}
.adv{display:none}body.showadv .adv{display:table-cell}
.bar{height:6px;background:#e5eaf2;border-radius:8px;overflow:hidden;margin-top:5px}
.bar i{display:block;height:100%;background:var(--acc)}
.home-grid .hint{margin-top:10px}
.hero{display:flex;align-items:center;justify-content:space-between;gap:20px;margin:0 0 18px;padding:20px 22px;border:1px solid #d9e2ff;border-radius:13px;background:linear-gradient(120deg,#f2f5ff,#fff)}
.hero h2{font-size:19px;letter-spacing:-.025em;margin:3px 0}
.hero p{margin:4px 0 0;color:var(--dim);max-width:680px}
.hero-actions{display:flex;gap:8px;max-width:58%;min-width:0;flex-shrink:1;flex-wrap:wrap;align-items:center;justify-content:flex-end}
.hero>div:first-child{flex:1;min-width:0}
.hero-actions>div{max-width:100%;min-width:0}
.hero-actions .subtle{overflow-wrap:anywhere}
.model-tools{margin:0 0 16px}
.picker{background:linear-gradient(135deg,#fff,#f9faff)}
.model-pick-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:12px;margin-top:16px}
.model-pick{border:1px solid var(--line);border-radius:10px;padding:15px;background:#fff}
.model-pick-head{display:flex;justify-content:space-between;align-items:flex-start;gap:10px}
.model-pick h3{margin:0;font-size:14px;word-break:break-word}
.model-pick .fit{font-size:11px;font-weight:700;color:var(--fg);background:var(--soft);border-radius:20px;padding:3px 8px;white-space:nowrap}
.model-pick .fit.good{background:#eaf6f0;color:var(--ok)}.model-pick .fit.warn{background:#fff6e7;color:var(--warn)}
.model-stats{display:flex;gap:7px;flex-wrap:wrap;margin:12px 0;color:var(--dim)}
.recommendation-reason{font-size:12px;line-height:1.5;color:var(--dim);min-height:36px;margin:9px 0 0}
.model-stats span{background:var(--soft);padding:3px 7px;border-radius:5px;font-size:11px}
.model-pick button{width:100%;margin-top:4px}
.empty-state{padding:20px;text-align:center;border:1px dashed #cbd4e2;border-radius:9px;color:var(--dim)}
.disclosure summary,.subtle-list summary{cursor:pointer;font-weight:650}
.disclosure[open] summary{margin-bottom:12px}
.subtle-list{margin-top:12px}
.download-box{padding:12px;margin:12px 0;background:#f8faff;border:1px solid var(--line);border-radius:9px}
.subtle,.note{color:var(--dim);font-size:12px}
@media(max-width:760px){header{padding:8px 12px;gap:8px}header .gh,header .act{padding:6px 7px;font-size:12px}main{padding:18px 14px 32px}.home-grid{grid-template-columns:1fr}.section-head{align-items:flex-start}.hero{align-items:flex-start;flex-direction:column}.hero-actions{width:100%}nav{padding:7px 10px;overflow:visible}nav button,nav summary{padding:8px 9px}.service-card{grid-template-columns:1fr}.service-meta{grid-column:1}.service-card .service-choice{grid-column:1}}
@media(max-width:760px){.hero-actions{max-width:none;min-width:0}}
@media(max-width:760px){.import-table{display:block;width:100%}.import-table thead{display:none}.import-table tbody{display:block;width:100%}.import-table tbody tr{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:7px;padding:12px 0;border-bottom:1px solid var(--line)}.import-table td{display:block;min-width:0;padding:0 2px}.import-table td:first-child{grid-column:1/-1}.import-table td:first-child .subtle{overflow-wrap:anywhere;word-break:break-word;white-space:normal}.import-table td:nth-child(2){grid-column:1}.import-table td:nth-child(3){grid-column:2;max-width:100%;text-align:right}.import-table .miss{display:block;max-width:100%;overflow-wrap:anywhere}}
@media(max-width:760px){#modelTable{display:block;width:100%;min-width:0}#modelTable thead{display:none}#modelTable tbody{display:block;width:100%}#modelTable tbody tr{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:7px;padding:11px 0;border-bottom:1px solid var(--line)}#modelTable td{display:block;min-width:0;padding:2px 0}#modelTable td.adv{display:none}#modelTable td:first-child{grid-column:1;overflow-wrap:anywhere}#modelTable td:nth-child(2){display:none}#modelTable td:nth-child(3){grid-column:1;color:var(--dim);font-size:12px}#modelTable td:nth-child(9){grid-column:2;grid-row:1;white-space:nowrap}#modelTable td:nth-child(10){grid-column:1/-1;display:flex;flex-wrap:wrap;gap:6px}#modelTable td:nth-child(10) button{font-size:11px;padding:6px 8px}}
/* Anything slow gets a card in the corner saying what is happening, how long it usually takes,
   and its latest line of output. Every long action already routes through spin(), so the card is
   driven off the same busy() state the buttons use rather than a second bookkeeping system. */
#act{position:fixed;right:14px;bottom:14px;width:330px;max-width:calc(100vw - 28px);z-index:40;
 background:var(--panel);border:1px solid var(--line);border-radius:6px;box-shadow:0 10px 28px rgba(0,0,0,.22);display:none}
#act.on{display:block}
#acth{display:flex;justify-content:space-between;align-items:center;padding:6px 10px;background:var(--soft);
 border-bottom:1px solid var(--line);font-size:11px;color:var(--dim);border-radius:6px 6px 0 0}
#acth button{background:none;border:0;color:var(--dim);font-size:14px;line-height:1;padding:0 2px;cursor:pointer}
#actb{padding:9px 10px;font-size:12px;max-height:46vh;overflow:auto}
.job{margin-bottom:10px}.job:last-child{margin-bottom:0}
.job b{font-weight:600}
.job .note{color:var(--dim);font-size:11px;margin-top:1px}
.job pre{margin:4px 0 0;font-size:10.5px;color:var(--dim);white-space:pre-wrap;max-height:46px;overflow:hidden}
.bar.indet i{width:34%;animation:slide 1.25s ease-in-out infinite}
@keyframes slide{0%{margin-left:-34%}100%{margin-left:100%}}
.tag{font-size:10px;padding:1px 5px;border-radius:9px;border:1px solid var(--line);color:var(--dim);background:var(--soft)}
.miss{color:var(--bad)}.on2{color:var(--ok)}
.hint{background:#eaf1fb;border:1px solid #c3d6f2;border-radius:4px;padding:7px 9px;color:#28425f;font-size:12px;margin-bottom:9px}
/* One line saying how a mode behaves, above its controls. Plain text rather than a .hint box:
   three stacked callouts read as three warnings. */
.mode{color:var(--dim);font-size:11.5px;margin:0 0 7px}
/* In-page dialogs. The browser's own alert/confirm/prompt are titled with the origin -
   "127.0.0.1:9300 says" - which tells the user nothing and looks like a web page rather than the
   application this is pretending to be. These are also the only place the panel can put a real
   label on a destructive choice. */
#ovl{position:fixed;inset:0;background:rgba(20,25,32,.42);display:none;align-items:center;justify-content:center;z-index:50}
#ovl.on{display:flex}
#dlg{background:var(--panel);border:1px solid var(--line);border-radius:5px;box-shadow:0 12px 34px rgba(0,0,0,.28);
 width:min(430px,92vw);overflow:hidden}
#dlg h4{margin:0;padding:8px 12px;background:var(--soft);border-bottom:1px solid var(--line);font-size:12px;font-weight:600}
#dlgbody{padding:11px 12px;font-size:12.5px;white-space:pre-wrap;line-height:1.5}
#dlgbody b{font-weight:600}
#dlgin{width:100%;margin-top:9px}
#dlgfoot{display:flex;gap:7px;justify-content:flex-end;padding:9px 12px;border-top:1px solid var(--line);background:var(--soft)}
.row{display:flex;gap:7px;align-items:center;flex-wrap:wrap}
pre{background:#f7f8fa;border:1px solid var(--line);border-radius:3px;padding:6px;font-size:11px;margin:5px 0 0;white-space:pre-wrap;max-height:100px;overflow:auto;user-select:text;color:#3a4250}
code{background:var(--soft);padding:1px 4px;border-radius:3px;font-size:11px}
/* Sensor readout, laid out the way GPU-Z does it: name on the left, four numeric columns
   right-aligned in a tabular font so the digits line up and a changing value doesn't reflow
   the column. Rows are banded because there are twenty of them and no other structure. */
table.sens td,table.sens th{padding:2px 8px}
table.sens td:not(:first-child),table.sens th:not(:first-child){text-align:right;
 font-variant-numeric:tabular-nums;font-feature-settings:"tnum";width:15%}
table.sens tbody tr:nth-child(odd){background:var(--soft)}
table.sens td:first-child{color:var(--dim)}
table.sens td.now{font-weight:600;color:var(--fg)}
/* Endpoint list: the URL is the thing being copied, so it gets a monospace column of its own
   and the explanation sits underneath rather than competing with it. */
table.ep td{vertical-align:top;padding:4px 8px}
table.ep td:first-child{white-space:nowrap;color:var(--dim);width:1%}
table.ep code{font-size:11.5px;user-select:all}
table.ep .note{color:var(--dim);font-size:11px;margin-top:1px}
.logo{width:19px;height:19px;flex:0 0 auto}
</style></head><body>
<!-- The mark: a chip outline with a conversation bubble inside it. The whole idea of this app in
     one glyph - a model running on your own silicon rather than someone else's. Drawn as an
     inline SVG symbol so it costs no request, scales, and inherits the theme's colours; the
     favicon below is the same shape as a data URI. -->
<svg width="0" height="0" style="position:absolute" aria-hidden="true"><symbol id="mark" viewBox="0 0 32 32">
 <rect x="6.5" y="6.5" width="19" height="19" rx="3.5" fill="none" stroke="currentColor" stroke-width="2"/>
 <g stroke="currentColor" stroke-width="2" stroke-linecap="round">
  <path d="M12 6.5V3M16 6.5V3M20 6.5V3M12 25.5V29M16 25.5V29M20 25.5V29"/>
  <path d="M6.5 12H3M6.5 16H3M6.5 20H3M25.5 12H29M25.5 16H29M25.5 20H29"/>
 </g>
 <path d="M12 12.5h8a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.5 1.5h-4.2L13 21v-2.5h-1a1.5 1.5 0 0 1-1.5-1.5v-3a1.5 1.5 0 0 1 1.5-1.5z"
  fill="var(--acc)" stroke="none"/>
</symbol></svg>
<header><svg class="logo" viewBox="0 0 32 32" aria-hidden="true"><use href="#mark"/></svg>
<b>Model Pilot</b><span id="d" class="dot down" title="stack status"></span><span id="sub" style="color:var(--dim);font-size:11px"></span>
<span style="flex:1"></span>
 <button class="gh" id="hre" aria-label="Restart selected services" onclick="act('restart')" disabled>Restart</button>
 <button class="gh" id="hst" aria-label="Stop selected services" onclick="act('stop')" disabled>Stop</button>
 <button class="act" id="go" aria-label="Start selected services" onclick="act('deploy')" disabled>Start</button></header>
<nav aria-label="Main navigation">
 <button class="on" data-pane="0" aria-current="page" onclick="tab(0,this)">Home</button>
 <button data-pane="2" onclick="tab(2,this)">Models</button>
 <button data-pane="5" onclick="tab(5,this)">Activity</button>
 <button data-pane="6" onclick="tab(6,this)">Settings</button>
 <details class="nav-more" id="navMore"><summary id="moreNav" aria-label="More navigation">More</summary><div class="nav-menu">
  <button onclick="tab(1,this)">System</button>
  <button onclick="tab(4,this)">Monitoring</button>
 </div></details>
</nav>
<main>

<div class="pane on" id="p0">
 <div class="section-head"><div><div class="eyebrow">YOUR LOCAL AI</div><h1>Home</h1><p>Set up a private model once, then chat on your own machine.</p></div></div>
 <div id="homeLoading" class="hint" role="status" aria-live="polite">Checking this PC and the local services. This can take a few seconds.</div>
 <div id="guide"></div>
 <div id="verifyResult" class="verify-result" role="status" aria-live="polite" style="display:none"></div>
 <div class="home-grid">
  <section class="surface"><div class="surface-head"><div><h2>What is running</h2><p>Start or stop the local model service and chat.</p></div><div class="row">
   <button class="gh" id="homeRestart" onclick="act('restart')">Restart</button><button class="gh" id="homeStop" onclick="act('stop')">Stop</button></div></div>
   <div id="svc" class="service-grid"><div class="hint" style="grid-column:1/-1">Checking installed services...</div></div>
  </section>
  <section class="surface"><div class="surface-head"><div><h2>This PC</h2><p>Available memory for local models.</p></div></div><div class="kv" id="hw"><span>Hardware</span><div>Reading memory and accelerator information...</div></div></section>
 </div>
</div>

<div class="pane" id="p1">
 <div class="section-head"><div><div class="eyebrow">ADVANCED</div><h1>System</h1><p>Component details and local API endpoints for troubleshooting or integrations.</p></div></div>
 <div class="row" style="margin-bottom:9px">
  <button class="gh" onclick="chk()">Check component updates</button>
  <button class="gh" onclick="inst('components')">Repair components</button>
  <button class="gh" onclick="inst('upgrade')">Upgrade pinned components</button>
  <span id="vchk" style="color:var(--dim);font-size:11px"></span>
 </div>
 <div id="comps"></div>
 <fieldset><legend>Running model processes</legend>
  <table><thead><tr><th>PID</th><th>Memory</th></tr></thead><tbody id="e4"></tbody></table>
  <div class="hint" style="margin:7px 0 0">The model service starts a model only when you use it and unloads it after its idle timeout.</div>
 </fieldset>
 <fieldset><legend>Endpoints for compatible tools</legend>
  <div class="mode">Model Pilot offers local OpenAI-compatible and Anthropic-compatible endpoints. Choose a listed model id in the tool you connect.</div>
  <table class="ep"><tbody id="eps"></tbody></table>
  <div id="epmodels" class="hint" style="margin:7px 0 0"></div>
 </fieldset>
</div>

<div class="pane" id="p2">
 <div class="section-head"><div><div class="eyebrow">MODEL LIBRARY</div><h1>Models</h1><p>Choose a model that fits this PC, or add one you already downloaded.</p></div></div>
 <section class="surface picker">
  <div class="eyebrow">START HERE</div><h2>Find a model for this PC</h2>
  <p>We rank models against the memory available on this PC. Review the download size before choosing.</p>
  <div class="row">
   <select id="sgcase" aria-label="Recommendation use case" style="width:auto">
    <option value="chat">Everyday chat</option><option value="general">General use</option><option value="reasoning">Reasoning</option><option value="coding">Coding</option>
   </select>
   <button class="act" id="sgbtn" onclick="suggest()">Find models</button>
   <span id="sgmsg" class="subtle"></span>
  </div>
  <div id="sug"></div>
 </section>
 <div class="home-grid model-tools">
  <section class="surface"><div class="eyebrow">ALREADY DOWNLOADED?</div><h2>Find models on your drive</h2>
   <p>Choose a folder and scan for GGUF files. Adding one creates a model entry with 16k context and q8_0 KV defaults; the file stays where it is and is never copied or moved. Tune can measure settings for this PC later.</p>
   <div class="row"><button class="gh" onclick="browseDir()">Choose model folder</button><button class="gh" id="scanModelsBtn" onclick="scanModels()">Scan folder</button></div>
   <div class="subtle" id="modelDirLabel" style="margin-top:9px"></div>
   <div id="modelFiles"></div>
  </section>
  <details class="surface disclosure"><summary>I know which model I want</summary>
   <p>Inspect a Hugging Face repo or paste a direct GGUF URL.</p>
   <div class="row"><input id="repo" aria-label="Hugging Face repository or model URL" placeholder="Hugging Face repo, model URL or .gguf URL" style="flex:1;min-width:240px">
    <button class="gh" onclick="inspect()">Inspect</button></div>
   <div id="insp"></div>
  </details>
 </div>
 <section class="surface"><div class="surface-head"><div><h2>Your models</h2><p>Models configured for this install. Tune a model to measure settings for this PC.</p></div>
  <label class="check-label"><input type="checkbox" id="advchk" onchange="adv(this.checked)"> Advanced settings</label></div>
  <div id="dlbox" class="download-box" style="display:none"><h3>Downloads</h3><div id="dlrows"></div></div>
  <div class="table-wrap"><table id="modelTable"><thead><tr><th>Model</th><th>File size</th><th>Conversation length</th><th class="adv">Context</th><th class="adv">KV</th><th class="adv">MoE</th><th class="adv">Last used</th><th class="adv">Loads</th><th>Status</th><th>Actions</th></tr></thead><tbody id="mt"></tbody></table></div>
  <div id="emptyModels" class="empty-state" style="display:none">No models configured yet. Find a recommendation above or scan a folder for GGUF files.</div>
  <div class="subtle" style="margin-top:10px">Context length describes how much conversation a model can hold. Tune measures a setting that fits this PC.</div>
  <details class="subtle-list"><summary>Unconfigured model files</summary><div class="table-wrap"><table><tbody id="orph"></tbody></table></div></details>
 </section>
</div>


<div class="pane" id="p4">
 <div class="section-head"><div><div class="eyebrow">LIVE HARDWARE</div><h1>Monitoring</h1><p>Sensor history is sampled only while this view is open.</p></div></div>
 <fieldset><legend>Sensors</legend>
  <div class="row" style="margin-bottom:6px">
   <button class="gh" onclick="monReset()">Reset min/max</button>
   <span id="monmeta" style="color:var(--dim);font-size:11px"></span>
  </div>
  <div class="table-wrap"><table class="sens"><thead><tr><th>Sensor</th><th>Current</th><th>Minimum</th><th>Maximum</th><th>Average</th></tr></thead>
   <tbody id="sens"><tr><td colspan="5" style="color:var(--dim)">waiting for the first sample...</td></tr></tbody></table></div>
  <div class="hint" style="margin:7px 0 0">Sampled once a second while this tab is open, and not at all while it isn't. Min/max/average cover the samples since this window opened or since the last reset - they are not a lifetime record.</div>
 </fieldset>
</div>

<div class="pane" id="p5">
 <div class="section-head"><div><div class="eyebrow">BACKGROUND WORK</div><h1>Activity</h1><p>Follow downloads, setup, upgrades and model tuning.</p></div></div>
 <fieldset><legend>Running and recent jobs</legend>
  <div class="mode">Downloads, installs, autotune runs and stack restarts all run detached and write here. This is where their output goes.</div>
  <div id="jobs"></div>
 </fieldset>
</div>

<div class="pane" id="p6">
 <div class="section-head"><div><div class="eyebrow">PREFERENCES</div><h1>Settings</h1><p>Keep your local data protected, up to date and easy to recover.</p></div></div>
 <fieldset><legend>Model storage</legend>
  <div class="row"><input id="mdir" aria-label="Model download folder" style="flex:1" readonly><button class="gh" onclick="browseDir()">Choose folder</button></div>
  <div class="hint" style="margin-top:8px">New downloads are saved here. To find and register existing files, go to Models &gt; Find models on your drive. Files stay in place.</div>
 </fieldset>
 <fieldset><legend>Ports</legend><div class="kv" id="st"></div></fieldset>
 <fieldset><legend>Desktop integration</legend>
  <div class="row"><button class="gh" onclick="mkLnk()">Create desktop &amp; start-menu shortcut</button>
   <span id="lnk" style="color:var(--dim);font-size:11px"></span></div>
  <div class="hint" style="margin-top:8px">Open Model Pilot from the Start Menu or Desktop shortcut. You can also launch the app directly from its install folder.</div>
  <div class="row" style="margin-top:10px"><label><input type="checkbox" id="autost" onchange="setAuto(this.checked)"> Start the stack when I log in</label>
   <span id="autoss" style="color:var(--dim);font-size:11px"></span></div>
  <div class="hint">Brings llama-swap, the chat UI and the tray indicator back on their own after a restart or a crash. The panel itself stays on demand.</div>
 </fieldset>
 <fieldset><legend>Keep Model Pilot current</legend>
  <div class="row"><button class="gh" onclick="checkProductUpdate(true)">Check for app updates</button><span id="appupd" style="color:var(--dim);font-size:11px">Checking GitHub for the current release...</span></div>
 </fieldset>
 <fieldset><legend>Back up and restore</legend>
  <div class="row"><button class="gh" onclick="backupData()">Create backup</button><button class="gh" onclick="loadBackups()">Refresh backups</button></div>
  <div class="hint" style="margin-top:8px">Backups keep chats, users, settings and configuration in a private local ZIP. Model weights, logs and download caches are never included.</div>
  <div class="row" style="margin-top:10px"><select id="backups" aria-label="Local backups" style="flex:1;min-width:240px"><option>Loading backups...</option></select><button class="gh" id="restoreBackup" onclick="restoreBackup()" disabled>Restore selected backup</button></div>
  <div id="backupNote" class="hint" style="margin-top:8px">Restoring first creates a fresh backup, then stops the stack so restored chats and settings can take effect safely.</div>
 </fieldset>
 <fieldset><legend>Help and recovery</legend>
  <div class="row"><button class="gh" onclick="runPreflight()">Check this PC</button><button class="gh" onclick="exportDiagnostics()">Create redacted diagnostic report</button></div>
  <div id="preflight" class="hint" style="margin-top:8px">The PC check looks at disk, memory and accelerator headroom before setup or an upgrade.</div>
  <div class="hint" style="margin-top:8px">The diagnostic ZIP excludes chats, logs, local paths, usernames, tokens and model weights. Review it before sharing through <a href="https://github.com/hgaaditya/modelpilot/issues/new/choose" target="_blank" rel="noreferrer">GitHub support</a>.</div>
 </fieldset>
 <fieldset><legend>Remove parts of the install</legend>
 <div class="hint" style="margin-bottom:8px">Each selected runtime can be reinstalled by pressing Start. The checkbox only deletes GGUF weights inside this installation; model folders you selected elsewhere are always kept. Everything also removes optional ComfyUI models, inputs, outputs and user settings.</div>
  <div class="row" style="gap:8px;flex-wrap:wrap">
   <select id="rstc" aria-label="Install component to remove">
    <option value="llama-cpp">Engine (llama.cpp)</option>
    <option value="llama-prism">PrismML fork</option>
    <option value="swap">Model router binary</option>
    <option value="webui">Chat UI, with its chats and settings</option>
    <option value="llmfit">Model picker (llmfit)</option>
    <option value="uv">Private Python</option>
    <option value="downloads">Download cache</option>
    <option value="logs">Logs</option>
    <option value="metadata">Version stamp and logon shortcut</option>
    <option value="all">Everything (full uninstall)</option>
   </select>
   <button class="gh" onclick="rstShow()">Show what this removes</button>
   <span id="rstmsg" style="color:var(--dim);font-size:11px"></span>
  </div>
  <div id="rstout" style="margin-top:10px"></div>
 </fieldset>
</div>
</main>
<div id="act" role="region" aria-label="Background task activity"><div id="acth"><span id="actt">Working</span><button onclick="actHide()" aria-label="Dismiss activity status">&times;</button></div><div id="actb"></div></div>
<div id="ovl"><div id="dlg" role="dialog" aria-modal="true" aria-labelledby="dlgtitle">
 <h4 id="dlgtitle">Model Pilot</h4>
 <div id="dlgbody"></div>
 <div id="dlgfoot"><button class="gh" id="dlgno">Cancel</button><button class="act" id="dlgyes">OK</button></div>
</div></div>
<script>
// ---- dialogs
// One implementation behind msg/ask/askText, all promise-based so callers just await them.
// Replaces alert/confirm/prompt, whose browser-drawn versions are titled "127.0.0.1:9300 says".
let dlgResolve=null,dlgReturnFocus=null;
function dlgClose(v){
 document.getElementById('ovl').classList.remove('on');
 const previous=dlgReturnFocus;dlgReturnFocus=null;
 if(previous&&previous.isConnected)previous.focus();
 const r=dlgResolve;dlgResolve=null;if(r)r(v);
}
function dlgOpen(o){
 return new Promise(res=>{
  dlgResolve=res;dlgReturnFocus=document.activeElement;
  document.getElementById('dlgtitle').textContent=o.title||'Model Pilot';
  document.getElementById('dlgbody').innerHTML=o.html;
  const yes=document.getElementById('dlgyes'),no=document.getElementById('dlgno');
  yes.textContent=o.ok||'OK';
  yes.className=o.danger?'dz':'act';
  no.style.display=o.noCancel?'none':'';
  no.textContent=o.cancel||'Cancel';
  document.getElementById('ovl').classList.add('on');
  const inp=document.getElementById('dlgin');
  if(inp){inp.focus();inp.select()}else{yes.focus()}
 });
}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;')}
// Plain message - one button, nothing to cancel.
function msg(text,title){return dlgOpen({html:esc(text),ok:'Close',noCancel:true,title})}
// Yes/no. danger:true colours the confirm button as destructive.
function ask(text,opts){opts=opts||{};return dlgOpen({html:esc(text),ok:opts.ok||'Continue',cancel:opts.cancel,danger:opts.danger,title:opts.title})}
// Text entry. Resolves to null on cancel, matching prompt().
async function askText(text,value,help){
 const r=await dlgOpen({html:esc(text)+(help?`<div style="color:var(--dim);font-size:11.5px;margin-top:6px">${esc(help)}</div>`:'')+
   `<input id="dlgin" value="${esc(value==null?'':value)}">`,ok:'Save'});
 return r;
}
document.addEventListener('DOMContentLoaded',()=>{
 document.getElementById('dlgyes').onclick=()=>{const i=document.getElementById('dlgin');dlgClose(i?i.value:true)};
 document.getElementById('dlgno').onclick=()=>dlgClose(null);
 document.getElementById('ovl').onclick=e=>{if(e.target.id==='ovl')dlgClose(null)};
});
document.addEventListener('keydown',e=>{
 if(!dlgResolve)return;
 if(e.key==='Escape'){e.preventDefault();dlgClose(null);return}
 const dlg=document.getElementById('dlg');
 if(e.key==='Tab'){
  const items=[...dlg.querySelectorAll('button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])')]
   .filter(x=>x.getClientRects().length);
  if(!items.length){e.preventDefault();dlg.focus();return}
  const first=items[0],last=items[items.length-1];
  if(!dlg.contains(document.activeElement)){e.preventDefault();first.focus()}
  else if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus()}
  else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus()}
  return;
 }
 if(e.key==='Enter'&&document.activeElement.tagName!=='BUTTON'){
  e.preventDefault();const i=document.getElementById('dlgin');dlgClose(i?i.value:true)
 }
});

let S={},E={},M={},VER={},JOBS=[],EP={},BUILD=null,pollBusy=false;
// Every button here starts a detached job and returns immediately, so for up to one poll
// interval a click had no visible effect whatsoever - which reads as the click not registering.
// Busy state comes from the server's job list plus an optimistic mark for the round-trip gap.
// The action response attaches the exact job id, so an older same-name log cannot clear this
// click's mark. The deadline is only a backstop if the request never yields a job.
let PEND={};
function mark(k,ms){PEND[k]={d:Date.now()+(ms||10000),id:null}}
function busy(k){
 if(JOBS.some(j=>j.running&&j.name===k))return true;
 const p=PEND[k];
 if(p&&Date.now()<p.d)return true;
 delete PEND[k];return false;
}
// Called from the click handler, before the fetch. window.event is deprecated in general but
// exact here: this page only ever runs in the Chromium window we launch, and it gives the
// clicked button without threading an event argument through every call site.
function spin(k,ms){
 mark(k,ms);
 ACTHID=0;   // a new action un-hides the card; dismissing it should not silence the next one
 activity([]);
 const b=window.event&&window.event.target;
 if(b&&b.tagName==='BUTTON'){b.classList.add('busy');b.disabled=true}
}
// Buttons inside panels are rebuilt from scratch on every poll, so their busy state has to be
// re-derived at render time rather than set once on the element.
function B(cls,key,onclick,label){
 const b=busy(key);
 return `<button class="${cls}${b?' busy':''}"${b?' disabled':''} onclick="${onclick}">${label}</button>`;
}
// Every API call carries the per-run token. Being a custom header, it also forces a CORS
// preflight for anyone cross-origin, which this server does not answer.
const TOK='@@TOKEN@@';
const _f=window.fetch;
window.fetch=(u,o)=>{o=o||{};o.headers=Object.assign({},o.headers,{'X-LocalLLM-Token':TOK});return _f(u,o)};
function tab(i,b){
 document.querySelectorAll('.pane').forEach(p=>p.classList.toggle('on',p.id==='p'+i));
 document.querySelectorAll('nav button').forEach(x=>{x.classList.remove('on');x.removeAttribute('aria-current')});
 const primary=document.querySelector(`nav button[data-pane="${i}"]`);
 const more=document.getElementById('moreNav'),menu=document.getElementById('navMore');
 more.removeAttribute('aria-current');
 menu.open=false;
 if(primary){
  primary.classList.add('on');primary.setAttribute('aria-current','page');
  more.textContent='More';more.setAttribute('aria-label','More navigation');more.classList.remove('on');
 }else{
  const label={1:'System',4:'Monitoring'}[i]||'More';
  more.textContent='More · '+label;more.setAttribute('aria-label','More navigation, current section: '+label);
  more.setAttribute('aria-current','page');more.classList.add('on');if(b)b.classList.add('on');
 }
 // Sampling costs an nvidia-smi spawn per second on a single-threaded server, so it only runs
 // while the tab that shows it is actually in front.
 monRun(i===4);
 if(i===1)tick();
 if(i===6){auto();loadBackups()}
}
// ---- sensors (Monitoring tab)
let MON={},monTimer=null,monN=0;
function monReset(){MON={};monN=0;document.getElementById('sens').innerHTML=''}
// Sampling schedules itself instead of running on a fixed 1 Hz interval, and that is a
// correctness fix rather than tuning. /api/sensors spawns nvidia-smi and reads WMI: measured
// here it takes 1,128-1,641 ms, so setInterval(mon,1000) asked for work faster than it could
// ever be finished. Against a single-threaded listener the requests piled up, and everything
// else in the panel - the 3s status poll, the health dot, every button - queued behind that
// backlog. The next sample is now scheduled only once the last one has come back.
function monRun(on){
 if(on&&!monTimer){monTimer=1;monTick()}
 if(!on&&monTimer){clearTimeout(monTimer);monTimer=null}
}
async function monTick(){
 const t0=Date.now();
 try{await mon()}catch(e){}
 // one second is a floor, not a promise: a card that takes 1.6s to read is sampled every 1.6s.
 if(monTimer!==null)monTimer=setTimeout(monTick,Math.max(1000,Date.now()-t0));
}
async function mon(){
 let d;try{d=await (await fetch('/api/sensors')).json()}catch(e){return}
 monN++;
 const rows=(d.sensors||[]).map(s=>{
  // A sensor the card doesn't report stays blank rather than counting as zero, which would drag
  // an average toward a number that was never measured.
  if(s.value===null||s.value===undefined)return `<tr><td>${s.name}</td><td colspan="4" style="color:var(--dim);text-align:right">not reported</td></tr>`;
  const a=MON[s.name]||(MON[s.name]={min:s.value,max:s.value,sum:0,n:0});
  a.min=Math.min(a.min,s.value);a.max=Math.max(a.max,s.value);a.sum+=s.value;a.n++;
  const f=v=>(Math.round(v*10)/10).toLocaleString();
  const u=s.unit?' '+s.unit:'';
  return `<tr><td>${s.name}</td><td class="now">${f(s.value)}${u}</td><td>${f(a.min)}${u}</td><td>${f(a.max)}${u}</td><td>${f(a.sum/a.n)}${u}</td></tr>`;
 }).join('');
 document.getElementById('sens').innerHTML=rows||'<tr><td colspan="5" style="color:var(--dim)">no sensors available (no NVIDIA GPU detected)</td></tr>';
 document.getElementById('monmeta').textContent=monN+' sample'+(monN===1?'':'s')+(d.loaded?'  -  model loaded: '+d.loaded:'  -  no model loaded');
}
async function post(u,o){return await (await fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(o||{})})).json()}
// Map the ticked services onto start.ps1's -Component, which takes all|swap|webui.
function selected(){
 const s=(S.services||[]).filter(x=>x.managed&&x.selected).map(x=>x.key);
 if(s.length===2)return 'all';
 if(s.length===1)return s[0];
 return null;   // nothing ticked - there is no action to take
}
// Job names carry the component, so restarting swap doesn't spin the webui button too.
function jkey(a,comp){return (comp&&comp!=='all')?a+'-'+comp:a}
async function act(a,c){
 const comp=(c!==undefined)?c:selected();
 if(comp===null){msg('No services are selected. Choose a service under System, then try again.');return}
 const k=jkey(a,comp);
 spin(k,a==='deploy'?600000:60000);
 try{
  const r=await post('/api/action',{action:a,component:comp});
  if(r.error){delete PEND[k];msg('Could not '+a+' selected services: '+r.error);setTimeout(tick,300);return}
  if(PEND[k]&&r.id)PEND[k].id=r.id;
  setTimeout(tick,1200);
 }catch(e){
  delete PEND[k];
  msg('Could not '+a+' selected services: '+e.message);
  setTimeout(tick,300);
 }
}
// The tick decides what Start/Stop act on; it does not itself start or stop anything. Unticking a
// service that is up therefore leaves it running and simultaneously removes it from the health
// summary, which is the one combination nobody expects - so offer the obvious follow-up rather
// than making the checkbox silently destructive.
async function toggleSvc(key,on){
 const svc=(S.services||[]).find(x=>x.key===key);
 await post('/api/settings',key==='swap'?{useSwap:on}:{useWebui:on});
 if(!on&&svc&&svc.up){
  if(await ask(svc.name+' is still running on its port. Unticking it only removes it from Start, Stop and the status summary.',
    {ok:'Stop '+svc.name,cancel:'Leave it running'})){act('stop',key);return}
 }
 tick();
}
// Loading is the one action with no job behind it - llama-swap swaps the model in when the
// one-token request lands. The mark clears when the model shows up as loaded, so the ceiling is
// only a backstop for a load that fails outright.
async function load(id){spin('load:'+id,300000);await post('/api/load',{id});setTimeout(tick,700)}
async function unloadAll(){spin('unload',8000);await post('/api/unload',{});setTimeout(tick,700)}
async function browseDir(){
 const r=await post('/api/browse-models',{});
 if(r.path){document.getElementById('mdir').value=r.path;await saveDir()}
}
async function saveDir(){
 const r=await post('/api/settings',{modelsDir:document.getElementById('mdir').value});
 if(r.error){msg(r.error);return}
 document.getElementById('mdir').value=r.modelsDir;tick()
}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
async function scanModels(notice){
 const box=document.getElementById('modelFiles'),btn=document.getElementById('scanModelsBtn');
 if(btn){btn.disabled=true;btn.textContent='Scanning...'}
 box.innerHTML='<div class="hint" role="status">Scanning the selected folder and its subfolders for GGUF files...</div>';
 try{
  const r=await fetch('/api/model-files'),d=await r.json();
  if(d.error){box.innerHTML='<div class="hint miss">'+esc(d.error)+'</div>';return}
  const files=d.files||[],addable=files.filter(f=>!f.conflict).length,warnings=d.scanWarnings||[];
  const summary=notice?'<div class="hint">'+esc(notice)+'</div>':'';
  const warning=warnings.length?`<div class="hint miss" role="alert"><b>Scan incomplete.</b> ${warnings.length} folder or file path${warnings.length===1?'':'s'} could not be read. Results may be incomplete. Check access permissions or choose another folder.${warnings.length?'<div class="subtle" style="margin-top:5px">'+warnings.slice(0,3).map(esc).join('<br>')+'</div>':''}</div>`:'';
  const count=`<div class="subtle" style="margin:8px 0">${addable} file${addable===1?'':'s'} ready to add${files.length>addable?`; ${files.length-addable} filename conflict${files.length-addable===1?'':'s'} need attention`:''}. Existing registered files are hidden.</div>`;
  const empty=warnings.length?'<div class="hint">No unregistered GGUF files were found in the folders this app could read.</div>':'<div class="hint">No unregistered GGUF model files found in this folder. Files already in your model list are hidden here.</div>';
  const table=files.length?'<table class="import-table"><thead><tr><th>File and location</th><th>Size</th><th>Action</th></tr></thead><tbody>'+
   files.map(f=>`<tr><td><b>${esc(f.name)}</b><div class="subtle" style="margin-top:3px;word-break:break-all">${esc(f.path)}</div></td><td>~${esc(f.sizeGb)} GB</td><td>${f.conflict?`<span class="miss">${esc(f.conflict)}</span>`:`<button class="act" onclick="registerModel(decodeURIComponent('${encodeURIComponent(f.path).replace(/'/g,'%27')}'),this)">Add to Models</button>`}</td></tr>`).join('')+
   '</tbody></table>':empty;
  box.innerHTML=summary+warning+count+table;
 }catch(e){box.innerHTML='<div class="hint miss">Could not scan this folder: '+esc(e)+'</div>'}
 finally{if(btn){btn.disabled=false;btn.textContent='Scan folder'}}
}
async function registerModel(path,btn){
 if(btn&&btn.disabled)return;
 if(btn){btn.disabled=true;btn.textContent='Adding...'}
 try{
  const r=await post('/api/register-model',{path});
  if(r.error){msg(r.error);return}
  await scanModels('Registered "'+r.id+'". The file stays in place; the new entry starts at 16k context with q8_0 KV cache.');
  tick()
 }catch(e){msg('Could not register this file: '+e)}
 finally{if(btn){btn.disabled=false;btn.textContent='Add to Models'}}
}
async function tune(id){spin('autotune-'+id,900000);await post('/api/autotune',{id});setTimeout(tick,700)}
async function inst(what){
 const names={components:'install or repair all components',upgrade:'upgrade to the pinned versions',
  'upgrade-latest':'upgrade to the newest upstream releases','prism':'install the PrismML fork (~620 MB)'};
 if(!await ask('This will '+names[what]+'.\n\nThe stack is stopped and restarted. Model weights and config.yaml are not touched.'))return;
 // Job names are set server-side: components->install, upgrade/upgrade-latest->upgrade, prism->prism.
 mark({components:'install',upgrade:'upgrade','upgrade-latest':'upgrade',prism:'prism'}[what],1800000);
 await post('/api/install',{what});setTimeout(tick,900);
}
async function chk(){
 spin('vercheck',120000);
 document.getElementById('vchk').textContent='querying GitHub and nodejs.org...';
 try{VER=await (await fetch('/api/versions?refresh=1')).json();
  document.getElementById('vchk').textContent='checked '+VER.checked}
 catch(e){document.getElementById('vchk').textContent='check failed'}
 delete PEND['vercheck'];tick();
}
async function checkProductUpdate(manual){
 const box=document.getElementById('appupd'); if(!box)return;
 if(manual)box.textContent='Checking GitHub...';
 try{
  await fetch('/api/product-update?run=1');
  const d=await waitFor('/api/product-update',30000);
  if(d.error)throw new Error(d.error);
  if(d.available)box.innerHTML='Version '+esc(d.latest)+' is ready. <button class="act" onclick="applyAppUpdate()">Update now</button>';
  else box.textContent='Model Pilot '+d.current+' is up to date.';
 }catch(e){box.textContent='Could not check for app updates. Try again when online.'}
}
async function applyAppUpdate(){
 if(!await ask('Download the verified release installer, update this app, and restart the control panel?\n\nYour models, chats and settings are kept.',{ok:'Update and restart'}))return;
 mark('app-update',1800000);await post('/api/app-update',{});document.getElementById('appupd').textContent='Downloading and applying the update. The panel will restart automatically.';
}
async function runPreflight(){
 const box=document.getElementById('preflight');box.textContent='Checking disk, memory and accelerator headroom...';
 try{
  await fetch('/api/preflight?run=1');const d=await waitFor('/api/preflight',30000);
  if(d.error)throw new Error(d.error);
  box.innerHTML=(d.checks||[]).map(c=>'<div class="'+(c.ok?'':'miss')+'"><b>'+esc(c.name)+':</b> '+esc(c.value)+' — '+esc(c.detail)+'</div>').join('');
 }catch(e){box.textContent='Could not complete the readiness check. See Activity for details.'}
}
async function backupData(){
 if(!await ask('Create a private local ZIP backup of chats, users, settings and configuration?\n\nModel weights, logs and download caches are excluded. The archive includes the Open WebUI session key, so keep it private.',{ok:'Create backup'}))return;
 mark('backup',300000);await post('/api/backup',{});document.getElementById('backupNote').textContent='Creating the backup. Its location will appear in Activity.';setTimeout(loadBackups,1200);
}
async function loadBackups(){
 const sel=document.getElementById('backups'),go=document.getElementById('restoreBackup');if(!sel||!go)return;
 try{
  const d=await (await fetch('/api/backups')).json(),items=d.backups||[];
  sel.innerHTML=items.length?items.map(x=>`<option value="${esc(x.path)}">${esc(x.name)} — ${fmtB(x.bytes)} — ${new Date(x.created).toLocaleString()}</option>`).join(''):'<option value="">No local backups yet</option>';
  go.disabled=!items.length;
 }catch(e){sel.innerHTML='<option value="">Could not read backups</option>';go.disabled=true}
}
async function restoreBackup(){
 const sel=document.getElementById('backups'),path=sel&&sel.value;if(!path)return;
 if(!await ask('Restore chats, settings and configuration from the selected backup?\n\nA fresh backup is created first. The stack is then stopped; press Start when the restore finishes.',{ok:'Restore backup',danger:true}))return;
 mark('restore',600000);await post('/api/restore',{path});document.getElementById('backupNote').textContent='Restoring the selected backup. A fresh safety backup is created first; see Activity for progress.';setTimeout(tick,900);
}
async function exportDiagnostics(){
 mark('diagnostics',120000);await post('/api/diagnostics',{});document.getElementById('preflight').textContent='Creating a redacted diagnostic ZIP. Its location will appear in Activity.';setTimeout(tick,700);
}
// Context and KV quantisation are just flags on the model's cmd, so they can be changed here -
// unlike the weight quantisation (Q4_K_M vs Q6_K), which is a different file and means a
// download. Writing them is start.ps1's Set-ModelTuning, the same code -Action autotune applies.
async function edit(id){
 const m=(M.models||[]).find(x=>x.id===id); if(!m)return;
 const ctx=await askText('Context size for "'+id+'", in tokens (-c).',m.ctx||16384,
   'Bigger costs VRAM - every token has to fit alongside the weights. Tune measures the largest that fits instead of guessing.');
 if(ctx===null)return;
 if(!/^\d+$/.test(ctx.trim())||+ctx<256){msg('Context has to be a whole number of tokens, 256 or more.');return}
 const kv=await askText('KV cache type for "'+id+'" (-ctk/-ctv).',m.kv||'q8_0',
   'q8_0 keeps long-context recall. q4_0 halves the cache, so more context fits in the same VRAM. f16 is unquantised and largest.');
 if(kv===null)return;
 if(!['q8_0','q4_0','q4_1','q5_0','q5_1','f16','f32'].includes(kv.trim())){msg('Unknown KV type "'+kv.trim()+'".');return}
 spin('edit:'+id,20000);
 const r=await (await fetch('/api/tune',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({id,ctx:+ctx,kv:kv.trim()})})).json();
 delete PEND['edit:'+id];
 if(r.error){msg('Could not write the config: '+r.error);tick();return}
 // llama-swap runs with -watch-config, so it re-reads the file within ~2s - no restart. What a
 // reload does NOT do is re-spawn a llama-server that is already running: that one keeps the -c
 // it was started with. So evict it if it's the model just edited, and say nothing otherwise.
 if(S.loaded===id){await post('/api/unload',{});msg('Saved. The model was unloaded so the next request picks up the new settings.')}
 tick();
}
// Deleting weights is multi-GB and irreversible, so it asks twice: once for the files, then
// separately about the config entry, which is a different decision.
async function del(id,gb){
 if(!await ask('Delete the weight files for "'+id+'"?\n\nThis frees about '+gb+' GB and cannot be undone - the model would have to be downloaded again.',
   {ok:'Delete '+gb+' GB',danger:true}))return;
 const alsoConfig=!!await ask('Also remove the "'+id+'" entry from config.yaml?\n\nKeeping it leaves the model listed with no weights, which is useful if you plan to download it again.',
   {ok:'Remove the entry too',cancel:'Keep the entry'});
 const r=await (await fetch('/api/delete-model',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id,alsoConfig})})).json();
 // No restart after removing the entry - llama-swap watches config.yaml (-watch-config).
 if(r.error)msg('Delete failed: '+r.error);
 setTimeout(tick,700);
}
function fmt(mb){return (mb/1024).toFixed(1)+' GB'}
// minfit is only ever set by the "include tighter fits" button on an empty result - the default
// is llmfit's 'good', and quietly starting from 'marginal' would recommend models that thrash.
// The server answers {running:true} until the job it started has finished. Polling here rather
// than holding the request open is the whole point: the listener stays free, so the page keeps
// updating and the activity card can animate while the work runs.
async function waitFor(url,ms){
 const until=Date.now()+(ms||180000);
 for(;;){
  const d=await (await fetch(url)).json();
  if(!d.running)return d;
  if(Date.now()>until)return {error:'Gave up waiting. It may still be running - see Activity.'};
  await new Promise(r=>setTimeout(r,1500));
 }
}
function relaxUse(){document.getElementById('sgcase').value='general';suggest()}
async function suggest(minfit){
 const b=document.getElementById('sgbtn');b.classList.add('busy');b.disabled=true;
 const use=document.getElementById('sgcase').value;
 document.getElementById('sgmsg').textContent='scoring models against this hardware...';
 try{
  const qs='/api/suggest?usecase='+encodeURIComponent(use)+(minfit?'&minfit='+minfit:'');
  spin('suggest',180000);
  const started=await (await fetch(qs+'&run=1')).json();
  const d=started.needInstall?started:await waitFor(qs,180000);
  // The picker is a separate 5 MB binary. Telling someone to go and run a CLI action is exactly
  // the friction this panel exists to remove, so the error turns into the button that fixes it.
  if(d.needInstall){document.getElementById('sug').innerHTML=
    '<div class="hint">The model picker is a separate 5 MB download. '
    +'<button class="act" onclick="installPicker()">Install model picker</button></div>';return}
  if(d.error){document.getElementById('sug').innerHTML='<div class="hint miss">'+esc(d.error)+'</div>';return}
  const m=d.models||[];
  document.getElementById('sug').innerHTML=m.length?
   '<div class="model-pick-grid">'+m.map(x=>{
    const grade=String(x.fit||'Potential fit'),fitClass=/^(perfect|good)$/i.test(grade)?'good':/marginal|poor/i.test(grade)?'warn':'';
    const reasons={perfect:'Strong hardware-fit estimate; actual speed still depends on context and other apps.',
      good:'Good hardware-fit estimate. Review download size and estimated speed before choosing.',
      marginal:'Tighter fit estimate; you may need to reduce context or accept slower generation.',
      poor:'Weak fit estimate; expect trade-offs in headroom or speed.'};
    const reason=reasons[grade.toLowerCase()]||'llmfit hardware-fit estimate; this is not a measured model run.';
    const fit=esc(grade),repo=encodeURIComponent(x.repo).replace(/'/g,'%27'),quant=encodeURIComponent(x.quant).replace(/'/g,'%27');
    const license=x.license?`<span>License: ${esc(x.license)}</span>`:'';
    return `<article class="model-pick"><div class="model-pick-head"><div><h3>${esc(x.name)}</h3><div class="subtle">${esc(x.quant)} quant</div></div><span class="fit ${fitClass}">${fit} fit</span></div>
     <p class="recommendation-reason">${reason}</p>
     <div class="model-stats"><span>~${esc(x.sizeGb)} GB download</span><span>~${esc(x.tps)} tok/s estimate</span><span>Trained context up to ${esc(x.ctx||'unknown')} tokens</span>${x.moe?'<span>MoE architecture</span>':''}${license}</div>
     <button class="act" onclick="dl(decodeURIComponent('${repo}'),decodeURIComponent('${quant}'))">Download ~${esc(x.sizeGb)} GB</button></article>`
   }).join('')+'</div><div class="subtle" style="margin-top:12px">Speed is an estimate from memory bandwidth, not a benchmark. Context shown is the trained maximum; Tune measures what fits on this PC.</div>'
   :'<div class="hint"><b>No recommendations for this choice.</b> This is not proof that no model can run on this PC - '
    +(use?'the <b>'+esc(use)+'</b> use case':'the current choice')
    +' ruled everything out'+(minfit?' even at a looser fit':'')+'. Try a broader choice or scan files already on your drive.<div class="row" style="margin-top:7px">'
    +(use?'<button class="gh" onclick="relaxUse()">Try general use</button>':'')
    +(minfit?'':'<button class="gh" onclick="suggest(&quot;marginal&quot;)">Include tighter fits</button>')
    +'<button class="gh" onclick="focusModelScanner()">Scan local files</button>'
    +'</div><div class="note" style="margin-top:6px">These are hardware-fit estimates, not measured model runs.</div></div>';
  document.getElementById('sgmsg').textContent='';
 }catch(e){document.getElementById('sug').innerHTML='<div class="hint miss">'+e+'</div>'}
 finally{b.classList.remove('busy');b.disabled=false;document.getElementById('sgmsg').textContent='';delete PEND['suggest'];activity([])}
}
// Keep the primary journey one click away from Home.
function gotoModels(){const b=document.querySelector('nav button[data-pane="2"]');if(b)tab(2,b)}
function focusModelScanner(){document.getElementById('modelDirLabel').scrollIntoView({behavior:'smooth',block:'center'});document.getElementById('scanModelsBtn').focus({preventScroll:true})}
function openChat(){const port=(M.settings&&M.settings.webuiPort)||8080;window.open('http://127.0.0.1:'+port,'_blank')}
async function verifyModel(id){
 const box=document.getElementById('verifyResult');
 box.style.display='block';box.innerHTML='<div class="hint" role="status">Sending a real completion. A cold model may take several minutes to load.</div>';
 spin('verify-model',900000);
 try{
  const started=await post('/api/verify-model',{id});
  if(started.error)throw new Error(started.error);
  const d=await waitFor('/api/verify-model?id='+encodeURIComponent(id),900000);
  const lines=(d.out||[]).map(x=>String(x)),output=lines.join('\n'),passed=output.includes('[MODEL_RESPONSE_CHECK_PASSED]');
  const detail=[output,d.err||''].filter(Boolean).join('\n');
  box.innerHTML=`<div class="hint ${passed?'':'miss'}"><b>${passed?'A real response was received.':'The response check failed.'}</b><pre>${esc(detail||d.error||'No output was recorded. See Activity for details.')}</pre></div>`;
 }catch(e){box.innerHTML='<div class="hint miss">Response check failed: '+esc(e)+'</div>'}
 finally{delete PEND['verify-model'];tick()}
}
function firstModel(){
 gotoModels();
 document.getElementById('sgcase').value='chat';
 suggest();
}
async function installPicker(){
 spin('llmfit',300000);
 await post('/api/install-picker',{});
 document.getElementById('sug').innerHTML='<div class="hint">Installing the picker - it appears under Activity. Press <b>Find models</b> again in a moment.</div>';
 setTimeout(tick,900);
}
async function inspect(){
 const r=document.getElementById('repo').value.trim(); if(!r)return;
 spin('inspect',120000);
 document.getElementById('insp').innerHTML='<div class="hint">Reading metadata over the network - a few MB, no weights. This takes ~40s.</div>';
 try{const qs='/api/inspect?model='+encodeURIComponent(r);
  await fetch(qs+'&run=1');
  const d=await waitFor(qs,180000);
  if(d.error){document.getElementById('insp').innerHTML='<div class="hint miss">'+d.error+'</div>';return}
  document.getElementById('insp').innerHTML='<div class="hint">'+d.summary+'</div><table><thead><tr><th>Variant</th><th>Size</th><th>Verdict</th><th></th></tr></thead><tbody>'+
   d.variants.map(v=>`<tr><td>${v.name}</td><td>${v.size}</td><td>${v.fits?'<span class="on2">'+v.verdict+'</span>':'<span class="miss">'+v.verdict+'</span>'}</td>
   <td><button class="gh" onclick="dl('${d.repo}','${v.quant}')">Download</button></td></tr>`).join('')+'</tbody></table>';
 }catch(e){document.getElementById('insp').innerHTML='<div class="hint miss">'+e+'</div>'}
 delete PEND['inspect'];activity([]);
}
// Destructive, so it is deliberately two steps: this only ever asks the server what would go, and
// the delete needs a separate confirmation naming the size. Nothing here deletes on first click.
let RSTPOLL=0;
async function rstShow(){
 const comp=document.getElementById('rstc').value;
 const inc=comp==='llama-cpp'||comp==='all' ? !!document.getElementById('rstim')?.checked : false;
 document.getElementById('rstmsg').textContent='working out what that removes...';
 document.getElementById('rstout').innerHTML='';
 clearTimeout(RSTPOLL);
 await post('/api/reset',{component:comp,includeModels:inc,run:1});
 const poll=async()=>{
  let d; try{d=await post('/api/reset',{component:comp,includeModels:inc})}catch(e){return}
  if(d.running){RSTPOLL=setTimeout(poll,700);return}
  rstRender(comp,inc,d.targets||[]);
 };
 RSTPOLL=setTimeout(poll,700);
}
function rstRender(comp,inc,t){
 document.getElementById('rstmsg').textContent='';
 const out=document.getElementById('rstout');
 if(!t.length){out.innerHTML='<div class="hint">Nothing of that is installed.</div>';return}
 const tot=t.reduce((a,x)=>a+(x.Bytes||0),0);
 let h='<table style="width:100%;font-size:12px"><tbody>';
 for(const x of t) h+='<tr><td style="padding:2px 8px 2px 0">'+esc(x.Label||'')+'</td>'
   +'<td style="color:var(--dim);word-break:break-all">'+esc(x.Path)+'</td>'
   +'<td style="text-align:right;white-space:nowrap">'+fmtB(x.Bytes||0)+'</td></tr>';
 h+='</tbody></table>';
 h+='<div class="row" style="margin-top:8px;gap:8px">';
 if(comp==='llama-cpp'||comp==='all')
   h+='<label style="font-size:12px"><input type="checkbox" id="rstim" '+(inc?'checked':'')+' onchange="rstShow()"> also delete GGUF weights inside this install (external folders are kept)</label>';
 h+='<button class="act" id="rstgo" style="background:#b3261e">Delete '+fmtB(tot)+'</button></div>';
 out.innerHTML=h;
 // Wired here rather than as an inline onclick: the whole page is a PowerShell here-string,
 // so a quote inside an attribute is one escaping layer away from a dead button.
 const go=document.getElementById('rstgo');
 if(go) go.onclick=()=>rstGo(comp,inc,tot);
}
function fmtB(b){
 if(b>=1073741824)return (b/1073741824).toFixed(1)+' GB';
 if(b>=1048576)return Math.round(b/1048576)+' MB';
 if(b>=1024)return Math.round(b/1024)+' KB';
 return b+' B';
}
async function rstGo(comp,inc,tot){
 const what=comp==='all'?'the whole install':'"'+comp+'"';
 // ask() escapes its text into HTML, so newlines would collapse - one flowing paragraph instead.
 // The button carries the size rather than saying OK: this repo's rule for destructive confirms.
 let warn='This deletes '+what+', '+fmtB(tot)+'. ';
 if(comp==='webui'||comp==='all') warn+='That includes your chat history and open-webui settings, which are not backed up anywhere. ';
 if(comp==='all') warn+='If installed, ComfyUI and its local models, inputs, outputs and user settings are included in the deletion list. ';
 warn+=inc?'GGUF weights inside this installation WILL be deleted - multi-GB and slow to fetch again. External model folders are always kept. ':'GGUF weights are kept. External model folders are always kept. ';
 if(!await ask(warn,{danger:true,ok:'Delete '+fmtB(tot)})) return;
 spin('reset-'+comp,600000);
 await post('/api/reset',{component:comp,includeModels:inc,confirm:true});
 document.getElementById('rstout').innerHTML='';
 document.getElementById('rstmsg').textContent='';
 setTimeout(tick,1200);
}
async function auto(set){
 const box=document.getElementById('autost'), note=document.getElementById('autoss');
 if(set!==undefined) note.textContent='working...';
 try{const d=await (await fetch('/api/autostart',{method:'POST',body:JSON.stringify(set===undefined?{}:{set:set})})).json();
  box.checked=!!d.on; note.textContent=(set===undefined)?'':(d.on?'on':'off');
 }catch(e){note.textContent=''+e}
}
const setAuto=v=>auto(v);
async function mkLnk(){
 document.getElementById('lnk').textContent='working...';
 try{const d=await (await fetch('/api/shortcuts',{method:'POST'})).json();
  document.getElementById('lnk').textContent=d.error?d.error:'created: '+d.paths.join('  |  ');
 }catch(e){document.getElementById('lnk').textContent=''+e}
}
// Previous sample per file, so speed is measured over the real gap between polls rather than
// assumed to be one tick. A file that disappears from the list takes its sample with it.
// -c is a token budget, which means nothing to someone choosing their first model. Words are
// the unit they actually think in - roughly 0.75 words per token - and the band is what decides
// whether a long chat survives, so both are shown and the raw number moves behind the toggle.
function chat(ctx){
 if(!ctx)return '-';
 const w=Math.round(ctx*0.75/1000);
 const band=ctx>=98304?'very long':ctx>=49152?'long':ctx>=24576?'medium':'short';
 return `${band} <span style="color:var(--dim)">~${w}k words</span>`;
}
try{if(localStorage.getItem('showadv'))document.addEventListener('DOMContentLoaded',()=>{document.getElementById('advchk').checked=true;adv(true)})}catch(e){}
function adv(on){document.body.classList.toggle('showadv',on);try{localStorage.setItem('showadv',on?'1':'')}catch(e){}}
// What each slow action is, in the user's terms, and how long it usually takes. Keyed by the same
// string spin() already uses, so adding an action means adding a line here and nothing else.
// Without this the panel's answer to "did my click do anything" was a disabled button and, minutes
// later, a log tail under Activity - which is not an answer.
const JOBS_SAY={
 // The Start button runs -Action deploy, but on an installed machine that downloads nothing -
 // every step is skipped and it just launches. Saying "Downloads the engine..." there was a
 // plain lie, and it made a two-second start look like it was doing something enormous.
 reset:['Removing part of the install','Deleting files. Press Start afterwards to reinstall whatever you removed.'],
 deploy:['Starting','Launches the router and the chat UI. First-run setup downloads and builds the stack; the wait depends on your connection and PC.'],
 restart:['Restarting','A few seconds. The chat UI takes longer than the router.'],
 stop:['Stopping',''],
 download:['Downloading a model','Multi-GB. Safe to interrupt - it resumes where it stopped.'],
 llmfit:['Installing the model picker','About 5 MB.'],
 inspect:['Reading the model listing','Metadata only, no weights. Around 40 seconds.'],
 suggest:['Scoring models against this PC','Ranks the catalogue against your RAM, VRAM and memory bandwidth. Up to a minute.'],
 'verify-model':['Checking a real model response','Sends one short completion and records the model reply here. A cold load can take several minutes.'],
 unload:['Freeing VRAM',''],
 vercheck:['Checking for newer versions','Asks GitHub and nodejs.org.'],
 backup:['Creating your backup','Chats, users, settings and configuration are being archived locally.'],
 restore:['Restoring your backup','A fresh safety backup is created first, then restored data replaces chats and settings.'],
 diagnostics:['Creating a redacted diagnostic report','The ZIP excludes chats, logs, local paths, usernames, tokens and model weights.']
};
function jobSay(k){
 if(k==='verify-model')return JOBS_SAY[k];
 const base=k.split(/[:\-]/)[0], who=k.slice(base.length+1);
 if(base==='load')  return ['Loading '+who,'Reading multi-GB weights into VRAM. Ten seconds to a minute.'];
 if(base==='edit')  return ['Saving settings for '+who,''];
 if(base==='autotune')return['Measuring what fits for '+who,'Loads the model repeatedly at different settings. Several minutes.'];
 const e=JOBS_SAY[base]||JOBS_SAY[k];
 if(e)return [e[0]+(who&&who!=='all'?' ('+who+')':''),e[1]];
 return [k,''];
}
let ACTHID=0;
function actHide(){ACTHID=Date.now();document.getElementById('act').classList.remove('on')}
// Rendered from busy() - the same source the buttons use - so the card appears on the click that
// starts something, not on the poll that eventually notices it.
function activity(dls){
 const keys=[...new Set([...Object.keys(PEND),...JOBS.filter(j=>j.running).map(j=>j.name)])].filter(busy);
 const card=document.getElementById('act');
 if(!keys.length){card.classList.remove('on');ACTHID=0;return}
 if(ACTHID){card.classList.remove('on');return}
 card.classList.add('on');
 document.getElementById('actt').textContent=keys.length>1?keys.length+' things running':'Working';
 document.getElementById('actb').innerHTML=keys.map(k=>{
  const [title,note]=jobSay(k);
  const j=JOBS.find(x=>x.running&&x.name===k);
  const line=(j&&j.tail||'').split('\n').filter(t=>t.trim()).pop()||'';
  // A download knows its real percentage, so it gets a real bar; everything else gets a moving
  // one, which says "alive" without claiming to know how far along it is.
  const d=k==='download'&&dls.length?dls[0]:null;
  const pct=d&&d.total?Math.min(100,d.bytes*100/d.total):null;
  return `<div class="job"><b>${esc(title)}</b>
   ${note?`<div class="note">${esc(note)}</div>`:''}
   <div class="bar${pct===null?' indet':''}"><i${pct===null?'':` style="width:${pct.toFixed(1)}%"`}></i></div>
   ${line?`<pre>${esc(line).slice(0,200)}</pre>`:''}</div>`
 }).join('');
}
let DLP={};
function gb(b){return (b/1073741824).toFixed(2)+' GB'}
function downloads(rows){
 const box=document.getElementById('dlbox');
 box.style.display=rows.length?'':'none';
 if(!rows.length){DLP={};return}
 const now=Date.now();
 document.getElementById('dlrows').innerHTML=rows.map(d=>{
  const prev=DLP[d.file];
  let rate=0;
  if(prev&&now>prev.t&&d.bytes>prev.b)rate=(d.bytes-prev.b)/((now-prev.t)/1000);
  DLP[d.file]={t:now,b:d.bytes,rate:rate||(prev?prev.rate:0)};
  const r=DLP[d.file].rate;
  // total is 0 for a bare .gguf URL, where nothing announced a size - show what has arrived
  // rather than a percentage that would have to be invented.
  const pct=d.total?Math.min(100,d.bytes*100/d.total):null;
  const eta=(r>0&&d.total&&d.total>d.bytes)?Math.round((d.total-d.bytes)/r):null;
  const stalled=d.idle>90;
  const right=stalled?'<span class="miss">no data for '+Math.round(d.idle/60)+' min - it may have died; re-run the download, it resumes</span>'
   :[pct!==null?pct.toFixed(1)+'%':'size unknown',
     gb(d.bytes)+(d.total?' of '+gb(d.total):''),
     r>0?(r/1048576).toFixed(1)+' MB/s':'',
     eta!==null?'about '+(eta>=3600?Math.round(eta/3600)+' h':eta>=60?Math.round(eta/60)+' min':eta+' s')+' left':''
    ].filter(Boolean).join(' &middot; ');
  return `<div style="margin-bottom:9px">
   <div style="display:flex;gap:10px;justify-content:space-between;font-size:12px"><b>${esc(d.file)}</b>
    <span style="color:var(--dim)">${right}</span></div>
   <div class="bar" style="height:7px"><i style="width:${pct===null?100:pct}%;background:${stalled?'var(--warn)':'var(--ok)'};${pct===null?'opacity:.35':''}"></i></div></div>`
 }).join('');
}
async function dl(repo,quant){spin('download',3600000);await post('/api/download',{model:repo,quant});document.getElementById('insp').innerHTML='<div class="hint">Download started - watch Activity below.</div>';setTimeout(tick,800)}
async function tick(){
 if(pollBusy)return;
 pollBusy=true;
 try{
  try{S=await (await fetch('/api/status')).json()}catch(e){return}
 // Stale page check, first thing: if the server is running different code than served this page,
 // nothing rendered below can be trusted to match it. Covers the ordinary restart too, since the
 // window survives the server it was opened from.
 if(!BUILD)BUILD=S.build; else if(S.build!==BUILD){location.reload();return}
 document.getElementById('homeLoading').style.display='none';
 // Jobs before anything renders: every button's busy state is derived from this list.
 try{JOBS=await (await fetch('/api/jobs')).json()}catch(e){}
 try{M=await (await fetch('/api/models')).json()}catch(e){}
 // Clear an optimistic mark only when the exact job started by this click has finished.
 // File timestamps are not job start times: using their age could leave a completed restart
 // spinning until the full timeout, or clear it based on an unrelated older job.
 JOBS.forEach(j=>{const p=PEND[j.name];
  if(p&&p.id===j.id&&!j.running)delete PEND[j.name]});
 // A load has no job behind it, so its mark clears on the outcome instead - the model is loaded.
 if(S.loaded)delete PEND['load:'+S.loaded];
 // Health is judged only against ticked services - a deselected one being down is not a fault.
 const mine=S.services.filter(s=>s.managed&&s.selected);
 const up=mine.filter(s=>s.up).length, need=mine.length;
 // The header is visible before the first status response; hold lifecycle controls until the
 // selected services are known, so an early click cannot be mistaken for "nothing selected".
 const ready=Array.isArray(S.services);
 const sel=ready?selected():null;
 [['go','deploy'],['hre','restart'],['hst','stop'],['homeRestart','restart'],['homeStop','stop']].forEach(([el,a])=>{
  const e=document.getElementById(el),b=ready&&busy(jkey(a,sel));
  e.classList.toggle('busy',b);e.disabled=!ready||b||(el==='go'&&need>0&&up===need);
 });
 document.getElementById('d').className='dot '+(need===0?'down':up===need?'up':up?'part':'down');
 document.getElementById('sub').textContent=need===0?'nothing selected':up===need?'running':up?'partly running':'stopped';
 document.getElementById('svc').innerHTML=S.services.map(s=>{
  const state=!s.installed?['Not installed','']:!s.managed?['Available','']:s.up?['Running','good']:s.selected?['Stopped','bad']:['Not selected',''];
  return `<article class="service-card">
   <div><h3>${esc(s.name)}</h3><p>${esc(s.role)}</p></div>
   <div class="service-meta"><span class="status-pill ${state[1]}">${state[0]}</span>${s.url&&s.up?`<a href="${esc(s.url)}" target="_blank"><button class="gh">Open</button></a>`:''}</div>
   ${s.managed?`<label class="service-choice"><input type="checkbox" ${s.selected?'checked':''} onchange="toggleSvc('${s.key}',this.checked)"> Include in Start and Stop</label>`:''}
  </article>`
 }).join('');
 const gpuTotal=Number(S.gpu.total)||0,gpuUsed=Number(S.gpu.used)||0;
 const gpuName=gpuTotal?S.gpu.name:'No supported accelerator detected';
 const gpuVram=gpuTotal?`${fmt(gpuUsed)} / ${fmt(gpuTotal)}<div class="bar"><i style="width:${Math.max(0,Math.min(100,100*gpuUsed/gpuTotal))}%"></i></div>`:'Not reported';
 document.getElementById('hw').innerHTML=`<span>GPU</span><div>${esc(gpuName)}</div>
  <span>VRAM</span><div>${gpuVram}</div>
  <span>GPU load</span><div>${gpuTotal?`${S.gpu.util}% &nbsp; ${S.gpu.temp} &deg;C`:'Not reported'}</div>
  <span>System RAM</span><div>${S.ramUsed} / ${S.ramTot} GB<div class="bar"><i style="width:${100*S.ramUsed/S.ramTot}%"></i></div></div>
  <span>Loaded model</span><div>${S.loaded||'<span style="color:var(--dim)">idle</span>'}</div>`;
 // First-run walkthrough. Someone who just unzipped this has three things to do in order -
 // install the components, fetch a model, open the chat - and no way to know that from a panel
 // that only reports state. Each step names the next action and disappears once it is done.
 const fresh=mine.some(s=>!s.installed), noModels=M.models&&M.models.length===0;
 const noWeights=M.models&&M.models.length>0&&M.models.every(m=>!m.present);
 let hero={step:'LOCAL STATUS',title:'Your workspace',text:'Your local model services run on this PC.',button:'',action:''};
 if(need===0) hero={step:'SETUP',title:'Choose what to run',text:'Select llama-swap and/or the chat interface below, then start your local workspace.',button:'',action:''};
 else if(fresh) hero={step:'STEP 1 - SET UP',title:'Set up your local AI workspace',text:'Install the local engine, model router and chat interface. This downloads the runtime once; model files are added separately.',button:'Install and start',action:"act('deploy')"};
 else if(!up) hero={step:'READY WHEN YOU ARE',title:'Your services are stopped',text:'Start the selected services to use your local models.',button:'Start services',action:"act('deploy')"};
 else if(up<need) hero={step:'CHECKING SERVICES',title:'Part of your workspace is running',text:'Restart the selected services to bring the rest back online.',button:'Restart services',action:"act('restart')"};
 else if(noModels) hero={step:'STEP 2 - CHOOSE A MODEL',title:'Your workspace is ready for a model',text:'Find a recommendation sized for this PC or register a GGUF file you already have.',button:'Find a model',action:'firstModel()'};
 else if(noWeights) hero={step:'MODEL FILES NEEDED',title:'Your models need their weight files',text:'Choose a folder containing the GGUF files, or download a model from the library.',button:'Manage models',action:'gotoModels()'};
 else if(M.models&&M.models.every(m=>!m.loads&&!m.lastUsed)) hero={step:'STEP 3 - FIRST CHAT',title:'Ready for your first chat',text:'Open the chat interface and choose one of your models. The first request loads it into memory.',button:'Open chat',action:'openChat()'};
 else hero={step:'ALL SYSTEMS READY',title:'Your local AI is ready',text:'Open the chat interface to continue. Your conversations stay on this PC.',button:'Open chat',action:'openChat()'};
 const testable=(M.models||[]).find(m=>m.id===S.loaded&&m.present&&m.engineOk)||(M.models||[]).find(m=>m.present&&m.engineOk);
 const routerUp=S.services.some(s=>s.key==='swap'&&s.up);
 const testBusy=busy('verify-model'),testId=testable?encodeURIComponent(testable.id).replace(/'/g,'%27'):'';
 const testButton=testable&&routerUp?`<div><button class="gh" id="verifyModelBtn" onclick="verifyModel(decodeURIComponent('${testId}'))" ${testBusy?'disabled':''}>${testBusy?'Checking response...':'Test a real response'}</button><div class="subtle">Checks ${esc(testable.id)}; may switch the loaded model and use VRAM. It confirms that the model returns text, not that the answer is accurate or useful.</div></div>`:'';
 document.getElementById('guide').innerHTML=`<section class="hero"><div><div class="eyebrow">${hero.step}</div><h2>${hero.title}</h2><p>${hero.text}</p></div><div class="hero-actions">${hero.button?`<button class="act" onclick="${hero.action}">${hero.button}</button>`:''}${testButton}</div></section>`;

 if(document.getElementById('p1').classList.contains('on'))try{E=await (await fetch('/api/engine')).json()}catch(e){}
 if(E.llamacpp){
  // One panel per component, with its own versions and its own actions - the version table that
  // used to sit at the bottom repeated the Build line already shown here.
  const V=(VER.rows||[]).reduce((a,r)=>(a[r.component]=r,a),{});
  const verLine=k=>{const r=V[k];if(!r)return '';
   const behind=r.latest&&r.latest!==r.installed;
   return `<span>Pinned</span><div>${r.pinned}</div><span>Latest upstream</span><div>${r.latest?(behind?'<span class="miss">'+r.latest+' available</span>':'<span class="on2">'+r.latest+' (current)</span>'):'<span style="color:var(--dim)">not checked</span>'}</div>`};
  const panel=(title,body,btns)=>`<fieldset><legend>${title}</legend><div class="kv">${body}</div>${btns?`<div class="row" style="margin-top:7px">${btns}</div>`:''}</fieldset>`;
  let h='';
  h+=panel('llama.cpp (stock) - inference engine',
    `<span>Status</span><div>${E.llamacpp.installed?'<span class="on2">installed</span>':'<span class="miss">not installed</span>'}</div>
     <span>Build</span><div>${E.llamacpp.version||'-'}</div>${verLine('llamaCpp')}
     <span>Path</span><div style="color:var(--dim)">${E.llamacpp.path}</div>`,
    E.llamacpp.installed?'':B('gh','install',"inst('components')",'Install'));
  h+=panel('llama.cpp (PrismML fork) - low-bit kernels',
    `<span>Status</span><div>${E.prism.installed?'<span class="on2">installed</span>':'<span class="tag">not installed</span>'}</div>
     <span>Build</span><div>${E.prism.version||'-'}</div>${verLine('prism fork')}
     <span>Path</span><div style="color:var(--dim)">${E.prism.path}</div>`,
    B('gh','prism',"inst('prism')",E.prism.installed?'Reinstall / update':'Install'));
  h+=panel('llama-swap - model router',
    `<span>Status</span><div>${E.swap.up?'<span class="on2">running</span>':'<span class="miss">stopped</span>'}</div>
     <span>Processes</span><div>${E.swap.procs.map(p=>'pid '+p.pid+' ('+p.mb+' MB)').join(', ')||'-'}</div>${verLine('llamaSwap')}`,
    B('gh','restart-swap',"act('restart','swap')",'Restart')+' '+
    B('gh','stop-swap',"act('stop','swap')",'Stop')+' '+
    B('gh','unload','unloadAll()','Unload models'));
  h+=panel('open-webui - chat interface',
    `<span>Status</span><div>${E.webui.up?'<span class="on2">running</span>':'<span class="miss">stopped</span>'}</div>${verLine('openWebUI')}${verLine('node')?'':''}`,
    B('gh','restart-webui',"act('restart','webui')",'Restart')+' '+
    B('gh','stop-webui',"act('stop','webui')",'Stop'));
  document.getElementById('comps').innerHTML=h;
  document.getElementById('e4').innerHTML=E.servers.length?E.servers.map(s=>`<tr><td>${s.pid}</td><td>${s.mb} MB</td></tr>`).join(''):'<tr><td colspan=2 style="color:var(--dim)">none - no model loaded</td></tr>';
 }
 // Endpoints change only when a port or a model does, so they ride the same poll as the rest of
 // this tab rather than getting their own.
 if(document.getElementById('p1').classList.contains('on'))try{EP=await (await fetch('/api/endpoints')).json()}catch(e){}
 if(EP.rows){
  document.getElementById('eps').innerHTML=EP.rows.map(r=>{
   const up=r.url.indexOf(':'+ (M.settings?M.settings.webuiPort:8080))>0 ? EP.webuiUp : EP.swapUp;
   return `<tr><td>${esc(r.what)}</td>
    <td><code>${esc(r.url)}</code> ${up?'':'<span class="tag miss">not running</span>'}
     <div class="note">${esc(r.note)}</div></td></tr>`}).join('');
  document.getElementById('epmodels').innerHTML=EP.models.length
   ? 'Model ids ready to use: '+EP.models.map(m=>'<code>'+esc(m)+'</code>').join(' ')
   : 'No model has both its weights and an engine yet, so there is nothing to request.';
 }
 // M was loaded near the top of the poll so the home guide and storage controls can render early.
 downloads(M.downloads||[]);
 activity(M.downloads||[]);
 if(M.models){
  const empty=M.models.length===0;
  document.getElementById('modelTable').style.display=empty?'none':'';
  document.getElementById('emptyModels').style.display=empty?'':'none';
  document.getElementById('mt').innerHTML=M.models.map(m=>{
   const on=S.loaded===m.id;
   // A model that has been asked for but hasn't finished loading is neither idle nor loaded,
   // and a multi-GB load takes long enough that the difference matters.
   const loading=!on&&busy('load:'+m.id);
   const dot=on?'<span class="dot up" title="loaded"></span> ':(loading?'<span class="dot part" title="loading"></span> ':'');
   return `<tr>
   <td>${dot}${m.id} ${m.prism?'<span class="tag">prism</span>':''}</td>
   <td>${m.present?m.sizeGb+' GB':'<span class="miss">no weights</span>'}</td>
   <td>${chat(m.ctx)}</td>
   <td class="adv">${m.ctx||'-'}</td><td class="adv">${m.kv||'-'}</td><td class="adv">${m.moe!==null?m.moe:'-'}</td>
   <td class="adv" style="color:var(--dim)">${m.lastUsed||'-'}</td><td class="adv">${m.loads||0}</td>
   <td>${!m.engineOk?'<span class="miss">engine missing</span>':(on?'<span class="on2">loaded</span>':(loading?'<span style="color:var(--warn)">loading</span>':(m.present?(M.support&&M.support[m.id]?'<span class="on2">text response verified</span>':'<span style="color:var(--dim)">ready — verify response</span>'):'-')))}</td>
   <td>${m.present?B('gh','load:'+m.id,`load('${m.id}')`,'Load')+' '+
                   B('gh','edit:'+m.id,`edit('${m.id}')`,'Edit')+' '+
                   B('gh','autotune-'+m.id,`tune('${m.id}')`,'Tune')+' ':''}<button class="dz" onclick="del('${m.id}',${m.sizeGb})">Delete</button></td></tr>`}).join('');
  document.getElementById('orph').innerHTML=M.orphans.length?M.orphans.map(o=>`<tr><td>${o.file}</td><td>${o.sizeGb} GB</td><td style="color:var(--dim)">downloaded, not in config.yaml</td></tr>`).join(''):'<tr><td style="color:var(--dim)">none</td></tr>';
 }
 // Cached versions only; the -Latest query costs GitHub round-trips so it waits for the button.
 if(!VER.rows&&document.getElementById('p1').classList.contains('on')){try{VER=await (await fetch('/api/versions')).json()}catch(e){}}
 document.getElementById('jobs').innerHTML=JOBS.length?JOBS.map(x=>`<div style="margin-bottom:6px"><b style="font-size:11px">${x.id}</b> ${x.running?'<span class="tag" style="color:var(--warn)">running</span>':''} <span style="color:var(--dim);font-size:11px">${x.age}s ago</span><pre>${(x.tail||'(no output yet)').replace(/</g,'&lt;')}</pre></div>`).join(''):'<span style="color:var(--dim)">nothing running</span>';
 const md=document.getElementById('mdir');
 if(M.settings){
  if(document.activeElement!==md)md.value=M.settings.modelsDir;
  document.getElementById('modelDirLabel').textContent='Current folder: '+M.settings.modelsDir;
  document.getElementById('st').innerHTML=`<span>llama-swap</span><div>127.0.0.1:${M.settings.swapPort}</div><span>Chat UI</span><div>127.0.0.1:${M.settings.webuiPort}</div><span>This panel</span><div>127.0.0.1:${location.port}</div>`;
 }
 }finally{pollBusy=false}
}
tick();setTimeout(()=>checkProductUpdate(false),1000);setInterval(tick,3000);
</script></body></html>
'@

# ---------------------------------------------------------------- server

# Single instance. Launching again - double-clicking the icon, or clicking it while the panel is
# already up - should surface the existing panel, not start a second server or stack up windows.
$alreadyUp = $false
try { $alreadyUp = (Invoke-WebRequest "http://127.0.0.1:$Port/api/ping" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } catch { }
if ($alreadyUp) {
    Write-Host "Panel already running on $Port."
    if (-not $NoWindow) { Open-PanelWindow }
    return
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch { throw "Could not bind 127.0.0.1:$Port - is the panel already running? ($($_.Exception.Message))" }
Write-Host "Model Pilot panel -> http://127.0.0.1:$Port  (Ctrl-C to stop)"

# Closing the window leaves this server running, which is the behaviour we want - it is a
# minimise, not a quit. That only works if there is something to restore it from, so make sure
# the tray exists. tray.ps1 holds a named mutex, so launching it when it is already up is a
# no-op rather than a second icon.
$trayPs = Join-Path $root 'tray.ps1'
if (Test-Path $trayPs) {
    $trayArgs = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $trayPs)
    $trayArgs = @($trayArgs | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) })
    Start-Process powershell -WindowStyle Hidden -ArgumentList $trayArgs
}

if (-not $NoWindow) { Open-PanelWindow }

function Read-Body($req) {
    $s = (New-Object IO.StreamReader($req.InputStream)).ReadToEnd()
    if ($s) { $s | ConvertFrom-Json } else { $null }
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request; $res = $ctx.Response
        $body = ''; $type = 'application/json'

        # Gate every API path. The page itself is served without a token (it has to be, it is
        # what carries the token) but it only renders - it cannot act.
        #
        # /api/ping is the one exception, and has to be: it is how a second launch discovers that a
        # panel is already up, and that check runs before any token exists to send. Gating it meant
        # every launch believed nothing was running and then failed to bind the port. It returns a
        # fixed literal - no state, no action - so the only thing it leaks to a cross-origin caller
        # is that this port is a Model Pilot panel, which failing to bind reveals anyway.
        if ($req.Url.AbsolutePath -like '/api/*' -and $req.Url.AbsolutePath -ne '/api/ping') {
            $origin = $req.Headers['Origin']
            $token  = $req.Headers['X-LocalLLM-Token']
            $bad = ($origin -and $origin -ne $script:selfOrigin) -or ($token -ne $script:csrfToken)
            if ($bad) {
                $res.StatusCode = 403
                $deny = [Text.Encoding]::UTF8.GetBytes('{"error":"forbidden: cross-origin or missing token"}')
                $res.ContentType = 'application/json'
                $res.ContentLength64 = $deny.Length
                try { $res.OutputStream.Write($deny, 0, $deny.Length) } catch { }
                try { $res.Close() } catch { }
                continue
            }
        }
        try {
            switch -Regex ($req.Url.AbsolutePath) {
                # Deliberately does no work: the single-instance check needs an answer that can
                # never be slower than its timeout. /api/status shells out to nvidia-smi, queries
                # WMI and probes two health endpoints, so it is far too slow to test liveness with.
                '^/api/ping$'   { $body = '{"ok":true}' }
                '^/api/status$' { $body = Get-Dashboard | ConvertTo-Json -Depth 6 -Compress }
                '^/api/engine$' { $body = Get-Engine | ConvertTo-Json -Depth 6 -Compress }
                '^/api/sensors$' { $body = Get-Sensors | ConvertTo-Json -Depth 5 -Compress }
                '^/api/endpoints$' { $body = Get-Endpoints | ConvertTo-Json -Depth 5 -Compress }
                '^/api/backups$' { $body = @{ backups = @(Get-Backups) } | ConvertTo-Json -Depth 4 -Compress }
                '^/api/restore$' {
                    $p = Read-Body $req
                    if (-not $p.path) { throw 'Choose a backup before restoring.' }
                    Start-Job2 'restore' @('-Action', 'restore', '-BackupPath', [string]$p.path) | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/diagnostics$' {
                    Start-Job2 'diagnostics' @('-Action', 'diagnostics') | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/install-picker$' {
                    Start-Job2 'llmfit' @('-Action', 'install-llmfit') $startPs | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/models$' {
                    $body = @{ models = @(Get-ConfiguredModels); orphans = @(Get-OrphanModels)
                               downloads = @(Get-Downloads); settings = (Get-Settings); support = (Get-ModelSupport) } | ConvertTo-Json -Depth 6 -Compress
                }
                # ConvertTo-Json on an empty array yields nothing at all, not "[]", so the
                # array is forced with a leading comma to keep it an array of one dimension.
                '^/api/jobs$'   { $body = ConvertTo-Json -InputObject @(Get-Jobs) -Depth 4 -Compress }
                '^/api/action$' {
                    $p = Read-Body $req
                    $jobId = $null
                    if ($p.action -in 'deploy', 'restart', 'stop') {
                        $a = @('-Action', $p.action, '-NoTray')
                        if ($p.component) { $a += @('-Component', $p.component) }
                        # The component is part of the job name so "restart swap" and "restart
                        # webui" are distinguishable - otherwise both buttons would spin for either.
                        $name = if ($p.component -and $p.component -ne 'all') { "$($p.action)-$($p.component)" } else { $p.action }
                        $jobId = Start-Job2 $name $a
                    }
                    $body = @{ ok = $true; id = $jobId } | ConvertTo-Json -Compress
                }
                '^/api/verify-model$' {
                    if ($req.HttpMethod -eq 'POST') {
                        $p = Read-Body $req
                        $id = [string]$p.id
                        if ($id -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Choose a configured model before running the response check.' }
                        $old = $script:asyncJobs['verify-model']
                        if ($old) {
                            $oldResult = Get-Async 'verify-model' $old.key
                            if ($oldResult.running -and $old.key -ne $id) {
                                throw "A response check is already running for '$($old.key)'. Wait for it to finish first."
                            }
                        }
                        $current = Get-Async 'verify-model' $id
                        if (-not $current -or -not $current.running) {
                            Start-Async 'verify-model' $id @('-Action', 'test-model', '-Id', $id)
                        }
                        $body = '{"running":true}'
                    } elseif ($req.HttpMethod -eq 'GET') {
                        $id = [Web.HttpUtility]::ParseQueryString($req.Url.Query)['id']
                        $result = Get-Async 'verify-model' $id
                        $body = if ($result) { $result | ConvertTo-Json -Depth 4 -Compress }
                                else { @{ error = 'No response check is running for this model.' } | ConvertTo-Json -Compress }
                    } else { throw 'Use POST to start or GET to read a model response check.' }
                }
                '^/api/load$' {
                    $p = Read-Body $req
                    # Any completion makes llama-swap swap that model in; one token is enough.
                    Start-Job -ScriptBlock { param($u, $m)
                        try { Invoke-RestMethod $u -Method Post -TimeoutSec 900 -ContentType 'application/json' `
                              -Body (@{ model = $m; messages = @(@{role='user';content='hi'}); max_tokens = 1 } | ConvertTo-Json) } catch { }
                    } -ArgumentList "http://127.0.0.1:$swapPort/v1/chat/completions", $p.id | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/unload$' {
                    try { Invoke-RestMethod "http://127.0.0.1:$swapPort/api/models/unload" -Method Post -TimeoutSec 10 | Out-Null } catch { }
                    $body = '{"ok":true}'
                }
                '^/api/tune$' {
                    # Inline, not a job: it rewrites two flags in a text file and the user is
                    # waiting on the answer. Errors have to come back to the dialog, not a log.
                    $p = Read-Body $req
                    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startPs,
                           '-Action', 'set-tuning', '-Id', $p.id, '-Context', $p.ctx, '-Kv', $p.kv)
                    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                    $out = try { & powershell @a 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
                    if ($LASTEXITCODE -ne 0) {
                        # A PowerShell error record is one useful line followed by carets, source
                        # extracts and CategoryInfo. Surfacing the tail put the noise in the dialog
                        # and left the message out; the first real line is the message.
                        $msg = ($out | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(\+|At line|At C:)' } | Select-Object -First 1)
                        $res.StatusCode = 500
                        $body = @{ error = ("$msg" -replace '^powershell(\.exe)?\s*:\s*', '').Trim() } | ConvertTo-Json -Compress
                    }
                    else { $body = @{ ok = $true } | ConvertTo-Json -Compress }
                }
                '^/api/autotune$' {
                    $p = Read-Body $req
                    Start-Job2 "autotune-$($p.id)" @('-Action', 'autotune', '-Id', $p.id, '-Apply') | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/download$' {
                    $p = Read-Body $req
                    $s = Get-Settings
                    $a = @('-Action', 'add-model', '-Model', $p.model,
                           '-ModelDir', ('"{0}"' -f $s.modelsDir))
                    if ($p.quant) { $a += @('-Quant', $p.quant) }
                    Start-Job2 "download" $a | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/suggest$' {
                    $q = [Web.HttpUtility]::ParseQueryString($req.Url.Query)
                    $key = "$($q['usecase'])|$($q['minfit'])"
                    if (-not (Test-Path (Join-Path $root 'llmfit\llmfit.exe'))) { $body = '{"needInstall":true}' }
                    else {
                        # run=1 is the button; every other request is the page polling for the answer.
                        if ($q['run'] -eq '1') {
                            $a = @('-Action', 'suggest', '-Json', '-Top', '8')
                            if ($q['usecase']) { $a += @('-UseCase', $q['usecase']) }
                            # Whitelisted rather than passed through, since it lands on a command line.
                            if ($q['minfit'] -in 'good', 'marginal', 'poor') { $a += @('-MinFit', $q['minfit']) }
                            Start-Async 'suggest' $key $a
                            $body = '{"running":true}'
                        } else {
                            $st = Get-Async 'suggest' $key
                            if (-not $st)        { $body = '{"running":true}' }
                            elseif ($st.running) { $body = '{"running":true}' }
                            else {
                                $line = $st.out | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1
                                if ($line) { $body = $line }
                                else {
                                    $msg = @($st.out) + @($st.err -split "`r?`n") |
                                           Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^\s*(\+|At line|At C:)' } |
                                           Select-Object -Last 1
                                    $body = @{ error = ("$msg" -replace '^powershell(\.exe)?\s*:\s*', '').Trim() } | ConvertTo-Json -Compress
                                }
                            }
                        }
                    }
                }
                '^/api/inspect$' {
                    $q = [Web.HttpUtility]::ParseQueryString($req.Url.Query)
                    $model = $q['model']
                    if ($q['run'] -eq '1') {
                        Start-Async 'inspect' $model @('-Action', 'inspect', '-Model', $model)
                        $body = '{"running":true}'
                    } else {
                        $st = Get-Async 'inspect' $model
                        if (-not $st -or $st.running) { $body = '{"running":true}' }
                        else {
                            $lines = @($st.out)
                            $summary = ($lines | Where-Object { $_ -match '^arch ' } | Select-Object -First 1)
                            $variants = @()
                            foreach ($l in $lines) {
                                if ($l -match '^(\S+)\s+([\d.]+ GB)\s+(\S+)\s+(\S+)\s+(.+?)\s*$' -and $l -notmatch '^variant') {
                                    $verdict = $Matches[5].Trim()
                                    $quant = if ($Matches[1] -match '(?i)[-_.]((?:IQ|Q|UD-Q)\d[A-Z0-9_]*|BF16|F16|F32)$') { $Matches[1] } else { '' }
                                    $variants += @{ name = $Matches[1]; size = $Matches[2]; verdict = $verdict
                                                    fits = ($verdict -notmatch 'needs >|will not fit'); quant = $quant }
                                }
                            }
                            $repo = if ($model -match 'huggingface\.co/([^/]+/[^/?#]+)') { $Matches[1] } else { $model }
                            if (-not $variants) {
                                $msg = (@($lines) + @($st.err -split "`r?`n") | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 3) -join ' '
                                $body = @{ error = "$msg" } | ConvertTo-Json -Compress
                            }
                            else { $body = @{ repo = $repo; summary = $summary; variants = $variants } | ConvertTo-Json -Depth 5 -Compress }
                        }
                    }
                }
                '^/api/browse-models$' {
                    $s = Get-Settings
                    $path = Select-Directory 'Choose the folder where model downloads should be saved' $s.modelsDir
                    $body = @{ path = $path } | ConvertTo-Json -Compress
                }
                '^/api/model-files$' {
                    $s = Get-Settings
                    $existing = @(Get-ConfiguredModels)
                    $known = @($existing | Where-Object { $_.path } | ForEach-Object {
                        [IO.Path]::GetFullPath($_.path).ToLowerInvariant()
                    })
                    $knownIds = @{}
                    foreach ($model in $existing) { $knownIds[$model.id.ToLowerInvariant()] = $true }
                    $files = @()
                    $scanErrors = @()
                    if (Test-Path -LiteralPath $s.modelsDir -PathType Container) {
                        $files = @(Get-ChildItem -LiteralPath $s.modelsDir -Filter '*.gguf' -File -Recurse -ErrorAction SilentlyContinue -ErrorVariable +scanErrors |
                            Where-Object { $_.Name -notmatch '-\d{5}-of-\d{5}\.gguf$' -or $_.Name -match '-00001-of-\d{5}\.gguf$' } |
                            Where-Object { $known -notcontains $_.FullName.ToLowerInvariant() } |
                            ForEach-Object {
                                $id = Get-ModelIdFromFileName $_.FullName
                                $conflict = if (-not $id) { 'Rename this file to create a model id.' }
                                            elseif ($knownIds.ContainsKey($id)) { "Model id '$id' is already in use; rename this file." }
                                            else { $null }
                                @{ path = $_.FullName; name = $_.Name; id = $id; conflict = $conflict
                                   sizeGb = [math]::Round($_.Length / 1GB, 1) }
                            })
                    } else {
                        $scanErrors += "Selected folder is missing or unavailable: $($s.modelsDir)"
                    }
                    $scanWarnings = @($scanErrors | ForEach-Object {
                        if ($_ -is [string]) { $_ }
                        elseif ($_.TargetObject) { [string]$_.TargetObject }
                        else { [string]$_.Exception.Message }
                    } | Select-Object -Unique)
                    $body = @{ files = $files; scanWarnings = $scanWarnings } | ConvertTo-Json -Depth 4 -Compress
                }
                '^/api/register-model$' {
                    $p = Read-Body $req
                    $path = [IO.Path]::GetFullPath([string]$p.path)
                    $dir = [IO.Path]::GetFullPath((Get-Settings).modelsDir).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                    if (-not $path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'Choose a model from the selected storage folder.'
                    }
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or [IO.Path]::GetExtension($path) -ine '.gguf') {
                        throw 'Choose an existing .gguf model file.'
                    }
                    $existing = @(Get-ConfiguredModels)
                    if ($existing | Where-Object { $_.path -and [IO.Path]::GetFullPath($_.path) -ieq $path }) {
                        throw 'This model file is already registered.'
                    }
                    $id = Get-ModelIdFromFileName $path
                    if (-not $id) { throw 'Could not make a model id from this filename.' }
                    if ($existing | Where-Object { $_.id -ieq $id }) { throw "Model id '$id' already exists; rename the file or edit config.yaml." }
                    if (-not (Test-Path $swapCfg)) { throw 'llama-swap config.yaml is not installed yet. Press Start first.' }
                    Copy-Item -LiteralPath $swapCfg -Destination "$swapCfg.bak" -Force
                    $entry = "`r`n  `"$id`":`r`n    cmd: >`r`n      `${llama-server}`r`n      -m `"$path`"`r`n      -c 16384 -ctk q8_0 -ctv q8_0`r`n    ttl: 600`r`n"
                    Add-Content -LiteralPath $swapCfg -Value $entry -Encoding UTF8
                    $body = @{ ok = $true; id = $id } | ConvertTo-Json -Compress
                }
                '^/api/settings$' {
                    $p = Read-Body $req
                    if ($p.PSObject.Properties.Name -contains 'modelsDir') {
                        $dir = [string]$p.modelsDir
                        if (-not $dir.Trim()) { throw 'Choose a folder for model storage.' }
                        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                            New-Item -ItemType Directory -Force -Path $dir | Out-Null
                        }
                        $p.modelsDir = (Resolve-Path -LiteralPath $dir).Path
                    }
                    $body = (Set-Settings $p) | ConvertTo-Json -Compress
                }
                '^/api/versions$' {
                    $refresh = [Web.HttpUtility]::ParseQueryString($req.Url.Query)['refresh'] -eq '1'
                    $body = (Get-Versions -Refresh:$refresh) | ConvertTo-Json -Depth 5 -Compress
                }
                '^/api/product-update$' {
                    $q = [Web.HttpUtility]::ParseQueryString($req.Url.Query)
                    if ($q['run'] -eq '1') {
                        Start-Async 'product-update' 'latest' @('-Action', 'update-check', '-Json')
                        $body = '{"running":true}'
                    } else {
                        $result = Get-Async 'product-update' 'latest'
                        if (-not $result -or $result.running) { $body = '{"running":true}' }
                        elseif ($result.err) { $body = @{ error = $result.err } | ConvertTo-Json -Compress }
                        else { $body = ($result.out -join "`n") }
                    }
                }
                '^/api/preflight$' {
                    $q = [Web.HttpUtility]::ParseQueryString($req.Url.Query)
                    if ($q['run'] -eq '1') {
                        Start-Async 'preflight' 'current' @('-Action', 'preflight', '-Json')
                        $body = '{"running":true}'
                    } else {
                        $result = Get-Async 'preflight' 'current'
                        if (-not $result -or $result.running) { $body = '{"running":true}' }
                        elseif ($result.err) { $body = @{ error = $result.err } | ConvertTo-Json -Compress }
                        else { $body = ($result.out -join "`n") }
                    }
                }
                '^/api/backup$' {
                    Start-Job2 'backup' @('-Action', 'backup') | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/app-update$' {
                    Start-Job2 'app-update' @('-Action', 'update-app', '-PanelPid', $PID) | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/install$' {
                    $p = Read-Body $req
                    switch ($p.what) {
                        'components' { Start-Job2 'install'  @('-Action', 'deploy', '-NoTray') | Out-Null }
                        'upgrade'    { Start-Job2 'upgrade'  @('-Action', 'upgrade', '-NoTray') | Out-Null }
                        'upgrade-latest' { Start-Job2 'upgrade' @('-Action', 'upgrade', '-Latest', '-NoTray') | Out-Null }
                        'prism'      { Start-Job2 'prism'    @('-Action', 'install-prism') | Out-Null }
                        default      { throw "unknown install target '$($p.what)'" }
                    }
                    $script:verInfo = $null      # versions will have moved
                    $body = '{"ok":true}'
                }
                '^/api/reset$' {
                    # Two shapes on purpose. Without 'confirm' this is a dry run: it answers what
                    # would be deleted and how big, so the page can show the user the real list
                    # before they agree to anything. Destructive work never happens on the same
                    # call that renders the warning.
                    $p = Read-Body $req
                    $comp = "$($p.component)"
                    if ($comp -notin 'all','swap','webui','llama-cpp','llama-prism','llmfit','uv','logs','downloads','metadata') {
                        $res.StatusCode = 400
                        $body = '{"error":"unknown component"}'
                    } elseif ($p.confirm) {
                        $a2 = @('-Action','reset','-Component',$comp,'-Force')
                        if ($p.includeModels) { $a2 += '-IncludeModels' }
                        Start-Job2 "reset-$comp" $a2 | Out-Null
                        $body = '{"ok":true,"started":true}'
                    } else {
                        # Sizing walks directories, so it runs as a job rather than inside the
                        # request - open-webui alone is 3 GB of small files and this listener is
                        # single-threaded.
        $key = "$comp|$([bool]$p.includeModels)"
                        if ($p.run) {
                            $a2 = @('-Action','reset','-Component',$comp,'-DryRun','-Json')
                            if ($p.includeModels) { $a2 += '-IncludeModels' }
                            Start-Async 'resetdry' $key $a2
                            $body = '{"running":true}'
                        } else {
                            $st = Get-Async 'resetdry' $key
                            if (-not $st -or $st.running) { $body = '{"running":true}' }
                            else {
                                # -Json prints one array; anything else on stdout is noise.
                                $line = $st.out | Where-Object { $_.TrimStart().StartsWith('[') -or $_.TrimStart().StartsWith('{') } | Select-Object -First 1
                                if ($line) { $body = "{""running"":false,""targets"":$line}" }
                                else { $body = '{"running":false,"targets":[]}' }
                            }
                        }
                    }
                }
                '^/api/shortcuts$' {
                    # Fast enough to run inline - it writes two .lnk files and nothing else.
                    $body = @{ ok = $true; paths = @(Install-Shortcuts) } | ConvertTo-Json -Compress
                }
                '^/api/autostart$' {
                    # POST with no 'set' reads; with one it writes. The write goes through
                    # start.ps1 rather than dropping a second .lnk-writing implementation here -
                    # uninstall has to delete that file, and only the CLI half is told about it.
                    # That costs a spawn inside the request: /api/ping measured 830 ms while a
                    # set was in flight. Deliberate, and the exception to the rule above rather
                    # than an oversight - this is one click, not a poll, and the alternatives are
                    # a duplicate .lnk writer that can drift from the CLI's, or answering with the
                    # state we intended instead of the one on disk. The read costs nothing.
                    $p = Read-Body $req
                    if ($null -ne $p.set) {
                        $a2 = @('-Action', 'autostart') + $(if (-not $p.set) { @('-Remove') } else { @() })
                        $autoStartArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startPs) + $a2
                        $autoStartArgs = @($autoStartArgs | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) })
                        Start-Process powershell -WindowStyle Hidden -Wait -ArgumentList $autoStartArgs
                    }
                    $lnk = Get-AutostartPath
                    $body = @{ ok = $true; on = (Test-Path $lnk) } | ConvertTo-Json -Compress
                }
                '^/api/delete-model$' {
                    $p = Read-Body $req
                    $body = (Remove-ModelFiles $p.id ([bool]$p.alsoConfig)) | ConvertTo-Json -Compress
                }
                default {
                    $type = 'text/html; charset=utf-8'
                    $body = $html.Replace('@@TOKEN@@', $script:csrfToken)
                }
            }
        } catch {
            $res.StatusCode = 500; $body = (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress)
        }
        # Writing the response sits outside the handler's try, so anything that goes wrong here
        # used to kill the listener and take the whole panel down with it - one endpoint
        # returning null was enough. A dead panel is far worse than a bad response.
        try {
            if ($null -eq $body) { $body = '' }
            $buf = [Text.Encoding]::UTF8.GetBytes([string]$body)
            $res.ContentType = $type
            $res.ContentLength64 = $buf.Length
            $res.OutputStream.Write($buf, 0, $buf.Length)
        } catch {
            Write-Host "response failed for $($req.Url.AbsolutePath): $($_.Exception.Message)"
        } finally {
            try { $res.Close() } catch { }
        }
    }
} finally { $listener.Stop(); $listener.Close() }
