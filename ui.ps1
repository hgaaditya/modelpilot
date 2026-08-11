# LocalLLM control panel - a local web UI that opens as a chromeless app window.
#
#   .\ui.ps1                 # start the server and open the window
#   .\ui.ps1 -NoWindow       # server only (then browse to http://127.0.0.1:9300)
#   .\ui.ps1 -Install        # desktop + start-menu shortcut, and optional start-with-Windows
#
# Why a local web page rather than a WinForms window: HTML gives a far better interface for the
# same effort, and --app mode makes the browser chromeless, so it still looks and behaves like a
# native app - own taskbar entry, own icon, no address bar.
#
# It binds to 127.0.0.1 only. That matters: this endpoint can start and stop processes, so it
# must never be reachable from the network.
#
# Everything it does shells out to start.ps1. The CLI stays the single source of truth; this is
# a face on it, not a reimplementation.

[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 9300,
    [switch]$NoWindow,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$root      = $PSScriptRoot
$startPs   = Join-Path $root 'start.ps1'
$swapCfg   = Join-Path $root 'llamaswap\config.yaml'
$swapPort  = 9292
$webuiPort = 8080

# ---------------------------------------------------------------- shortcuts

function Find-AppBrowser {
    # Any Chromium supports --app, but which one is picked matters a lot for memory. Opening the
    # window in a browser that is ALREADY RUNNING costs ~106 MB across 2 processes, because it
    # joins the existing browser process tree. Cold-starting a different browser spins up a whole
    # instance - browser, GPU, utility and renderer processes - and measured 500 MB. So prefer a
    # live browser, and only fall back to a fixed order when none is running.
    $installed = [ordered]@{
        chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                   "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
        msedge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")
        brave  = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe")
    }
    $running = @(Get-Process -Name chrome, msedge, brave -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty ProcessName -Unique)

    foreach ($name in @($running + $installed.Keys)) {      # running first, then any installed
        foreach ($p in $installed[$name]) {
            if ($p -and (Test-Path $p)) { return $p }
        }
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
        $lnk.TargetPath = $target
        $lnk.Arguments = $argline
        $lnk.WorkingDirectory = $root
        $lnk.Description = 'LocalLLM control panel'
        $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,15"
        $lnk.Save()
        Write-Host "shortcut -> $(Join-Path $dir 'LocalLLM.lnk')"
    }
    Write-Host ""
    Write-Host "To start with Windows, run this once (creates a logon task):"
    Write-Host "  schtasks /Create /TN LocalLLM /TR `"$target $argline`" /SC ONLOGON /F"
    return
}

# ---------------------------------------------------------------- data the UI needs

function Test-Endpoint($url) {
    try { (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop).StatusCode -eq 200 }
    catch { $false }
}

function Get-ConfiguredModels {
    if (-not (Test-Path $swapCfg)) { return @() }
    $parts = [regex]::Split((Get-Content $swapCfg -Raw), '(?m)^\s{2,}"([^"]+)"\s*:\s*$')
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
            moe     = if ($body -match '--n-cpu-moe\s+(\d+)') { [int]$Matches[1] } else { $null }
            prism   = $body -match 'llama-server-prism'
        }
    }
    $out
}

function Get-Status {
    $gpu = @{ total = 0; used = 0; free = 0; temp = 0; name = 'no NVIDIA GPU' }
    try {
        $q = (nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,temperature.gpu --format=csv,noheader,nounits) -split ','
        $gpu = @{ name = $q[0].Trim(); total = [int]$q[1]; used = [int]$q[2]; free = [int]$q[3]; temp = [int]$q[4] }
    } catch { }
    $loaded = $null
    try { $loaded = ((Invoke-RestMethod "http://127.0.0.1:$swapPort/running" -TimeoutSec 2).running |
                     Where-Object { $_.state -ne 'stopped' } | Select-Object -First 1).model } catch { }
    $os = Get-CimInstance Win32_OperatingSystem
    @{
        swap    = Test-Endpoint "http://127.0.0.1:$swapPort/health"
        webui   = Test-Endpoint "http://127.0.0.1:$webuiPort/health"
        loaded  = $loaded
        gpu     = $gpu
        # Win32_OperatingSystem reports these in kilobytes, so KB -> GB is /1MB, not /1KB.
        ramUsed = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
        ramTot  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        models  = @(Get-ConfiguredModels)
    }
}

# Long-running jobs (start, restart, autotune) must not block the HTTP thread, so they run
# detached and the UI reports on them by polling status like everything else.
function Start-StackAction($action, $component) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startPs, '-Action', $action)
    if ($component) { $a += @('-Component', $component) }
    Start-Process powershell -WindowStyle Hidden -ArgumentList $a
}

# ---------------------------------------------------------------- page

$html = @'
<!doctype html><html><head><meta charset="utf-8"><title>LocalLLM</title>
<style>
:root{--bg:#14161a;--card:#1c1f26;--line:#2a2f3a;--fg:#e6e9ef;--dim:#98a2b3;--ok:#3ecf8e;--warn:#e8b339;--bad:#e5534b;--acc:#5b8def}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
header{padding:16px 22px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:14px}
h1{font-size:16px;margin:0;font-weight:600}
.dot{width:10px;height:10px;border-radius:50%;display:inline-block}
.up{background:var(--ok)}.down{background:var(--bad)}.part{background:var(--warn)}
main{padding:22px;display:grid;gap:18px;max-width:1100px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px}
.card h2{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--dim);margin:0 0 12px}
.row{display:flex;gap:22px;flex-wrap:wrap}
.stat b{display:block;font-size:20px;font-weight:600}.stat span{color:var(--dim);font-size:12px}
button{background:var(--acc);color:#fff;border:0;border-radius:6px;padding:8px 14px;font-size:13px;cursor:pointer}
button.ghost{background:transparent;border:1px solid var(--line);color:var(--fg)}
button:disabled{opacity:.4;cursor:default}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line)}
th{color:var(--dim);font-weight:500;font-size:12px}
.tag{font-size:11px;padding:2px 7px;border-radius:20px;border:1px solid var(--line);color:var(--dim)}
.miss{color:var(--bad)}.bar{height:6px;background:#0d0f13;border-radius:3px;overflow:hidden;margin-top:6px}
.bar i{display:block;height:100%;background:var(--acc)}
.hint{background:#1a2233;border:1px solid #26344d;border-radius:8px;padding:12px 14px;color:#b9c6dd;font-size:13px}
code{background:#0d0f13;padding:2px 6px;border-radius:4px;font-size:12px}
</style></head><body>
<header><span id="d" class="dot down"></span><h1>LocalLLM</h1><span id="sub" style="color:var(--dim);font-size:12px"></span>
<span style="flex:1"></span>
<button class="ghost" onclick="act('restart')">Restart</button>
<button class="ghost" onclick="act('stop')">Stop</button>
<button id="go" onclick="act('deploy')">Start</button></header>
<main>
<div id="guide"></div>
<div class="card"><h2>System</h2><div class="row">
<div class="stat"><b id="gname">-</b><span>GPU</span></div>
<div class="stat"><b id="vram">-</b><span>VRAM<div class="bar"><i id="vbar" style="width:0"></i></div></span></div>
<div class="stat"><b id="ram">-</b><span>System RAM<div class="bar"><i id="rbar" style="width:0"></i></div></span></div>
<div class="stat"><b id="temp">-</b><span>GPU temp</span></div>
<div class="stat"><b id="loaded">idle</b><span>Loaded model</span></div>
</div></div>
<div class="card"><h2>Models</h2><table><thead><tr><th>Model</th><th>Size</th><th>Context</th><th>MoE offload</th><th></th></tr></thead><tbody id="mt"></tbody></table></div>
<div class="card"><h2>Links</h2><div class="row">
<a href="http://127.0.0.1:8080" target="_blank"><button class="ghost">Chat UI</button></a>
<a href="http://127.0.0.1:9292/ui" target="_blank"><button class="ghost">llama-swap dashboard</button></a>
</div></div>
</main>
<script>
async function act(a){await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:a})});setTimeout(tick,1200)}
async function load(id){await fetch('/api/load',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})});setTimeout(tick,800)}
function fmt(mb){return (mb/1024).toFixed(1)+' GB'}
async function tick(){
 let s; try{s=await (await fetch('/api/status')).json()}catch(e){return}
 const both=s.swap&&s.webui, some=s.swap||s.webui;
 document.getElementById('d').className='dot '+(both?'up':some?'part':'down');
 document.getElementById('sub').textContent=both?'running':some?(s.swap?'router up, chat UI down':'chat UI up, router down'):'stopped';
 document.getElementById('go').disabled=both;
 document.getElementById('gname').textContent=s.gpu.name;
 document.getElementById('vram').textContent=fmt(s.gpu.used)+' / '+fmt(s.gpu.total);
 document.getElementById('vbar').style.width=(100*s.gpu.used/s.gpu.total)+'%';
 document.getElementById('ram').textContent=s.ramUsed+' / '+s.ramTot+' GB';
 document.getElementById('rbar').style.width=(100*s.ramUsed/s.ramTot)+'%';
 document.getElementById('temp').textContent=s.gpu.temp+' °C';
 document.getElementById('loaded').textContent=s.loaded||'idle';
 document.getElementById('mt').innerHTML=s.models.map(m=>`<tr>
  <td>${m.id} ${m.prism?'<span class="tag">prism</span>':''}</td>
  <td>${m.present?m.sizeGb+' GB':'<span class="miss">file missing</span>'}</td>
  <td>${m.ctx||'-'}</td><td>${m.moe!==null?'--n-cpu-moe '+m.moe:'-'}</td>
  <td>${m.present&&s.swap?`<button class="ghost" onclick="load('${m.id}')">Load</button>`:''}</td></tr>`).join('');
 const miss=s.models.filter(m=>!m.present).length;
 let g='';
 if(!some) g='<div class="hint">Nothing is running. Press <b>Start</b> above - first run downloads components and can take several minutes.</div>';
 else if(!both) g='<div class="hint">Half the stack is up. <b>Restart</b> brings both services back.</div>';
 else if(miss) g=`<div class="hint">${miss} model${miss>1?'s':''} in the config have no weights on disk. Fetch one with <code>start.ps1 -Action add-model -Model &lt;hf-repo&gt;</code>, or remove the entry.</div>`;
 else if(!s.loaded) g='<div class="hint">Ready. Pick <b>Load</b> on a model to warm it, or open the Chat UI.</div>';
 document.getElementById('guide').innerHTML=g;
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
    else { Start-Process "http://127.0.0.1:$Port" }   # fall back to a normal tab
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request; $res = $ctx.Response
        $body = ''; $type = 'application/json'
        try {
            switch -Regex ($req.Url.AbsolutePath) {
                '^/api/status$' { $body = Get-Status | ConvertTo-Json -Depth 6 -Compress }
                '^/api/action$' {
                    $p = (New-Object IO.StreamReader($req.InputStream)).ReadToEnd() | ConvertFrom-Json
                    if ($p.action -in 'deploy', 'restart', 'stop') { Start-StackAction $p.action $p.component }
                    $body = '{"ok":true}'
                }
                '^/api/load$' {
                    # Any completion makes llama-swap load that model; one token is enough.
                    $p = (New-Object IO.StreamReader($req.InputStream)).ReadToEnd() | ConvertFrom-Json
                    $job = { param($u, $m)
                        try { Invoke-RestMethod $u -Method Post -TimeoutSec 900 -ContentType 'application/json' `
                              -Body (@{ model = $m; messages = @(@{role='user';content='hi'}); max_tokens = 1 } | ConvertTo-Json) } catch { }
                    }
                    Start-Job $job -ArgumentList "http://127.0.0.1:$swapPort/v1/chat/completions", $p.id | Out-Null
                    $body = '{"ok":true}'
                }
                default { $type = 'text/html; charset=utf-8'; $body = $html }
            }
        } catch {
            $res.StatusCode = 500; $body = (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress)
        }
        $buf = [Text.Encoding]::UTF8.GetBytes($body)
        $res.ContentType = $type
        $res.ContentLength64 = $buf.Length
        $res.OutputStream.Write($buf, 0, $buf.Length)
        $res.Close()
    }
} finally { $listener.Stop(); $listener.Close() }
