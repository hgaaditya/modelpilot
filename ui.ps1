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

function Install-Shortcuts {
    $ws = New-Object -ComObject WScript.Shell
    $target = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $argline = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $made = @()
    foreach ($dir in @([Environment]::GetFolderPath('Desktop'),
                       (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
        $path = Join-Path $dir 'LocalLLM.lnk'
        $lnk = $ws.CreateShortcut($path)
        $lnk.TargetPath = $target; $lnk.Arguments = $argline
        $lnk.WorkingDirectory = $root; $lnk.Description = 'LocalLLM control panel'
        $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,15"
        $lnk.Save()
        $made += $path
    }
    $made
}

if ($Install) {
    Install-Shortcuts | ForEach-Object { Write-Host "shortcut -> $_" }
    $target = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $argline = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Write-Host ""
    Write-Host "Start with Windows (run once):"
    Write-Host "  schtasks /Create /TN LocalLLM /TR `"$target $argline`" /SC ONLOGON /F"
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
            useSwap = $true; useWebui = $true }
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
    # timeout - two of them made /api/status block for four seconds, long enough to time out
    # unrelated requests queued behind it. On loopback a live service answers in milliseconds, so
    # a longer wait only buys latency when something is already down.
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
function Get-OrphanModels {
    $s = Get-Settings
    if (-not (Test-Path $s.modelsDir)) { return @() }
    $known = @(Get-ConfiguredModels | Where-Object { $_.path } | ForEach-Object { (Split-Path $_.path -Leaf).ToLower() })
    Get-ChildItem (Join-Path $s.modelsDir '*.gguf') -ErrorAction SilentlyContinue |
        Where-Object { $known -notcontains $_.Name.ToLower() } |
        ForEach-Object { [pscustomobject]@{ file = $_.Name; sizeGb = [math]::Round($_.Length / 1GB, 1) } }
}

function Get-Dashboard {
    $gpu = @{ name = 'no NVIDIA GPU'; total = 0; used = 0; free = 0; temp = 0; util = 0 }
    try {
        $q = (nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader,nounits) -split ','
        $gpu = @{ name = $q[0].Trim(); total = [int]$q[1]; used = [int]$q[2]; free = [int]$q[3]; temp = [int]$q[4]; util = [int]$q[5] }
    } catch { }
    $loaded = $null
    try { $loaded = ((Invoke-RestMethod "http://127.0.0.1:$swapPort/running" -TimeoutSec 2).running |
                     Where-Object { $_.state -ne 'stopped' } | Select-Object -First 1).model } catch { }
    Update-Usage $loaded
    # Cached for Get-Sensors, which is polled every second and must not add a second HTTP probe.
    $script:lastLoaded = $loaded
    $cfg = Get-Settings
    $os = Get-CimInstance Win32_OperatingSystem
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
        ramUsed = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
        ramTot  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
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
    $out = [Collections.ArrayList]@()
    # nvidia-smi prints [N/A] for anything the card or driver doesn't report - a fan curve on a
    # passively cooled card, power draw on some laptop parts. Those stay null rather than becoming
    # zero, which would be averaged in and read as a real measurement.
    $n = @{}
    try {
        $f = 'clocks.current.graphics,clocks.current.memory,temperature.gpu,fan.speed,' +
             'utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit,' +
             'pcie.link.gen.current,pcie.link.width.current'
        $q = (nvidia-smi "--query-gpu=$f" --format=csv,noheader,nounits) -split ','
        for ($i = 0; $i -lt $q.Count; $i++) {
            $s = $q[$i].Trim()
            $n[$i] = if ($s -match '^-?[\d.]+$') { [double]$s } else { $null }
        }
    } catch { }
    if ($n.Count) {
        $free = if ($null -ne $n[7] -and $null -ne $n[6]) { $n[7] - $n[6] } else { $null }
        foreach ($row in @(
            @('GPU Core Clock', $n[0], 'MHz'), @('GPU Memory Clock', $n[1], 'MHz'),
            @('GPU Temperature', $n[2], 'C'),  @('GPU Fan Speed', $n[3], '%'),
            @('GPU Load', $n[4], '%'),         @('Memory Controller Load', $n[5], '%'),
            @('GPU Memory Used', $n[6], 'MB'), @('GPU Memory Free', $free, 'MB'),
            @('Board Power Draw', $n[8], 'W'), @('Power Limit', $n[9], 'W'),
            @('PCIe Link Gen', $n[10], ''),    @('PCIe Link Width', $n[11], 'x'))) {
            [void]$out.Add(@{ name = $row[0]; value = $row[1]; unit = $row[2] })
        }
    }
    try {
        $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        [void]$out.Add(@{ name = 'CPU Load'; value = [math]::Round($cpu, 0); unit = '%' })
        $os = Get-CimInstance Win32_OperatingSystem
        [void]$out.Add(@{ name = 'System RAM Used'
                          value = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB, 0); unit = 'MB' })
    } catch { }
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
    # Same threshold as claude-local.ps1: Claude Code sends 15-25k tokens of system prompt and tool
    # definitions before your first message, so a model at -c 16384 fails on the first turn.
    $min = 32768
    $models = @(Get-ConfiguredModels)
    @{
        minContext = $min
        claude   = [bool](Get-Command claude -ErrorAction SilentlyContinue)
        opencode = [bool](Get-Command opencode -ErrorAction SilentlyContinue)
        script   = (Join-Path $root 'claude-local.ps1')
        delegate = (Join-Path $root 'local-llm.ps1')
        agentScript = (Join-Path $root 'local-agent.ps1')
        # Ready = it would run right now. Short = the only thing wrong is context, which the Models
        # tab can fix in two clicks, so it is worth naming separately from "not usable".
        ready = @($models | Where-Object { $_.present -and $_.engineOk -and $_.ctx -ge $min } |
                  ForEach-Object { @{ id = $_.id; ctx = $_.ctx } } | Sort-Object { -$_.ctx })
        short = @($models | Where-Object { $_.present -and $_.engineOk -and $_.ctx -lt $min } |
                  ForEach-Object { @{ id = $_.id; ctx = $_.ctx } } | Sort-Object { -$_.ctx })
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
    # The pid is what makes "is this still running" answerable. Without it the page can only see
    # that a log file exists, which is true forever, so a button could never stop spinning.
    Set-Content -Path (Join-Path $jobDir "$id.pid") -Value $p.Id -Encoding ascii
    $id
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
.bar{height:5px;background:#e2e6ec;border-radius:3px;overflow:hidden;margin-top:3px}
.bar i{display:block;height:100%;background:var(--acc)}
.tag{font-size:10px;padding:1px 5px;border-radius:9px;border:1px solid var(--line);color:var(--dim);background:var(--soft)}
.miss{color:var(--bad)}.on2{color:var(--ok)}
.hint{background:#eaf1fb;border:1px solid #c3d6f2;border-radius:4px;padding:7px 9px;color:#28425f;font-size:12px;margin-bottom:9px}
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
</style></head><body>
<header><span id="d" class="dot down"></span><b>LocalLLM</b><span id="sub" style="color:var(--dim);font-size:11px"></span>
<span style="flex:1"></span>
<button class="gh" id="hre" onclick="act('restart')">Restart</button>
<button class="gh" id="hst" onclick="act('stop')">Stop</button>
<button class="act" id="go" onclick="act('deploy')">Start</button></header>
<nav>
<button class="on" onclick="tab(0,this)">Dashboard</button>
<button onclick="tab(1,this)">Engine</button>
<button onclick="tab(2,this)">Models</button>
<button onclick="tab(3,this)">Coding agents</button>
<button onclick="tab(4,this)">Monitoring</button>
<button onclick="tab(5,this)">Settings</button>
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
</div>

<div class="pane" id="p2">
 <fieldset><legend>Add a model</legend>
  <div class="row">
   <input id="repo" placeholder="Hugging Face repo, e.g. unsloth/gpt-oss-20b-GGUF  (or a direct .gguf URL)" style="flex:1;min-width:260px">
   <button class="gh" onclick="inspect()">Inspect</button>
  </div>
  <div id="insp"></div>
 </fieldset>
 <fieldset><legend>Configured models</legend>
  <table><thead><tr><th>Model</th><th>Size</th><th>Context</th><th>KV</th><th>MoE</th><th>Last used</th><th>Loads</th><th>State</th><th></th></tr></thead><tbody id="mt"></tbody></table>
  <div class="hint" style="margin:7px 0 0">Last used comes from the weight file's access time. Loads counts only what this panel has seen, so it is a floor rather than a lifetime total.</div>
 </fieldset>
 <fieldset><legend>Weights on disk with no config entry</legend><table><tbody id="orph"></tbody></table></fieldset>
 <fieldset><legend>Activity</legend><div id="jobs"></div></fieldset>
</div>

<div class="pane" id="p3">
 <div class="hint">Your Claude quota running out mid-project doesn't have to end the session. These hand the same repo to a model running here - your files, your history, no upload.</div>
 <fieldset><legend>Claude Code, against a local model</legend>
  <div id="ag1"></div>
  <div class="row" style="margin-top:7px">
   <button class="gh" id="agtest" onclick="agCheck()">Test the handoff now</button>
   <span id="agmsg" style="color:var(--dim);font-size:11px"></span>
  </div>
  <div class="hint" style="margin-top:8px">The test loads a model and calls the same endpoint Claude Code uses, so it takes up to a minute the first time. Output appears under Models &gt; Activity. Worth doing <b>before</b> you need it.</div>
 </fieldset>
 <fieldset><legend>Other ways round</legend><div id="ag2"></div></fieldset>
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
 <fieldset><legend>Storage</legend>
  <div class="row"><input id="mdir" style="flex:1"><button class="gh" onclick="saveDir()">Save</button></div>
  <div class="hint" style="margin-top:8px">Where new downloads are written. Existing entries in config.yaml keep their own paths.</div>
 </fieldset>
 <fieldset><legend>Ports</legend><div class="kv" id="st"></div></fieldset>
 <fieldset><legend>Desktop integration</legend>
  <div class="row"><button class="gh" onclick="mkLnk()">Create desktop &amp; start-menu shortcut</button>
   <span id="lnk" style="color:var(--dim);font-size:11px"></span></div>
  <div class="hint" style="margin-top:8px">Otherwise the panel is opened by double-clicking <code>LocalLLM.cmd</code> in the install folder.</div>
 </fieldset>
</div>
</main>
<script>
let S={},E={},M={},VER={},JOBS=[];
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
 if(i===3)agents();}
// ---- coding agents
let AG={};
function cmdbox(cmd,note){
 // The command is the deliverable here - it has to be copyable, because retyping an absolute
 // path from a screenshot is exactly the friction this tab exists to remove.
 const id='c'+Math.random().toString(36).slice(2,8);
 return `<div style="margin:6px 0"><pre id="${id}" style="margin:0">${cmd.replace(/</g,'&lt;')}</pre>
  <div class="row" style="margin-top:3px"><button class="gh" onclick="cp('${id}',this)">Copy</button>
  <span style="color:var(--dim);font-size:11px">${note}</span></div></div>`;
}
async function cp(id,btn){
 try{await navigator.clipboard.writeText(document.getElementById(id).textContent);
  const t=btn.textContent;btn.textContent='Copied';setTimeout(()=>btn.textContent=t,1200)}
 catch(e){btn.textContent='copy failed'}
}
async function agents(){
 try{AG=await (await fetch('/api/agents')).json()}catch(e){return}
 const ok=s=>s?'<span class="on2">installed</span>':'<span class="miss">not found on PATH</span>';
 const best=(AG.ready&&AG.ready[0])?AG.ready[0]:null;
 let h=`<div class="kv"><span>claude CLI</span><div>${ok(AG.claude)}</div>
  <span>Usable models</span><div>${AG.ready.length?AG.ready.map(m=>m.id+' <span class="tag">-c '+m.ctx+'</span>').join(' '):'<span class="miss">none</span>'}</div></div>`;
 if(!AG.claude) h+='<div class="hint miss" style="margin-top:7px">Claude Code isn\'t on PATH. Install it first - this only redirects it, it doesn\'t replace it.</div>';
 if(!AG.ready.length){
  h+=`<div class="hint miss" style="margin-top:7px">No model here can back a coding agent yet.${
   AG.short.length?' These have weights but too little context: '+AG.short.map(m=>m.id+' (-c '+m.ctx+')').join(', ')+
   '. Claude Code sends 15-25k tokens of system prompt and tool definitions before your first message, so it needs at least -c '+AG.minContext+
   ' - raise one with Models &gt; Edit.':' Download one from the Models tab.'}</div>`;
 }else{
  h+=cmdbox(`powershell -ExecutionPolicy Bypass -File "${AG.script}" -Directory "C:\\path\\to\\your\\project" -Resume`,
            `Run in any terminal. Uses ${best.id} unless you pass -Model. Drop -Resume to start a fresh session instead of picking the project's up.`);
  h+='<div class="hint" style="margin-top:0">Only this process is redirected - your normal <code>claude</code> sessions still go to Anthropic.</div>';
 }
 document.getElementById('ag1').innerHTML=h;
 document.getElementById('ag2').innerHTML=
  `<div class="kv"><span>opencode CLI</span><div>${ok(AG.opencode)}</div></div>`+
  '<div class="hint" style="margin:7px 0 0">A local coding agent that never involves Anthropic at all.</div>'+
  cmdbox(`powershell -ExecutionPolicy Bypass -File "${AG.agentScript}" -Directory "C:\\path\\to\\your\\project" -Prompt "your task"`,'opencode driving a local model.')+
  '<div class="hint" style="margin:9px 0 0">Or keep Claude Code on the cloud model and hand it only the token-heavy grinding - reading a huge log, extracting fields. Only the answer comes back, so the input never enters your Claude context.</div>'+
  cmdbox(`powershell -ExecutionPolicy Bypass -File "${AG.delegate}" -Prompt "List every distinct error and its frequency" -File "app.log"`,'Local model does the reading; you keep your quota.');
 const b=document.getElementById('agtest'),bz=busy('agentcheck');
 b.classList.toggle('busy',bz);b.disabled=bz;
 // The verdict belongs next to the button that asked for it, not only in the Activity log on
 // another tab - "is this ready" is the whole question this tab answers.
 const j=JOBS.find(x=>x.name==='agentcheck');
 const el=document.getElementById('agmsg');
 if(bz)el.textContent='loading a model and calling /v1/messages...';
 else if(j)el.innerHTML=(j.tail||'').replace(/</g,'&lt;')||'ran, no output';
 else el.textContent='';
}
async function agCheck(){
 spin('agentcheck',900000);
 document.getElementById('agmsg').textContent='loading a model and calling /v1/messages...';
 await post('/api/agent-check',{});setTimeout(tick,900);
}
// ---- sensors (Monitoring tab)
let MON={},monTimer=null,monN=0;
function monReset(){MON={};monN=0;document.getElementById('sens').innerHTML=''}
function monRun(on){
 if(on&&!monTimer){mon();monTimer=setInterval(mon,1000)}
 if(!on&&monTimer){clearInterval(monTimer);monTimer=null}
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
 if(comp===null){alert('No services are ticked, so Start/Stop have nothing to act on.\n\nTick at least one on the Dashboard.');return}
 spin(jkey(a,comp),a==='deploy'?600000:60000);
 await post('/api/action',{action:a,component:comp});setTimeout(tick,1200);
}
async function toggleSvc(key,on){await post('/api/settings',key==='swap'?{useSwap:on}:{useWebui:on});tick()}
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
 if(!confirm('This will '+names[what]+'.\n\nThe stack will be stopped and restarted. Model weights and config.yaml are not touched.\n\nContinue?'))return;
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
 const ctx=prompt('Context size for "'+id+'" (-c), in tokens.\n\nLarger costs VRAM: every token has to fit alongside the weights.\nUse Tune to have it measured instead of guessed.',m.ctx||16384);
 if(ctx===null)return;
 if(!/^\d+$/.test(ctx.trim())||+ctx<256){alert('Context has to be a whole number of tokens, 256 or more.');return}
 const kv=prompt('KV cache quantisation for "'+id+'" (-ctk/-ctv).\n\nq8_0 = better long-context recall\nq4_0 = half the cache size, so more context in the same VRAM\nf16  = no quantisation, largest',m.kv||'q8_0');
 if(kv===null)return;
 if(!['q8_0','q4_0','q4_1','q5_0','q5_1','f16','f32'].includes(kv.trim())){alert('Unknown KV type "'+kv.trim()+'".');return}
 spin('edit:'+id,20000);
 const r=await (await fetch('/api/tune',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({id,ctx:+ctx,kv:kv.trim()})})).json();
 delete PEND['edit:'+id];
 if(r.error){alert('Could not write the config: '+r.error);tick();return}
 // llama-swap reads config.yaml only at startup, so the edit does nothing until it bounces.
 if(confirm('Saved. llama-swap only reads config.yaml at startup, so this takes effect after a restart.\n\nRestart llama-swap now?')) act('restart','swap');
 else tick();
}
// Deleting weights is multi-GB and irreversible, so it asks twice: once for the files, then
// separately about the config entry, which is a different decision.
async function del(id,gb){
 if(!confirm('Delete the weight files for "'+id+'"?\n\nThis frees about '+gb+' GB and cannot be undone - the model would have to be downloaded again.'))return;
 const alsoConfig=confirm('Also remove the "'+id+'" entry from config.yaml?\n\nOK  = remove the entry too\nCancel = keep the entry (it will show as "no weights")');
 const r=await (await fetch('/api/delete-model',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id,alsoConfig})})).json();
 if(r.error)alert('Delete failed: '+r.error); else if(alsoConfig)await post('/api/action',{action:'restart',component:'swap'});
 setTimeout(tick,700);
}
function fmt(mb){return (mb/1024).toFixed(1)+' GB'}
async function inspect(){
 const r=document.getElementById('repo').value.trim(); if(!r)return;
 spin('inspect',120000);
 document.getElementById('insp').innerHTML='<div class="hint">Reading metadata over the network - a few MB, no weights. This takes ~40s.</div>';
 try{const d=await (await fetch('/api/inspect?model='+encodeURIComponent(r))).json();
  if(d.error){document.getElementById('insp').innerHTML='<div class="hint miss">'+d.error+'</div>';return}
  document.getElementById('insp').innerHTML='<div class="hint">'+d.summary+'</div><table><thead><tr><th>Variant</th><th>Size</th><th>Verdict</th><th></th></tr></thead><tbody>'+
   d.variants.map(v=>`<tr><td>${v.name}</td><td>${v.size}</td><td>${v.fits?'<span class="on2">'+v.verdict+'</span>':'<span class="miss">'+v.verdict+'</span>'}</td>
   <td><button class="gh" onclick="dl('${d.repo}','${v.quant}')">Download</button></td></tr>`).join('')+'</tbody></table>';
 }catch(e){document.getElementById('insp').innerHTML='<div class="hint miss">'+e+'</div>'}
 delete PEND['inspect'];
}
async function mkLnk(){
 document.getElementById('lnk').textContent='working...';
 try{const d=await (await fetch('/api/shortcuts',{method:'POST'})).json();
  document.getElementById('lnk').textContent=d.error?d.error:'created: '+d.paths.join('  |  ');
 }catch(e){document.getElementById('lnk').textContent=''+e}
}
async function dl(repo,quant){spin('download',3600000);await post('/api/download',{model:repo,quant});document.getElementById('insp').innerHTML='<div class="hint">Download started - watch Activity below.</div>';setTimeout(tick,800)}
async function tick(){
 try{S=await (await fetch('/api/status')).json()}catch(e){return}
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
  <td>${s.installed?(s.up?'<span class="on2">running</span>':(s.managed&&!s.selected?'<span style="color:var(--dim)">stopped (not selected)</span>':'<span class="miss">stopped</span>')):'<span class="tag">not installed</span>'}</td>
  <td>${s.url&&s.up?`<a href="${s.url}" target="_blank"><button class="gh">Open</button></a>`:''}</td></tr>`).join('');
 document.getElementById('hw').innerHTML=`<span>GPU</span><div>${S.gpu.name}</div>
  <span>VRAM</span><div>${fmt(S.gpu.used)} / ${fmt(S.gpu.total)}<div class="bar"><i style="width:${100*S.gpu.used/S.gpu.total}%"></i></div></div>
  <span>GPU load</span><div>${S.gpu.util}% &nbsp; ${S.gpu.temp} °C</div>
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
 else if(noModels) g='<div class="hint"><b>Step 2 of 3.</b> The stack is running but has no models. Open <b>Models</b>, paste a Hugging Face GGUF repo (try <code>unsloth/gpt-oss-20b-GGUF</code>), press <b>Inspect</b>, and download a variant it says fits your card.</div>';
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
 try{M=await (await fetch('/api/models')).json()}catch(e){}
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
   <td>${m.ctx||'-'}</td><td>${m.kv||'-'}</td><td>${m.moe!==null?m.moe:'-'}</td>
   <td style="color:var(--dim)">${m.lastUsed||'-'}</td><td>${m.loads||0}</td>
   <td>${!m.engineOk?'<span class="miss">engine missing</span>':(on?'<span class="on2">loaded</span>':(loading?'<span style="color:var(--warn)">loading</span>':(m.present?'ready':'-')))}</td>
   <td>${m.present?B('gh','load:'+m.id,`load('${m.id}')`,'Load')+' '+
                   B('gh','edit:'+m.id,`edit('${m.id}')`,'Edit')+' '+
                   B('gh','autotune-'+m.id,`tune('${m.id}')`,'Tune')+' ':''}<button class="dz" onclick="del('${m.id}',${m.sizeGb})">Delete</button></td></tr>`}).join('');
  document.getElementById('orph').innerHTML=M.orphans.length?M.orphans.map(o=>`<tr><td>${o.file}</td><td>${o.sizeGb} GB</td><td style="color:var(--dim)">downloaded, not in config.yaml</td></tr>`).join(''):'<tr><td style="color:var(--dim)">none</td></tr>';
 }
 // Cached versions only; the -Latest query costs GitHub round-trips so it waits for the button.
 if(!VER.rows){try{VER=await (await fetch('/api/versions')).json()}catch(e){}}
 document.getElementById('jobs').innerHTML=JOBS.length?JOBS.map(x=>`<div style="margin-bottom:6px"><b style="font-size:11px">${x.id}</b> ${x.running?'<span class="tag" style="color:var(--warn)">running</span>':''} <span style="color:var(--dim);font-size:11px">${x.age}s ago</span><pre>${(x.tail||'(no output yet)').replace(/</g,'&lt;')}</pre></div>`).join(''):'<span style="color:var(--dim)">nothing running</span>';
 // The agents tab is derived from the same job list, so it refreshes on the normal poll while
 // it is in front rather than only when it is clicked into.
 if(document.getElementById('p3').classList.contains('on'))agents();
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
                '^/api/agent-check$' {
                    # A real end-to-end probe: it swaps a model in and calls /v1/messages, so it can
                    # take a minute. A job, therefore - the result reads out in Activity, and the
                    # button spins off the same job list as everything else.
                    Start-Job2 'agentcheck' @('-Check') (Join-Path $root 'claude-local.ps1') | Out-Null
                    $body = '{"ok":true}'
                }
                '^/api/models$' {
                    $body = @{ models = @(Get-ConfiguredModels); orphans = @(Get-OrphanModels); settings = (Get-Settings) } | ConvertTo-Json -Depth 6 -Compress
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
                '^/api/inspect$' {
                    # Runs inline: it is the one action the user is actively waiting on, and its
                    # output is the whole point rather than a side effect.
                    $q = [Web.HttpUtility]::ParseQueryString($req.Url.Query)['model']
                    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $startPs -Action inspect -Model $q 2>&1 | Out-String
                    $lines = $out -split "`r?`n"
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
                    $repo = if ($q -match 'huggingface\.co/([^/]+/[^/?#]+)') { $Matches[1] } else { $q }
                    if (-not $variants) { $body = @{ error = ($out.Trim() -split "`r?`n" | Select-Object -Last 3) -join ' ' } | ConvertTo-Json -Compress }
                    else { $body = @{ repo = $repo; summary = $summary; variants = $variants } | ConvertTo-Json -Depth 5 -Compress }
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
                '^/api/shortcuts$' {
                    # Fast enough to run inline - it writes two .lnk files and nothing else.
                    $body = @{ ok = $true; paths = @(Install-Shortcuts) } | ConvertTo-Json -Compress
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
