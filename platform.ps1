# Platform layer. THE ONLY FILE IN THIS REPO ALLOWED TO BRANCH ON OPERATING SYSTEM.
#
# Everything above this file - start.ps1, ui.ps1, diagnose.ps1 - stays platform-neutral and asks
# here instead. That rule is enforced in CI, not by good intentions: check.yml fails the build if
# nvidia-smi, WScript.Shell, Get-CimInstance or a `win-`/`darwin_` asset pattern appears anywhere
# else. Two implementations of the same behaviour drifting apart is the failure this repo has
# documented more often than any other, and "release once, ship both" is only true if there is
# exactly one copy of every decision.
#
# Dot-source it:  . (Join-Path $PSScriptRoot 'platform.ps1')
#
# COMPATIBILITY: this must parse and run on BOTH Windows PowerShell 5.1 (what every Windows box
# already has, and what the Windows install still uses) and pwsh 7 (what macOS bootstraps into
# .pwsh\). So: no ternaries, no ?? , no `clean` parameter sets, and never reference $IsWindows /
# $IsMacOS directly - they are undefined on 5.1 and read-only automatic constants on 7.

# --- detection -----------------------------------------------------------------------------
# PSEdition 'Desktop' is 5.1 and only ever runs on Windows. pwsh sets Platform to Win32NT or Unix;
# `uname` is only invoked once we already know we are not on Windows, so it can never be a missing
# command on a Windows box.
$script:PlatformName =
    if ($PSVersionTable.PSEdition -eq 'Desktop') { 'Windows' }
    elseif ($PSVersionTable.Platform -eq 'Win32NT') { 'Windows' }
    elseif ((& uname) -eq 'Darwin') { 'MacOS' }
    else { 'Linux' }

$Plat = @{
    Name      = $script:PlatformName
    IsWindows = ($script:PlatformName -eq 'Windows')
    IsMac     = ($script:PlatformName -eq 'MacOS')
}
# The identifier that names a release artifact and selects upstream downloads. Apple Silicon only
# by decision - Intel Macs have no Metal path worth targeting, and adding x64 doubles the asset
# matrix for users we do not know we have.
$Plat.Id = if ($Plat.IsWindows) { 'windows-x64' } elseif ($Plat.IsMac) { 'macos-arm64' } else { 'linux-x64' }

function Assert-SupportedPlatform {
    if (-not ($Plat.IsWindows -or $Plat.IsMac)) {
        throw "LocalLLM supports Windows and macOS (Apple Silicon). Detected: $($Plat.Name)."
    }
}

# --- archives ------------------------------------------------------------------------------
# Absolute path, never a bare `tar`. A clean rebuild died on exactly this: with Git for Windows'
# usr\bin ahead on PATH, `tar` is GNU tar, which reads "C:\LocalLLM" as host:path and fails with
# "Cannot connect to C: resolve failed". Windows has shipped bsdtar at this path since 1809.
function Get-TarExe {
    if ($Plat.IsWindows) { return (Join-Path $env:SystemRoot 'System32\tar.exe') }
    return '/usr/bin/tar'
}

# One entry point for "unpack this thing", because the two platforms' upstreams disagree about
# format: llama.cpp ships .zip for Windows and .tar.gz for macOS, and so does node.
function Expand-Download($archive, $destination) {
    if (-not (Test-Path $destination)) { New-Item -ItemType Directory -Force -Path $destination | Out-Null }
    if ($archive -match '\.zip$') {
        if ($Plat.IsWindows) { Expand-Archive -Path $archive -DestinationPath $destination -Force; return }
        # bsdtar reads zips too, and on macOS it avoids Expand-Archive's habit of mangling the
        # executable bit that every binary in these archives depends on.
        & (Get-TarExe) -xf $archive -C $destination
    } else {
        & (Get-TarExe) -xzf $archive -C $destination
    }
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract $archive (exit $LASTEXITCODE)." }
}

