[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$start = Get-Content (Join-Path $root 'start.ps1') -Raw
$block = [regex]::Match($start, '(?ms)^\$VER\s*=\s*@\{(.*?)^\}').Groups[1].Value
if (-not $block) { throw 'Could not find the $VER table in start.ps1.' }
$pins = @{}
foreach ($match in [regex]::Matches($block, "(?m)^\s{4}(\w+)\s*=\s*'([^']+)'")) {
    $pins[$match.Groups[1].Value] = $match.Groups[2].Value
}
foreach ($key in 'llamaCpp', 'llamaSwap', 'openWebUI', 'node', 'uv', 'llmfit') {
    if (-not $pins.ContainsKey($key)) { throw "Missing $key in start.ps1 `$VER." }
}
$productVersion = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
if ($productVersion -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "VERSION is not semver: $productVersion" }

function Component($name, $version, $purl, $url) {
    [ordered]@{ type = 'application'; name = $name; version = $version; purl = $purl
                externalReferences = @([ordered]@{ type = 'distribution'; url = $url }) }
}
$manifest = [ordered]@{
    '$schema' = 'https://cyclonedx.org/schema/bom-1.5.schema.json'
    bomFormat = 'CycloneDX'
    specVersion = '1.5'
    serialNumber = 'urn:uuid:4f837d9e-36d4-4b2d-aecb-b4c045adb8a5'
    version = 1
    metadata = [ordered]@{ component = [ordered]@{ type = 'application'; name = 'Model Pilot'; version = $productVersion
        licenses = @([ordered]@{ license = [ordered]@{ id = 'MIT' } }) } }
    components = @(
        (Component 'llama.cpp' $pins.llamaCpp "pkg:github/ggml-org/llama.cpp@$($pins.llamaCpp)" 'https://github.com/ggml-org/llama.cpp/releases'),
        (Component 'llama-swap' $pins.llamaSwap "pkg:github/mostlygeek/llama-swap@$($pins.llamaSwap)" 'https://github.com/mostlygeek/llama-swap/releases'),
        (Component 'Open WebUI' $pins.openWebUI "pkg:github/open-webui/open-webui@$($pins.openWebUI)" "https://github.com/open-webui/open-webui/releases/tag/v$($pins.openWebUI)"),
        (Component 'Node.js' ($pins.node -replace '^v', '') "pkg:generic/node@$($pins.node -replace '^v', '')" "https://nodejs.org/dist/$($pins.node)/"),
        (Component 'uv' $pins.uv "pkg:github/astral-sh/uv@$($pins.uv)" "https://github.com/astral-sh/uv/releases/tag/$($pins.uv)"),
        (Component 'llmfit' $pins.llmfit "pkg:github/AlexsJones/llmfit@$($pins.llmfit)" "https://github.com/AlexsJones/llmfit/releases/tag/$($pins.llmfit)")
    )
}
$json = $manifest | ConvertTo-Json -Depth 10
$path = Join-Path $root 'supply-chain.json'
if ($Check) {
    if (-not (Test-Path $path)) { throw 'supply-chain.json is missing; run tools/Sync-SupplyChainManifest.ps1.' }
    $actual = (Get-Content $path -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10)
    if ($actual -ne $json) { throw 'supply-chain.json is stale; run tools/Sync-SupplyChainManifest.ps1.' }
    Write-Host 'supply-chain.json matches start.ps1 $VER and VERSION.'
    return
}
[IO.File]::WriteAllText($path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Write-Host 'Generated supply-chain.json from start.ps1 $VER and VERSION.'
