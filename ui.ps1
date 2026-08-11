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
$swapPort   = 9292
$webuiPort  = 8080
New-Item -ItemType Directory -Force -Path $jobDir | Out-Null

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
        $out += [pscustomobject]@{
            id      = $parts[$i]
            path    = $path
            present = [bool]$present
            sizeGb  = if ($present) { [math]::Round((Get-Item $path).Length / 1GB, 1) } else { 0 }
            ctx     = if ($body -match '-c\s+(\d+)') { [int]$Matches[1] } else { 0 }
            kv      = if ($body -match '-ctk\s+(\S+)') { $Matches[1] } else { '' }
            moe     = if ($body -match '--n-cpu-moe\s+(\d+)') { [int]$Matches[1] } else { $null }
            prism   = [bool]($body -match 'llama-server-prism')
        }
    }
    $out
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
:root{--bg:#1b1d22;--panel:#23262d;--line:#333842;--fg:#e8ebf0;--dim:#939cab;--ok:#43c98b;--warn:#e0ae3c;--bad:#e0574d;--acc:#4d8bf0}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:13px/1.45 "Segoe UI",system-ui,sans-serif;user-select:none}
header{display:flex;align-items:center;gap:10px;padding:8px 12px;background:var(--panel);border-bottom:1px solid var(--line)}
header b{font-size:13px;font-weight:600}
.dot{width:9px;height:9px;border-radius:50%}.up{background:var(--ok)}.down{background:var(--bad)}.part{background:var(--warn)}
nav{display:flex;gap:1px;background:var(--line);padding:0 8px;border-bottom:1px solid var(--line)}
nav button{background:var(--bg);border:0;border-bottom:2px solid transparent;color:var(--dim);padding:7px 16px;font-size:12px;cursor:pointer}
nav button.on{color:var(--fg);border-bottom-color:var(--acc);background:var(--panel)}
main{padding:12px}
.pane{display:none}.pane.on{display:block}
fieldset{border:1px solid var(--line);border-radius:4px;margin:0 0 10px;padding:8px 10px 10px}
legend{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.07em;padding:0 5px}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;color:var(--dim);font-weight:500;padding:4px 8px;border-bottom:1px solid var(--line)}
td{padding:4px 8px;border-bottom:1px solid #2a2e37}
tr:last-child td{border-bottom:0}
.kv{display:grid;grid-template-columns:130px 1fr;gap:2px 10px;font-size:12px}
.kv span{color:var(--dim)}
button.act{background:var(--acc);color:#fff;border:0;border-radius:3px;padding:4px 11px;font-size:12px;cursor:pointer}
button.gh{background:#2b2f38;color:var(--fg);border:1px solid var(--line);border-radius:3px;padding:4px 11px;font-size:12px;cursor:pointer}
button:disabled{opacity:.35;cursor:default}
input,select{background:#171a1f;border:1px solid var(--line);color:var(--fg);border-radius:3px;padding:4px 7px;font-size:12px;user-select:text}
input{width:100%}
.bar{height:5px;background:#131519;border-radius:3px;overflow:hidden;margin-top:3px}
.bar i{display:block;height:100%;background:var(--acc)}
.tag{font-size:10px;padding:1px 6px;border-radius:9px;border:1px solid var(--line);color:var(--dim)}
.miss{color:var(--bad)}.on2{color:var(--ok)}
.hint{background:#1d2634;border:1px solid #2b3purple;border-color:#2b3a52;border-radius:4px;padding:8px 10px;color:#aebbd0;font-size:12px;margin-bottom:10px}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
pre{background:#131519;border:1px solid var(--line);border-radius:3px;padding:7px;font-size:11px;margin:6px 0 0;white-space:pre-wrap;max-height:110px;overflow:auto;user-select:text}
code{background:#131519;padding:1px 5px;border-radius:3px;font-size:11px}
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
  <table><thead><tr><th>Model</th><th>Size</th><th>Context</th><th>KV</th><th>MoE offload</th><th>State</th><th></th></tr></thead><tbody id="mt"></tbody></table>
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
   <td>${S.loaded===m.id?'<span class="on2">loaded</span>':(m.present?'ready':'-')}</td>
   <td>${m.present?`<button class="gh" onclick="load('${m.id}')">Load</button> <button class="gh" onclick="tune('${m.id}')">Tune</button>`:''}</td></tr>`).join('');
  document.getElementById('orph').innerHTML=M.orphans.length?M.orphans.map(o=>`<tr><td>${o.file}</td><td>${o.sizeGb} GB</td><td style="color:var(--dim)">downloaded, not in config.yaml</td></tr>`).join(''):'<tr><td style="color:var(--dim)">none</td></tr>';
 }
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

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch { throw "Could not bind 127.0.0.1:$Port - is the panel already running? ($($_.Exception.Message))" }
Write-Host "LocalLLM panel -> http://127.0.0.1:$Port  (Ctrl-C to stop)"

if (-not $NoWindow) {
    $browser = Find-AppBrowser
    if ($browser) { Start-Process $browser "--app=http://127.0.0.1:$Port" }
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
