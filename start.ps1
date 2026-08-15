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
#   .\start.ps1 -Action install-prism      # PrismML llama.cpp fork (low-bit kernels), alongside the stock build
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

# PositionalBinding=$false: -Action bench forwards everything it doesn't recognise to run.py via
# $BenchArgs, and without this PowerShell grabs those trailing values positionally for whichever
# parameter happens to be next in the declaration order.
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('deploy', 'upgrade', 'uninstall', 'status', 'stop', 'restart', 'add-model', 'tray', 'bench', 'install-prism', 'inspect', 'autotune', 'check-config', 'set-tuning', 'install-llmfit', 'suggest', 'check-ui')]
    [string]$Action = 'deploy',

    # bench: passed straight through to bench\run.py (--models, --tasks, --repeat, --compare).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$BenchArgs,

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

    # autotune: write the measured settings straight into config.yaml instead of printing them.
    [switch]$Apply,

    # set-tuning: KV cache type for -ctk/-ctv. q4_0 halves the cache against q8_0, buying context
    # at some cost to recall of tokens early in a long conversation.
    [ValidateSet('q8_0', 'q4_0', 'q4_1', 'q5_0', 'q5_1', 'f16', 'f32')]
    [string]$Kv = 'q8_0',

    # set-tuning: expert layers to keep on the CPU (MoE models only). -1 means "leave the entry's
    # existing value alone", which is not the same as 0 (offload nothing) - a plain [int] can't
    # express "unset", and dropping the flag silently would change how the model runs.
    [int]$NCpuMoe = -1,

    # uninstall: also delete the multi-GB .gguf weights (kept by default - they're slow to re-fetch).
    [switch]$IncludeModels,

    # suggest: narrow llmfit's recommendations. 'any' drops the filter - an empty string cannot,
    # because `-Capability ''` through `powershell -File` is a parameter with no value and fails
    # before the script runs. Capability defaults to tool_use because a model
    # that cannot call tools is useless for the coding-agent path, which is the reason most people
    # are picking a model here at all - and it is the property they otherwise find out last.
    [ValidateSet('general', 'coding', 'reasoning', 'chat', 'multimodal', 'embedding')]
    [string]$UseCase,
    [string]$Capability = 'tool_use',
    [ValidateSet('perfect', 'good', 'marginal')]
    [string]$MinFit = 'good',
    [int]$Top = 8,

    # suggest: machine-readable, for the control panel.
    [switch]$Json,

    # deploy: keep node_modules and the private Node runtime after the frontend is built. They are
    # ~1.1 GB and are only needed to rebuild it, so they are deleted by default.
    [switch]$KeepBuildDeps,

    # uninstall: skip the confirmation prompt.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- pinned versions ------------------------------------------------------
# Bump these and run `-Action upgrade` to move the stack forward deterministically.
$VER = @{
    llamaCpp  = 'b10155'
    llamaSwap = 'v250'
    openWebUI = '0.11.0'      # open-webui pins requires-python <3.13 and node <=22.x
    node      = 'v22.23.1'
    cuda      = 'cuda-13.3'   # only a fallback - the exact CUDA asset is resolved from the release
    # PrismML's llama.cpp fork, installed alongside (never over) the stock build by
    # '-Action install-prism'. It carries the custom low-bit kernels that stock llama.cpp lacks:
    # Bonsai-style ternary weights use ggml tensor types 42/142, and stock b10155 tops out at 41,
    # so those models fail to load on the normal binary no matter how they're configured.
    prism     = 'prism-b9599-9ca265a'
    # llmfit (MIT, github.com/AlexsJones/llmfit) - a hardware-aware model recommender. Answers the
    # question this stack could not: not "does this quant of the model I already chose fit", which
    # is '-Action inspect', but "which model should I get at all". 5 MB download, installed by
    # '-Action install-llmfit'.
    llmfit    = 'v1.1.9'
    # uv (astral-sh/uv) - replaces winget for getting Python, and pip for installing into it.
    uv        = '0.12.3'
}

$root         = $PSScriptRoot
$llamaCpp     = Join-Path $root 'llama.cpp'
$llamaPrism   = Join-Path $root 'llama.cpp-prism'   # PrismML fork, side by side with the stock build
$modelsDir    = Join-Path $llamaCpp 'models'        # shared: both binaries read the same weights
$uvDir        = Join-Path $root 'uv'          # provides Python; nothing is installed system-wide
$llmfitDir    = Join-Path $root 'llmfit'
$llmfitExe    = Join-Path $llmfitDir 'llmfit.exe'
$llamaSwapDir = Join-Path $root 'llamaswap'
$swapConfig   = Join-Path $llamaSwapDir 'config.yaml'
$swapConfigTpl= Join-Path $llamaSwapDir 'config.example.yaml'
$logDir       = Join-Path $root 'logs'
$stampFile    = Join-Path $root '.stack-versions.json'
$dl           = Join-Path $env:TEMP 'localllm-dl'
$swapPort     = 9292
$webuiPort    = 8080

# Every install download comes through here - open-webui's source, the llama.cpp build, Node, uv -
# and it used to be one Invoke-WebRequest with a single "Downloading ..." line and nothing after
# it. That is the 1.5 GB first run the README describes as "a few minutes": on a slow link the
# console, the job log and the panel all sit on that one line for the whole of it, with no way to
# tell a slow download from a dead one. Routed through Get-BigFile, these now stage to <name>.part
# with the expected size beside them, so they resume and the panel can show a real bar.
function Get-File($url, $out) {
    Write-Host "Downloading $url"
    $total = 0
    # A HEAD is cheap, but only some of these answer with a Content-Length: nodejs.org does,
    # GitHub's release/codeload redirects do not. 0 is the honest answer there - progress then
    # reads as bytes-so-far rather than an invented percentage.
    try {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $total = [long]((Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 20).Headers['Content-Length']) }
        finally { $ErrorActionPreference = $old }
    } catch { }
    Get-BigFile $url $out $total
}

# config.yaml carries absolute paths to llama-server.exe and to every .gguf, so it can't be
# checked in as-is - a clone to any other directory would point at files that don't exist.
# config.example.yaml is the tracked one, with {{LOCALLLM_ROOT}} where this repo's path goes;
# the real config is generated here on first use and is gitignored thereafter, which also keeps
# a user's own model list out of the repo. Never overwrites an existing config.
function Initialize-SwapConfig {
    if (Test-Path $swapConfig) { return }
    if (-not (Test-Path $swapConfigTpl)) { throw "Neither $swapConfig nor $swapConfigTpl exists - the repo is incomplete." }
    New-Item -ItemType Directory -Force -Path $llamaSwapDir | Out-Null
    $text = (Get-Content $swapConfigTpl -Raw).Replace('{{LOCALLLM_ROOT}}', $root)
    Set-Content -Path $swapConfig -Value $text -Encoding utf8 -NoNewline
    Write-Host "Generated $swapConfig from config.example.yaml (paths rooted at $root)."
}

# Weights are multi-GB: Invoke-WebRequest has no resume and no progress, curl.exe (ships with
# Windows 10+) has both. Downloads to <out>.part and only renames on success, so an interrupted
# pull resumes on re-run and a partial file is never mistaken for a complete model.
# $total is the expected size when the caller knows it (the HF file tree carries it). It is
# written to <out>.part.json so a reader - the control panel - can turn bytes-on-disk into a
# percentage. The alternative was parsing curl's progress meter, which is carriage-return redraws
# on stderr: it tails into a log as noise, which is exactly how a 5 GB download came to look like
# a stalled job for ten minutes. The sidecar survives a failure on purpose, so a resumed download
# still knows what it is aiming at.
function Get-BigFile($url, $out, [long]$total = 0) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) {
        $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
        if (-not $curl) { throw "curl.exe not found - it ships with Windows 10+; install it or download $url manually into $modelsDir." }
    }
    $part = "$out.part"
    @{ total = $total; url = $url; started = (Get-Date).ToString('o') } |
        ConvertTo-Json -Compress | Set-Content -Path "$part.json" -Encoding utf8
    & $curl -L -C - --fail --progress-bar -o $part $url
    if ($LASTEXITCODE -ne 0) {
        $resume = if (Test-Path $part) { " Partial file kept at $part - re-run to resume." } else { "" }
        throw "Download failed (curl exit $LASTEXITCODE).$resume"
    }
    Move-Item $part $out -Force
    Remove-Item "$part.json" -Force -ErrorAction SilentlyContinue
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
# interpreter. Both Stop-Stack and Test-ComponentRunning key off this.
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
    # Scoped to this install, matching Stop-Stack - otherwise a second copy of the repo reports
    # "already running" because of the first copy's services, and refuses to start.
    if ($component -ne 'webui' -and @(Get-Process -Name 'llama-swap' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($root, 'OrdinalIgnoreCase') }).Count) { return $true }
    if ($component -ne 'swap' -and @(Get-WebuiProcess).Count) { return $true }
    $false
}


