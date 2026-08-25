# LocalLLM control panel - a local web UI that opens as a chromeless desktop window.
#
#   .\ui.ps1                 # start the server and open the window
#   .\ui.ps1 -NoWindow       # server only (then browse to http://127.0.0.1:9300)
#   .\ui.ps1 -Launch         # spawn the server detached and wait for it (what LocalLLM.cmd runs)
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
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$root       = $PSScriptRoot
# Platform differences live in platform.ps1 and nowhere else - see the header there.
. (Join-Path $PSScriptRoot 'platform.ps1')
$startPs    = Join-Path $root 'start.ps1'
$swapCfg    = Join-Path $root 'llamaswap\config.yaml'
$llamaCpp   = Join-Path $root 'llama.cpp'
$llamaPrism = Join-Path $root 'llama.cpp-prism'
$logDir     = Join-Path $root 'logs'
$jobDir     = Join-Path $logDir 'jobs'
$settingsFile = Join-Path $root '.ui-settings.json'
$usageFile  = Join-Path $root '.ui-usage.json'
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
# EnumWindows is the only way to actually see them. The title match alone isn't enough either -
# this repo lives in C:\LocalLLM, so an Explorer window on that folder is also titled "LocalLLM" -
# hence the check that the owning process is a browser.
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

function Get-PanelWindows { @([PanelWin]::Find('LocalLLM', $BROWSER_PROCS)) }

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