# --- upstream asset selection --------------------------------------------------------------
# Every hardcoded win-x64 / darwin_arm64 string in this project lives in this one function.
# Verified present at the versions already pinned in $VER, which is what makes a single pin table
# serve both platforms:
#   llama-b10155-bin-macos-arm64.tar.gz     10.9 MB   (no CUDA runtime - Metal is in the OS)
#   llama-swap_244_darwin_arm64.tar.gz      12.8 MB
#
# Returns @{ Pattern = <regex matched against a GitHub release asset name>
#            Url     = <direct fallback when the API is unavailable or rate-limited>
#            Extra   = <second asset that must be fetched alongside, or $null> }
function Get-ComponentAsset($component, $ver, $hasAccelerator) {
    if ($Plat.IsWindows) {
        switch ($component) {
            'llamaCpp' {
                # Anchored: the unanchored form also matches cudart-llama-bin-win-cuda-12.4-x64.zip,
                # which sorts first - a clean deploy then fetched cudart twice and no binaries.
                $variant = if ($hasAccelerator) { 'cuda' } else { 'cpu' }
                $pat = if ($hasAccelerator) { '^llama-.*-bin-win-cuda-.*-x64\.zip$' } else { '^llama-.*-bin-win-cpu-x64\.zip$' }
                return @{ Pattern = $pat
                          Url     = "https://github.com/ggml-org/llama.cpp/releases/download/$($ver.llamaCpp)/llama-$($ver.llamaCpp)-bin-win-$variant-x64.zip"
                          Extra   = $(if ($hasAccelerator) { '^cudart-.*-x64\.zip$' } else { $null }) }
            }
            'llamaSwap' { return @{ Pattern = 'windows_amd64\.zip$'; Url = $null; Extra = $null } }
            'node'      { return @{ Pattern = $null
                                    Url     = "https://nodejs.org/dist/$($ver.node)/node-$($ver.node)-win-x64.zip"
                                    Extra   = $null } }
            'llmfit'    { return @{ Pattern = 'x86_64-pc-windows-msvc\.zip$'; Url = $null; Extra = $null } }
        }
    }
    if ($Plat.IsMac) {
        switch ($component) {
            # No cudart equivalent and no cpu/gpu split: the macOS build carries Metal, and on
            # Apple Silicon there is no configuration in which you would not want it.
            'llamaCpp'  { return @{ Pattern = '^llama-.*-bin-macos-arm64\.tar\.gz$'
                                    Url     = "https://github.com/ggml-org/llama.cpp/releases/download/$($ver.llamaCpp)/llama-$($ver.llamaCpp)-bin-macos-arm64.tar.gz"
                                    Extra   = $null } }
            'llamaSwap' { return @{ Pattern = 'darwin_arm64\.tar\.gz$'; Url = $null; Extra = $null } }
            'node'      { return @{ Pattern = $null
                                    Url     = "https://nodejs.org/dist/$($ver.node)/node-$($ver.node)-darwin-arm64.tar.gz"
                                    Extra   = $null } }
            'llmfit'    { return @{ Pattern = 'aarch64-apple-darwin\.tar\.gz$'; Url = $null; Extra = $null } }
        }
    }
    throw "No '$component' asset defined for $($Plat.Id)."
}

# Directory name inside the node archive - it differs per platform and the deploy needs it to find
# npm afterwards.
function Get-NodeDirName($ver) {
    if ($Plat.IsWindows) { return "node-$($ver.node)-win-x64" }
    return "node-$($ver.node)-darwin-arm64"
}

# Executable suffix, for building tool paths without branching at the call site.
function Get-ExeSuffix { if ($Plat.IsWindows) { return '.exe' } return '' }

