# Local LLM stack: bootstrap, launch, upgrade, uninstall.
#
#   .\start.ps1                      # deploy (first run) + launch. Idempotent.
#   .\start.ps1 -Action stop         # stop llama-swap, any llama-server, and the open-webui backend
#   .\start.ps1 -Action restart      # stop, then launch again
#   .\start.ps1 -Action restart -Component swap    # just llama-swap: how a new model becomes routable
#   .\start.ps1 -Action status       # what's installed vs. what's pinned vs. what's newest upstream
#   .\start.ps1 -Action upgrade      # move to the versions pinned in $VER below
#   .\start.ps1 -Action upgrade -Latest   # move to the newest upstream release of each component
#   .\start.ps1 -Action add-model -Url <direct .gguf url>   # resumable weight download into llama.cpp\models
#   .\start.ps1 -Action tray         # (re)start just the tray status indicator
#   .\start.ps1 -Action uninstall    # stop + remove everything (keeps .gguf weights unless -IncludeModels)
#
# Launching verifies both services answer /health before reporting success, warns up front about
# any model in config.yaml whose .gguf is missing, and raises a tray indicator (see tray.ps1,
# suppress with -NoTray).
#
# Versions live in $VER and are stamped to .stack-versions.json after each successful run, so
# a plain re-run relaunches what's installed instead of silently re-provisioning.
#
# Starts:
#   llama-swap  http://127.0.0.1:9292  (model router -> llama-server)
#   open-webui  http://127.0.0.1:8080  (chat UI)

[CmdletBinding()]
param(
    [ValidateSet('deploy', 'upgrade', 'uninstall', 'status', 'stop', 'restart', 'add-model', 'tray')]
    [string]$Action = 'deploy',

    # deploy/restart: don't launch the tray status indicator.
    [switch]$NoTray,

    # stop/restart: act on one half of the stack only. 'swap' also takes down the llama-server
    # processes it spawned. Restarting 'swap' alone is how a newly added model becomes routable,
    # since llama-swap only reads config.yaml at startup.
    [ValidateSet('all', 'swap', 'webui')]
    [string]$Component = 'all',

    # upgrade/status: resolve the newest upstream release of each component instead of using $VER.
    [switch]$Latest,

    # add-model: what to fetch. A Hugging Face repo ("bartowski/Qwen_Qwen3-8B-GGUF", optionally
    # suffixed ":Q4_K_M"), a huggingface.co URL of either a repo or a single file, or any other
    # direct .gguf URL.
    [Alias('Url')]
    [string]$Model,

    # add-model: which quantisation to pull from a repo that offers several.
    [string]$Quant = 'Q4_K_M',

    # add-model: llama-swap model id to register (defaults to the file name, lowercased).
    [string]$Id,

    # add-model: context size for the generated config.yaml entry.
    [int]$Context = 16384,

    # add-model: save under this filename instead of the one in the URL.
    [string]$Name,

    # add-model: download only, don't touch llamaswap\config.yaml.
    [switch]$NoConfig,

    # uninstall: also delete the multi-GB .gguf weights (kept by default - they're slow to re-fetch).
    [switch]$IncludeModels,

    # uninstall: skip the confirmation prompt.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- pinned versions ------------------------------------------------------
# Bump these and run `-Action upgrade` to move the stack forward deterministically.
$VER = @{
    llamaCpp  = 'b10155'
    llamaSwap = 'v244'
    openWebUI = '0.11.0'      # open-webui pins requires-python <3.13 and node <=22.x
    node      = 'v22.23.1'
    cuda      = 'cuda-13.3'   # only a fallback - the exact CUDA asset is resolved from the release
}

$root         = $PSScriptRoot
$llamaCpp     = Join-Path $root 'llama.cpp'
$modelsDir    = Join-Path $llamaCpp 'models'
$llamaSwapDir = Join-Path $root 'llamaswap'
$swapConfig   = Join-Path $llamaSwapDir 'config.yaml'
$logDir       = Join-Path $root 'logs'
$stampFile    = Join-Path $root '.stack-versions.json'
$dl           = Join-Path $env:TEMP 'localllm-dl'
$swapPort     = 9292
$webuiPort    = 8080

function Get-File($url, $out) {
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $out
}

# Weights are multi-GB: Invoke-WebRequest has no resume and no progress, curl.exe (ships with
# Windows 10+) has both. Downloads to <out>.part and only renames on success, so an interrupted
# pull resumes on re-run and a partial file is never mistaken for a complete model.
function Get-BigFile($url, $out) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) {
        $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
        if (-not $curl) { throw "curl.exe not found - it ships with Windows 10+; install it or download $url manually into $modelsDir." }
    }
    $part = "$out.part"
    & $curl -L -C - --fail --progress-bar -o $part $url
    if ($LASTEXITCODE -ne 0) {
        $resume = if (Test-Path $part) { " Partial file kept at $part - re-run to resume." } else { "" }
        throw "Download failed (curl exit $LASTEXITCODE).$resume"
    }
    Move-Item $part $out -Force
}

function Read-Stamp {
    if (-not (Test-Path $stampFile)) { return $null }
    $obj = Get-Content $stampFile -Raw | ConvertFrom-Json
    $h = @{}
    foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h
}