# Double-clicking LocalLLM.cmd lands here. The panel has to outlive its launcher - closing the
# browser window is a minimise, not a quit - so this spawns the server detached and then waits on
# its health endpoint. Without the wait, a failure to start (a taken port, a broken PowerShell
# policy) would be completely silent: no window, no message, nothing to act on.
if ($Launch) {
    # Files extracted from a downloaded .zip carry mark-of-the-web. -ExecutionPolicy Bypass already
    # ignores it, but clearing it stops the "do you want to run" prompt in every other entry point.
    Get-ChildItem $root -Filter *.ps1 | Unblock-File -ErrorAction SilentlyContinue
    Start-Process powershell -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
                      '-File', $PSCommandPath, '-Port', $Port
    Write-Host "Starting the LocalLLM panel..."
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
    $loaded = $null
    try { $loaded = ((Invoke-RestMethod "http://127.0.0.1:$swapPort/running" -TimeoutSec 2).running |
                     Where-Object { $_.state -ne 'stopped' } | Select-Object -First 1).model } catch { }
    Update-Usage $loaded
    # Cached for Get-Sensors, which is polled every second and must not add a second HTTP probe.
    $script:lastLoaded = $loaded
    $cfg = Get-Settings
    $mem = Get-SystemMemoryUsage
    @{
        # 'selected' marks what Start/Stop act on. opencode is a CLI invoked per task, not a
        # service with a lifecycle, so it is reported but never started or stopped - selectable
        # would imply a button that cannot do anything.
        services = @(
            @{ key = 'swap'; name = 'llama-swap'; role = 'model router'; managed = $true; selected = [bool]$cfg.useSwap
               up = (Test-Endpoint "http://127.0.0.1:$swapPort/health"); url = "http://127.0.0.1:$swapPort/ui"
               installed = (Test-Path (Join-Path $root 'llamaswap\llama-swap.exe')) }
            @{ key = 'webui'; name = 'open-webui'; role = 'chat interface'; managed = $true; selected = [bool]$cfg.useWebui
               up = (Test-Endpoint "http://127.0.0.1:$webuiPort/health"); url = "http://127.0.0.1:$webuiPort"
               installed = [bool](Get-ChildItem $root -Directory -Filter 'open-webui-*' -ErrorAction SilentlyContinue) }
            @{ key = 'opencode'; name = 'opencode'; role = 'local coding agent (per-task CLI)'; managed = $false; selected = $false
               up = $false; url = ''; installed = [bool](Get-Command opencode -ErrorAction SilentlyContinue) }
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

# What a coding agent needs to know, cheaply enough to poll: which CLIs are on PATH, and which
# configured models could actually back one. Deliberately does NOT probe /v1/messages - that can
# load a multi-GB model and take a minute, so it lives behind the Test button instead.
function Get-Agents {
    # The Claude Code handoff used to live here too, with a model chooser, a context
    # threshold and a .agent-compat.json verdict behind it. All of it is gone: a local
    # model drives opencode-style one-shot work fine and does not converge on a real
    # agent loop, so the panel offers the one that works and says why the other left.
    @{
        opencode = [bool](Get-Command opencode -ErrorAction SilentlyContinue)
        delegate = (Join-Path $root 'local-llm.ps1')
        agentScript = (Join-Path $root 'local-agent.ps1')
        projectDir = (Get-Settings).projectDir
    }
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
            @{ what = 'Anthropic messages'; url = "$swap/v1/messages"
               note = 'What Claude Code uses. ANTHROPIC_BASE_URL=' + $swap }
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
    $p = Start-Process powershell -WindowStyle Hidden -ArgumentList $a -PassThru `
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
       out = $(if (Test-Path $log) { Get-Content $log } else { @() })
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
<!doctype html><html><head><meta charset="utf-8"><title>LocalLLM</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect x='6.5' y='6.5' width='19' height='19' rx='3.5' fill='none' stroke='%232360c4' stroke-width='2'/%3E%3Cg stroke='%232360c4' stroke-width='2' stroke-linecap='round'%3E%3Cpath d='M12 6.5V3M16 6.5V3M20 6.5V3M12 25.5V29M16 25.5V29M20 25.5V29'/%3E%3Cpath d='M6.5 12H3M6.5 16H3M6.5 20H3M25.5 12H29M25.5 16H29M25.5 20H29'/%3E%3C/g%3E%3Cpath d='M12 12.5h8a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.5 1.5h-4.2L13 21v-2.5h-1a1.5 1.5 0 0 1-1.5-1.5v-3a1.5 1.5 0 0 1 1.5-1.5z' fill='%232360c4'/%3E%3C/svg%3E">
<style>
:root{--bg:#f3f4f6;--panel:#fff;--line:#d6dae1;--fg:#1b2027;--dim:#5f6875;--ok:#127a45;--warn:#8a6100;--bad:#c1362b;--acc:#2360c4;--soft:#eef1f5}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:12.5px/1.4 "Segoe UI",system-ui,sans-serif;user-select:none}
header{display:flex;align-items:center;gap:9px;padding:7px 11px;background:var(--panel);border-bottom:1px solid var(--line)}
header b{font-size:13px;font-weight:600}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%}.up{background:var(--ok)}.down{background:var(--bad)}.part{background:var(--warn)}
nav{display:flex;background:var(--soft);padding:0 8px;border-bottom:1px solid var(--line)}
nav button{background:transparent;border:0;border-bottom:2px solid transparent;color:var(--dim);padding:6px 15px;font-size:12px;cursor:pointer}
nav button.on{color:var(--acc);border-bottom-color:var(--acc);background:var(--panel);font-weight:600}
main{padding:10px}
.pane{display:none}.pane.on{display:block}
fieldset{border:1px solid var(--line);border-radius:4px;margin:0 0 9px;padding:6px 9px 8px;background:var(--panel)}
legend{color:var(--dim);font-size:10.5px;text-transform:uppercase;letter-spacing:.06em;padding:0 4px;font-weight:600}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;color:var(--dim);font-weight:600;padding:3px 7px;border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:3px 7px;border-bottom:1px solid #eceff3;white-space:nowrap}
tr:last-child td{border-bottom:0}
.kv{display:grid;grid-template-columns:118px 1fr;gap:1px 10px;font-size:12px}
.kv span{color:var(--dim)}
button.act{background:var(--acc);color:#fff;border:0;border-radius:3px;padding:3px 10px;font-size:11.5px;cursor:pointer}
button.gh{background:var(--soft);color:var(--fg);border:1px solid var(--line);border-radius:3px;padding:3px 10px;font-size:11.5px;cursor:pointer}
button.gh:hover{background:#e3e8ef}
button.dz{background:#fff;color:var(--bad);border:1px solid #e4b7b2;border-radius:3px;padding:3px 9px;font-size:11.5px;cursor:pointer}
button:disabled{opacity:.4;cursor:default}
/* A click that starts a background job has no other visible effect for up to three seconds -
   the next poll - so the button says so itself. The label stays readable; only a spinner is
   added, because a button whose text vanishes reads as broken rather than busy. */
@keyframes spin{to{transform:rotate(360deg)}}
button.busy{cursor:progress;opacity:1}
button.busy::before{content:'';display:inline-block;width:9px;height:9px;margin-right:5px;vertical-align:-1px;
 border:2px solid var(--dim);border-top-color:transparent;border-radius:50%;animation:spin .6s linear infinite}
button.act.busy::before{border-color:#fff;border-top-color:transparent}
button.busy:disabled{opacity:.85}
input,select{background:#fff;border:1px solid var(--line);color:var(--fg);border-radius:3px;padding:3px 6px;font-size:12px;user-select:text}
input{width:100%}
.adv{display:none}body.showadv .adv{display:table-cell}
.bar{height:5px;background:#e2e6ec;border-radius:3px;overflow:hidden;margin-top:3px}
.bar i{display:block;height:100%;background:var(--acc)}
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
<b>LocalLLM</b><span id="d" class="dot down" title="stack status"></span><span id="sub" style="color:var(--dim);font-size:11px"></span>
<span style="flex:1"></span>
<button class="gh" id="hre" onclick="act('restart')">Restart</button>
<button class="gh" id="hst" onclick="act('stop')">Stop</button>
<button class="act" id="go" onclick="act('deploy')">Start</button></header>
<nav>
<button class="on" onclick="tab(0,this)">Dashboard</button>
<button onclick="tab(2,this)">Models</button>
<button onclick="tab(1,this)">Engine</button>
<button onclick="tab(3,this)">Tools</button>
<button onclick="tab(4,this)">Monitoring</button>
<button onclick="tab(5,this)">Activity</button>
<button onclick="tab(6,this)">Settings</button>
</nav>
<main>
<div id="guide"></div>

<div class="pane on" id="p0">
 <fieldset><legend>Services</legend>
  <table><thead><tr><th style="width:24px"></th><th>Service</th><th>Role</th><th>State</th><th></th></tr></thead><tbody id="svc"></tbody></table>
  <div class="hint" style="margin:7px 0 0">Ticked services are your stack: Start, Stop and Restart act on those only, and the status light ignores the rest.</div>
 </fieldset>
 <fieldset><legend>Hardware</legend><div class="kv" id="hw"></div></fieldset>
</div>

<div class="pane" id="p1">
 <div class="row" style="margin-bottom:9px">
  <button class="gh" onclick="chk()">Check for updates</button>
  <button class="gh" onclick="inst('components')">Install / repair all</button>
  <button class="gh" onclick="inst('upgrade')">Upgrade to pinned</button>
  <button class="gh" onclick="inst('upgrade-latest')">Upgrade to latest</button>
  <span id="vchk" style="color:var(--dim);font-size:11px"></span>
 </div>
 <div id="comps"></div>
 <fieldset><legend>Running llama-server processes</legend>
  <table><thead><tr><th>PID</th><th>Memory</th></tr></thead><tbody id="e4"></tbody></table>
  <div class="hint" style="margin:7px 0 0">llama-server is not started directly - llama-swap spawns one per model on demand and stops it after the model's idle timeout.</div>
 </fieldset>
 <fieldset><legend>Endpoints you can use from other tools</legend>
  <div class="mode">One port speaks both the OpenAI and the Anthropic shapes and routes by the <code>model</code> field, so anything that takes a base URL and a model name works - continue.dev, Zed, aider, a shell script.</div>
  <table class="ep"><tbody id="eps"></tbody></table>
  <div id="epmodels" class="hint" style="margin:7px 0 0"></div>
 </fieldset>
</div>

<div class="pane" id="p2">
 <fieldset><legend>What should I run?</legend>
  <div class="mode">Ranks known models against this machine's actual RAM, VRAM and memory bandwidth, and tells you which quant to take.</div>
  <div class="row">
   <select id="sgcase" style="width:auto">
    <option value="">any use case</option><option value="coding">coding</option>
    <option value="reasoning">reasoning</option><option value="general">general</option><option value="chat">chat</option>
   </select>
   <label style="font-size:11px;color:var(--dim)"><input type="checkbox" style="width:auto" id="sgtools"> must be able to call tools</label>
   <button class="act" id="sgbtn" onclick="suggest()">Suggest models</button>
   <span id="sgmsg" style="color:var(--dim);font-size:11px"></span>
  </div>
  <div id="sug"></div>
 </fieldset>

 <fieldset><legend>Add a model you already know</legend>
  <div class="row">
   <input id="repo" placeholder="Hugging Face repo, e.g. unsloth/gpt-oss-20b-GGUF  (or a direct .gguf URL)" style="flex:1;min-width:260px">
   <button class="gh" onclick="inspect()">Inspect</button>
  </div>
  <div id="insp"></div>
 </fieldset>
 <fieldset id="dlbox" style="display:none"><legend>Downloading</legend><div id="dlrows"></div></fieldset>
 <fieldset><legend>Configured models</legend>
  <div class="row" style="margin-bottom:6px"><label style="font-size:11px;color:var(--dim)">
    <input type="checkbox" style="width:auto" id="advchk" onchange="adv(this.checked)"> Show the raw llama.cpp settings</label></div>
  <table><thead><tr><th>Model</th><th>Size</th><th>Conversation length</th><th class="adv">Context</th><th class="adv">KV</th><th class="adv">MoE</th><th class="adv">Last used</th><th class="adv">Loads</th><th>State</th><th></th></tr></thead><tbody id="mt"></tbody></table>
  <div class="hint" style="margin:7px 0 0">Conversation length is how much of a chat the model can hold before it starts forgetting the beginning. <b>Tune</b> measures this machine and sets it as high as your card allows. Tick the box above for the raw <code>-c</code>, KV type and usage counts.</div>
 </fieldset>
 <fieldset><legend>Weights on disk with no config entry</legend><table><tbody id="orph"></tbody></table></fieldset>
</div>

<div class="pane" id="p3">
 <fieldset><legend>Project</legend>
  <div class="row"><input id="pdir" placeholder="C:\path\to\your\project" style="flex:1"></div>
  <div class="hint" style="margin:7px 0 0">Used by the two Run buttons below.</div>
  <div id="agstat" style="color:var(--dim);font-size:11px;margin-top:5px"></div>
 </fieldset>

 <fieldset><legend>Why Claude Code is not here</legend>
  <div class="mode">Measured on this box: a fresh session with plugins off, asked to make <code>load_items</code> skip blank lines in a 12-line file, ran <b>219 tool calls over 29 minutes</b>, never produced a single line of reply, and left the file unchanged. Every earlier failure had a harness cause - this one had none, so it is a model limit rather than a wiring bug. The panel does not offer a session it cannot finish.</div>
  <div class="hint" style="margin:7px 0 0">The script is still installed for direct questions: <code>claude-local.ps1 -Prompt "..."</code>. Note <code>-Check</code> passes this same model in 33s, so it does not predict whether a real session converges.</div>
 </fieldset>

 <fieldset><legend>opencode, on a local model</legend>
  <div class="mode">A local agent does the whole task itself, start to finish. Nothing reaches Anthropic at any point.</div>
  <div class="row"><input id="agtask" placeholder="what it should do, e.g. add a guard clause to divide()" style="flex:1">
   <button class="gh" onclick="runLocal('agent')">Run</button></div>
 </fieldset>

 <fieldset><legend>Delegate the reading</legend>
  <div class="mode">Claude Code stays on the cloud model and keeps its judgement; only the bulk reading happens here, so a huge file costs you almost no quota.</div>
  <div class="row"><input id="dgfile" placeholder="file to read (optional)" style="flex:1.2">
   <input id="dgtask" placeholder="what to extract" style="flex:1.4">
   <button class="gh" onclick="runLocal('delegate')">Run</button></div>
 </fieldset>
 <div class="hint">Results from the two Run buttons appear under Models &gt; Activity.</div>
</div>

<div class="pane" id="p4">
 <fieldset><legend>Sensors</legend>
  <div class="row" style="margin-bottom:6px">
   <button class="gh" onclick="monReset()">Reset min/max</button>
   <span id="monmeta" style="color:var(--dim);font-size:11px"></span>
  </div>
  <table class="sens"><thead><tr><th>Sensor</th><th>Current</th><th>Minimum</th><th>Maximum</th><th>Average</th></tr></thead>
   <tbody id="sens"><tr><td colspan="5" style="color:var(--dim)">waiting for the first sample...</td></tr></tbody></table>
  <div class="hint" style="margin:7px 0 0">Sampled once a second while this tab is open, and not at all while it isn't. Min/max/average cover the samples since this window opened or since the last reset - they are not a lifetime record.</div>
 </fieldset>
</div>

<div class="pane" id="p5">
 <fieldset><legend>Running and recent jobs</legend>
  <div class="mode">Downloads, installs, autotune runs and stack restarts all run detached and write here. This is where their output goes.</div>
  <div id="jobs"></div>
 </fieldset>
</div>

<div class="pane" id="p6">
 <fieldset><legend>Storage</legend>
  <div class="row"><input id="mdir" style="flex:1"><button class="gh" onclick="saveDir()">Save</button></div>
  <div class="hint" style="margin-top:8px">Where new downloads are written. Existing entries in config.yaml keep their own paths.</div>
 </fieldset>
 <fieldset><legend>Ports</legend><div class="kv" id="st"></div></fieldset>
 <fieldset><legend>Desktop integration</legend>
  <div class="row"><button class="gh" onclick="mkLnk()">Create desktop &amp; start-menu shortcut</button>
   <span id="lnk" style="color:var(--dim);font-size:11px"></span></div>
  <div class="hint" style="margin-top:8px">Otherwise the panel is opened by double-clicking <code>LocalLLM.cmd</code> in the install folder.</div>
  <div class="row" style="margin-top:10px"><label><input type="checkbox" id="autost" onchange="setAuto(this.checked)"> Start the stack when I log in</label>
   <span id="autoss" style="color:var(--dim);font-size:11px"></span></div>
  <div class="hint">Brings llama-swap, the chat UI and the tray indicator back on their own after a restart or a crash. The panel itself stays on demand.</div>
 </fieldset>
 <fieldset><legend>Remove parts of the install</legend>
  <div class="hint" style="margin-bottom:8px">Each of these can be reinstalled by pressing Start again. Model weights are never deleted unless you tick the box.</div>
  <div class="row" style="gap:8px;flex-wrap:wrap">
   <select id="rstc">
    <option value="llama-cpp">Engine (llama.cpp)</option>
    <option value="llama-prism">PrismML fork</option>
    <option value="swap">Model router binary</option>
    <option value="webui">Chat UI, with its chats and settings</option>
    <option value="llmfit">Model picker (llmfit)</option>
    <option value="uv">Private Python</option>
    <option value="downloads">Download cache</option>
    <option value="logs">Logs</option>
    <option value="metadata">Version stamp, agent verdicts, logon shortcut</option>
    <option value="all">Everything (full uninstall)</option>
   </select>
   <button class="gh" onclick="rstShow()">Show what this removes</button>
   <span id="rstmsg" style="color:var(--dim);font-size:11px"></span>
  </div>
  <div id="rstout" style="margin-top:10px"></div>
 </fieldset>
</div>
</main>
<div id="act"><div id="acth"><span id="actt">Working</span><button onclick="actHide()" title="hide">&times;</button></div><div id="actb"></div></div>
<div id="ovl"><div id="dlg" role="dialog" aria-modal="true">
 <h4 id="dlgtitle">LocalLLM</h4>
 <div id="dlgbody"></div>
 <div id="dlgfoot"><button class="gh" id="dlgno">Cancel</button><button class="act" id="dlgyes">OK</button></div>
</div></div>
<script>
// ---- dialogs
// One implementation behind msg/ask/askText, all promise-based so callers just await them.
// Replaces alert/confirm/prompt, whose browser-drawn versions are titled "127.0.0.1:9300 says".
let dlgResolve=null;
function dlgClose(v){
 document.getElementById('ovl').classList.remove('on');
 const r=dlgResolve;dlgResolve=null;if(r)r(v);
}
function dlgOpen(o){
 return new Promise(res=>{
  dlgResolve=res;
  document.getElementById('dlgtitle').textContent=o.title||'LocalLLM';
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
 if(e.key==='Escape'){e.preventDefault();dlgClose(null)}
 if(e.key==='Enter'){e.preventDefault();const i=document.getElementById('dlgin');dlgClose(i?i.value:true)}
});

let S={},E={},M={},VER={},JOBS=[],EP={},BUILD=null;
// Every button here starts a detached job and returns immediately, so for up to one poll
// interval a click had no visible effect whatsoever - which reads as the click not registering.
// Busy state comes from two places: the server's job list, which is the truth and survives a
// reload, and an optimistic local mark that covers the gap before the next poll sees the job.
// A mark records when it was made as well as when to give up, because "has this job finished"
// can only be answered against the click that started it - a log left over from the same action
// ten minutes ago would otherwise clear a mark made a moment ago.
let PEND={};
function mark(k,ms){PEND[k]={t:Date.now(),d:Date.now()+(ms||10000)}}
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
function tab(i,b){document.querySelectorAll('.pane').forEach((p,n)=>p.classList.toggle('on',n===i));
 document.querySelectorAll('nav button').forEach(x=>x.classList.remove('on'));b.classList.add('on');
 // Sampling costs an nvidia-smi spawn per second on a single-threaded server, so it only runs
 // while the tab that shows it is actually in front.
 monRun(i===4);
 if(i===3)agents();
 // Read the real state when the tab comes up rather than tracking it: the shortcut can be
 // removed in Explorer or switched off in Task Manager without this page hearing about it.
 if(i===6)auto()}
// ---- coding agents
let AG={};
function pdir(){return document.getElementById('pdir').value.trim()}
async function agents(){
 try{AG=await (await fetch('/api/agents')).json()}catch(e){return}
 const dir=document.getElementById('pdir');
 if(document.activeElement!==dir&&!dir.value&&AG.projectDir)dir.value=AG.projectDir;
 document.getElementById('agstat').innerHTML=AG.opencode?'':'<span class="miss">opencode not on PATH - only Delegate the reading will run</span>';
}
async function runLocal(kind){
 const task=document.getElementById(kind==='agent'?'agtask':'dgtask').value.trim();
 if(!task){msg('Say what it should do first.');return}
 spin(kind==='agent'?'opencode':'delegate',1800000);
 const r=await (await fetch('/api/run-local',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({kind,prompt:task,dir:pdir(),file:document.getElementById('dgfile').value.trim()})})).json();
 if(r.error)msg(r.error);
 setTimeout(tick,700);
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
async function post(u,o){await fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(o||{})})}
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
 if(comp===null){msg('No services are ticked, so Start, Stop and Restart have nothing to act on.\n\nTick llama-swap and/or open-webui on the Dashboard.');return}
 spin(jkey(a,comp),a==='deploy'?600000:60000);
 await post('/api/action',{action:a,component:comp});setTimeout(tick,1200);
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
async function tune(id){spin('autotune-'+id,900000);await post('/api/autotune',{id});setTimeout(tick,700)}
async function saveDir(){await post('/api/settings',{modelsDir:document.getElementById('mdir').value});tick()}
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
function relaxUse(){document.getElementById('sgcase').value='';suggest()}
function relaxTools(on){document.getElementById('sgtools').checked=on;suggest()}
async function suggest(minfit){
 const b=document.getElementById('sgbtn');b.classList.add('busy');b.disabled=true;
 const use=document.getElementById('sgcase').value, tools=document.getElementById('sgtools').checked;
 document.getElementById('sgmsg').textContent='scoring models against this hardware...';
 try{
  const qs='/api/suggest?usecase='+encodeURIComponent(use)+'&tools='+(tools?'1':'0')+(minfit?'&minfit='+minfit:'');
  spin('suggest',180000);
  const started=await (await fetch(qs+'&run=1')).json();
  const d=started.needInstall?started:await waitFor(qs,180000);
  // The picker is a separate 5 MB binary. Telling someone to go and run a CLI action is exactly
  // the friction this panel exists to remove, so the error turns into the button that fixes it.
  if(d.needInstall){document.getElementById('sug').innerHTML=
    '<div class="hint">The picker is a separate 5 MB download. '
    +'<button class="act" onclick="installPicker()">Install it</button></div>';return}
  if(d.error){document.getElementById('sug').innerHTML='<div class="hint miss">'+d.error+'</div>';return}
  const m=d.models||[];
  document.getElementById('sug').innerHTML=m.length?
   '<table><thead><tr><th>Model</th><th>Quant</th><th>Fit</th><th>Size</th><th>est. tok/s</th><th>Context</th><th></th></tr></thead><tbody>'+
   m.map(x=>`<tr><td>${x.name}${x.moe?' <span class="tag">MoE</span>':''}</td><td>${x.quant}</td>
    <td>${x.fit==='Perfect'?'<span class="on2">'+x.fit+'</span>':x.fit}</td>
    <td>${x.sizeGb} GB</td><td>${x.tps}</td><td>${x.ctx||'-'}</td>
    <td><button class="gh" onclick="dl('${x.repo}','${x.quant}')">Download</button></td></tr>`).join('')+
   '</tbody></table><div class="hint" style="margin:7px 0 0">Speeds are estimated from memory bandwidth, not measured - <b>Tune</b> on a downloaded model measures this machine properly. Context here is what the model was trained for, not what will fit; the downloaded entry gets its own setting.</div>'
   :'<div class="hint"><b>Nothing matched.</b> That is the filters, not your hardware - '
    +(use?'the <b>'+esc(use)+'</b> use case':'the current filters')
    +' ruled everything out'+(minfit?' even at a looser fit':'')+'.<div class="row" style="margin-top:7px">'
    +(use?'<button class="gh" onclick="relaxUse()">Try any use case</button>':'')
    +'<button class="gh" onclick="relaxTools('+(tools?'false':'true')+')">'
    +(tools?'Drop the tool-calling requirement':'Require tool calling')+'</button>'
    +(minfit?'':'<button class="gh" onclick="suggest(&quot;marginal&quot;)">Include tighter fits</button>')
    +'</div><div class="note" style="margin-top:6px">These filters do not simply narrow the list - each one changes how models are ranked, so turning one <i>on</i> can produce results where <i>off</i> produced none.</div></div>';
  document.getElementById('sgmsg').textContent='';
 }catch(e){document.getElementById('sug').innerHTML='<div class="hint miss">'+e+'</div>'}
 finally{b.classList.remove('busy');b.disabled=false;document.getElementById('sgmsg').textContent='';delete PEND['suggest'];activity([])}
}
// Straight from the dashboard into the picker, with the tab switched for them. The nav button
// is found by its label rather than threaded through, because tab() wants the element it marks.
function firstModel(){
 const b=[...document.querySelectorAll('nav button')].find(x=>x.textContent==='Models');
 if(b)tab(2,b);
 document.getElementById('sgtools').checked=false;   // a first model is for chatting, not tools
 suggest();
}
async function installPicker(){
 spin('llmfit',300000);
 await post('/api/install-picker',{});
 document.getElementById('sug').innerHTML='<div class="hint">Installing the picker - it appears under Activity. Press <b>Suggest models</b> again in a moment.</div>';
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
  let d; try{d=await (await post('/api/reset',{component:comp,includeModels:inc})).json()}catch(e){return}
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
   h+='<label style="font-size:12px"><input type="checkbox" id="rstim" '+(inc?'checked':'')+' onchange="rstShow()"> also delete model weights</label>';
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
 warn+=inc?'Model weights WILL be deleted - multi-GB and slow to fetch again. ':'Model weights are kept. ';
 warn+='Press Start afterwards to reinstall.';
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
 deploy:['Starting','Launches the router and the chat UI. A first run also downloads them - about 1.5 GB, several minutes.'],
 restart:['Restarting','A few seconds. The chat UI takes longer than the router.'],
 stop:['Stopping',''],
 download:['Downloading a model','Multi-GB. Safe to interrupt - it resumes where it stopped.'],
 llmfit:['Installing the model picker','About 5 MB.'],
 inspect:['Reading the model listing','Metadata only, no weights. Around 40 seconds.'],
 suggest:['Scoring models against this PC','Ranks the catalogue against your RAM, VRAM and memory bandwidth. Up to a minute.'],
 unload:['Freeing VRAM',''],
 vercheck:['Checking for newer versions','Asks GitHub and nodejs.org.'],
 opencode:['The local agent is working','It edits files in your project directly.'],
 delegate:['The local model is reading your file','Long files are split into chunks and answered in turn.']
};
function jobSay(k){
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
 try{S=await (await fetch('/api/status')).json()}catch(e){return}
 // Stale page check, first thing: if the server is running different code than served this page,
 // nothing rendered below can be trusted to match it. Covers the ordinary restart too, since the
 // window survives the server it was opened from.
 if(!BUILD)BUILD=S.build; else if(S.build!==BUILD){location.reload();return}
 // Jobs before anything renders: every button's busy state is derived from this list.
 try{JOBS=await (await fetch('/api/jobs')).json()}catch(e){}
 // A finished job clears its optimistic mark. Without this the mark would hold the button
 // spinning for its whole ceiling - and the ceilings are generous, because they exist for the
 // job that never starts. Restarting llama-swap takes about two seconds; the button should
 // stop spinning then, not sixty seconds later.
 JOBS.forEach(j=>{const p=PEND[j.name];
  if(p&&!j.running&&(Date.now()-j.age*1000)>p.t)delete PEND[j.name]});
 // A load has no job behind it, so its mark clears on the outcome instead - the model is loaded.
 if(S.loaded)delete PEND['load:'+S.loaded];
 // Health is judged only against ticked services - a deselected one being down is not a fault.
 const mine=S.services.filter(s=>s.managed&&s.selected);
 const up=mine.filter(s=>s.up).length, need=mine.length;
 // The header buttons are static markup rather than re-rendered, so they are synced by hand.
 const sel=selected();
 [['go','deploy'],['hre','restart'],['hst','stop']].forEach(([el,a])=>{
  const e=document.getElementById(el),b=busy(jkey(a,sel));
  e.classList.toggle('busy',b);e.disabled=b||(el==='go'&&need>0&&up===need);
 });
 document.getElementById('d').className='dot '+(need===0?'down':up===need?'up':up?'part':'down');
 document.getElementById('sub').textContent=need===0?'nothing selected':up===need?'running':up?'partly running':'stopped';
 document.getElementById('svc').innerHTML=S.services.map(s=>`<tr>
  <td>${s.managed?`<input type="checkbox" style="width:auto" ${s.selected?'checked':''} onchange="toggleSvc('${s.key}',this.checked)">`:''}</td>
  <td>${s.name}</td><td style="color:var(--dim)">${s.role}</td>
  <td>${!s.installed?'<span class="tag">not installed</span>'
    // An unmanaged entry is a CLI you invoke per task, not a service - calling it "stopped", in
    // red, reads as a fault when nothing is wrong and there is no button that would fix it.
    :!s.managed?'<span style="color:var(--dim)">available</span>'
    // Running but not ticked has to say so. The tick is a selection for Start/Stop, not an
    // on/off switch, so unticking leaves the service serving - and the header dot ignores it,
    // because health is judged against ticked services only. Reported as plain "running" that
    // is a service nothing on this page accounts for.
    :s.up?(s.selected?'<span class="on2">running</span>'
                     :'<span class="on2">running</span> <span style="color:var(--dim)">(not selected)</span>')
    :s.selected?'<span class="miss">stopped</span>'
    :'<span style="color:var(--dim)">stopped (not selected)</span>'}</td>
  <td>${s.url&&s.up?`<a href="${s.url}" target="_blank"><button class="gh">Open</button></a>`:''}</td></tr>`).join('');
 document.getElementById('hw').innerHTML=`<span>GPU</span><div>${S.gpu.name}</div>
  <span>VRAM</span><div>${fmt(S.gpu.used)} / ${fmt(S.gpu.total)}<div class="bar"><i style="width:${100*S.gpu.used/S.gpu.total}%"></i></div></div>
  <span>GPU load</span><div>${S.gpu.util}% &nbsp; ${S.gpu.temp} &deg;C</div>
  <span>System RAM</span><div>${S.ramUsed} / ${S.ramTot} GB<div class="bar"><i style="width:${100*S.ramUsed/S.ramTot}%"></i></div></div>
  <span>Loaded model</span><div>${S.loaded||'<span style="color:var(--dim)">idle</span>'}</div>`;
 // First-run walkthrough. Someone who just unzipped this has three things to do in order -
 // install the components, fetch a model, open the chat - and no way to know that from a panel
 // that only reports state. Each step names the next action and disappears once it is done.
 const fresh=mine.some(s=>!s.installed), noModels=M.models&&M.models.length===0;
 const noWeights=M.models&&M.models.length>0&&M.models.every(m=>!m.present);
 let g='';
 if(need===0) g='<div class="hint">No services are ticked, so Start and Stop have nothing to act on. Tick llama-swap and/or open-webui below.</div>';
 else if(fresh) g='<div class="hint"><b>Step 1 of 3.</b> Nothing is installed yet. Press <b>Start</b> - it downloads the inference engine, the router and the chat UI (about 1.5 GB) and takes several minutes on a first run. Progress shows under <b>Engine</b>.</div>';
 else if(!up) g='<div class="hint">Nothing is running. Press <b>Start</b>.</div>';
 else if(up<need) g='<div class="hint">Only part of your stack is up. <b>Restart</b> brings the rest back.</div>';
 // Step 2 used to be four manual instructions ending in "download a variant it says fits your
 // card", which is the step a first-time user is least equipped to judge. It is now one button
 // that opens Models and runs the picker against this machine's own VRAM.
 else if(noModels) g='<div class="hint"><b>Step 2 of 3.</b> The stack is running but has no models yet. '
  +'<button class="act" onclick="firstModel()">Find one that fits this PC</button></div>';
 else if(noWeights) g='<div class="hint">Models are configured but none of their weight files are on disk. Download one from <b>Models</b>, or delete the entries that point at weights you do not have.</div>';
 // Step 3 is keyed on "no model has ever been used", not on "nothing loaded right now" - models
 // unload on their idle timer all day, and a banner that returns every time would be noise.
 else if(M.models&&M.models.every(m=>!m.loads&&!m.lastUsed)) g='<div class="hint"><b>Step 3 of 3.</b> Ready. Open the chat UI with the <b>Open</b> button below and pick a model - your first message loads it, which takes a few seconds.</div>';
 document.getElementById('guide').innerHTML=g;

 try{E=await (await fetch('/api/engine')).json()}catch(e){}
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
 try{EP=await (await fetch('/api/endpoints')).json()}catch(e){}
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
 try{M=await (await fetch('/api/models')).json()}catch(e){}
 downloads(M.downloads||[]);
 activity(M.downloads||[]);
 if(M.models){
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
   <td>${!m.engineOk?'<span class="miss">engine missing</span>':(on?'<span class="on2">loaded</span>':(loading?'<span style="color:var(--warn)">loading</span>':(m.present?'ready':'-')))}</td>
   <td>${m.present?B('gh','load:'+m.id,`load('${m.id}')`,'Load')+' '+
                   B('gh','edit:'+m.id,`edit('${m.id}')`,'Edit')+' '+
                   B('gh','autotune-'+m.id,`tune('${m.id}')`,'Tune')+' ':''}<button class="dz" onclick="del('${m.id}',${m.sizeGb})">Delete</button></td></tr>`}).join('');
  document.getElementById('orph').innerHTML=M.orphans.length?M.orphans.map(o=>`<tr><td>${o.file}</td><td>${o.sizeGb} GB</td><td style="color:var(--dim)">downloaded, not in config.yaml</td></tr>`).join(''):'<tr><td style="color:var(--dim)">none</td></tr>';
 }
 // Cached versions only; the -Latest query costs GitHub round-trips so it waits for the button.
 if(!VER.rows){try{VER=await (await fetch('/api/versions')).json()}catch(e){}}
 document.getElementById('jobs').innerHTML=JOBS.length?JOBS.map(x=>`<div style="margin-bottom:6px"><b style="font-size:11px">${x.id}</b> ${x.running?'<span class="tag" style="color:var(--warn)">running</span>':''} <span style="color:var(--dim);font-size:11px">${x.age}s ago</span><pre>${(x.tail||'(no output yet)').replace(/</g,'&lt;')}</pre></div>`).join(''):'<span style="color:var(--dim)">nothing running</span>';
 // The agents tab refreshes on the normal poll while it is in front. The session list does NOT:
 // it is server-cached for 30s, but the *request* still queues on a single-threaded listener,
 // and adding a seventh call to a 3s tick was enough to saturate it - /api/ping, which does no
 // work at all, was taking a second. Sessions change on the timescale of starting a project, so
 // once every 30s is plenty.
 if(document.getElementById('p3').classList.contains('on'))agents()
 const md=document.getElementById('mdir');
 if(M.settings&&document.activeElement!==md){md.value=M.settings.modelsDir;
  document.getElementById('st').innerHTML=`<span>llama-swap</span><div>127.0.0.1:${M.settings.swapPort}</div><span>Chat UI</span><div>127.0.0.1:${M.settings.webuiPort}</div><span>This panel</span><div>127.0.0.1:${location.port}</div>`;}
}
tick();setInterval(tick,3000);
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
Write-Host "LocalLLM panel -> http://127.0.0.1:$Port  (Ctrl-C to stop)"

