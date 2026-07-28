# Local LLM stack: from-scratch bootstrap (first run) + launch (every run).
# Re-run this any time on a fresh machine - already-done steps are skipped.
# Pinned versions so a wipe-and-reclone always reproduces the same stack:
#   llama.cpp   b10155
#   llama-swap  v244
#   Node.js     v22.23.1 (isolated copy - open-webui pins <=22.x, doesn't touch a global Node install)
#   Python      3.12 (open-webui pins <3.13)
#
# Starts:
#   llama-swap  http://127.0.0.1:9292  (model router -> llama-server)
#   open-webui  http://127.0.0.1:8080  (chat UI)

$ErrorActionPreference = 'Stop'
$root         = $PSScriptRoot
$llamaCpp     = Join-Path $root 'llama.cpp'
$llamaSwapDir = Join-Path $root 'llamaswap'
$webui        = Join-Path $root 'open-webui-0.11.0'
$venv         = Join-Path $webui '.venv'
$venvPy       = Join-Path $venv 'Scripts\python.exe'
$nodeRoot     = Join-Path $webui '.node-runtime'
$nodeDir      = Join-Path $nodeRoot 'node-v22.23.1-win-x64'
$nodeExe      = Join-Path $nodeDir 'node.exe'
$npmCmd       = Join-Path $nodeDir 'npm.cmd'
$dl           = Join-Path $env:TEMP 'localllm-dl'
New-Item -ItemType Directory -Force -Path $dl | Out-Null

function Get-File($url, $out) {
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $out
}

# --- 0. open-webui source (v0.11.0) ---
# Not vendored in this repo - it's a full upstream project, so it's fetched fresh like the binaries.
if (-not (Test-Path $webui)) {
    Write-Host "Fetching open-webui v0.11.0 source..."
    $owuiTar = Join-Path $dl 'open-webui-v0.11.0.tar.gz'
    Get-File 'https://github.com/open-webui/open-webui/archive/refs/tags/v0.11.0.tar.gz' $owuiTar
    tar -xzf $owuiTar -C $root
    if (-not (Test-Path $webui)) { throw "Extracted open-webui archive but $webui was not created - check the tarball's root folder name." }
}

# --- 1. llama.cpp binaries (b10155) ---
if (-not (Test-Path (Join-Path $llamaCpp 'llama-server.exe'))) {
    New-Item -ItemType Directory -Force -Path $llamaCpp | Out-Null
    $hasGpu = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
    $variant = if ($hasGpu) { 'cuda-13.3' } else { 'cpu' }
    Write-Host "Fetching llama.cpp b10155 ($variant)..."
    $zip = Join-Path $dl "llama-b10155-$variant.zip"
    Get-File "https://github.com/ggml-org/llama.cpp/releases/download/b10155/llama-b10155-bin-win-$variant-x64.zip" $zip
    Expand-Archive -Path $zip -DestinationPath $llamaCpp -Force
    if ($hasGpu) {
        $cudartZip = Join-Path $dl 'cudart-b10155.zip'
        Get-File 'https://github.com/ggml-org/llama.cpp/releases/download/b10155/cudart-llama-bin-win-cuda-13.3-x64.zip' $cudartZip
        Expand-Archive -Path $cudartZip -DestinationPath $llamaCpp -Force
    }
}
New-Item -ItemType Directory -Force -Path (Join-Path $llamaCpp 'models') | Out-Null

# --- 2. llama-swap binary (v244) ---
if (-not (Test-Path (Join-Path $llamaSwapDir 'llama-swap.exe'))) {
    New-Item -ItemType Directory -Force -Path $llamaSwapDir | Out-Null
    Write-Host "Fetching llama-swap v244..."
    $swapZip = Join-Path $dl 'llama-swap-v244.zip'
    Get-File 'https://github.com/mostlygeek/llama-swap/releases/download/v244/llama-swap_244_windows_amd64.zip' $swapZip
    Expand-Archive -Path $swapZip -DestinationPath $llamaSwapDir -Force
}
# config.yaml is checked-in project config, not a download artifact - must already exist alongside this script.

