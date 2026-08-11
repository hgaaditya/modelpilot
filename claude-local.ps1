# Launch Claude Code against the local stack instead of Anthropic's API.
#
#   .\claude-local.ps1                       # in the current directory, best available model
#   .\claude-local.ps1 -Model qwen3-14b
#   .\claude-local.ps1 -Directory C:\work\api -Resume     # pick the project's session back up
#   .\claude-local.ps1 -Prompt "what does build.ps1 do?"  # one-shot, prints the answer and exits
#   .\claude-local.ps1 -Check                # will this work? - without launching anything
#
# The point of this script is the handoff: you are mid-project, your Claude quota is gone, and you
# want to keep going on the same repo with a local model. So it validates everything that can be
# validated *before* handing over - a model that exists, an engine that can run it, a context big
# enough for Claude Code's own prompt, and a real answer from the Anthropic-shaped endpoint - and
# says which part is wrong when one is. A connection error surfacing inside Claude Code half a
# minute later tells you nothing about which of those five things broke.
#
# The environment is set for this process only, so your normal `claude` sessions are untouched.
# Setting ANTHROPIC_BASE_URL in the user or machine environment would redirect *every* Claude Code
# session on the machine, which is almost never what you want.

[CmdletBinding(PositionalBinding = $false)]
param(
    # A model id from llamaswap\config.yaml. Default: whichever configured model is best suited to
    # agentic work, which is not the same as the biggest one - see Select-AgentModel.
    [string]$Model,

    # Claude Code also reaches for a small, fast model for background work (titles, summaries).
    # Pointing it at the same big model makes every trivial call cost a full swap and reload.
    [string]$SmallModel = 'qwen2.5-0.5b-instruct-q4_k_m',

    # Where to start Claude Code. The whole point is continuing an existing project, and that is
    # rarely this repo, so it can be pointed anywhere without cd-ing there first.
    [string]$Directory,

    [int]$Port = 9292,

    # Report whether a handoff would work right now, then exit. Nothing is launched.
    [switch]$Check,

    # -Check as JSON, for the control panel.
    [switch]$Json,

    # Continue the existing Claude Code session in -Directory instead of starting a new one.
    # A switch rather than the usual `-- --continue`, because `--` is not passed through by
    # `powershell -File script.ps1` - it is parsed as an empty parameter name and the launch fails
    # before the script runs.
    [switch]$Resume,

    # One-shot, non-interactive: run this and print the answer (claude -p). The two cases that
    # matter - resume a session, ask one question - are switches of their own rather than
    # passthrough, because PowerShell prefix-matches parameter names: claude's own -p binds to
    # this script's -Port and fails with a type error that says nothing about what went wrong.
    [string]$Prompt,

    # Anything else for claude itself. Only reliable from a PowerShell session
    # (`.\claude-local.ps1 -ClaudeArgs '--verbose','--debug'`) - under `powershell -File` an array
    # cannot be expressed, and a bare flag risks the same prefix collision as -p above.
    [string[]]$ClaudeArgs = @()
)

$ErrorActionPreference = 'Stop'
$base = "http://127.0.0.1:$Port"
$swapConfig = Join-Path $PSScriptRoot 'llamaswap\config.yaml'

# Claude Code sends its system prompt and every tool definition before your first word - 15-25k
# tokens of it. A model configured with -c 16384 cannot hold that, so the session fails on the
# first message with a context error that looks like the model's fault rather than the config's.
# 32768 is the smallest -c that leaves usable room for an actual conversation on top.
$MIN_AGENT_CTX = 32768