# Closing the window leaves this server running, which is the behaviour we want - it is a
# minimise, not a quit. That only works if there is something to restore it from, so make sure
# the tray exists. tray.ps1 holds a named mutex, so launching it when it is already up is a
# no-op rather than a second icon.
$trayPs = Join-Path $root 'tray.ps1'
if (Test-Path $trayPs) {
    Start-Process powershell -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $trayPs
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
        # is that this port is a LocalLLM panel, which failing to bind reveals anyway.
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
                '^/api/agents$'  { $body = Get-Agents | ConvertTo-Json -Depth 5 -Compress }
                '^/api/endpoints$' { $body = Get-Endpoints | ConvertTo-Json -Depth 5 -Compress }
                '^/api/run-local$' {
                    # opencode and local-llm both run to completion and print an answer, so they
                    # are jobs like everything else and read out in Activity.
                    $p = Read-Body $req
                    if (-not $p.prompt) { throw "Give it something to do." }
                    if ($p.kind -eq 'agent') {
                        if (-not $p.dir) { throw "Pick a project directory first." }
                        if (-not (Test-Path $p.dir)) { throw "'$($p.dir)' does not exist." }
                        Set-Settings ([pscustomobject]@{ projectDir = $p.dir }) | Out-Null
                        Start-Job2 'opencode' @('-Directory', $p.dir, '-Prompt', $p.prompt) (Join-Path $root 'local-agent.ps1') | Out-Null
                    } else {
                        if ($p.file -and -not (Test-Path $p.file)) { throw "'$($p.file)' does not exist." }
                        $a = @('-Prompt', $p.prompt)
                        if ($p.file) { $a += @('-File', $p.file) }
                        Start-Job2 'delegate' $a (Join-Path $root 'local-llm.ps1') | Out-Null
                    }
                    $body = '{"ok":true}'
                }
                '^/api/install-picker$' {
                    Start-Job2 'llmfit' @('-Action', 'install-llmfit') $startPs | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/models$' {
                    $body = @{ models = @(Get-ConfiguredModels); orphans = @(Get-OrphanModels)
                               downloads = @(Get-Downloads); settings = (Get-Settings) } | ConvertTo-Json -Depth 6 -Compress
                }
                # ConvertTo-Json on an empty array yields nothing at all, not "[]", so the
                # array is forced with a leading comma to keep it an array of one dimension.
                '^/api/jobs$'   { $body = ConvertTo-Json -InputObject @(Get-Jobs) -Depth 4 -Compress }
                '^/api/action$' {
                    $p = Read-Body $req
                    if ($p.action -in 'deploy', 'restart', 'stop') {
                        $a = @('-Action', $p.action, '-NoTray')
                        if ($p.component) { $a += @('-Component', $p.component) }
                        # The component is part of the job name so "restart swap" and "restart
                        # webui" are distinguishable - otherwise both buttons would spin for either.
                        $name = if ($p.component -and $p.component -ne 'all') { "$($p.action)-$($p.component)" } else { $p.action }
                        Start-Job2 $name $a | Out-Null
                    }
                    $body = '{"ok":true}'
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
                    $a = @('-Action', 'add-model', '-Model', $p.model)
                    if ($p.quant) { $a += @('-Quant', $p.quant) }
                    Start-Job2 "download" $a | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/suggest$' {
                    $q = [Web.HttpUtility]::ParseQueryString($req.Url.Query)
                    $key = "$($q['usecase'])|$($q['tools'])|$($q['minfit'])"
                    if (-not (Test-Path (Join-Path $root 'llmfit\llmfit.exe'))) { $body = '{"needInstall":true}' }
                    else {
                        # run=1 is the button; every other request is the page polling for the answer.
                        if ($q['run'] -eq '1') {
                            $a = @('-Action', 'suggest', '-Json', '-Top', '8')
                            if ($q['usecase']) { $a += @('-UseCase', $q['usecase']) }
                            if ($q['tools'] -ne '1') { $a += @('-Capability', 'any') }
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
                '^/api/settings$' {
                    $p = Read-Body $req
                    $body = (Set-Settings $p) | ConvertTo-Json -Compress
                }
                '^/api/versions$' {
                    $refresh = [Web.HttpUtility]::ParseQueryString($req.Url.Query)['refresh'] -eq '1'
                    $body = (Get-Versions -Refresh:$refresh) | ConvertTo-Json -Depth 5 -Compress
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
                        Start-Process powershell -WindowStyle Hidden -Wait -ArgumentList (
                            @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startPs) + $a2)
                    }
                    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'LocalLLM.lnk'
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
