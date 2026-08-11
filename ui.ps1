# LocalLLM control panel - a local web UI that opens as a chromeless desktop window.
#
#   .\ui.ps1                 # start the server and open the window
#   .\ui.ps1 -NoWindow       # server only (then browse to http://127.0.0.1:9300)
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
    [switch]$Install
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

# Version strings cost a process launch each, so they're read once and kept.
$script:versionCache = @{}

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

if ($Install) {
    $ws = New-Object -ComObject WScript.Shell
    $target = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $argline = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    foreach ($dir in @([Environment]::GetFolderPath('Desktop'),
                       (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
        $lnk = $ws.CreateShortcut((Join-Path $dir 'LocalLLM.lnk'))
        $lnk.TargetPath = $target; $lnk.Arguments = $argline
        $lnk.WorkingDirectory = $root; $lnk.Description = 'LocalLLM control panel'
        $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,15"
        $lnk.Save()
        Write-Host "shortcut -> $(Join-Path $dir 'LocalLLM.lnk')"
    }
    Write-Host ""
    Write-Host "Start with Windows (run once):"
    Write-Host "  schtasks /Create /TN LocalLLM /TR `"$target $argline`" /SC ONLOGON /F"
    return
}

# ---------------------------------------------------------------- settings

function Get-Settings {
    $d = @{ modelsDir = (Join-Path $llamaCpp 'models'); swapPort = $swapPort; webuiPort = $webuiPort }
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
    try { (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop).StatusCode -eq 200 }
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
    $os = Get-CimInstance Win32_OperatingSystem
    @{
        services = @(
            @{ name = 'llama-swap'; role = 'model router'; up = (Test-Endpoint "http://127.0.0.1:$swapPort/health"); url = "http://127.0.0.1:$swapPort/ui"; installed = (Test-Path (Join-Path $root 'llamaswap\llama-swap.exe')) }
            @{ name = 'open-webui'; role = 'chat interface'; up = (Test-Endpoint "http://127.0.0.1:$webuiPort/health"); url = "http://127.0.0.1:$webuiPort"; installed = [bool](Get-ChildItem $root -Directory -Filter 'open-webui-*' -ErrorAction SilentlyContinue) }
            @{ name = 'opencode'; role = 'local coding agent'; up = $false; url = ''; installed = [bool](Get-Command opencode -ErrorAction SilentlyContinue) }
        )
        gpu     = $gpu
        loaded  = $loaded
        # Win32_OperatingSystem reports kilobytes, so KB -> GB is /1MB.
        ramUsed = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
        ramTot  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
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

function Start-Job2($name, $argList) {
    $id = "{0}-{1}" -f $name, (Get-Date -Format 'HHmmss')
    $log = Join-Path $jobDir "$id.log"
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startPs) + $argList
    Start-Process powershell -WindowStyle Hidden -ArgumentList $a -RedirectStandardOutput $log -RedirectStandardError "$log.err"
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
            @{ id = $_.BaseName; age = [int]((Get-Date) - $_.LastWriteTime).TotalSeconds; tail = $tail }
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
.dot{width:9px;height:9px;border-radius:50%}.up{background:var(--ok)}.down{background:var(--bad)}.part{background:var(--warn)}
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
</style></head><body>
<header><span id="d" class="dot down"></span><b>LocalLLM</b><span id="sub" style="color:var(--dim);font-size:11px"></span>
<span style="flex:1"></span>
<button class="gh" onclick="act('restart')">Restart</button>
<button class="gh" onclick="act('stop')">Stop</button>
<button class="act" id="go" onclick="act('deploy')">Start</button></header>
<nav>
<button class="on" onclick="tab(0,this)">Dashboard</button>
<button onclick="tab(1,this)">Engine</button>
<button onclick="tab(2,this)">Models</button>
<button onclick="tab(3,this)">Settings</button>
</nav>
<main>
<div id="guide"></div>

<div class="pane on" id="p0">
 <fieldset><legend>Services</legend>
  <table><thead><tr><th>Service</th><th>Role</th><th>State</th><th></th></tr></thead><tbody id="svc"></tbody></table>
 </fieldset>
 <fieldset><legend>Hardware</legend><div class="kv" id="hw"></div></fieldset>
</div>

<div class="pane" id="p1">
 <fieldset><legend>llama.cpp (stock)</legend><div class="kv" id="e1"></div></fieldset>
 <fieldset><legend>llama.cpp (PrismML fork - low-bit kernels)</legend><div class="kv" id="e2"></div></fieldset>
 <fieldset><legend>llama-swap (router)</legend><div class="kv" id="e3"></div>
  <div class="row" style="margin-top:8px">
   <button class="gh" onclick="act('restart','swap')">Restart router</button>
   <button class="gh" onclick="act('stop','swap')">Stop router</button>
   <button class="gh" onclick="unloadAll()">Unload models</button>
  </div>
  <div class="hint" style="margin:8px 0 0">llama-server is not started directly - llama-swap spawns one per model on demand and stops it after the model's idle timeout.</div>
 </fieldset>
 <fieldset><legend>Running llama-server processes</legend><table><thead><tr><th>PID</th><th>Memory</th></tr></thead><tbody id="e4"></tbody></table></fieldset>
 <fieldset><legend>Install &amp; upgrade</legend>
  <table><thead><tr><th>Component</th><th>Installed</th><th>Pinned</th><th>Latest upstream</th></tr></thead><tbody id="ver"></tbody></table>
  <div class="row" style="margin-top:7px">
   <button class="gh" onclick="chk()">Check for updates</button>
   <button class="gh" onclick="inst('components')">Install / repair</button>
   <button class="gh" onclick="inst('upgrade')">Upgrade to pinned</button>
   <button class="gh" onclick="inst('upgrade-latest')">Upgrade to latest</button>
   <button class="gh" onclick="inst('prism')">Install PrismML fork</button>
  </div>
  <div class="hint" style="margin:7px 0 0">Install / repair fetches anything missing and leaves what is already correct alone. Upgrades stop the stack, replace only components whose version changed, and never touch model weights or config.yaml.</div>
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
 <fieldset><legend>Storage</legend>
  <div class="row"><input id="mdir" style="flex:1"><button class="gh" onclick="saveDir()">Save</button></div>
  <div class="hint" style="margin-top:8px">Where new downloads are written. Existing entries in config.yaml keep their own paths.</div>
 </fieldset>
 <fieldset><legend>Ports</legend><div class="kv" id="st"></div></fieldset>
 <fieldset><legend>Desktop integration</legend>
  <div class="hint" style="margin:0">Run once in PowerShell for a desktop and start-menu icon:<br><code>.\ui.ps1 -Install</code></div>
 </fieldset>
</div>
</main>
<script>
let S={},E={},M={};
function tab(i,b){document.querySelectorAll('.pane').forEach((p,n)=>p.classList.toggle('on',n===i));
 document.querySelectorAll('nav button').forEach(x=>x.classList.remove('on'));b.classList.add('on')}
async function post(u,o){await fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(o||{})})}
async function act(a,c){await post('/api/action',{action:a,component:c});setTimeout(tick,1200)}
async function load(id){await post('/api/load',{id});setTimeout(tick,700)}
async function unloadAll(){await post('/api/unload',{});setTimeout(tick,700)}
async function tune(id){await post('/api/autotune',{id});setTimeout(tick,700)}
async function saveDir(){await post('/api/settings',{modelsDir:document.getElementById('mdir').value});tick()}
async function inst(what){
 const names={components:'install or repair all components',upgrade:'upgrade to the pinned versions',
  'upgrade-latest':'upgrade to the newest upstream releases','prism':'install the PrismML fork (~620 MB)'};
 if(!confirm('This will '+names[what]+'.\n\nThe stack will be stopped and restarted. Model weights and config.yaml are not touched.\n\nContinue?'))return;
 await post('/api/install',{what});setTimeout(tick,900);
}
async function chk(){
 document.getElementById('ver').innerHTML='<tr><td colspan=4 style="color:var(--dim)">querying GitHub and nodejs.org...</td></tr>';
 try{const v=await (await fetch('/api/versions?refresh=1')).json();renderVer(v)}catch(e){}
}
function renderVer(v){
 if(!v||!v.rows)return;
 document.getElementById('ver').innerHTML=v.rows.map(r=>{
  const behind=r.latest&&r.latest!==r.installed;
  return `<tr><td>${r.component}</td><td>${r.installed}</td><td>${r.pinned}</td>
   <td>${r.latest?(behind?'<span class="miss">'+r.latest+'</span>':'<span class="on2">'+r.latest+'</span>'):'<span style="color:var(--dim)">not checked</span>'}</td></tr>`}).join('');
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
 document.getElementById('insp').innerHTML='<div class="hint">Reading metadata over the network - a few MB, no weights. This takes ~40s.</div>';
 try{const d=await (await fetch('/api/inspect?model='+encodeURIComponent(r))).json();
  if(d.error){document.getElementById('insp').innerHTML='<div class="hint miss">'+d.error+'</div>';return}
  document.getElementById('insp').innerHTML='<div class="hint">'+d.summary+'</div><table><thead><tr><th>Variant</th><th>Size</th><th>Verdict</th><th></th></tr></thead><tbody>'+
   d.variants.map(v=>`<tr><td>${v.name}</td><td>${v.size}</td><td>${v.fits?'<span class="on2">'+v.verdict+'</span>':'<span class="miss">'+v.verdict+'</span>'}</td>
   <td><button class="gh" onclick="dl('${d.repo}','${v.quant}')">Download</button></td></tr>`).join('')+'</tbody></table>';
 }catch(e){document.getElementById('insp').innerHTML='<div class="hint miss">'+e+'</div>'}
}
async function dl(repo,quant){await post('/api/download',{model:repo,quant});document.getElementById('insp').innerHTML='<div class="hint">Download started - watch Activity below.</div>';setTimeout(tick,800)}
async function tick(){
 try{S=await (await fetch('/api/status')).json()}catch(e){return}
 const up=S.services.filter(s=>s.up).length, need=2;
 document.getElementById('d').className='dot '+(up>=need?'up':up?'part':'down');
 document.getElementById('sub').textContent=up>=need?'running':up?'partly running':'stopped';
 document.getElementById('go').disabled=up>=need;
 document.getElementById('svc').innerHTML=S.services.map(s=>`<tr><td>${s.name}</td><td style="color:var(--dim)">${s.role}</td>
  <td>${s.installed?(s.up?'<span class="on2">running</span>':'<span class="miss">stopped</span>'):'<span class="tag">not installed</span>'}</td>
  <td>${s.url&&s.up?`<a href="${s.url}" target="_blank"><button class="gh">Open</button></a>`:''}</td></tr>`).join('');
 document.getElementById('hw').innerHTML=`<span>GPU</span><div>${S.gpu.name}</div>
  <span>VRAM</span><div>${fmt(S.gpu.used)} / ${fmt(S.gpu.total)}<div class="bar"><i style="width:${100*S.gpu.used/S.gpu.total}%"></i></div></div>
  <span>GPU load</span><div>${S.gpu.util}% &nbsp; ${S.gpu.temp} °C</div>
  <span>System RAM</span><div>${S.ramUsed} / ${S.ramTot} GB<div class="bar"><i style="width:${100*S.ramUsed/S.ramTot}%"></i></div></div>
  <span>Loaded model</span><div>${S.loaded||'<span style="color:var(--dim)">idle</span>'}</div>`;
 let g='';
 if(!up) g='<div class="hint">Nothing is running. Press <b>Start</b> - the first run downloads components and can take several minutes.</div>';
 else if(up<need) g='<div class="hint">Only part of the stack is up. <b>Restart</b> brings the rest back.</div>';
 document.getElementById('guide').innerHTML=g;

 try{E=await (await fetch('/api/engine')).json()}catch(e){}
 if(E.llamacpp){
  document.getElementById('e1').innerHTML=`<span>Status</span><div>${E.llamacpp.installed?'<span class="on2">installed</span>':'<span class="miss">not installed</span>'}</div><span>Build</span><div>${E.llamacpp.version||'-'}</div><span>Path</span><div style="color:var(--dim)">${E.llamacpp.path}</div>`;
  document.getElementById('e2').innerHTML=`<span>Status</span><div>${E.prism.installed?'<span class="on2">installed</span>':'<span class="tag">not installed</span>'}</div><span>Build</span><div>${E.prism.version||'-'}</div><span>Path</span><div style="color:var(--dim)">${E.prism.path}</div>`;
  document.getElementById('e3').innerHTML=`<span>Status</span><div>${E.swap.up?'<span class="on2">running</span>':'<span class="miss">stopped</span>'}</div><span>Processes</span><div>${E.swap.procs.map(p=>'pid '+p.pid+' ('+p.mb+' MB)').join(', ')||'-'}</div>`;
  document.getElementById('e4').innerHTML=E.servers.length?E.servers.map(s=>`<tr><td>${s.pid}</td><td>${s.mb} MB</td></tr>`).join(''):'<tr><td colspan=2 style="color:var(--dim)">none - no model loaded</td></tr>';
 }
 try{M=await (await fetch('/api/models')).json()}catch(e){}
 if(M.models){
  document.getElementById('mt').innerHTML=M.models.map(m=>`<tr>
   <td>${m.id} ${m.prism?'<span class="tag">prism</span>':''}</td>
   <td>${m.present?m.sizeGb+' GB':'<span class="miss">no weights</span>'}</td>
   <td>${m.ctx||'-'}</td><td>${m.kv||'-'}</td><td>${m.moe!==null?m.moe:'-'}</td>
   <td style="color:var(--dim)">${m.lastUsed||'-'}</td><td>${m.loads||0}</td>
   <td>${S.loaded===m.id?'<span class="on2">loaded</span>':(m.present?'ready':'-')}</td>
   <td>${m.present?`<button class="gh" onclick="load('${m.id}')">Load</button> <button class="gh" onclick="tune('${m.id}')">Tune</button> `:''}<button class="dz" onclick="del('${m.id}',${m.sizeGb})">Delete</button></td></tr>`).join('');
  document.getElementById('orph').innerHTML=M.orphans.length?M.orphans.map(o=>`<tr><td>${o.file}</td><td>${o.sizeGb} GB</td><td style="color:var(--dim)">downloaded, not in config.yaml</td></tr>`).join(''):'<tr><td style="color:var(--dim)">none</td></tr>';
 }
 // Cached versions only; the -Latest query costs GitHub round-trips so it waits for the button.
 if(!document.getElementById('ver').innerHTML){try{renderVer(await (await fetch('/api/versions')).json())}catch(e){}}
 try{const j=await (await fetch('/api/jobs')).json();
  document.getElementById('jobs').innerHTML=j.length?j.map(x=>`<div style="margin-bottom:6px"><b style="font-size:11px">${x.id}</b> <span style="color:var(--dim);font-size:11px">${x.age}s ago</span><pre>${(x.tail||'(no output yet)').replace(/</g,'&lt;')}</pre></div>`).join(''):'<span style="color:var(--dim)">nothing running</span>';
 }catch(e){}
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
    if (-not $NoWindow) {
        # Focus the window that exists rather than opening another one.
        $existing = Get-Process -Name chrome, msedge, brave -ErrorAction SilentlyContinue |
                    Where-Object { $_.MainWindowTitle -eq 'LocalLLM' } | Select-Object -First 1
        if ($existing) {
            Add-Type -Namespace Win -Name N -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);' -ErrorAction SilentlyContinue
            [void][Win.N]::SetForegroundWindow($existing.MainWindowHandle)
        } else {
            $b = Find-AppBrowser
            if ($b) { Start-Process $b @("--app=http://127.0.0.1:$Port", '--window-size=1040,720') }
        }
    }
    return
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch { throw "Could not bind 127.0.0.1:$Port - is the panel already running? ($($_.Exception.Message))" }
Write-Host "LocalLLM panel -> http://127.0.0.1:$Port  (Ctrl-C to stop)"

if (-not $NoWindow) {
    $browser = Find-AppBrowser
    # Size the window to the content. Without this the browser opens at its own last-used
    # geometry, which is a large mostly-empty frame around a compact panel.
    if ($browser) { Start-Process $browser @("--app=http://127.0.0.1:$Port", '--window-size=1040,720') }
    else { Start-Process "http://127.0.0.1:$Port" }
}

function Read-Body($req) {
    $s = (New-Object IO.StreamReader($req.InputStream)).ReadToEnd()
    if ($s) { $s | ConvertFrom-Json } else { $null }
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request; $res = $ctx.Response
        $body = ''; $type = 'application/json'
        try {
            switch -Regex ($req.Url.AbsolutePath) {
                # Deliberately does no work: the single-instance check needs an answer that can
                # never be slower than its timeout. /api/status shells out to nvidia-smi, queries
                # WMI and probes two health endpoints, so it is far too slow to test liveness with.
                '^/api/ping$'   { $body = '{"ok":true}' }
                '^/api/status$' { $body = Get-Dashboard | ConvertTo-Json -Depth 6 -Compress }
                '^/api/engine$' { $body = Get-Engine | ConvertTo-Json -Depth 6 -Compress }
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
                        Start-Job2 $p.action $a | Out-Null
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
                '^/api/delete-model$' {
                    $p = Read-Body $req
                    $body = (Remove-ModelFiles $p.id ([bool]$p.alsoConfig)) | ConvertTo-Json -Compress
                }
                default { $type = 'text/html; charset=utf-8'; $body = $html }
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