function Write-Stamp($ver) {
    $ver | ConvertTo-Json | Set-Content -Path $stampFile -Encoding utf8
}

# Existing open-webui checkout, whatever version it is (the dir name carries the version).
function Find-WebuiDir {
    Get-ChildItem $root -Directory -Filter 'open-webui-*' -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1 | ForEach-Object { $_.FullName }
}

function Get-GitHubRelease($repo, $tag) {
    $url = if ($tag) { "https://api.github.com/repos/$repo/releases/tags/$tag" }
           else       { "https://api.github.com/repos/$repo/releases/latest" }
    try { Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'localllm-setup' } }
    catch { $null }
}

function Resolve-Latest($ver) {
    $out = $ver.Clone()
    Write-Host "Resolving newest upstream releases..."

    $r = Get-GitHubRelease 'ggml-org/llama.cpp'
    if ($r) { $out.llamaCpp = $r.tag_name } else { Write-Warning "Could not query llama.cpp releases - keeping $($ver.llamaCpp)" }

    $r = Get-GitHubRelease 'mostlygeek/llama-swap'
    if ($r) { $out.llamaSwap = $r.tag_name } else { Write-Warning "Could not query llama-swap releases - keeping $($ver.llamaSwap)" }

    $r = Get-GitHubRelease 'open-webui/open-webui'
    if ($r) { $out.openWebUI = $r.tag_name -replace '^v', '' } else { Write-Warning "Could not query open-webui releases - keeping $($ver.openWebUI)" }

    try {
        # open-webui's .npmrc has engine-strict=true pinning node <=22.x, so stay on the 22 line.
        $idx = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json'
        $n = $idx | Where-Object { $_.version -like 'v22.*' } | Select-Object -First 1
        if ($n) { $out.node = $n.version }
    } catch { Write-Warning "Could not query nodejs.org - keeping $($ver.node)" }

    $out
}

# open-webui's backend: only the python.exe running out of our own venv, never a user's other
# interpreter. Both Stop-Stack and Test-StackRunning key off this.
function Get-WebuiProcess {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) }
}

function Get-TrayProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'tray\.ps1' }
}

# The tray script self-deduplicates via a named mutex, so firing this off unconditionally is safe.
function Start-Tray {
    $tray = Join-Path $root 'tray.ps1'
    if (-not (Test-Path $tray)) { return }
    Start-Process powershell -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $tray,
                      '-SwapPort', "$swapPort", '-WebuiPort', "$webuiPort"
}

# 'swap' covers llama-swap and the llama-server processes it spawns - they're its children and
# are meaningless without it. 'webui' is the open-webui backend. 'all' is both.
function Test-ComponentRunning($component = 'all') {
    if ($component -ne 'webui' -and @(Get-Process -Name 'llama-swap' -ErrorAction SilentlyContinue).Count) { return $true }
    if ($component -ne 'swap' -and @(Get-WebuiProcess).Count) { return $true }
    $false
}

function Test-StackRunning { Test-ComponentRunning 'all' }