# --- accelerator and memory ----------------------------------------------------------------
# Returns @{ Present; Name; TotalMib; UsedMib; FreeMib }. FreeMib is what -Action autotune steps
# down against, and its meaning is genuinely different per platform - see Get-MemoryBudget.
function Get-AcceleratorInfo {
    $info = @{ Present = $false; Name = ''; TotalMib = 0; UsedMib = 0; FreeMib = 0 }
    if ($Plat.IsWindows) {
        if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $info }
        $q = (nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>$null)
        if (-not $q) { return $info }
        $f = ($q -split "`n")[0] -split ','
        $info.Present = $true
        $info.Name     = $f[0].Trim()
        $info.TotalMib = [int]$f[1].Trim()
        $info.UsedMib  = [int]$f[2].Trim()
        $info.FreeMib  = [int]$f[3].Trim()
        return $info
    }
    if ($Plat.IsMac) {
        # UNVERIFIED until Phase 2 runs on real hardware - written from the documented shape of
        # these tools, not from a measurement on this box, which has no Mac.
        #
        # Apple Silicon has no discrete VRAM: the GPU addresses the same unified memory as the CPU.
        # "Free VRAM" therefore has no direct analogue, and the honest number is how much memory
        # Metal is permitted to wire down. iogpu.wired_limit_mb of 0 means the OS default, which is
        # roughly 75% of physical RAM.
        $totalBytes = 0
        try { $totalBytes = [int64](& sysctl -n hw.memsize) } catch { }
        $totalMib = [int]($totalBytes / 1MB)
        $limitMib = 0
        try { $limitMib = [int](& sysctl -n iogpu.wired_limit_mb) } catch { }
        if ($limitMib -le 0) { $limitMib = [int]($totalMib * 0.75) }
        $name = 'Apple GPU'
        try {
            $chip = (& system_profiler SPDisplaysDataType) | Select-String -Pattern 'Chipset Model:\s*(.+)$'
            if ($chip) { $name = $chip.Matches[0].Groups[1].Value.Trim() }
        } catch { }
        # vm_stat reports free pages; page size is 16 KB on Apple Silicon but ask rather than assume.
        $freeMib = 0
        try {
            $pageSize = [int](& sysctl -n hw.pagesize)
            $freePages = 0
            foreach ($line in (& vm_stat)) {
                if ($line -match '^Pages (free|inactive|speculative):\s+(\d+)') { $freePages += [int64]$Matches[2] }
            }
            $freeMib = [int](($freePages * $pageSize) / 1MB)
        } catch { }
        $info.Present  = $true
        $info.Name     = $name
        $info.TotalMib = $limitMib
        $info.UsedMib  = [Math]::Max(0, $limitMib - $freeMib)
        $info.FreeMib  = [Math]::Min($limitMib, $freeMib)
        return $info
    }
    return $info
}

# How much room a model may actually take, in MiB. The step-down algorithm in -Action autotune is
# platform-neutral - try a context, measure, shrink - and only this probe changes underneath it.
# The reserve is what the rest of the machine needs and never gets counted: on Windows the desktop
# measured 970-1463 MiB with a browser open; on macOS the OS and WindowServer want considerably
# more, and taking it from the same pool the model is using is not optional.
function Get-MemoryBudget {
    $acc = Get-AcceleratorInfo
    if (-not $acc.Present) { return 0 }
    $reserveMib = if ($Plat.IsWindows) { 1500 } else { 4096 }
    return [Math]::Max(0, $acc.FreeMib - $reserveMib)
}

function Get-SystemMemoryGb {
    if ($Plat.IsWindows) {
        return [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    }
    try { return [math]::Round(([int64](& sysctl -n hw.memsize)) / 1GB, 1) } catch { return 0 }
}

# --- processes -----------------------------------------------------------------------------
# Both of these deliberately scope to this install: a machine's other Python interpreters and
# other PowerShell scripts must never be matched, let alone stopped. Returns objects carrying at
# least ProcessId, so callers can stay neutral.
function Get-ProcessUnderPath($processName, $pathPrefix) {
    if ($Plat.IsWindows) {
        return Get-CimInstance Win32_Process -Filter "Name='$processName'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($pathPrefix, [StringComparison]::OrdinalIgnoreCase) }
    }
    # macOS: ps gives pid and the full command line; match the executable path prefix in the
    # first field, which is how a venv's own python is told apart from /usr/bin/python3.
    $rows = @()
    foreach ($line in (& ps -axo pid=,command=)) {
        $t = $line.Trim()
        if ($t -match '^(\d+)\s+(\S+)') {
            $exe = $Matches[2]
            if ($exe.StartsWith($pathPrefix) -and $exe -match [regex]::Escape($processName)) {
                $rows += [pscustomobject]@{ ProcessId = [int]$Matches[1]; ExecutablePath = $exe; CommandLine = $t }
            }
        }
    }
    return $rows
}

function Get-ProcessByCommandLine($pattern) {
    if ($Plat.IsWindows) {
        return Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern }
    }
    $rows = @()
    foreach ($line in (& ps -axo pid=,command=)) {
        $t = $line.Trim()
        if ($t -match '^(\d+)\s+(.*)$' -and $Matches[2] -match $pattern) {
            $rows += [pscustomobject]@{ ProcessId = [int]$Matches[1]; CommandLine = $Matches[2] }
        }
    }
    return $rows
}