function Stop-Stack($component = 'all') {
    $stopped = 0
    if ($component -ne 'webui') {
        # Match on where the binary lives, not just its name. Matching by name alone meant a second
        # copy of this repo could stop the first one's services - verified: running -Action
        # uninstall in a throwaway clone killed the main install's llama-swap. The webui half
        # already scoped itself this way; this brings the llama half in line.
        #
        # Path matching still covers the PrismML fork, since llama.cpp-prism lives under the same
        # root, and still covers llama-server processes because llama-swap spawns them from there.
        foreach ($n in 'llama-swap', 'llama-server') {
            $procs = @(Get-Process -Name $n -ErrorAction SilentlyContinue |
                       Where-Object { $_.Path -and $_.Path.StartsWith($root, 'OrdinalIgnoreCase') })
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
# Returns nothing on purpose. This runs npm, uv and tar, all of which write to stdout, and a
# PowerShell function returns everything on its output stream - so a caller assigning the result
# gets the entire build transcript rather than a path. Callers derive the directory instead.
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
        # Anchored on the leading `llama-`, and this is load-bearing: the release also carries
        # `cudart-llama-bin-win-cuda-12.4-x64.zip`, which an unanchored pattern matches first
        # because the cudart assets sort ahead of the binaries. The result was that a clean install
        # downloaded cudart twice (373 MB each), never fetched the 235 MB binaries at all, and
        # ended up with no llama-server.exe - so nothing could run, after a 25-minute install.
        # The prism installer below already got this right with a -notmatch '^cudart'.
        $pat = if ($hasGpu) { '^llama-.*-bin-win-cuda-.*-x64\.zip$' } else { '^llama-.*-bin-win-cpu-x64\.zip$' }
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
    # config.yaml isn't downloaded - it's generated from the tracked template with this clone's path.
    Initialize-SwapConfig

    # --- 3. model weights ---
    # Deliberately not bootstrapped: GGUF quant sources vary by provider and can't be guessed.
    # Fetch them with '-Action add-model'; Test-SwapConfig reports any that config.yaml expects
    # but that aren't on disk.

    # --- 4. Python 3.12, via uv (open-webui pins requires-python <3.13) ---
    # winget used to do this and was the most fragile step in the whole bootstrap: it is absent on
    # LTSC and Server, absent on images where the Store is stripped, can demand interactive
    # elevation, and installs machine-wide so an uninstall leaves it behind.
    #
    # uv is a single static binary that fetches its own standalone CPython. Measured here: 2s to
    # download uv, 2s to install Python 3.12, 1s to make the venv - and it resolved open-webui's
    # 127 pinned packages in 6 seconds, which pip spends minutes on. No admin, no registry, and
    # UV_PYTHON_INSTALL_DIR keeps the interpreter inside this install so uninstall really removes
    # it. It also pins the Python version rather than inheriting whatever the machine happens to
    # have, which makes "what Python are you on?" answerable in a bug report.
    $uvExe = Get-Uv

    # Contained, not machine-wide: both the interpreter and uv's download cache live under $root.
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $root '.python'
    $env:UV_CACHE_DIR          = Join-Path $root '.uv-cache'

    # --- 5. venv + backend deps ---
    if (-not (Test-Path $venvPy)) {
        # --no-bin: without it uv also drops a python3.12.exe shim in ~\.local\bin, which is a
        # write outside this install and warns when something unmanaged is already there. The venv
        # is what gets used; the shim was never wanted.
        Write-Host "Installing Python 3.12 (private to this install) ..."
        & $uvExe python install 3.12 --no-bin
        if ($LASTEXITCODE -ne 0) { throw "uv could not install Python 3.12." }
        Write-Host "Creating venv at $venv ..."
        & $uvExe venv $venv --python 3.12
        if ($LASTEXITCODE -ne 0) { throw "uv could not create the venv at $venv." }
        Write-Host "Installing backend dependencies (127 packages, several GB with torch) ..."
        & $uvExe pip install --python $venvPy -r (Join-Path $webui 'backend\requirements.txt')
        if ($LASTEXITCODE -ne 0) { throw "dependency install failed" }

        # uv's wheel cache measured 2,189 MB on a clean install here - every one of those wheels
        # is already unpacked into .venv, so it is the same dead weight the frontend build's
        # node_modules was, and it was being kept for the life of the install. Same trade as that
        # deletion: an upgrade re-downloads, which it would have had to do anyway.
        if (-not $KeepBuildDeps) {
            $cache = $env:UV_CACHE_DIR
            if ($cache -and (Test-Path $cache)) {
                $mb = [int]((Get-ChildItem $cache -Recurse -File -ErrorAction SilentlyContinue |
                             Measure-Object Length -Sum).Sum / 1MB)
                Write-Host "Removing uv's wheel cache ($mb MB) - the venv already holds everything it unpacked."
                Remove-Item $cache -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # --- 6. isolated Node (open-webui .npmrc has engine-strict=true, pins <=22.x) ---
    # Only needed to build the frontend, and step 7 deletes it again once the build exists - so
    # without the build guard every later deploy re-downloaded 34 MB of Node it would never use.
    if (-not (Test-Path (Join-Path $webui 'build')) -and -not (Test-Path $nodeExe)) {
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
        # vite/rollup peaked at 3.8 GB building this frontend and died on `node`'s default
        # old-space cap of roughly 4 GB: "FATAL ERROR: Ineffective mark-compacts near heap limit".
        # Found by deploying a clean clone on a 16 GB machine - it failed at the last step of a
        # 25-minute install, which is the worst possible place for a first run to break. The cap is
        # a v8 default, not a memory shortage: there were 7 GB free at the time. Set for this
        # process only, so nothing else on the machine inherits it.
        $oldNodeOpts = $env:NODE_OPTIONS
        $env:NODE_OPTIONS = '--max-old-space-size=6144'
        & $npmCmd run build
        $buildRc = $LASTEXITCODE
        $env:NODE_OPTIONS = $oldNodeOpts
        if ($buildRc -ne 0) { Pop-Location; throw "npm run build failed" }
        Pop-Location

        # The frontend build is static: the Python backend serves build\ and never invokes node.
        # Verified - neither backend\start_windows.bat nor main.py references node or node_modules.
        # So once build\ exists, node_modules and the private Node runtime are dead weight, and on
        # this machine they were 1,014 MB and 95 MB respectively. That is more than the entire
        # inference stack costs. An upgrade re-fetches them, which is the same work a rebuild would
        # have needed anyway.
        if (-not $KeepBuildDeps) {
            foreach ($d in @((Join-Path $webui 'node_modules'), $nodeRoot)) {
                if (Test-Path $d) {
                    $mb = [int]((Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue |
                                 Measure-Object Length -Sum).Sum / 1MB)
                    Write-Host "Removing build-only $((Split-Path $d -Leaf)) ($mb MB) - the backend serves build\ and never calls node."
                    Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
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
}

# uv (astral-sh/uv, MIT/Apache-2.0): one static binary that installs its own CPython and resolves
# dependencies. Fetched the same way as every other component here - pinned version, GitHub
# release, matched by asset name - so it is one more download rather than a new kind of dependency.
function Get-Uv {
    $exe = Join-Path $uvDir 'uv.exe'
    if (Test-Path $exe) { return $exe }
    New-Item -ItemType Directory -Force -Path $uvDir, $dl | Out-Null
    $zip = Join-Path $dl "uv-$($VER.uv).zip"
    if (-not (Test-Path $zip)) {
        Write-Host "Fetching uv $($VER.uv) (18 MB) - it provides Python, so nothing has to be installed system-wide..."
        Get-File "https://github.com/astral-sh/uv/releases/download/$($VER.uv)/uv-x86_64-pc-windows-msvc.zip" $zip
    }
    Expand-Archive -Path $zip -DestinationPath $uvDir -Force
    if (-not (Test-Path $exe)) { throw "uv.exe missing after extracting $zip - check the asset layout." }
    $exe
}

# ==========================================================================
#  launch
# ==========================================================================
# The macros: block, as name -> the .exe that macro runs. Model entries reference a macro rather
# than naming a binary, so a model's engine can only be checked by resolving it back through here.
function Get-SwapMacros($text) {
    $map = @{}
    $block = [regex]::Match($text, '(?ms)^macros:\s*\r?$(.*?)(?=^\S|\z)')
    if (-not $block.Success) { return $map }
    # Macro names sit at indent 2, their folded body below. Comment lines start with '#', which
    # the name character class excludes, so the file's prose doesn't parse as a macro.
    foreach ($m in [regex]::Matches($block.Groups[1].Value,
                   '(?ms)^\s{2}([A-Za-z0-9_.-]+):\s*>\s*\r?$(.*?)(?=^\s{2}[A-Za-z0-9_.-]+:|\z)')) {
        $exe = [regex]::Match($m.Groups[2].Value, '"([^"]+\.exe)"')
        if ($exe.Success) { $map[$m.Groups[1].Value] = $exe.Groups[1].Value }
    }
    $map
}

# Everything about a model entry that can be checked without loading it. All of these fail the
# same invisible way at runtime - llama-swap starts fine, llama-server dies on spawn, and the only
# symptom is "connection refused" from the proxy the first time that model is selected. Report
# them up front instead.
#
# Warn, never block. An entry whose weights or engine aren't installed yet is a legitimate state -
# you might be about to fetch them - and refusing to start the whole stack over one bad entry
# would take the other nine models down with it.
function Test-SwapConfig {
    if (-not (Test-Path $swapConfig)) { Write-Warning "$swapConfig not found - llama-swap has no models to serve."; return }
    $text = Get-Content $swapConfig -Raw
    $macros = Get-SwapMacros $text
    # Split on the model-id lines ("qwen3-14b":) so each chunk holds one model's cmd.
    $parts = [regex]::Split($text, '(?m)^\s{2,}"([^"]+)"\s*:\s*$')
    $missingWeights = 0; $missingEngine = 0; $missingPrism = 0; $seen = @{}

    for ($i = 1; $i -lt $parts.Count; $i += 2) {
        $id = $parts[$i]; $chunk = $parts[$i + 1]

        # YAML keeps the last of a duplicated key, so the earlier entry silently does nothing -
        # including one you just edited and are watching not take effect.
        if ($seen.ContainsKey($id)) { Write-Warning "model '$id' is defined more than once - only the last one takes effect." }
        $seen[$id] = $true

        # Engine. A model naming a macro that isn't defined, or one whose binary isn't installed
        # (the prism fork is a separate opt-in download), can never spawn.
        $macro = [regex]::Match($chunk, '\$\{([A-Za-z0-9_.-]+)\}')
        $exe = $null
        if ($macro.Success -and $macro.Groups[1].Value -ne 'PORT') {
            $name = $macro.Groups[1].Value
            if (-not $macros.ContainsKey($name)) {
                Write-Warning "model '$id' uses macro `${$name} which is not defined in the macros: block."
                $missingEngine++
            } else { $exe = $macros[$name] }
        } else {
            $lit = [regex]::Match($chunk, '"([^"]+\.exe)"')
            if ($lit.Success) { $exe = $lit.Groups[1].Value }
        }
        if ($exe -and -not (Test-Path $exe)) {
            $missingEngine++
            if ($exe -like "$llamaPrism*") { $missingPrism++ }
            Write-Warning "model '$id' needs an engine that is not installed: $exe"
        }

        # Weights.
        $m = [regex]::Match($chunk, '-m\s+"?([^"\r\n]+?\.gguf)"?')
        if (-not $m.Success) {
            Write-Warning "model '$id' has no -m <file>.gguf - llama-server has nothing to load."
        } elseif (-not (Test-Path $m.Groups[1].Value.Trim())) {
            $missingWeights++
            Write-Warning "model '$id' references a file that does not exist: $($m.Groups[1].Value.Trim())"
        }

        # llama-swap assigns each instance a port and substitutes ${PORT}. A literal one means two
        # models racing for the same port, and a proxy dialling a port nothing is listening on -
        # which is exactly the "dial tcp [::1]:5800 refused" this stack has already produced once.
        $port = [regex]::Match($chunk, '--port\s+(\d+)')
        if ($port.Success) { Write-Warning "model '$id' hardcodes --port $($port.Groups[1].Value) - use `${PORT} so llama-swap can assign one." }
    }

    if ($missingWeights) {
        Write-Host "  -> those $missingWeights model(s) will fail on first use. Fetch weights with:"
        Write-Host "     .\start.ps1 -Action add-model -Model <hf repo, hf url, or .gguf url>"
    }
    if ($missingEngine) {
        Write-Host "  -> those $missingEngine model(s) have no engine to run on."
        # Only the prism fork has a one-command fix; anything else is a hand-written path to correct.
        if ($missingPrism) { Write-Host "     Install the PrismML fork with:  .\start.ps1 -Action install-prism" }
    }
    if ($missingWeights -or $missingEngine) { Write-Host "" }
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

function Start-Stack($webui, $component = 'all', [bool]$freshTree = $false) {
    if (Test-ComponentRunning $component) {
        $what = if ($component -eq 'all') { 'Stack' } else { $component }
        Write-Host "$what is already running - use '-Action restart' to bounce it, or '-Action stop' to stop it."
        Write-Host "  llama-swap dashboard: http://127.0.0.1:$swapPort/ui"
        Write-Host "  open-webui chat:      http://127.0.0.1:$webuiPort"
        # Still worth doing: the user may have exited the tray and re-run this to get it back.
        if (-not $NoTray) { Start-Tray }
        return
    }

    if ($component -ne 'webui') { Initialize-SwapConfig; Test-SwapConfig }

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
        # -watch-config: llama-swap polls config.yaml every 2s and reloads it in place. Without it
        # every edit - add-model, set-tuning, the panel's Models > Edit - needed a restart, which
        # meant the panel asking for one and the tray carrying a "Reload models" item for the
        # common case. Verified against v244: appending a model made it appear in /v1/models
        # within 5s, logging "reloading configuration" / "configuration reloaded".
        # A model already running keeps the flags it was spawned with until it unloads - a reload
        # rewrites the routing table, it does not restart a live llama-server.
        $swapProc = Start-Process -FilePath (Join-Path $llamaSwapDir 'llama-swap.exe') `
            -ArgumentList '--config', $swapConfig, '--listen', ":$swapPort", '-watch-config' `
            -WorkingDirectory $llamaSwapDir -NoNewWindow -PassThru `
            -RedirectStandardOutput $swapLogs[1] -RedirectStandardError $swapLogs[0]
    }

    if ($component -ne 'swap') {
        # A first boot is a different animal from every later one: open-webui runs ~60 alembic
        # migrations against an empty SQLite file and downloads its sentence-transformers
        # embedding weights before it answers /health. Measured on a clean install here, 180s was
        # not close - the health check timed out mid-migration and rolled back a launch that was
        # working perfectly, which reads as a broken install at the end of a 25-minute setup.
        # Every later boot has the db and the weights already, so it keeps the tighter budget.
        # A boot is slow when either the database has to be built or the tree is new - an upgrade
        # copies the database into a freshly built venv, so 'the db exists' alone says nothing.
        # Measured: that upgrade boot took 86 of the 180 seconds, which passes here and would not
        # on a slower disk. $freshTree is what the caller knows and this function cannot.
        $webuiFirstBoot = $freshTree -or -not (Test-Path (Join-Path $webui 'backend\data\webui.db'))
        if ($webuiFirstBoot) { Write-Host "  (first boot: migrating the database and fetching embedding weights - this one takes a few minutes)" }
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
        if ($webuiProc) { Wait-Healthy 'open-webui' "http://127.0.0.1:$webuiPort/health" $webuiProc $webuiLogs $(if ($webuiFirstBoot) { 900 } else { 180 }) }
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

# GGUF keeps all its metadata at the head of the file, so a range request reads a model's
# architecture and shape without pulling the weights. That is the difference between knowing a
# 63 GB MoE model won't load and finding out after downloading it.
function Get-GgufInfo {
    param([string]$Path, [string]$Url)

    # The metadata block has no fixed size - a model with a 200k-token vocabulary carries tens of
    # MB of tokenizer arrays ahead of the weights - and nothing in the header says how long it is.
    # So read a window, and if parsing runs off the end, fetch a bigger one.
    # Running off the end surfaces as several different exception messages depending on which
    # read overflowed, so retry on any failure rather than trying to enumerate them.
    $last = $null
    foreach ($HeadBytes in 4MB, 16MB, 64MB) {
        try { return Get-GgufInfoAt -Path $Path -Url $Url -HeadBytes $HeadBytes }
        catch { $last = $_ }
    }
    throw "could not parse GGUF metadata within 64 MB: $($last.Exception.Message)"
}

function Get-GgufInfoAt {
    param([string]$Path, [string]$Url, [int]$HeadBytes)

    $bytes = if ($Path) {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] ([math]::Min([long]$HeadBytes, $fs.Length))
            [void]$fs.Read($buf, 0, $buf.Length); $buf
        } finally { $fs.Dispose() }
    } else {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.AddRange(0, $HeadBytes - 1)
        $req.UserAgent = 'localllm-setup'
        $resp = $req.GetResponse()
        try {
            $ms = New-Object IO.MemoryStream
            $resp.GetResponseStream().CopyTo($ms)
            $ms.ToArray()
        } finally { $resp.Dispose() }
    }

    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'GGUF') { throw "Not a GGUF file." }
    $o = 4
    $ver = [BitConverter]::ToUInt32($bytes, $o); $o += 4
    $nTensors = [BitConverter]::ToUInt64($bytes, $o); $o += 8
    $nKv = [BitConverter]::ToUInt64($bytes, $o); $o += 8

    # GGUF value type ids; 8 = string, 9 = array, the rest are fixed-width scalars.
    $width = @{ 0 = 1; 1 = 1; 2 = 2; 3 = 2; 4 = 4; 5 = 4; 6 = 4; 7 = 1; 10 = 8; 11 = 8; 12 = 8 }
    function Read-GgufString([byte[]]$b, [ref]$off) {
        $n = [BitConverter]::ToUInt64($b, $off.Value); $off.Value += 8
        $s = [Text.Encoding]::UTF8.GetString($b, $off.Value, $n); $off.Value += $n; $s
    }
    function Skip-GgufValue([byte[]]$b, [ref]$off, [int]$t, $w) {
        if ($t -eq 8) { [void](Read-GgufString $b $off); return }
        if ($t -eq 9) {
            $et = [BitConverter]::ToUInt32($b, $off.Value); $off.Value += 4
            $n = [BitConverter]::ToUInt64($b, $off.Value); $off.Value += 8
            for ($i = 0; $i -lt $n; $i++) { Skip-GgufValue $b $off $et $w }
            return
        }
        $off.Value += $w[[int]$t]
    }

    $kv = @{}
    $ref = [ref]$o
    # The keys worth having (architecture, expert counts, block count) are written before the
    # tokenizer arrays, which are what make these headers tens of MB. So walk until the buffer
    # runs out and keep whatever was read - a truncated tail costs nothing we need.
    try {
        for ($i = 0; $i -lt $nKv; $i++) {
            $key = Read-GgufString $bytes $ref
            $t = [BitConverter]::ToUInt32($bytes, $ref.Value); $ref.Value += 4
            if ($t -eq 8) { $kv[$key] = Read-GgufString $bytes $ref }
            elseif ($t -in 4, 5) { $kv[$key] = [BitConverter]::ToUInt32($bytes, $ref.Value); Skip-GgufValue $bytes $ref $t $width }
            elseif ($t -in 10, 11) { $kv[$key] = [BitConverter]::ToUInt64($bytes, $ref.Value); Skip-GgufValue $bytes $ref $t $width }
            else { Skip-GgufValue $bytes $ref $t $width }
        }
    } catch {
        # Ran past the window. Fine if the architecture block already landed; the caller retries
        # with a bigger read if it didn't.
        if (-not $kv['general.architecture']) { throw }
    }

    $arch = $kv['general.architecture']
    [pscustomobject]@{
        Arch        = $arch
        Version     = $ver
        Tensors     = $nTensors
        Experts     = [int]$kv["$arch.expert_count"]        # >0 means MoE
        ExpertsUsed = [int]$kv["$arch.expert_used_count"]
        Blocks      = [int]$kv["$arch.block_count"]
        TrainCtx    = [int]$kv["$arch.context_length"]
        Embedding   = [int]$kv["$arch.embedding_length"]
        FileType    = $kv['general.file_type']
    }
}

# llama.cpp's own fitter: loads the model's metadata, looks at free VRAM, and prints the CLI
# args that fit. Beats hand-measuring, and it accounts for the KV type it's told about.
function Get-FittedContext($ggufPath, $kvType = 'q4_0') {
    $exe = Join-Path $llamaCpp 'llama-fit-params.exe'
    $prismExe = Join-Path $llamaPrism 'llama-fit-params.exe'
    # A low-bit model only loads on the fork, so fit it with the fork's own binary.
    if ((Test-Path $prismExe) -and -not (Test-Path $exe)) { $exe = $prismExe }
    if (-not (Test-Path $exe)) { return $null }
    # llama-fit-params writes its progress to stderr, and this script runs with
    # $ErrorActionPreference = 'Stop' - so a bare `2>$null` turns that output into a terminating
    # NativeCommandError and the whole call lands in the catch. It did: this function returned
    # $null for every model, which is why autotune's ladder always started from its hardcoded
    # 16384 fallback rather than from the fitter it prints in the same breath.
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $exe -m $ggufPath -ctk $kvType -ctv $kvType -fa on 2>$null | Select-Object -Last 1
        if ($out -match '-c\s+(\d+)') { return [int]$Matches[1] }
    } catch { } finally { $ErrorActionPreference = $old }
    $null
}

# Appends a model entry to config.yaml, matching the style already in the file. The file is
# hand-maintained, so it gets a .bak first and is never rewritten wholesale.
# Replace the cmd flags of an existing entry in place, leaving its id, macro, model path, ttl and
# every other entry untouched. Only the tuning flags are rewritten, so hand-written comments and
# per-model options elsewhere in the file survive.
function Set-ModelTuning($id, $ctx, $kv, $nCpuMoe) {
    if (-not (Test-Path $swapConfig)) { throw "$swapConfig not found." }
    $text = Get-Content $swapConfig -Raw
    $pattern = "(?ms)(^\s{2,}""$([regex]::Escape($id))""\s*:\s*$.*?-m\s+""[^""]+""\s*$)(.*?)(?=^\s*ttl:|^\s{2}""|\z)"
    $m = [regex]::Match($text, $pattern)
    if (-not $m.Success) { return $false }

    $flags = "`r`n      -c $ctx -ctk $kv -ctv $kv"
    if ($null -ne $nCpuMoe) { $flags += "`r`n      --n-cpu-moe $nCpuMoe" }
    $flags += "`r`n"

    Copy-Item $swapConfig "$swapConfig.bak" -Force
    $updated = $text.Remove($m.Groups[2].Index, $m.Groups[2].Length).Insert($m.Groups[2].Index, $flags)
    Set-Content -Path $swapConfig -Value $updated -Encoding utf8 -NoNewline
    $true
}

function Add-ModelToConfig($id, $ggufPath, $context) {
    Initialize-SwapConfig   # add-model can be the first thing a fresh clone runs
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
#  autotune: find the offload split that actually fits this machine
# ==========================================================================

# Boot llama-server with one candidate configuration and report whether it came up, what it
# cost in VRAM, and how fast it generates. Estimating this from parameter counts is guesswork -
# compute buffers and the KV cache move the answer around - so it is measured.
function Test-ModelLoad {
    param($Exe, $Gguf, [int]$Ctx, $Kv = 'q4_0', $NCpuMoe = $null, [int]$Port = 9418, [int]$TimeoutSec = 240)

    $log = Join-Path $env:TEMP "autotune-$Port.log"
    Remove-Item $log, "$log.out" -ErrorAction SilentlyContinue
    $baseline = [int]((nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) -split "`n")[0]

    $a = @('-m', $Gguf, '-c', "$Ctx", '-ctk', $Kv, '-ctv', $Kv, '-fa', 'on', '-np', '1',
           '--host', '127.0.0.1', '--port', "$Port")
    if ($null -ne $NCpuMoe) { $a += @('--n-cpu-moe', "$NCpuMoe") }

    $p = Start-Process -FilePath $Exe -PassThru -NoNewWindow -ArgumentList $a `
        -RedirectStandardError $log -RedirectStandardOutput "$log.out"

    $ok = $false
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        Start-Sleep -Seconds 1
        if ($p.HasExited) { break }
        if (Select-String -Path $log -Pattern 'listening on' -Quiet -ErrorAction SilentlyContinue) { $ok = $true; break }
    }

    $res = @{ Ok = $false; VramMib = 0; GenTps = 0; Why = '' }
    if ($ok) {
        Start-Sleep -Seconds 2
        $res.VramMib = [int]((nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) -split "`n")[0]
        $res.FreeMib = [int]((nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) -split "`n")[0]
        try {
            $body = @{ model = 'x'; messages = @(@{ role = 'user'; content = 'Count to five.' }); max_tokens = 64 } | ConvertTo-Json -Depth 5
            $r = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 180
            $res.GenTps = [math]::Round($r.timings.predicted_per_second, 1)
        } catch { }
        $res.Ok = $true
    } else {
        $tail = Get-Content $log -Tail 40 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'error|failed|out of memory|unable' } | Select-Object -Last 1
        $res.Why = if ($p.HasExited) { "exited ($tail)" } else { 'timed out' }
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 4          # let the driver actually release the VRAM before the next probe
    [pscustomobject]$res
}

function Invoke-Autotune {
    param($Gguf, [int]$Ctx = 0, $Kv = 'q4_0', [int]$MarginMib = 1200)

    if (-not (Test-Path $Gguf)) { throw "No such file: $Gguf" }
    $info = Get-GgufInfo -Path $Gguf
    $sizeGb = (Get-Item $Gguf).Length / 1GB

    # A low-bit model only loads on the fork, so probe with whichever binary can open it.
    $exe = Join-Path $llamaCpp 'llama-server.exe'
    if ($info.Arch -in 'qwen35' -or (Test-Path (Join-Path $llamaPrism 'llama-server.exe')) -and $info.FileType -ge 41) {
        $prism = Join-Path $llamaPrism 'llama-server.exe'
        if (Test-Path $prism) { $exe = $prism }
    }

    $total = [int]((nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits) -split "`n")[0]
    Write-Host ""
    Write-Host "model : $(Split-Path $Gguf -Leaf)  ($('{0:N1}' -f $sizeGb) GB)"
    Write-Host "arch  : $($info.Arch), $($info.Blocks) blocks, $(if ($info.Experts -gt 0) { "MoE $($info.Experts)e/$($info.ExpertsUsed)a" } else { 'dense' })"
    Write-Host "card  : $total MiB total, keeping $MarginMib MiB spare for the desktop"

    # Context candidates, largest first. llama-fit-params sizes to VRAM free at the instant it
    # runs, so its answer can be optimistic; rather than discounting it by a made-up factor, try
    # it and step down only if the measured headroom is short. An earlier version cut a blanket
    # 25% and turned a hand-measured 20480 into 12288 for no reason a measurement supported.
    $ctxLadder = if ($Ctx) { @($Ctx) } else {
        $fit = Get-FittedContext $Gguf $Kv
        # llama-fit-params prints `-c 0` when the whole trained window fits, and `-not 0` is true
        # in PowerShell - so that answer was being read as no answer, and the ladder started from
        # a flat 16384. It only ever steps *down*, so the starting rung is a ceiling: measured on
        # qwen2.5-0.5b it settled at -c 16384 with 10,625 MiB still free, and Tune in the panel
        # would therefore have cut a model that add-model had correctly set to 32768.
        if ($null -eq $fit -or $fit -le 0) {
            $trained = try { (Get-GgufInfo -Path $Gguf).TrainCtx } catch { 0 }
            $fit = if ($trained -gt 0) { $trained } else { 16384 }
        }
        Write-Host "ctx   : llama-fit-params suggests $fit; trying that first, stepping down if headroom is short"
        @(1.0, 0.75, 0.5, 0.35) | ForEach-Object { [int]([math]::Floor($fit * $_ / 1024) * 1024) } |
            Where-Object { $_ -ge 2048 } | Select-Object -Unique
    }
    Write-Host ""

    if ($info.Experts -le 0) {
        # Dense: nothing to split, so the only question is how much context fits.
        Write-Host "dense model - no expert split to tune; finding the largest context that fits ..."
        foreach ($c in $ctxLadder) {
            Write-Host ("  trying -c {0,-7} ... " -f $c) -NoNewline
            $r = Test-ModelLoad -Exe $exe -Gguf $Gguf -Ctx $c -Kv $Kv
            if ($r.Ok -and $r.FreeMib -ge $MarginMib) {
                Write-Host ("ok  {0} MiB used, {1} MiB free, {2} tok/s" -f $r.VramMib, $r.FreeMib, $r.GenTps)
                return [pscustomobject]@{ Ctx = $c; NCpuMoe = $null; Kv = $Kv; VramMib = $r.VramMib; FreeMib = $r.FreeMib; GenTps = $r.GenTps }
            }
            Write-Host $(if ($r.Ok) { "tight ({0} MiB free < {1})" -f $r.FreeMib, $MarginMib } else { "no ($($r.Why))" })
        }
        throw "no context in the ladder fits with $MarginMib MiB spare. Pass -Context explicitly, or use a smaller quant."
    }
    $Ctx = $ctxLadder[0]

    # MoE: --n-cpu-moe N keeps the experts of the first N layers on the CPU. More N means less
    # VRAM and less speed, so the best setting is the SMALLEST N that still fits with headroom.
    # Fit is monotonic in N, so binary search it instead of walking every layer.
    $lo = 0; $hi = $info.Blocks; $best = $null
    Write-Host "searching smallest --n-cpu-moe that fits (0..$($info.Blocks)) ..."
    while ($lo -le $hi) {
        $mid = [int](($lo + $hi) / 2)
        Write-Host ("  trying --n-cpu-moe {0,-3} ... " -f $mid) -NoNewline
        $r = Test-ModelLoad -Exe $exe -Gguf $Gguf -Ctx $Ctx -Kv $Kv -NCpuMoe $mid
        if ($r.Ok -and $r.FreeMib -ge $MarginMib) {
            Write-Host ("ok  {0} MiB used, {1} MiB free, {2} tok/s" -f $r.VramMib, $r.FreeMib, $r.GenTps)
            $best = [pscustomobject]@{ Ctx = $Ctx; NCpuMoe = $mid; Kv = $Kv; VramMib = $r.VramMib; FreeMib = $r.FreeMib; GenTps = $r.GenTps }
            $hi = $mid - 1          # fits: try offloading fewer layers, which is faster
        } elseif ($r.Ok) {
            Write-Host ("tight ({0} MiB free < {1}) - treating as no fit" -f $r.FreeMib, $MarginMib)
            $lo = $mid + 1
        } else {
            Write-Host "no  ($($r.Why))"
            $lo = $mid + 1
        }
    }
    if (-not $best) { throw "no --n-cpu-moe value fits this card at -c $Ctx. Try a smaller quant or a smaller -Context." }
    $best
}

# ==========================================================================
#  main
# ==========================================================================

# These don't touch versions at all - handle them before any stamp/release resolution.
if ($Action -eq 'stop') { Stop-Stack $Component; return }

if ($Action -eq 'tray') { Start-Tray; Write-Host "Tray indicator started (look in the notification area)."; return }

if ($Action -eq 'install-llmfit') {
    # llmfit is a single 24 MB exe, MIT-licensed, and answers a question nothing else here does:
    # which model to get in the first place. Separate from deploy because the stack works fine
    # without it - it recommends, it doesn't run anything.
    if ((Test-Path $llmfitExe) -and -not $Force) {
        Write-Host "$llmfitExe already present (use -Force to reinstall)."
        return
    }
    New-Item -ItemType Directory -Force -Path $llmfitDir, $dl | Out-Null
    $tag = $VER.llmfit
    if ($Latest) {
        $r = Get-GitHubRelease 'AlexsJones/llmfit'
        if ($r) { $tag = $r.tag_name } else { Write-Warning "Could not query llmfit's releases - using pinned $tag" }
    }
    $rel = Get-GitHubRelease 'AlexsJones/llmfit' $tag
    if (-not $rel) { throw "No release '$tag' in AlexsJones/llmfit." }
    # Matched by shape, not by a name built from the tag, so a changed naming scheme fails loudly
    # here rather than 404ing on a URL we guessed.
    $asset = $rel.assets | Where-Object { $_.name -match 'x86_64-pc-windows-msvc\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        Write-Host "`nNo Windows x64 asset in $tag. Available:"
        $rel.assets | ForEach-Object { Write-Host "  $($_.name)" }
        throw "Nothing to install."
    }
    $zip = Join-Path $dl $asset.name
    if (-not (Test-Path $zip)) { Get-File $asset.browser_download_url $zip }
    $tmp = Join-Path $dl 'llmfit-x'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    # The archive nests everything under a versioned directory, so find the exe rather than
    # assuming it sits at the root.
    $found = Get-ChildItem $tmp -Recurse -Filter 'llmfit.exe' | Select-Object -First 1
    if (-not $found) { throw "llmfit.exe not found inside $($asset.name)." }
    Copy-Item $found.FullName $llmfitExe -Force
    Get-ChildItem $tmp -Recurse -Include 'LICENSE', 'README.md' | ForEach-Object { Copy-Item $_.FullName $llmfitDir -Force }
    Remove-Item $tmp -Recurse -Force

    $stamp = Read-Stamp; if (-not $stamp) { $stamp = @{} }
    $stamp['llmfit'] = $tag
    Write-Stamp $stamp
    Write-Host "Installed llmfit $tag to $llmfitExe"
    Write-Host "Ask it what to run:  .\start.ps1 -Action suggest"
    return
}

# The panel is one PowerShell here-string containing the whole page, so a typo in its JavaScript
# is invisible to PowerShell's parser: ui.ps1 starts, serves, and the page renders with every
# button dead. Two such typos shipped in one editing session - a quote closed early inside an
# onclick attribute, and a real newline where an escaped one was meant - and both looked exactly
# like "the feature didn't work". Node is already vendored for the frontend build, so the check
# costs nothing to run.
if ($Action -eq 'check-ui') {
    $node = Get-ChildItem (Join-Path $root 'open-webui-*\.node-runtime') -Recurse -Filter 'node.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    # The vendored Node is deleted once the frontend is built, so on a normal install there is
    # none - which made this check unrunnable exactly where it matters. Any node will parse
    # JavaScript, so fall back to one on PATH before giving up.
    if (-not $node) { $node = (Get-Command node -ErrorAction SilentlyContinue).Source }
    if (-not $node) { throw "No node available. Install Node, or re-provision with -KeepBuildDeps, or run this from a clone that has just been built." }
    $html = Get-Content (Join-Path $root 'ui.ps1') -Raw
    $js = [regex]::Matches($html, '(?s)<script>(.*?)</script>') | ForEach-Object { $_.Groups[1].Value }
    if (-not $js) { throw "No <script> block found in ui.ps1 - has the page been restructured?" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "localllm-ui-$PID.js"
    ($js -join "`n").Replace('@@TOKEN@@', 'x') | Set-Content $tmp -Encoding utf8
    & $node --check $tmp
    $rc = $LASTEXITCODE
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($rc -ne 0) { throw "ui.ps1's JavaScript does not parse - see above. The panel would load with every button dead." }
    Write-Host "ui.ps1 JavaScript parses."
    return
}

if ($Action -eq 'suggest') {
    # Complements '-Action inspect' rather than replacing it. inspect answers "which quant of THIS
    # repo fits"; suggest answers "which model at all", which is the question a new install
    # actually has and which this stack previously answered with "paste a Hugging Face repo".
    if (-not (Test-Path $llmfitExe)) { throw "llmfit isn't installed - run '.\start.ps1 -Action install-llmfit' (5 MB)." }

    # --runtime llamacpp because that is the only engine here; --capability tool_use because a
    # model that can't call tools is useless for the coding-agent path, and it is the capability
    # people most often discover the hard way. --no-dashboard because llmfit otherwise starts a
    # background web server, which this is not asking for.
    $a = @('recommend', '--runtime', 'llamacpp', '--min-fit', $MinFit, '-n', "$Top", '--no-dashboard')
    if ($UseCase)    { $a += @('--use-case', $UseCase) }
    if ($Capability -and $Capability -ne 'any') { $a += @('--capability', $Capability) }

    Write-Host "Asking llmfit what fits this machine..."
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $raw = try { & $llmfitExe @a 2>$null | Out-String } finally { $ErrorActionPreference = $old }
    if (-not $raw.Trim()) { throw "llmfit returned nothing. Try running '$llmfitExe doctor' directly." }
    $data = $raw | ConvertFrom-Json

    # Only rows we can actually act on: llmfit also ranks vLLM/AWQ and MLX builds, which this
    # stack cannot load, and those carry no GGUF source to download.
    $rows = @($data.models | Where-Object { $_.gguf_sources -and $_.gguf_sources.Count -gt 0 })

    if ($Json) {
        # Flattened to exactly what a caller needs to show a row and act on it: the repo and quant
        # are what '-Action add-model' takes, so the panel's Download button is a one-liner.
        @{ models = @($rows | ForEach-Object {
                @{ name = $_.name; repo = $_.gguf_sources[0].repo; quant = $_.best_quant
                   fit = $_.fit_label; sizeGb = $_.disk_size_gb; tps = $_.estimated_tps
                   moe = [bool]$_.is_moe; ctx = $_.context_length; license = "$($_.license)" } }) } |
            ConvertTo-Json -Depth 5 -Compress
        return
    }

    if (-not $rows.Count) {
        Write-Warning "llmfit found no GGUF-backed model matching those filters. Loosen them with -MinFit marginal, or drop -Capability."
        return
    }

    Write-Host ""
    Write-Host ("{0,-46} {1,-9} {2,-8} {3,7} {4,8}  {5}" -f 'model', 'quant', 'fit', 'GB', 'tok/s', 'notes')
    Write-Host ('-' * 108)
    foreach ($m in $rows) {
        $note = @()
        if ($m.is_moe) { $note += 'MoE' }
        if ($m.context_length) { $note += "ctx $($m.context_length)" }
        Write-Host ("{0,-46} {1,-9} {2,-8} {3,7:N1} {4,8:N1}  {5}" -f
            $m.name.Substring(0, [Math]::Min(46, $m.name.Length)), $m.best_quant, $m.fit_label,
            $m.disk_size_gb, $m.estimated_tps, ($note -join ', '))
    }
    Write-Host ""
    Write-Host "Fetch one with (repo is llmfit's GGUF source, not the model name above):"
    foreach ($m in $rows | Select-Object -First 3) {
        Write-Host "  .\start.ps1 -Action add-model -Model '$($m.gguf_sources[0].repo)' -Quant $($m.best_quant)"
    }
    Write-Host ""
    Write-Host "Speeds are llmfit's estimate from memory bandwidth, not a measurement - '-Action bench' measures."
    return
}

if ($Action -eq 'install-prism') {
    # Deliberately a separate action rather than part of deploy: it's ~620 MB of downloads that
    # only matters if you actually run a low-bit model, and it must never replace the stock
    # build - every other model in config.yaml depends on that one.
    $exe = Join-Path $llamaPrism 'llama-server.exe'
    if ((Test-Path $exe) -and -not $Force) {
        Write-Host "$exe already present (use -Force to reinstall)."
        return
    }
    New-Item -ItemType Directory -Force -Path $llamaPrism, $dl | Out-Null

    $tag = $VER.prism
    if ($Latest) {
        $r = Get-GitHubRelease 'PrismML-Eng/llama.cpp'
        if ($r) { $tag = $r.tag_name } else { Write-Warning "Could not query the fork's releases - using pinned $tag" }
    }
    Write-Host "Fetching PrismML llama.cpp fork $tag ..."
    $rel = Get-GitHubRelease 'PrismML-Eng/llama.cpp' $tag
    if (-not $rel) { throw "No release '$tag' in PrismML-Eng/llama.cpp." }

    # The fork also publishes plain cpu/vulkan/hip builds; the CUDA one is the point of it here.
    # Its Windows CUDA asset is named off the kernel build (llama-prism-b1-...), not the release
    # tag, so match on shape rather than on the tag string.
    $main = $rel.assets | Where-Object { $_.name -match 'bin-win-cuda-.*-x64\.zip$' -and $_.name -notmatch '^cudart' } | Select-Object -First 1
    if (-not $main) {
        Write-Host "`nNo Windows CUDA asset in $tag. Available:"
        $rel.assets | ForEach-Object { Write-Host ("  {0,-58} {1,6:N0} MB" -f $_.name, ($_.size / 1MB)) }
        throw "Nothing to install."
    }
    $cudart = $rel.assets | Where-Object { $_.name -match '^cudart-.*-x64\.zip$' } | Select-Object -First 1

    foreach ($a in @($main, $cudart) | Where-Object { $_ }) {
        $zip = Join-Path $dl $a.name
        if (-not (Test-Path $zip)) { Get-BigFile $a.browser_download_url $zip $a.size } else { Write-Host "$($a.name) already downloaded." }
        Write-Host "Extracting $($a.name) ..."
        Expand-Archive -Path $zip -DestinationPath $llamaPrism -Force
    }

    if (-not (Test-Path $exe)) { throw "Extracted the archives but $exe is missing - check the asset layout." }
    $stamp = Read-Stamp
    if (-not $stamp) { $stamp = @{} }
    $stamp['prism'] = $tag
    Write-Stamp $stamp

    Write-Host "`nInstalled to $llamaPrism"
    Write-Host "Add a model that needs it to $swapConfig using the 'llama-server-prism' macro:"
    Write-Host ""
    Write-Host '  "<model-id>":'
    Write-Host '    cmd: >'
    Write-Host '      ${llama-server-prism}'
    Write-Host "      -m `"$modelsDir\<file>.gguf`""
    Write-Host '      -c 16384 -ctk q4_0 -ctv q4_0'
    Write-Host '    ttl: 600'
    Write-Host "`nllama-swap watches config.yaml, so it becomes routable a couple of seconds after you save it."
    return
}

if ($Action -eq 'bench') {
    $bench = Join-Path $root 'bench\run.py'
    if (-not (Test-Path $bench)) { throw "$bench not found." }
    if (-not (Test-ComponentRunning 'swap')) { throw "llama-swap isn't running - start the stack first." }
    # Reuse the venv the deploy already built rather than depending on a machine-wide Python.
    $webui = Find-WebuiDir
    $py = if ($webui) { Join-Path $webui '.venv\Scripts\python.exe' } else { $null }
    if (-not ($py -and (Test-Path $py))) {
        $py = (Get-Command python -ErrorAction SilentlyContinue).Source
        if (-not $py) { throw "No Python found - deploy the stack first, or put python on PATH." }
    }
    # -u: a full run takes minutes per model, and buffered stdout would show nothing until the end.
    & $py -u $bench --base "http://127.0.0.1:$swapPort" @BenchArgs
    exit $LASTEXITCODE
}

if ($Action -eq 'restart') {
    $webui = Find-WebuiDir
    if (-not $webui) { throw "Nothing deployed - run '.\start.ps1' with no arguments first." }
    Stop-Stack $Component
    Start-Stack $webui $Component
    return
}

if ($Action -eq 'autotune') {
    # Accepts a model id already in config.yaml, or a path/filename under models\.
    $gguf = $null
    if ($Model) {
        $gguf = if (Test-Path $Model) { (Resolve-Path $Model).Path } else { Join-Path $modelsDir $Model }
    } elseif ($Id) {
        $text = Get-Content $swapConfig -Raw
        $parts = [regex]::Split($text, '(?m)^\s{2,}"([^"]+)"\s*:\s*$')
        for ($i = 1; $i -lt $parts.Count; $i += 2) {
            if ($parts[$i] -eq $Id) {
                $m = [regex]::Match($parts[$i + 1], '-m\s+"?([^"\r\n]+?\.gguf)"?')
                if ($m.Success) { $gguf = $m.Groups[1].Value.Trim() }
            }
        }
        if (-not $gguf) { throw "No model '$Id' in $swapConfig." }
    } else {
        throw "-Action autotune needs -Id <config model id> or -Model <path to .gguf>."
    }
    if (-not (Test-Path $gguf)) { throw "Weights not found: $gguf" }

    if (Test-ComponentRunning 'swap') {
        Write-Warning "llama-swap is running and may hold VRAM. Stop it first for accurate numbers: -Action stop -Component swap"
    }

    # -Context carries a default for add-model, so its mere presence says nothing. Only an
    # explicitly passed value should pin the context; otherwise autotune computes one.
    $ctxArg = if ($PSBoundParameters.ContainsKey('Context')) { $Context } else { 0 }
    $best = Invoke-Autotune -Gguf $gguf -Ctx $ctxArg -Kv $(if ($PSBoundParameters.ContainsKey('Quant')) { $Quant } else { 'q4_0' })

    $id = if ($Id) { $Id } else { [IO.Path]::GetFileNameWithoutExtension($gguf).ToLower() }
    $moeLine = if ($null -ne $best.NCpuMoe) { "`n      --n-cpu-moe $($best.NCpuMoe)" } else { '' }
    Write-Host ""
    Write-Host "tuned: -c $($best.Ctx) -ctk $($best.Kv) -ctv $($best.Kv)$(if ($null -ne $best.NCpuMoe) { " --n-cpu-moe $($best.NCpuMoe)" })  ->  $($best.GenTps) tok/s, $($best.VramMib) MiB used"
    if ($Apply) {
        if (Set-ModelTuning $id $best.Ctx $best.Kv $best.NCpuMoe) {
            Write-Host "written to $swapConfig (previous kept as config.yaml.bak)."
            Write-Host "llama-swap re-reads the file within a couple of seconds. A model that is loaded right now keeps the settings it was spawned with until it unloads."
        } else {
            # No entry to rewrite - autotune doesn't invent one, since it can't know which macro
            # the model needs (a low-bit model has to use llama-server-prism).
            Write-Warning "No entry called '$id' in config.yaml, so there was nothing to update. Add it with the block below, then re-run with -Apply."
            $Apply = $false
        }
    }
    if (-not $Apply) {
        Write-Host ""
        Write-Host "config.yaml entry (or re-run with -Apply to write it):"
        Write-Host ""
        Write-Host "  `"$id`":"
        Write-Host "    cmd: >"
        Write-Host "      `${llama-server}"
        Write-Host "      -m `"$gguf`""
        Write-Host "      -c $($best.Ctx) -ctk $($best.Kv) -ctv $($best.Kv)$moeLine"
        Write-Host "    ttl: 600"
    }
    return
}

if ($Action -eq 'inspect') {
    if (-not $Model) { throw "-Action inspect needs -Model <hf repo, hf url, or .gguf url>." }
    $spec = Resolve-ModelSpec $Model

    $vramMib = 0
    try { $vramMib = [int]((nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits) -split "`n")[0] } catch { }
    $freeMib = 0
    try { $freeMib = [int]((nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) -split "`n")[0] } catch { }
    $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    Write-Host "`nthis machine: $vramMib MiB VRAM ($freeMib MiB free now), $ramGb GB system RAM`n"

    $targets = if ($spec.Repo) {
        Write-Host "Reading $($spec.Repo) from Hugging Face..."
        @(Get-HfVariants $spec.Repo) | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Bytes = $_.Bytes
                Url = "https://huggingface.co/$($spec.Repo)/resolve/main/$($_.Parts[0].path)" }
        }
    } else {
        @([pscustomobject]@{ Name = (Split-Path ($spec.Url -split '\?')[0] -Leaf); Bytes = 0; Url = $spec.Url })
    }

    # Architecture and expert counts are properties of the model, not of the quantisation, so
    # every variant in a repo shares them. Read one header (the smallest, so the range request is
    # cheapest) instead of pulling tens of MB per variant.
    $probe = $targets | Sort-Object Bytes | Select-Object -First 1
    Write-Host "Reading metadata from $($probe.Name) ..."
    $info = $null; $why = ''
    try { $info = Get-GgufInfo -Url $probe.Url } catch { $why = $_.Exception.Message }
    if (-not $info) { throw "Could not read GGUF metadata: $why" }

    Write-Host ""
    Write-Host "arch $($info.Arch) | $($info.Blocks) blocks | trained context $($info.TrainCtx) | $(if ($info.Experts -gt 0) { "MoE, $($info.Experts) experts, $($info.ExpertsUsed) active per token" } else { 'dense' })"

    Write-Host ("`n{0,-44} {1,9} {2,-10} {3,-16} {4}" -f 'variant', 'size', 'arch', 'kind', 'verdict')
    Write-Host ('-' * 104)
    foreach ($t in $targets) {
        $kind = if ($info.Experts -gt 0) { "MoE $($info.Experts)e/$($info.ExpertsUsed)a" } else { 'dense' }
        $sizeGb = $t.Bytes / 1GB

        # Weights must fit somewhere. On VRAM alone for a dense model; for MoE the experts can
        # live in system RAM and only the active path needs the card, which is the whole reason
        # a 12 GB GPU can run a 100B model at all.
        $budgetGb = ($vramMib - 1500) / 1024      # leave ~1.5 GB for the desktop and buffers
        $verdict =
            if ($sizeGb -le $budgetGb) { 'fits in VRAM' }
            elseif ($info.Experts -gt 0 -and $sizeGb -le ($ramGb - 4)) { 'MoE: offload experts (--n-cpu-moe)' }
            elseif ($info.Experts -gt 0) { "MoE but needs > $ramGb GB RAM" }
            else { 'too big (dense, will not fit)' }

        Write-Host ("{0,-44} {1,9} {2,-10} {3,-16} {4}" -f `
            $t.Name, (Format-Size $t.Bytes), $info.Arch, $kind, $verdict)
    }
    Write-Host ""
    Write-Host "arch must be one llama.cpp knows - an unknown one fails at load no matter the size."
    Write-Host "Pull one with:  .\start.ps1 -Action add-model -Model '<repo>' -Quant <label>"
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
            $downloads += @{ Url = "https://huggingface.co/$($spec.Repo)/resolve/main/$($p.path)"; File = (Split-Path $p.path -Leaf); Size = [long]$p.size }
        }
        if (-not $Id) { $Id = $v.Name.ToLower() }
    }
    else {
        $file = if ($Name) { $Name } else { Split-Path ($spec.Url -split '\?')[0] -Leaf }
        if ($file -notlike '*.gguf') { throw "'$file' is not a .gguf - pass -Name <file>.gguf if the URL doesn't end in one." }
        $downloads += @{ Url = $spec.Url; File = $file; Size = 0 }   # a bare URL tells us nothing until it arrives
        if (-not $Id) { $Id = [IO.Path]::GetFileNameWithoutExtension($file).ToLower() }
    }

    $i = 0
    foreach ($d in $downloads) {
        $i++
        $dest = Join-Path $modelsDir $d.File
        if (Test-Path $dest) { Write-Host "[$i/$($downloads.Count)] $($d.File) already present - skipping."; continue }
        Write-Host "[$i/$($downloads.Count)] Fetching $($d.File) (resumable - safe to interrupt and re-run)..."
        Get-BigFile $d.Url $dest $d.Size
    }

    # llama.cpp loads a split model from its first part and finds the rest itself.
    $primary = Join-Path $modelsDir $downloads[0].File
    Write-Host "`nSaved to $modelsDir"

    # A freshly downloaded model used to land at a flat -c 16384 whatever card it was going onto,
    # which is the number the panel then reports as its conversation length - so every new model
    # read as "short" until someone ran Tune. llama.cpp ships its own fitter, which reads the file
    # and the free VRAM and prints the -c that fits; on this box it answers 36608 for a 14B at
    # Q4_K_M against that same 16384. It sizes to VRAM free at the instant it runs, so it is a
    # good starting point rather than a measurement - `-Action autotune` is what measures - and it
    # is capped at what the model was actually trained for, since asking for more buys nothing.
    $ctxToUse = $Context
    if (-not $PSBoundParameters.ContainsKey('Context')) {
        $fit = Get-FittedContext $primary
        if ($null -ne $fit) {
            $trained = try { (Get-GgufInfo -Path $primary).TrainCtx } catch { 0 }
            # The fitter prints `-c 0` when the whole trained window fits - 0 is also what llama.cpp
            # itself reads as "use the model's own maximum". Resolve it to the real number, because
            # 0 in config.yaml tells the panel nothing about how long a conversation can get.
            if ($fit -le 0) { $fit = $trained }
            if ($trained -gt 0 -and $fit -gt $trained) { $fit = $trained }
            if ($fit -gt 0) {
                $ctxToUse = [math]::Max(8192, [int]([math]::Floor($fit / 1024) * 1024))
                Write-Host "context: $ctxToUse, sized to this card by llama-fit-params (-Context overrides; -Action autotune measures)."
            }
        }
    }

    if ($NoConfig) {
        Write-Host "Skipped config.yaml (-NoConfig). Register it as '$Id' pointing at $primary when you're ready."
    }
    elseif (Add-ModelToConfig $Id $primary $ctxToUse) {
        Write-Host "Registered in $swapConfig as `"$Id`" (context $ctxToUse, previous config saved as config.yaml.bak)."

        # No restart: llama-swap runs with -watch-config and polls the file every 2s.
        Write-Host "llama-swap picks it up within a couple of seconds - it is routable without a restart."
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

    'set-tuning' {
        # autotune measures these numbers; this just writes ones you already decided on, through
        # the same Set-ModelTuning so a hand edit and a measured one land identically.
        if (-not $Id) { throw "-Id is required: which model in config.yaml to change." }
        $moe = if ($NCpuMoe -ge 0) { $NCpuMoe } else { $null }
        if ($NCpuMoe -lt 0) {
            # Preserve whatever the entry already had rather than dropping the flag.
            $cur = [regex]::Match((Get-Content $swapConfig -Raw),
                   "(?ms)^\s{2,}""$([regex]::Escape($Id))""\s*:.*?(?=^\s{2}""|\z)")
            if ($cur.Success -and $cur.Value -match '--n-cpu-moe\s+(\d+)') { $moe = [int]$Matches[1] }
        }
        if (Set-ModelTuning $Id $Context $Kv $moe) {
            Write-Host "$Id -> -c $Context -ctk $Kv -ctv $Kv$(if ($null -ne $moe) { " --n-cpu-moe $moe" })"
            Write-Host "written to $swapConfig (previous kept as config.yaml.bak)."
            Write-Host "llama-swap re-reads the file within a couple of seconds. A model that is loaded right now keeps the settings it was spawned with until it unloads."
        } else {
            throw "No entry called '$Id' in config.yaml."
        }
    }

    'check-config' {
        # The same preflight the launch runs, on its own - so a config edit can be checked before
        # bouncing llama-swap, rather than by bouncing it and reading the warnings on the way past.
        Initialize-SwapConfig
        Write-Host "Checking $swapConfig ..."
        Write-Host ""
        Test-SwapConfig
        Write-Host "done."
    }

    'status' {
        $latestVer = if ($Latest) { $target } else { $null }
        Write-Host ""
        Write-Host ("{0,-12} {1,-14} {2,-14} {3}" -f 'component', 'installed', 'pinned', 'latest')
        foreach ($k in 'llamaCpp', 'llamaSwap', 'openWebUI', 'node') {
            $inst = if ($installed -and $installed.ContainsKey($k)) { $installed[$k] } else { '(unstamped)' }
            $lat  = if ($latestVer) { $latestVer[$k] } else { '-' }
            Write-Host ("{0,-12} {1,-14} {2,-14} {3}" -f $k, $inst, $VER[$k], $lat)
        }
        $pi = if ($installed -and $installed.ContainsKey('prism')) { $installed['prism'] } else { '(not installed)' }
        Write-Host ("{0,-12} {1,-14} {2,-14} {3}" -f 'prism fork', $pi, $VER['prism'], '-')
        $wd = Find-WebuiDir
        Write-Host ""
        Write-Host "open-webui dir: $(if ($wd) { $wd } else { '(none)' })"
        Write-Host "llama-server:   $(if (Test-Path (Join-Path $llamaCpp 'llama-server.exe')) { 'installed' } else { 'missing' })"
        Write-Host "prism fork:     $(if (Test-Path (Join-Path $llamaPrism 'llama-server.exe')) { "installed ($llamaPrism)" } else { "not installed (-Action install-prism)" })"
        Write-Host "llama-swap:     $(if (Test-Path (Join-Path $llamaSwapDir 'llama-swap.exe')) { 'installed' } else { 'missing' })"
        Write-Host "running:        $((@(Get-Process -Name llama-swap, llama-server -ErrorAction SilentlyContinue)).Count) llama process(es)"
        if (-not $Latest) { Write-Host "`n(add -Latest to also show newest upstream releases)" }
    }

    'deploy' {
        $freshWebuiTree = -not (Test-Path (Join-Path $root "open-webui-$($target.openWebUI)"))
        Invoke-Deploy $target
        Write-Stamp $target
        # Derived, never returned - see the note on Invoke-Deploy.
        $webui = Join-Path $root "open-webui-$($target.openWebUI)"
        # Honour -Component here too: provisioning still covers everything, but a caller who only
        # wants the router running should get only the router started.
        Start-Stack $webui $Component $freshWebuiTree
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

        Invoke-Deploy $target
        Write-Stamp $target
        $webui = Join-Path $root "open-webui-$($target.openWebUI)"

        # Only now that the new tree built and booted-ready is the old one disposable.
        if ($webuiChanged -and $oldWebui -and $oldWebui -ne $webui -and (Test-Path $oldWebui)) {
            $keep = Join-Path $root ('_old-' + (Split-Path $oldWebui -Leaf))
            Write-Host "Old install kept at $keep - delete it once you've confirmed the upgrade works."
            Move-Item $oldWebui $keep -Force
        }

        Start-Stack $webui 'all' $webuiChanged
    }

    'uninstall' {
        $targets = @()
        if (Test-Path $llamaCpp)     { $targets += if ($IncludeModels) { $llamaCpp } else { "$llamaCpp (except models\)" } }
        if (Test-Path $llamaPrism)   { $targets += $llamaPrism }
        if (Test-Path (Join-Path $llamaSwapDir 'llama-swap.exe')) { $targets += "$llamaSwapDir\llama-swap.exe (config.yaml kept)" }
        Get-ChildItem $root -Directory -Filter 'open-webui-*' -ErrorAction SilentlyContinue | ForEach-Object { $targets += $_.FullName }
        Get-ChildItem $root -Directory -Filter '_old-open-webui-*' -ErrorAction SilentlyContinue | ForEach-Object { $targets += $_.FullName }
        if (Test-Path $logDir)    { $targets += $logDir }
        if (Test-Path $stampFile) { $targets += $stampFile }
        if (Test-Path $dl)        { $targets += $dl }
        # uv, the private CPython it installed, and its download cache. All inside $root precisely
        # so that uninstall can take them - the old winget route installed Python machine-wide and
        # left it behind for the user to find and remove themselves.
        if (Test-Path $uvDir)     { $targets += $uvDir }
        foreach ($d in @((Join-Path $root '.python'), (Join-Path $root '.uv-cache'))) {
            if (Test-Path $d) { $targets += $d }
        }

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
        Remove-Item $llamaPrism -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $llamaSwapDir 'llama-swap.exe') -Force -ErrorAction SilentlyContinue
        Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'open-webui-*' -or $_.Name -like '_old-open-webui-*' } |
            Remove-Item -Recurse -Force
        Remove-Item $logDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $stampFile -Force -ErrorAction SilentlyContinue
        Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue
        # These three are printed in the "will permanently delete" list above and were never
        # actually deleted - a fresh uninstall left uv.exe and its siblings sitting there, 47 MB
        # of a tool the user was told had been removed. An uninstaller that overstates what it
        # removed is worse than one that removes less and says so.
        Remove-Item $uvDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $root '.python') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $root '.uv-cache') -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host "`nUninstalled. Re-run '.\start.ps1' to rebuild from scratch."
    }
}