# Context and runnability per model, out of config.yaml. llama-swap's /v1/models lists every
# configured id whether or not it can actually start, and doesn't report -c at all - and both of
# those decide whether a model can be an agent.
# (Third place in this repo that regex-parses config.yaml, after start.ps1 and ui.ps1. If a fourth
# appears, it is time for one shared parser rather than another copy.)
function Get-ModelFacts {
    if (-not (Test-Path $swapConfig)) { return @{} }
    $text = ((Get-Content $swapConfig) | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $parts = [regex]::Split($text, '(?m)^\s{2,}"([^"]+)"\s*:\s*$')
    $out = @{}
    for ($i = 1; $i -lt $parts.Count; $i += 2) {
        $b = $parts[$i + 1]
        $weights = if ($b -match '-m\s+"?([^"\r\n]+?\.gguf)"?') { $Matches[1].Trim() } else { $null }
        $engine = Join-Path $PSScriptRoot $(if ($b -match 'llama-server-prism') { 'llama.cpp-prism' } else { 'llama.cpp' })
        $out[$parts[$i]] = [pscustomobject]@{
            ctx      = if ($b -match '-c\s+(\d+)') { [int]$Matches[1] } else { 0 }
            present  = [bool]($weights -and (Test-Path $weights))
            engineOk = Test-Path (Join-Path $engine 'llama-server.exe')
        }
    }
    $out
}

# Runnable means: weights on disk, an engine to run them, and a context that can hold the agent's
# own prompt. A model failing any of those is not a fallback, it is a 500 a minute from now.
function Test-Runnable($f) { $f -and $f.present -and $f.engineOk -and $f.ctx -ge $MIN_AGENT_CTX }

# Best available agent model: the largest context among the runnable ones, because context is what
# runs out first in a coding session. Deliberately not "the biggest model" - a 20B at -c 16384 is
# useless here and a 14B at -c 65536 is not.
function Select-AgentModel($ids, $facts) {
    $fit = @($ids | Where-Object { Test-Runnable $facts[$_] } | Sort-Object { -$facts[$_].ctx })
    if ($fit.Count) { $fit[0] } else { $null }
}

$report = [ordered]@{ ok = $false; base = $base; model = $null; smallModel = $null
                      context = 0; minContext = $MIN_AGENT_CTX; candidates = @(); problem = $null }

# 1. Is the router up at all?
try { $null = Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 3 }
catch { $report.problem = "llama-swap isn't answering on $base - start the stack first (LocalLLM.cmd, or .\start.ps1)." }

# 2. Which models does it serve, and which of those can hold an agent's prompt?
$known = @()
if (-not $report.problem) {
    try { $known = @((Invoke-RestMethod "$base/v1/models" -TimeoutSec 5).data.id) }
    catch { $report.problem = "llama-swap answered /health but not /v1/models: $($_.Exception.Message)" }
}
$facts = Get-ModelFacts
$report.candidates = @($known | Where-Object { Test-Runnable $facts[$_] } |
                       ForEach-Object { @{ id = $_; context = $facts[$_].ctx } } | Sort-Object { -$_.context })

if (-not $report.problem) {
    if (-not $Model) {
        $Model = Select-AgentModel $known $facts
        if (-not $Model) {
            # Say which of the three requirements nothing meets, rather than just "none found".
            $big = @($known | Where-Object { $facts[$_] -and $facts[$_].ctx -ge $MIN_AGENT_CTX })
            $report.problem = if ($big.Count) {
                "Every model with enough context is missing its weights or its engine: $($big -join ', '). " +
                "Fetch weights with '.\start.ps1 -Action add-model', or run '-Action check-config' for the detail."
            } else {
                "No configured model has a context of at least $MIN_AGENT_CTX, which Claude Code needs for its own " +
                "system prompt and tool definitions. Raise one with " +
                "'.\start.ps1 -Action set-tuning -Id <model> -Context $MIN_AGENT_CTX', or the panel's Models > Edit."
            }
        }
    } elseif ($known -notcontains $Model) {
        $report.problem = "'$Model' isn't in config.yaml. Available: $($known -join ', ')"
    } elseif (-not $facts[$Model].present) {
        $report.problem = "'$Model' is configured but its .gguf isn't on disk - fetch it with '.\start.ps1 -Action add-model'."
    } elseif (-not $facts[$Model].engineOk) {
        $report.problem = "'$Model' needs an engine that isn't installed (run '.\start.ps1 -Action check-config' for the path)."
    }
}
$report.model = $Model
$report.context = if ($Model -and $facts[$Model]) { $facts[$Model].ctx } else { 0 }

# The small model is a convenience, not a requirement: if it isn't there, let Claude Code use the
# main one rather than refusing to start over background work like conversation titles.
if (-not $report.problem -and $known -notcontains $SmallModel) {
    Write-Warning "'$SmallModel' isn't configured, so background calls will use $Model (slower, and each one can trigger a model swap)."
    $SmallModel = $Model
}
$report.smallModel = $SmallModel

# 3. A context warning that is not fatal: the model exists and will run, it just won't get far.
if (-not $report.problem -and $Model -and $facts[$Model].ctx -lt $MIN_AGENT_CTX) {
    Write-Warning ("'$Model' is configured with -c $($facts[$Model].ctx). Claude Code sends 15-25k tokens of system " +
                   "prompt and tool definitions before your first message, so expect it to fail immediately. " +
                   "Raise it to at least $MIN_AGENT_CTX.")
}

# 4. The endpoint Claude Code actually uses. /health being up says nothing about /v1/messages
#    working - that is the Anthropic-shaped surface, and it is what a handoff depends on.
if (-not $report.problem -and $Model) {
    try {
        $body = @{ model = $Model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'hi' }) } | ConvertTo-Json -Depth 5
        $r = Invoke-RestMethod "$base/v1/messages" -Method Post -ContentType 'application/json' `
                 -Body $body -TimeoutSec $(if ($Check) { 900 } else { 60 })
        if (-not $r) { $report.problem = "/v1/messages returned nothing for '$Model'." }
    } catch {
        $report.problem = "/v1/messages failed for '$Model': $($_.Exception.Message)"
    }
}

$report.ok = -not $report.problem

if ($Json) { $report | ConvertTo-Json -Depth 5 -Compress; exit $(if ($report.ok) { 0 } else { 1 }) }

if ($Check) {
    if ($report.ok) {
        Write-Host "Ready. Claude Code can run against $base right now."
        Write-Host "  model:       $($report.model)  (-c $($report.context))"
        Write-Host "  small model: $($report.smallModel)"
        Write-Host ""
        Write-Host "To hand a project over:"
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Directory <your project> -Resume"
    } else {
        Write-Warning $report.problem
        if ($report.candidates.Count) {
            Write-Host "Models with enough context: $(($report.candidates | ForEach-Object { "$($_.id) (-c $($_.context))" }) -join ', ')"
        }
    }
    exit $(if ($report.ok) { 0 } else { 1 })
}

if ($report.problem) { throw $report.problem }

if ($Directory) {
    if (-not (Test-Path $Directory)) { throw "-Directory '$Directory' does not exist." }
    Set-Location $Directory
}

$env:ANTHROPIC_BASE_URL   = $base
$env:ANTHROPIC_AUTH_TOKEN = 'local'      # llama-swap doesn't check it, but the client requires one
$env:ANTHROPIC_MODEL      = $Model
$env:ANTHROPIC_SMALL_FAST_MODEL = $SmallModel
# Local models are far slower than the hosted ones, and the default first-token timeout is
# optimistic once a multi-GB model has to be swapped in before anything can be generated.
$env:API_TIMEOUT_MS       = '600000'

Write-Host "Claude Code -> $base"
Write-Host "  model:       $Model  (-c $($report.context))"
Write-Host "  small model: $SmallModel"
Write-Host "  directory:   $(Get-Location)"
Write-Host ""
if (-not $Resume) { Write-Host "Picking up an existing session in this directory? Add -Resume." ; Write-Host "" }

$a = @()
if ($Resume) { $a += '--continue' }
if ($Prompt) { $a += @('-p', $Prompt) }
$a += $ClaudeArgs
& claude @a