function Stop-Stack($component = 'all') {
    $stopped = 0
    if ($component -ne 'webui') {
        foreach ($n in 'llama-swap', 'llama-server') {
            $procs = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
            $stopped += $procs.Count
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    if ($component -ne 'swap') {
        Get-WebuiProcess | ForEach-Object {
            $stopped++
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    $what = if ($component -eq 'all') { 'stack' } else { $component }
    if ($stopped) { Write-Host "Stopped $stopped $what process(es)."; Start-Sleep -Seconds 1 }
    else { Write-Host "Nothing was running for '$what'." }
}

# ==========================================================================
#  deploy - every step is skipped once its artifact exists
# ==========================================================================
function Invoke-Deploy($ver) {
    $webui    = Join-Path $root "open-webui-$($ver.openWebUI)"
    $venv     = Join-Path $webui '.venv'
    $venvPy   = Join-Path $venv 'Scripts\python.exe'
    $nodeRoot = Join-Path $webui '.node-runtime'
    $nodeDir  = Join-Path $nodeRoot "node-$($ver.node)-win-x64"
    $nodeExe  = Join-Path $nodeDir 'node.exe'
    $npmCmd   = Join-Path $nodeDir 'npm.cmd'

    New-Item -ItemType Directory -Force -Path $dl | Out-Null

    # --- 0. open-webui source ---
    # Not vendored in this repo - it's a full upstream project, so it's fetched fresh like the binaries.
    if (-not (Test-Path $webui)) {
        Write-Host "Fetching open-webui v$($ver.openWebUI) source..."
        $owuiTar = Join-Path $dl "open-webui-v$($ver.openWebUI).tar.gz"
        Get-File "https://github.com/open-webui/open-webui/archive/refs/tags/v$($ver.openWebUI).tar.gz" $owuiTar
        tar -xzf $owuiTar -C $root
        if (-not (Test-Path $webui)) { throw "Extracted open-webui archive but $webui was not created - check the tarball's root folder name." }
    }

    # --- 1. llama.cpp binaries ---
    if (-not (Test-Path (Join-Path $llamaCpp 'llama-server.exe'))) {
        New-Item -ItemType Directory -Force -Path $llamaCpp | Out-Null
        $hasGpu = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
        Write-Host "Fetching llama.cpp $($ver.llamaCpp) ($(if ($hasGpu) { 'CUDA' } else { 'CPU' }))..."

        # The CUDA toolkit version is baked into the asset name and changes between releases,
        # so read it off the release rather than guessing; $VER.cuda is only the offline fallback.
        $rel = Get-GitHubRelease 'ggml-org/llama.cpp' $ver.llamaCpp
        $pat = if ($hasGpu) { '-bin-win-cuda-.*-x64\.zip$' } else { '-bin-win-cpu-x64\.zip$' }
        $url = $null
        if ($rel) { $url = ($rel.assets | Where-Object { $_.name -match $pat } | Select-Object -First 1).browser_download_url }
        if (-not $url) {
            $variant = if ($hasGpu) { $ver.cuda } else { 'cpu' }
            $url = "https://github.com/ggml-org/llama.cpp/releases/download/$($ver.llamaCpp)/llama-$($ver.llamaCpp)-bin-win-$variant-x64.zip"
        }
        $zip = Join-Path $dl "llama-$($ver.llamaCpp).zip"
        Get-File $url $zip
        Expand-Archive -Path $zip -DestinationPath $llamaCpp -Force

        if ($hasGpu) {
            $curl = $null
            if ($rel) { $curl = ($rel.assets | Where-Object { $_.name -match '^cudart-.*-x64\.zip$' } | Select-Object -First 1).browser_download_url }
            if (-not $curl) { $curl = "https://github.com/ggml-org/llama.cpp/releases/download/$($ver.llamaCpp)/cudart-llama-bin-win-$($ver.cuda)-x64.zip" }
            $cudartZip = Join-Path $dl "cudart-$($ver.llamaCpp).zip"
            Get-File $curl $cudartZip
            Expand-Archive -Path $cudartZip -DestinationPath $llamaCpp -Force
        }
    }
    New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null

    # --- 2. llama-swap binary ---
    if (-not (Test-Path (Join-Path $llamaSwapDir 'llama-swap.exe'))) {
        New-Item -ItemType Directory -Force -Path $llamaSwapDir | Out-Null
        Write-Host "Fetching llama-swap $($ver.llamaSwap)..."
        $num = $ver.llamaSwap -replace '^v', ''
        $swapZip = Join-Path $dl "llama-swap-$($ver.llamaSwap).zip"
        Get-File "https://github.com/mostlygeek/llama-swap/releases/download/$($ver.llamaSwap)/llama-swap_${num}_windows_amd64.zip" $swapZip
        Expand-Archive -Path $swapZip -DestinationPath $llamaSwapDir -Force
    }
    # config.yaml is checked-in project config, not a download artifact - must already exist alongside this script.

    # --- 3. model weights ---
    # Deliberately not bootstrapped: GGUF quant sources vary by provider and can't be guessed.
    # Fetch them with '-Action add-model'; Test-ModelFiles reports any that config.yaml expects
    # but that aren't on disk.

    # --- 4. Python 3.11/3.12 (open-webui pins requires-python <3.13) ---
    $pyExe = Find-CompatPython
    if (-not $pyExe) {
        Write-Host "No Python 3.11/3.12 found (open-webui needs <3.13) - installing via winget..."
        winget install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements
        $pyExe = Find-CompatPython
        if (-not $pyExe) { throw "Python 3.12 install did not register with the 'py' launcher. Install it manually and re-run." }
    }

    # --- 5. venv + backend deps ---
    if (-not (Test-Path $venvPy)) {
        Write-Host "Creating venv at $venv ..."
        & $pyExe -m venv $venv
        & $venvPy -m pip install --upgrade pip
        & $venvPy -m pip install -r (Join-Path $webui 'backend\requirements.txt')
        if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
    }

    # --- 6. isolated Node (open-webui .npmrc has engine-strict=true, pins <=22.x) ---
    if (-not (Test-Path $nodeExe)) {
        New-Item -ItemType Directory -Force -Path $nodeRoot | Out-Null
        Write-Host "Fetching Node.js $($ver.node) (isolated - your global Node install is untouched)..."
        $nodeZip = Join-Path $dl "node-$($ver.node)-win-x64.zip"
        Get-File "https://nodejs.org/dist/$($ver.node)/node-$($ver.node)-win-x64.zip" $nodeZip
        Expand-Archive -Path $nodeZip -DestinationPath $nodeRoot -Force
    }

    # --- 7. frontend build (production single-port serving) ---
    if (-not (Test-Path (Join-Path $webui 'build'))) {
        Write-Host "Building open-webui frontend (first run only, several minutes)..."
        Push-Location $webui
        & $npmCmd install
        if ($LASTEXITCODE -ne 0) { Pop-Location; throw "npm install failed" }
        & $npmCmd run build
        if ($LASTEXITCODE -ne 0) { Pop-Location; throw "npm run build failed" }
        Pop-Location
    }

    # --- 8. .env wired to point at llama-swap instead of Ollama ---
    $envFile = Join-Path $webui '.env'
    if (-not (Test-Path $envFile)) {
        Write-Host "Writing $envFile ..."
        $content = Get-Content (Join-Path $webui '.env.example') -Raw
        $content = $content -replace "OPENAI_API_BASE_URL=''", "OPENAI_API_BASE_URL='http://127.0.0.1:$swapPort/v1'"
        $content = $content -replace "OPENAI_API_KEY=''", "OPENAI_API_KEY='sk-local'"
        $content += "`nENABLE_OLLAMA_API=false`n"

        # WEBUI_SECRET_KEY: required whenever auth is on; normally generated by start.sh/start_windows.bat,
        # which we bypass by invoking uvicorn directly. Generate once and persist in .env so it's stable
        # across restarts (a rotating key would invalidate every session/token on each launch).
        $secretBytes = New-Object byte[] 32
        [System.Security.Cryptography.RNGCryptoServiceProvider]::new().GetBytes($secretBytes)
        $content += "WEBUI_SECRET_KEY='$([Convert]::ToBase64String($secretBytes))'`n"

        Set-Content -Path $envFile -Value $content
    }

    $webui
}

function Find-CompatPython {
    (py -0p 2>$null) -split "`r?`n" |
        Where-Object { $_ -match '-V:3\.1[12]\b' } |
        Select-Object -First 1 |
        ForEach-Object { ($_ -split '\s{2,}')[-1].Trim() }
}

# ==========================================================================
#  launch
# ==========================================================================
# Every model entry in config.yaml names a .gguf that must already exist - if it doesn't,
# llama-swap still starts and the only symptom is a "connection refused" proxy error when that
# model is first selected, because its llama-server died on spawn. Report it up front instead.
function Test-ModelFiles {
    if (-not (Test-Path $swapConfig)) { Write-Warning "$swapConfig not found - llama-swap has no models to serve."; return }
    $text = Get-Content $swapConfig -Raw
    # Split on the model-id lines ("qwen3-14b":) so each chunk holds one model's cmd.
    $parts = [regex]::Split($text, '(?m)^\s{2,}"([^"]+)"\s*:\s*$')
    $missing = 0
    for ($i = 1; $i -lt $parts.Count; $i += 2) {
        $id = $parts[$i]
        $m = [regex]::Match($parts[$i + 1], '-m\s+"?([^"\r\n]+?\.gguf)"?')
        if (-not $m.Success) { continue }
        $path = $m.Groups[1].Value.Trim()
        if (-not (Test-Path $path)) {
            $missing++
            Write-Warning "model '$id' references a file that does not exist: $path"
        }
    }
    if ($missing) {
        Write-Host "  -> those $missing model(s) will fail on first use. Fetch weights with:"
        Write-Host "     .\start.ps1 -Action add-model -Model <hf repo, hf url, or .gguf url>"
        Write-Host ""
    }
}

# Last few lines of a component's logs, minus the sentence-transformers progress spam
# ("Batches: 100%|####...") that otherwise fills the whole tail with nothing.
# Checks stdout as well as stderr: llama-swap logs everything to stdout, including the reason
# it failed, so a stderr-only tail would come back empty on exactly the runs that matter.
function Show-ErrorTail($logFiles, $lines = 20) {
    $shown = $false
    foreach ($f in $logFiles) {
        if (-not (Test-Path $f)) { continue }
        $tail = Get-Content $f -Tail 200 |
            Where-Object { $_.Trim() -and $_ -notmatch '^\s*Batches:' } |
            Select-Object -Last $lines
        if (-not $tail) { continue }
        Write-Host "`n--- tail of $f ---"
        $tail | ForEach-Object { Write-Host "  $_" }
        Write-Host "--- end ---"
        $shown = $true
    }
    if (-not $shown) { Write-Host "  (nothing logged - check $logDir)" }
}

# Poll until the endpoint answers, the process dies, or we run out of budget. A dead process is
# never going to become healthy, so bail on that immediately rather than waiting out the timeout.
function Wait-Healthy($label, $url, $proc, $logFiles, $timeoutSec) {
    Write-Host "Waiting for $label ..." -NoNewline
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($proc -and $proc.HasExited) {
            Write-Host " FAILED"
            Write-Warning "$label exited immediately (code $($proc.ExitCode))."
            Show-ErrorTail $logFiles
            throw "$label failed to start."
        }
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { Write-Host " ok"; return }
        } catch { }
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 2
    }
    Write-Host " TIMEOUT"
    Write-Warning "$label did not answer $url within ${timeoutSec}s."
    Show-ErrorTail $logFiles
    throw "$label failed its health check."
}

function Start-Stack($webui, $component = 'all') {
    if (Test-ComponentRunning $component) {
        $what = if ($component -eq 'all') { 'Stack' } else { $component }
        Write-Host "$what is already running - use '-Action restart' to bounce it, or '-Action stop' to stop it."
        Write-Host "  llama-swap dashboard: http://127.0.0.1:$swapPort/ui"
        Write-Host "  open-webui chat:      http://127.0.0.1:$webuiPort"
        # Still worth doing: the user may have exited the tray and re-run this to get it back.
        if (-not $NoTray) { Start-Tray }
        return
    }

    if ($component -ne 'webui') { Test-ModelFiles }

    # -NoNewWindow: Start-Process's default (a new console window) fails with
    # "operation was canceled by the user" when there's no window station to attach to
    # (e.g. run from a scheduled task or a non-interactive shell) - NoNewWindow works everywhere.
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $swapLogs  = @((Join-Path $logDir 'llama-swap.err.log'), (Join-Path $logDir 'llama-swap.log'))
    $webuiLogs = @((Join-Path $logDir 'open-webui.err.log'), (Join-Path $logDir 'open-webui.log'))

    $swapProc = $null
    $webuiProc = $null

    if ($component -ne 'webui') {
        Write-Host "Starting llama-swap on :$swapPort ..."
        $swapProc = Start-Process -FilePath (Join-Path $llamaSwapDir 'llama-swap.exe') `
            -ArgumentList '--config', $swapConfig, '--listen', ":$swapPort" `
            -WorkingDirectory $llamaSwapDir -NoNewWindow -PassThru `
            -RedirectStandardOutput $swapLogs[1] -RedirectStandardError $swapLogs[0]
    }

    if ($component -ne 'swap') {
        Write-Host "Starting open-webui on :$webuiPort ..."
        $webuiProc = Start-Process -FilePath (Join-Path $webui '.venv\Scripts\python.exe') `
            -ArgumentList '-m', 'uvicorn', 'open_webui.main:app', '--host', '0.0.0.0', '--port', "$webuiPort", '--forwarded-allow-ips', "'*'", '--ws', 'auto' `
            -WorkingDirectory (Join-Path $webui 'backend') -NoNewWindow -PassThru `
            -RedirectStandardOutput $webuiLogs[1] -RedirectStandardError $webuiLogs[0]
    }

    # If a service fails its check, tear down whatever this call started - a half-started stack
    # holding ports and GPU memory is worse than no stack, and the next run's guard would refuse
    # to launch because it looks "already running". Only what we started, though: restarting one
    # component must not take the other one down with it.
    try {
        if ($swapProc)  { Wait-Healthy 'llama-swap' "http://127.0.0.1:$swapPort/health" $swapProc $swapLogs 20 }
        # Generous budget: open-webui's first boot downloads sentence-transformers embedding weights.
        if ($webuiProc) { Wait-Healthy 'open-webui' "http://127.0.0.1:$webuiPort/health" $webuiProc $webuiLogs 180 }
    } catch {
        Write-Host "`nRolling back the partial launch..."
        Stop-Stack $component
        throw
    }

    if (-not $NoTray) { Start-Tray }

    Write-Host "`nllama-swap dashboard: http://127.0.0.1:$swapPort/ui"
    Write-Host "open-webui chat:      http://127.0.0.1:$webuiPort"
    Write-Host "Logs: $logDir  (both run detached - stop with '.\start.ps1 -Action stop')"
}

# ==========================================================================
#  add-model: Hugging Face resolution + config.yaml registration
# ==========================================================================

# Accepts what a person actually has to hand: a repo id, a repo page URL, a file page URL, or a
# direct download link. Returns @{ Repo = ...; Quant = ...; Url = ... } with Repo set when we
# need to go ask Hugging Face which files exist, or Url set when we already know the file.
function Resolve-ModelSpec($spec) {
    $spec = $spec.Trim()

    if ($spec -notmatch '^https?://') {
        # "owner/name" or "owner/name:Q4_K_M"
        $quant = $null
        if ($spec -match '^(.+?):([^:/]+)$') { $spec = $Matches[1]; $quant = $Matches[2] }
        if ($spec -notmatch '^[^/\s]+/[^/\s]+$') {
            throw "'$spec' is neither a URL nor an 'owner/name' Hugging Face repo id."
        }
        return @{ Repo = $spec; Quant = $quant }
    }

    if ($spec -match '^https?://(?:www\.)?huggingface\.co/(.+)$') {
        $path = $Matches[1] -replace '[?#].*$', ''
        # .../resolve/<rev>/<file> is the download form; .../blob/<rev>/<file> is the page for it.
        if ($path -match '^([^/]+/[^/]+)/(?:resolve|blob)/([^/]+)/(.+)$') {
            return @{ Url = "https://huggingface.co/$($Matches[1])/resolve/$($Matches[2])/$($Matches[3])" }
        }
        # .../tree/<rev>/... and bare repo pages both just identify a repo.
        if ($path -match '^([^/]+/[^/]+)') { return @{ Repo = $Matches[1] } }
    }

    @{ Url = $spec }
}

# Every .gguf in a repo, grouped into one entry per variant. A large model is published as
# "name-00001-of-00010.gguf" split parts, and pulling only part 1 gives you a model that won't
# load - so parts are kept together and downloaded as a set.
function Get-HfVariants($repo) {
    $api = "https://huggingface.co/api/models/$repo/tree/main?recursive=true"
    try {
        $tree = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'localllm-setup' } -ErrorAction Stop
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 401 -or $code -eq 404) {
            throw "Hugging Face returned $code for '$repo' - check the spelling, and note that gated or private repos can't be fetched without a token."
        }
        throw "Could not query Hugging Face for '$repo': $($_.Exception.Message)"
    }

    $files = @($tree | Where-Object { $_.type -eq 'file' -and $_.path -match '\.gguf$' })
    if (-not $files) { throw "No .gguf files in '$repo' - is it a GGUF conversion of the model, or the original weights?" }

    $groups = @{}
    foreach ($f in $files) {
        $leaf = Split-Path $f.path -Leaf
        # Collapse the split suffix so all parts of one variant land in the same group.
        $key = [IO.Path]::GetFileNameWithoutExtension($leaf) -replace '-\d{5}-of-\d{5}$', ''
        if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
        $groups[$key] += $f
    }

    $groups.Keys | Sort-Object | ForEach-Object {
        $parts = @($groups[$_] | Sort-Object path)
        [pscustomobject]@{
            Name    = $_
            Parts   = $parts
            Bytes   = ($parts | Measure-Object -Property size -Sum).Sum
            # The quant label is the tail of the name: Qwen_Qwen3-8B-Q4_K_M -> Q4_K_M
            Quant   = if ($_ -match '(?i)[-_.]((?:IQ|Q)\d[A-Z0-9_]*|BF16|F16|F32)$') { $Matches[1] } else { $_ }
        }
    }
}