# --- user locations --------------------------------------------------------------------------
function Get-UserDataDir {
    if ($Plat.IsWindows) { return $env:APPDATA }
    return (Join-Path $HOME 'Library/Application Support')
}

# Where a browser lives, for the panel's chromeless --app window.
function Get-BrowserPath {
    if ($Plat.IsWindows) {
        $candidates = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
                        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                        "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe")
    } else {
        $candidates = @('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
                        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
                        '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser')
    }
    foreach ($p in $candidates) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

# --- autostart -------------------------------------------------------------------------------
# Windows: a shortcut in the Startup folder. macOS: a LaunchAgent plist. Both are per-user, need no
# admin, survive an upgrade untouched, and are visible where that platform's users already look to
# switch a startup item off (Task Manager > Startup apps / System Settings > Login Items).
function Get-AutostartPath {
    if ($Plat.IsWindows) { return (Join-Path ([Environment]::GetFolderPath('Startup')) 'LocalLLM.lnk') }
    return (Join-Path $HOME 'Library/LaunchAgents/com.localllm.stack.plist')
}

function Enable-Autostart($scriptPath, $workingDir) {
    $target = Get-AutostartPath
    if ($Plat.IsWindows) {
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($target)
        $s.TargetPath       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
        $s.WorkingDirectory = $workingDir
        $s.Description      = 'Start the LocalLLM stack at logon'
        $s.IconLocation     = Join-Path $env:SystemRoot 'System32\shell32.dll,15'
        $s.Save()
        return $target
    }
    # UNVERIFIED until Phase 3. RunAtLoad only - deliberately no KeepAlive, because a stack that
    # cannot start should not be respawned in a loop with nobody watching the log.
    $pwshExe = Join-Path (Split-Path $workingDir -Parent) '.pwsh/pwsh'
    if (-not (Test-Path $pwshExe)) { $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
    $plist = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.localllm.stack</string>
  <key>ProgramArguments</key>
  <array>
    <string>$pwshExe</string>
    <string>-NoProfile</string>
    <string>-File</string>
    <string>$scriptPath</string>
  </array>
  <key>WorkingDirectory</key><string>$workingDir</string>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
"@
    $dir = Split-Path $target -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -Path $target -Value $plist -Encoding utf8
    & launchctl load $target 2>$null
    return $target
}

function Disable-Autostart {
    $target = Get-AutostartPath
    if (-not (Test-Path $target)) { return $false }
    if ($Plat.IsMac) { & launchctl unload $target 2>$null }
    Remove-Item $target -Force
    return $true
}

# Present is not the same as enabled, on either platform, and reporting "on" for a machine where it
# will never run is the kind of unverified claim this repo keeps getting caught by. Windows records
# a Task Manager toggle in the registry and leaves the .lnk alone; macOS can have a plist that is
# not loaded.
function Test-AutostartEnabled {
    if (-not (Test-Path (Get-AutostartPath))) { return $false }
    if ($Plat.IsWindows) {
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        $v = (Get-ItemProperty $k -Name 'LocalLLM.lnk' -ErrorAction SilentlyContinue).'LocalLLM.lnk'
        # ponytail: byte 0 odd = disabled is the documented shape of this value; read the rest of
        # the struct only if Microsoft gives it more meanings.
        return -not ($v -and ($v[0] % 2))
    }
    $listed = & launchctl list 2>$null | Select-String -SimpleMatch 'com.localllm.stack'
    return [bool]$listed
}
