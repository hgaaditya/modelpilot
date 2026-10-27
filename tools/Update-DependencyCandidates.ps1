[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Json,
    [string]$CandidateVersion
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$headers = @{ 'User-Agent' = 'model-pilot-dependency-check' }
if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $env:GITHUB_TOKEN" }

if ($CandidateVersion -and -not $Apply) {
    throw 'CandidateVersion requires -Apply.'
}
if ($CandidateVersion -and $CandidateVersion -notmatch '^\d+\.\d+\.\d+-deps\.\d+$') {
    throw "CandidateVersion must be a dependency prerelease such as 0.1.17-deps.123. Got '$CandidateVersion'."
}

function Get-LatestNode22 {
    $text = (Invoke-WebRequest -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing).Content
    $match = [regex]::Match($text, '"version":"(v22[^"]+)"')
    if (-not $match.Success) { throw 'Could not find a current Node.js v22 release.' }
    $match.Groups[1].Value
}
function Test-NodeWindowsZip($version) {
    $text = (Invoke-WebRequest -Uri "https://nodejs.org/dist/$version/SHASUMS256.txt" -UseBasicParsing).Content
    if ($text -notmatch [regex]::Escape("node-$version-win-x64.zip")) { throw "Node.js $version has no win-x64 zip distribution." }
}

function Get-Pins {
    $text = Get-Content (Join-Path $root 'start.ps1') -Raw
    $block = [regex]::Match($text, '(?ms)^\$VER\s*=\s*@\{(.*?)^\}').Groups[1].Value
    if (-not $block) { throw 'Could not find the $VER table in start.ps1.' }
    $pins = @{}
    foreach ($match in [regex]::Matches($block, "(?m)^\s{4}(\w+)\s*=\s*'([^']+)'")) { $pins[$match.Groups[1].Value] = $match.Groups[2].Value }
    $pins
}
function Get-Release($repo, $tag) {
    $url = if ($tag) { "https://api.github.com/repos/$repo/releases/tags/$tag" } else { "https://api.github.com/repos/$repo/releases/latest" }
    Invoke-RestMethod -Uri $url -Headers $headers
}
function Require-Asset($release, $pattern, $component) {
    if (-not @($release.assets | Where-Object { $_.name -match $pattern })) { throw "$component $($release.tag_name) has no asset matching $pattern" }
}
function Test-ReleaseAssets($pins) {
    $llama = Get-Release 'ggml-org/llama.cpp' $pins.llamaCpp
    Require-Asset $llama '^llama-.*-bin-win-cpu-x64\.zip$' 'llama.cpp'
    Require-Asset $llama '^llama-.*-bin-win-cuda-.*-x64\.zip$' 'llama.cpp'
    Require-Asset $llama '^cudart-.*-x64\.zip$' 'llama.cpp'
    $swap = Get-Release 'mostlygeek/llama-swap' $pins.llamaSwap
    Require-Asset $swap 'windows_amd64\.zip$' 'llama-swap'
    $webui = Get-Release 'open-webui/open-webui' "v$($pins.openWebUI)"
    if (-not $webui) { throw "Open WebUI v$($pins.openWebUI) was not found." }
    $uv = Get-Release 'astral-sh/uv' $pins.uv
    Require-Asset $uv 'uv-x86_64-pc-windows-msvc\.zip$' 'uv'
    $llmfit = Get-Release 'AlexsJones/llmfit' $pins.llmfit
    Require-Asset $llmfit 'x86_64-pc-windows-msvc\.zip$' 'llmfit'
    Test-NodeWindowsZip $pins.node
}

$pins = Get-Pins
$candidates = @{}
$candidates.llamaCpp = (Get-Release 'ggml-org/llama.cpp' $null).tag_name
$candidates.llamaSwap = (Get-Release 'mostlygeek/llama-swap' $null).tag_name
$candidates.openWebUI = ((Get-Release 'open-webui/open-webui' $null).tag_name -replace '^v', '')
$candidates.uv = (Get-Release 'astral-sh/uv' $null).tag_name
$candidates.llmfit = (Get-Release 'AlexsJones/llmfit' $null).tag_name
$node = Get-LatestNode22
Test-NodeWindowsZip $node
$candidates.node = $node
$assetError = $null
try { Test-ReleaseAssets $candidates } catch { $assetError = $_.Exception.Message }
if ($assetError) {
    $result = [ordered]@{ changed = $false; changes = @(); pins = $pins; candidates = $candidates; blocked = $assetError }
    if ($Json) { $result | ConvertTo-Json -Depth 6 -Compress }
    throw "No PR created: $assetError"
}

$changes = @()
foreach ($key in 'llamaCpp', 'llamaSwap', 'openWebUI', 'node', 'uv', 'llmfit') {
    if ($pins[$key] -ne $candidates[$key]) { $changes += [ordered]@{ component = $key; from = $pins[$key]; to = $candidates[$key] } }
}
if ($Apply -and $changes.Count) {
    if ($CandidateVersion) {
        [IO.File]::WriteAllText((Join-Path $root 'VERSION'), $CandidateVersion + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
    $path = Join-Path $root 'start.ps1'
    $text = Get-Content $path -Raw
    foreach ($change in $changes) {
        $pattern = "(?m)^(\s{4}$([regex]::Escape($change.component))\s*=\s*')[^']+('.*)$"
        $text = [regex]::Replace($text, $pattern, "`$1$($change.to)`$2", 1)
    }
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    & (Join-Path $PSScriptRoot 'Sync-SupplyChainManifest.ps1')
}
$result = [ordered]@{ changed = [bool]$changes.Count; changes = @($changes); pins = $pins; candidates = $candidates }
if ($Json) { $result | ConvertTo-Json -Depth 6 -Compress } else {
    if ($changes) { $changes | ForEach-Object { Write-Host "$($_.component): $($_.from) -> $($_.to)" } }
    else { Write-Host 'No newer supported upstream releases found.' }
}