function Format-Size($bytes) { '{0:N1} GB' -f ($bytes / 1GB) }

# Appends a model entry to config.yaml, matching the style already in the file. The file is
# hand-maintained and git-tracked, so it gets a .bak first and is never rewritten wholesale.
function Add-ModelToConfig($id, $ggufPath, $context) {
    if (-not (Test-Path $swapConfig)) { Write-Warning "$swapConfig not found - skipping registration."; return $false }
    $text = Get-Content $swapConfig -Raw
    if ($text -match "(?m)^\s{2,}""$([regex]::Escape($id))""\s*:") {
        Write-Warning "config.yaml already has a model called '$id' - leaving it alone."
        return $false
    }

    Copy-Item $swapConfig "$swapConfig.bak" -Force
    if (-not $text.EndsWith("`n")) { $text += "`r`n" }
    $block = @'

  "@ID@":
    cmd: >
      ${llama-server}
      -m "@PATH@"
      -c @CTX@ -ctk q8_0 -ctv q8_0
    ttl: 600
'@
    $block = $block.Replace('@ID@', $id).Replace('@PATH@', $ggufPath).Replace('@CTX@', "$context")
    Set-Content -Path $swapConfig -Value ($text + $block + "`r`n") -Encoding utf8 -NoNewline
    $true
}