# --- 3. model weights ---
# TODO: fill in $Url for each model once you confirm the exact HF source (quant provider varies).
$models = @(
    @{ File = 'Qwen3-14B-Q4_K_M.gguf'; Url = $null }
    @{ File = 'Qwen3-8B-Q4_K_M.gguf';  Url = $null }
    @{ File = 'Llama-4-Scout-Q4.gguf'; Url = $null }
)
foreach ($m in $models) {
    $dest = Join-Path $llamaCpp "models\$($m.File)"
    if (Test-Path $dest) { continue }
    if ($m.Url) {
        Write-Host "Fetching $($m.File)..."
        Get-File $m.Url $dest
    } else {
        Write-Warning "$($m.File) is missing and no source URL is set in start.ps1 - that model entry in config.yaml will fail to load until you add one."
    }
}

# --- 4. Python 3.11/3.12 (open-webui pins requires-python <3.13) ---
function Find-CompatPython {
    (py -0p 2>$null) -split "`r?`n" |
        Where-Object { $_ -match '-V:3\.1[12]\b' } |
        Select-Object -First 1 |
        ForEach-Object { ($_ -split '\s{2,}')[-1].Trim() }
}

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

# --- 6. isolated Node 22 (open-webui .npmrc has engine-strict=true, pins <=22.x) ---
if (-not (Test-Path $nodeExe)) {
    New-Item -ItemType Directory -Force -Path $nodeRoot | Out-Null
    Write-Host "Fetching Node.js v22.23.1 (isolated - your global Node install is untouched)..."
    $nodeZip = Join-Path $dl 'node-v22.23.1-win-x64.zip'
    Get-File 'https://nodejs.org/dist/v22.23.1/node-v22.23.1-win-x64.zip' $nodeZip
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
    $content = $content -replace "OPENAI_API_BASE_URL=''", "OPENAI_API_BASE_URL='http://127.0.0.1:9292/v1'"
    $content = $content -replace "OPENAI_API_KEY=''", "OPENAI_API_KEY='sk-local'"
    $content += "`nENABLE_OLLAMA_API=false`n"

    # WEBUI_SECRET_KEY: required whenever auth is on; normally generated by start.sh/start_windows.bat,
    # which we bypass by invoking uvicorn directly. Generate once and persist in .env so it's stable
    # across restarts (a rotating key would invalidate every session/token on each launch).
    $secretBytes = New-Object byte[] 32
    [System.Security.Cryptography.RNGCryptoServiceProvider]::new().GetBytes($secretBytes)
    $secret = [Convert]::ToBase64String($secretBytes)
    $content += "WEBUI_SECRET_KEY='$secret'`n"

    Set-Content -Path $envFile -Value $content
}

# --- 9. launch llama-swap + open-webui ---
# -NoNewWindow: Start-Process's default (a new console window) fails with
# "operation was canceled by the user" when there's no window station to attach to
# (e.g. run from a scheduled task or a non-interactive shell) - NoNewWindow works everywhere.
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

Write-Host "Starting llama-swap on :9292 ..."
Start-Process -FilePath (Join-Path $llamaSwapDir 'llama-swap.exe') `
    -ArgumentList '--config', (Join-Path $llamaSwapDir 'config.yaml'), '--listen', ':9292' `
    -WorkingDirectory $llamaSwapDir -NoNewWindow `
    -RedirectStandardOutput (Join-Path $logDir 'llama-swap.log') -RedirectStandardError (Join-Path $logDir 'llama-swap.err.log')

Write-Host "Starting open-webui on :8080 ..."
Start-Process -FilePath $venvPy `
    -ArgumentList '-m', 'uvicorn', 'open_webui.main:app', '--host', '0.0.0.0', '--port', '8080', '--forwarded-allow-ips', "'*'", '--ws', 'auto' `
    -WorkingDirectory (Join-Path $webui 'backend') -NoNewWindow `
    -RedirectStandardOutput (Join-Path $logDir 'open-webui.log') -RedirectStandardError (Join-Path $logDir 'open-webui.err.log')

Start-Sleep -Seconds 2
Write-Host "`nllama-swap dashboard: http://127.0.0.1:9292/ui"
Write-Host "open-webui chat:      http://127.0.0.1:8080"
Write-Host "Logs: $logDir  (both run detached - use Task Manager or 'taskkill /IM llama-swap.exe /IM python.exe /F' to stop)"
