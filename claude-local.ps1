# Launch Claude Code against the local stack instead of Anthropic's API.
#
#   .\claude-local.ps1                 # uses bonsai-27b
#   .\claude-local.ps1 -Model qwen3-14b
#   .\claude-local.ps1 -- --continue   # anything after -- goes to claude itself
#
# The environment is set for this process only, so your normal `claude` sessions are untouched.
# Setting ANTHROPIC_BASE_URL in the user or machine environment would redirect *every* Claude
# Code session, which is almost never what you want.

[CmdletBinding(PositionalBinding = $false)]
param(
    # Must be a model id from llamaswap\config.yaml.
    [string]$Model = 'bonsai-27b',

    # Claude Code also reaches for a small, fast model for background work (titles, summaries).
    # Pointing it at the same big model makes every trivial call cost a full swap+load.
    [string]$SmallModel = 'qwen2.5-0.5b-instruct-q4_k_m',

    [int]$Port = 9292,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ClaudeArgs
)

$ErrorActionPreference = 'Stop'
$base = "http://127.0.0.1:$Port"

# Fail early with a clear message rather than letting Claude Code report a connection error.
try {
    $null = Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 3
} catch {
    throw "llama-swap isn't answering on $base - run '.\start.ps1' first."
}

$known = (Invoke-RestMethod "$base/v1/models" -TimeoutSec 5).data.id
foreach ($m in @($Model, $SmallModel)) {
    if ($known -notcontains $m) {
        throw "'$m' isn't in config.yaml. Available: $($known -join ', ')"
    }
}

$env:ANTHROPIC_BASE_URL   = $base
$env:ANTHROPIC_AUTH_TOKEN = 'local'      # llama-swap doesn't check it, but the client requires one
$env:ANTHROPIC_MODEL      = $Model
$env:ANTHROPIC_SMALL_FAST_MODEL = $SmallModel
# Local models are far slower than the hosted ones; the default first-token timeout is optimistic
# once a multi-GB model has to be swapped in.
$env:API_TIMEOUT_MS       = '600000'

Write-Host "Claude Code -> $base"
Write-Host "  model:       $Model"
Write-Host "  small model: $SmallModel"
Write-Host ""

& claude @ClaudeArgs