# ==========================================================================
#  main
# ==========================================================================

# These don't touch versions at all - handle them before any stamp/release resolution.
if ($Action -eq 'stop') { Stop-Stack $Component; return }

if ($Action -eq 'tray') { Start-Tray; Write-Host "Tray indicator started (look in the notification area)."; return }

if ($Action -eq 'restart') {
    $webui = Find-WebuiDir
    if (-not $webui) { throw "Nothing deployed - run '.\start.ps1' with no arguments first." }
    Stop-Stack $Component
    Start-Stack $webui $Component
    return
}

if ($Action -eq 'add-model') {
    if (-not $Model) { throw "-Action add-model needs -Model <hf repo, hf url, or direct .gguf url>." }
    New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null

    $spec = Resolve-ModelSpec $Model
    $downloads = @()   # each: @{ Url = ...; File = ... }

    if ($spec.Repo) {
        Write-Host "Looking up $($spec.Repo) on Hugging Face..."
        $variants = @(Get-HfVariants $spec.Repo)

        # -Quant wins over a ":Q4_K_M" suffix on the spec only if the user actually typed it;
        # otherwise the suffix wins, then the default.
        $wanted = if ($PSBoundParameters.ContainsKey('Quant')) { $Quant }
                  elseif ($spec.Quant) { $spec.Quant }
                  else { $Quant }

        $match = @($variants | Where-Object { $_.Quant -eq $wanted })
        if (-not $match) { $match = @($variants | Where-Object { $_.Name -match "(?i)[-_.]$([regex]::Escape($wanted))$" }) }

        if (-not $match) {
            Write-Host "`nNo '$wanted' in $($spec.Repo). Available:`n"
            $variants | ForEach-Object { Write-Host ("  {0,-12} {1,10}   {2}" -f $_.Quant, (Format-Size $_.Bytes), $_.Name) }
            throw "Pick one with -Quant <label>."
        }
        if ($match.Count -gt 1) {
            Write-Host "`n'$wanted' matches more than one variant:`n"
            $match | ForEach-Object { Write-Host ("  {0,-40} {1,10}" -f $_.Name, (Format-Size $_.Bytes)) }
            throw "Narrow it down with -Quant <label>."
        }

        $v = $match[0]
        Write-Host "Selected $($v.Name)  [$($v.Quant), $(Format-Size $v.Bytes), $($v.Parts.Count) file(s)]"
        foreach ($p in $v.Parts) {
            # Split parts live in a subfolder upstream but must sit side by side locally.
            $downloads += @{ Url = "https://huggingface.co/$($spec.Repo)/resolve/main/$($p.path)"; File = (Split-Path $p.path -Leaf) }
        }
        if (-not $Id) { $Id = $v.Name.ToLower() }
    }
    else {
        $file = if ($Name) { $Name } else { Split-Path ($spec.Url -split '\?')[0] -Leaf }
        if ($file -notlike '*.gguf') { throw "'$file' is not a .gguf - pass -Name <file>.gguf if the URL doesn't end in one." }
        $downloads += @{ Url = $spec.Url; File = $file }
        if (-not $Id) { $Id = [IO.Path]::GetFileNameWithoutExtension($file).ToLower() }
    }

    $i = 0
    foreach ($d in $downloads) {
        $i++
        $dest = Join-Path $modelsDir $d.File
        if (Test-Path $dest) { Write-Host "[$i/$($downloads.Count)] $($d.File) already present - skipping."; continue }
        Write-Host "[$i/$($downloads.Count)] Fetching $($d.File) (resumable - safe to interrupt and re-run)..."
        Get-BigFile $d.Url $dest
    }

    # llama.cpp loads a split model from its first part and finds the rest itself.
    $primary = Join-Path $modelsDir $downloads[0].File
    Write-Host "`nSaved to $modelsDir"

    if ($NoConfig) {
        Write-Host "Skipped config.yaml (-NoConfig). Register it as '$Id' pointing at $primary when you're ready."
    }
    elseif (Add-ModelToConfig $Id $primary $Context) {
        Write-Host "Registered in $swapConfig as `"$Id`" (context $Context, previous config saved as config.yaml.bak)."
        # llama-swap only reads config.yaml at startup, but open-webui has no reason to bounce.
        Write-Host "Run '.\start.ps1 -Action restart -Component swap' to make it routable."
    }
    return
}

$installed = Read-Stamp
$target    = $VER.Clone()

if ($Latest) {
    $target = Resolve-Latest $target
} elseif ($Action -eq 'deploy' -and $installed) {
    # A plain re-run relaunches what's already on disk; use -Action upgrade to move versions.
    foreach ($k in @($target.Keys)) { if ($installed.ContainsKey($k)) { $target[$k] = $installed[$k] } }
}

switch ($Action) {

    'status' {
        $latestVer = if ($Latest) { $target } else { $null }
        Write-Host ""
        Write-Host ("{0,-12} {1,-14} {2,-14} {3}" -f 'component', 'installed', 'pinned', 'latest')
        foreach ($k in 'llamaCpp', 'llamaSwap', 'openWebUI', 'node') {
            $inst = if ($installed -and $installed.ContainsKey($k)) { $installed[$k] } else { '(unstamped)' }
            $lat  = if ($latestVer) { $latestVer[$k] } else { '-' }
            Write-Host ("{0,-12} {1,-14} {2,-14} {3}" -f $k, $inst, $VER[$k], $lat)
        }
        $wd = Find-WebuiDir
        Write-Host ""
        Write-Host "open-webui dir: $(if ($wd) { $wd } else { '(none)' })"
        Write-Host "llama-server:   $(if (Test-Path (Join-Path $llamaCpp 'llama-server.exe')) { 'installed' } else { 'missing' })"
        Write-Host "llama-swap:     $(if (Test-Path (Join-Path $llamaSwapDir 'llama-swap.exe')) { 'installed' } else { 'missing' })"
        Write-Host "running:        $((@(Get-Process -Name llama-swap, llama-server -ErrorAction SilentlyContinue)).Count) llama process(es)"
        if (-not $Latest) { Write-Host "`n(add -Latest to also show newest upstream releases)" }
    }

    'deploy' {
        $webui = Invoke-Deploy $target
        Write-Stamp $target
        Start-Stack $webui
    }

    'upgrade' {
        $oldWebui = Find-WebuiDir
        $newWebui = Join-Path $root "open-webui-$($target.openWebUI)"

        $changes = @()
        foreach ($k in 'llamaCpp', 'llamaSwap', 'openWebUI', 'node') {
            $inst = if ($installed -and $installed.ContainsKey($k)) { $installed[$k] } else { $null }
            if ($inst -ne $target[$k]) { $changes += "$k : $(if ($inst) { $inst } else { '?' }) -> $($target[$k])" }
        }
        if (-not $changes) { Write-Host "Already on the target versions - nothing to upgrade."; break }

        Write-Host "`nUpgrading:"
        $changes | ForEach-Object { Write-Host "  $_" }
        Write-Host ""

        Stop-Stack

        # llama.cpp: wipe the binaries (stale DLLs from the old build would otherwise linger)
        # but never the weights.
        if ((-not $installed) -or $installed.llamaCpp -ne $target.llamaCpp) {
            if (Test-Path $llamaCpp) {
                Write-Host "Removing old llama.cpp binaries (models/ kept)..."
                Get-ChildItem $llamaCpp -Force | Where-Object { $_.Name -ne 'models' } | Remove-Item -Recurse -Force
            }
        }

        if ((-not $installed) -or $installed.llamaSwap -ne $target.llamaSwap) {
            Write-Host "Removing old llama-swap binary (config.yaml kept)..."
            Remove-Item (Join-Path $llamaSwapDir 'llama-swap.exe') -Force -ErrorAction SilentlyContinue
        }

        $webuiChanged = (-not $installed) -or $installed.openWebUI -ne $target.openWebUI
        $nodeChanged  = (-not $installed) -or $installed.node -ne $target.node

        if ($webuiChanged -and $oldWebui -and $oldWebui -ne $newWebui) {
            # New version goes in a new dir; carry over the two things that hold state.
            if (-not (Test-Path $newWebui)) {
                Write-Host "Fetching open-webui v$($target.openWebUI) source..."
                New-Item -ItemType Directory -Force -Path $dl | Out-Null
                $tarPath = Join-Path $dl "open-webui-v$($target.openWebUI).tar.gz"
                Get-File "https://github.com/open-webui/open-webui/archive/refs/tags/v$($target.openWebUI).tar.gz" $tarPath
                tar -xzf $tarPath -C $root
                if (-not (Test-Path $newWebui)) { throw "Extracted open-webui archive but $newWebui was not created." }
            }
            # backend/data holds webui.db (users, chats, settings); .env holds WEBUI_SECRET_KEY -
            # regenerating that key would invalidate every existing session and token.
            $oldData = Join-Path $oldWebui 'backend\data'
            if (Test-Path $oldData) {
                Write-Host "Migrating backend/data (chats, users, settings)..."
                Copy-Item $oldData (Join-Path $newWebui 'backend') -Recurse -Force
            }
            $oldEnv = Join-Path $oldWebui '.env'
            if (Test-Path $oldEnv) {
                Write-Host "Migrating .env ..."
                Copy-Item $oldEnv (Join-Path $newWebui '.env') -Force
            }
        } elseif ($nodeChanged -and $oldWebui) {
            # Same open-webui, newer Node: drop the toolchain and the build output, keep everything else.
            Write-Host "Node changed - removing .node-runtime and build/ for a rebuild..."
            Remove-Item (Join-Path $oldWebui '.node-runtime') -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $oldWebui 'build') -Recurse -Force -ErrorAction SilentlyContinue
        }

        $webui = Invoke-Deploy $target
        Write-Stamp $target

        # Only now that the new tree built and booted-ready is the old one disposable.
        if ($webuiChanged -and $oldWebui -and $oldWebui -ne $webui -and (Test-Path $oldWebui)) {
            $keep = Join-Path $root ('_old-' + (Split-Path $oldWebui -Leaf))
            Write-Host "Old install kept at $keep - delete it once you've confirmed the upgrade works."
            Move-Item $oldWebui $keep -Force
        }

        Start-Stack $webui
    }

    'uninstall' {
        $targets = @()
        if (Test-Path $llamaCpp)     { $targets += if ($IncludeModels) { $llamaCpp } else { "$llamaCpp (except models\)" } }
        if (Test-Path (Join-Path $llamaSwapDir 'llama-swap.exe')) { $targets += "$llamaSwapDir\llama-swap.exe (config.yaml kept)" }
        Get-ChildItem $root -Directory -Filter 'open-webui-*' -ErrorAction SilentlyContinue | ForEach-Object { $targets += $_.FullName }
        Get-ChildItem $root -Directory -Filter '_old-open-webui-*' -ErrorAction SilentlyContinue | ForEach-Object { $targets += $_.FullName }
        if (Test-Path $logDir)    { $targets += $logDir }
        if (Test-Path $stampFile) { $targets += $stampFile }
        if (Test-Path $dl)        { $targets += $dl }

        if (-not $targets) { Write-Host "Nothing installed - nothing to remove."; break }

        Write-Host "`nThis will permanently delete:"
        $targets | ForEach-Object { Write-Host "  $_" }
        if (-not $IncludeModels) {
            Write-Host "`nModel weights in $modelsDir are KEPT (pass -IncludeModels to delete them too)."
        } else {
            Write-Warning "Model weights in $modelsDir WILL be deleted - these are multi-GB and slow to re-download."
        }
        Write-Host "start.ps1, CLAUDE.md and llamaswap\config.yaml are kept."

        if (-not $Force) {
            $answer = Read-Host "`nType 'yes' to proceed"
            if ($answer -ne 'yes') { Write-Host "Aborted."; break }
        }

        Stop-Stack
        # Otherwise a tray dot lingers in the notification area pointing at a stack that's gone.
        Get-TrayProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

        if (Test-Path $llamaCpp) {
            if ($IncludeModels) { Remove-Item $llamaCpp -Recurse -Force }
            else { Get-ChildItem $llamaCpp -Force | Where-Object { $_.Name -ne 'models' } | Remove-Item -Recurse -Force }
        }
        Remove-Item (Join-Path $llamaSwapDir 'llama-swap.exe') -Force -ErrorAction SilentlyContinue
        Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'open-webui-*' -or $_.Name -like '_old-open-webui-*' } |
            Remove-Item -Recurse -Force
        Remove-Item $logDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $stampFile -Force -ErrorAction SilentlyContinue
        Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host "`nUninstalled. Re-run '.\start.ps1' to rebuild from scratch."
    }
}
