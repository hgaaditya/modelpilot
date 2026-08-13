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

    # -Check: how long the tool-use probe gets before it counts as "does not converge". Generous
    # enough for a cold multi-GB load plus a couple of agent turns, short enough to be a check
    # rather than a wait.
    [int]$ProbeTimeoutSec = 300,

    # Which of Claude Code's tools to send. Not a preference - a workaround for a hard llama.cpp
    # limit. Claude Code's built-in Workflow tool declares its `script` parameter with
    # maxLength: 524288; llama.cpp turns a maxLength into a GBNF repetition `char{0,N}`, and
    # 524288 blows the repetition sanity ceiling its own grammar parser enforces. The whole
    # tool-call grammar then fails to compile and every request 400s with
    # "Failed to initialize samplers: failed to parse grammar" - which reads as the model being
    # broken when nothing about the model is involved.
    #
    # --disallowedTools does NOT help: it withholds permission but still sends the schema.
    # Only --tools, which picks the set that gets sent at all, keeps Workflow out of the request.
    # `--tools default` would send everything including Workflow, so it can't be used either.
    #
    # So this is an allow-list of everything EXCEPT Workflow, not a curated minimum. An earlier
    # version copied a short list off a bug report and quietly cost the session the `PowerShell`
    # tool - on Windows, of all things. Unknown names are ignored rather than rejected (verified:
    # `--tools NopeNotARealTool` produces no error), so listing a superset is safe and is the
    # right trade: a tool this misses is silently unavailable, while a tool that doesn't exist
    # costs nothing.
    #
    # NOTE: --tools only filters Claude Code's BUILT-IN tools. Tools contributed by plugins and
    # MCP servers bypass it entirely - measured, a session with 12 built-ins allowed still sent 24
    # tools, the other 14 being one plugin's MCP server. See -NoMcp below.
    #
    # Pass -Tools '' to send everything, i.e. to check whether upstream has fixed the grammar bug.
    # See github.com/ggml-org/llama.cpp issues 25746 / 25923 / 25895.
    [string]$Tools = 'Bash,PowerShell,Read,Write,Edit,NotebookEdit,Glob,Grep,WebFetch,WebSearch,' +
                     'BashOutput,KillShell,Task,Agent,Skill,SlashCommand,TodoWrite,TaskCreate,' +
                     'TaskUpdate,TaskList,TaskGet,TaskOutput,TaskStop,AskUserQuestion,ExitPlanMode',

    # Leave your MCP servers out of this session. Default ON for local models, because the cost is
    # not small and it is invisible: measured on this machine, the first request of an identical
    # task was 4,989 bytes with plugins off and 65,472 bytes with them on - 16,182 tokens, or
    # ~40% of a 40960-token window consumed before you type anything. 33.8 KB of that was tool
    # schemas, 24 tools of which 14 came from a single plugin's MCP server.
    #
    # That is affordable against a 200k cloud window and ruinous against a local one, which is why
    # the default differs from what you would want on the hosted model. --strict-mcp-config with no
    # --mcp-config means "use only the MCP servers I named", i.e. none - and unlike --bare it keeps
    # your hooks, CLAUDE.md and plugin skills, so style plugins still work.
    #
    # -NoMcp:$false restores them if a session genuinely needs an MCP server.
    [bool]$NoMcp = $true,

    # Third-party plugins, and the user-level settings that enable them. Not the same lever as
    # -Bare: this keeps the project's own CLAUDE.md, the built-in tools and skills, and drops only
    # what another workflow installed machine-wide.
    #
    # It exists because a local session came back answering from *other sessions*. The claude-mem
    # plugin's SessionStart hook injects an index of every past conversation on this machine -
    # 18,407 tokens by its own banner - and a 27B model cannot tell background context from the
    # task in front of it, so it answered a question about this repo with a July crash triage.
    # caveman and ponytail inject their whole style documents on top of that.
    #
    # Measured in this repo, against a captured /v1/messages with the defaults below already on
    # (--strict-mcp-config and the -Tools list), counted with llama-swap's own count_tokens:
    #   plugins on   44,284 tokens - 34% of gemma4-v2's 131072, before you type
    #   plugins off  29,231 tokens - 22%
    # 15,053 tokens, and the part that goes is the part that was contaminating the answers.
    #
    # --setting-sources drops the *user* settings file, which is where enabledPlugins lives. That
    # also drops the global ~/.claude/CLAUDE.md, which is this machine's preferences for cloud
    # sessions rather than anything about the repo. Verified by capturing the real request: the
    # project CLAUDE.md is still in it, caveman/ponytail/RTK are not.
    #
    # -NoPlugins:$false restores the lot for a session that wants a specific plugin.
    [bool]$NoPlugins = $true,

    # Everything else a session loads before you type: the CLAUDE.md chain, hooks, plugins and
    # skills. --bare is what -Check already uses, and it exists here because the cost is not small
    # and is invisible until the session dies. Measured against this repo with
    # /v1/messages/count_tokens: the CLAUDE.md files alone are ~13,700 tokens, and there are 136
    # SKILL.md files on this machine whose descriptions come to another ~7,000. Against a 40960
    # window that is a session reporting "Context limit reached" before its first message - which
    # is what it did.
    #
    # Off by default, because a coding session usually wants its project's own instructions. Turn
    # it on when the window is tight and the repo's CLAUDE.md is large.
    [switch]$Bare,

    # Plugins to disable for local sessions only. These inject instructions into every request, so
    # they cost window on every turn while buying behaviour a small quantised model follows less
    # reliably than a frontier one does. Disabled here rather than in the user's own settings, so
    # their normal cloud sessions are unaffected.
    #
    # Measured on this machine, same task and model, first request to the main model:
    #
    #   everything on                     65,472 bytes   16,182 tokens   40% of a 40960 window
    #   MCP excluded (-NoMcp)             57,164 bytes   13,856 tokens   34%
    #   + these plugins off               46,821 bytes   11,392 tokens   28%
    #
    # These plugins inject through the MESSAGES, not the system block - the system block is
    # Claude Code's own prompt and is 6,200 characters either way. Turning them off took the
    # message content from 25,536 to 15,063 characters, about 10.5 KB per request, re-sent every
    # turn because the API is stateless. The best output saving observed in return was 7.6% -
    # roughly 50 tokens on a 700-token answer. To break even a style instruction would have to cut
    # ~2,400 tokens per turn, which means 5,000-token responses; agentic turns are nowhere near it.
    #
    # The same plugins are a good deal on the hosted model, which is why this default differs from
    # what you would want there: 2,400 tokens against a 200k window is noise and the output saving
    # is real money. Against 40960 it is 6% of the window per turn, spent in the currency you are
    # short of - and a small quantised model follows sustained style rules less reliably anyway.
    #
    # Pass -NoStylePlugins @() to keep them, or name your own list.
    [string[]]$NoStylePlugins = @('ponytail@ponytail', 'caveman@caveman'),

    # Resume one specific conversation by its id. Claude Code keeps every session as
    # ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl, and -r/--resume takes that id, so the
    # panel can list real sessions and hand one straight back - which is the actual "my quota ran
    # out mid-project" move, rather than starting somewhere new.
    [string]$SessionId,

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

# Settings handed to Claude Code for this session only, via --settings. The one that matters:
#
#   CLAUDE_CODE_ATTRIBUTION_HEADER=0
#
# Claude Code injects an x-anthropic-billing-header string as a text block at the FRONT of the
# system prompt, and its cch= segment changes on every request. llama.cpp's prompt cache matches
# on a prefix, so a prefix that differs every turn means the cache never hits and the entire
# context - 20k+ tokens of system prompt and tool definitions - is reprocessed from scratch on
# every single turn. Reported at roughly 90% slower, and it matches what was measured here before
# this existed: ~45s per turn on a model that does 2300 tok/s of prompt processing.
#
# It has to be a settings file: `export CLAUDE_CODE_ATTRIBUTION_HEADER=0` is ignored when routing
# through ANTHROPIC_BASE_URL. Written per-run rather than into the user's ~/.claude/settings.json,
# for the same reason this script sets ANTHROPIC_BASE_URL for one process only - a global change
# would follow every other Claude Code session on the machine.
# Everything Claude Code needs to talk to llama-swap instead of Anthropic, set for THIS process
# only. Shared by the -Check probe and the real launch so the two cannot drift - a probe that
# passes under different settings than the session it is vouching for is worthless.
function Set-LocalEnv($ctx) {
    # Claude Code marks every process it spawns with CLAUDE_CODE_CHILD_SESSION, and a session
    # carrying that marker does not write a transcript. The marker is inherited by anything
    # launched from a Claude Code session - this script, the control panel, and the terminal the
    # panel opens - so a handoff started from inside a dying session came up with
    # "Transcript saving is off" and left no .jsonl behind.
    #
    # That is not cosmetic and it is not an edge case: launching the handoff from the session whose
    # quota just ran out is the exact scenario this script exists for, and the panel's Hand over
    # list is read from those .jsonl files. A local session started that way would silently never
    # appear in it, so the next handoff cannot resume the work the last one did.
    #
    # The session ids go with it - a new, independent session must not claim the id of the one that
    # launched it. Cleared for this process only, like everything else here.
    foreach ($v in 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_HOST_SESSION_ID') {
        if (Test-Path "env:$v") { Remove-Item "env:$v" }
    }
    $env:ANTHROPIC_BASE_URL   = $base
    $env:ANTHROPIC_AUTH_TOKEN = 'local'      # llama-swap doesn't check it, but the client requires one
    $env:ANTHROPIC_MODEL      = $Model
    $env:ANTHROPIC_SMALL_FAST_MODEL = $SmallModel
    # Claude Code also asks for model tiers by name - it fires background requests at
    # claude-haiku-4-5-* for titles and tool checks, dozens before your first real turn. Left
    # unmapped those hit llama-swap as an unknown model. Pointing every tier at something that
    # exists here keeps the housekeeping off the big model and out of the error log.
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = $SmallModel
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $Model
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL   = $Model
    # Local models are far slower than the hosted ones, and the default first-token timeout is
    # optimistic once a multi-GB model has to be swapped in before anything can be generated.
    $env:API_TIMEOUT_MS = '600000'
    # See the note on CLAUDE_CODE_MAX_CONTEXT_TOKENS below - without it Claude Code assumes 200k.
    $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = "$ctx"
}

function New-SessionSettings {
    $f = Join-Path $env:TEMP 'localllm-claude-settings.json'
    $s = @{ env = @{ CLAUDE_CODE_ATTRIBUTION_HEADER = '0' } }
    # Style plugins are re-sent in full on every request, because the API is stateless - they are a
    # per-turn tax on the context window, not a one-off. Measured here, the injected style blocks
    # were 6,200 characters. Against a 200k cloud window that is nothing; against 40960 it is real.
    # -NoStylePlugins names the ones to switch off for local sessions only, leaving the user's own
    # ~/.claude/settings.json untouched - the same principle as setting ANTHROPIC_BASE_URL for one
    # process rather than the machine.
    if ($NoStylePlugins.Count) {
        $s.enabledPlugins = @{}
        foreach ($p in $NoStylePlugins) { $s.enabledPlugins[$p] = $false }
    }
    $s | ConvertTo-Json -Depth 4 | Set-Content $f -Encoding utf8
    $f
}

# Which models have actually been shown to work with Claude Code, as opposed to merely answering
# a request. The distinction is not academic: bonsai-27b answers every synthetic payload thrown at
# it - plain, system-as-blocks, tools, a full tool_use/tool_result round trip - and then fails
# Claude Code itself with 'Jinja Exception: System message must be at the beginning'. So the only
# probe that tells the truth is running Claude Code, and the only way not to re-run it every time
# is to remember the answer. Per machine, hence gitignored: it depends on the local build.
$compatFile = Join-Path $PSScriptRoot '.agent-compat.json'

function Get-Compat {
    if (-not (Test-Path $compatFile)) { return @{} }
    try {
        $h = @{}
        (Get-Content $compatFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
        $h
    } catch { @{} }
}

function Set-Compat($id, $ok, $reason) {
    $h = Get-Compat
    $h[$id] = [pscustomobject]@{ ok = [bool]$ok; reason = "$reason"
                                 at = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    $h | ConvertTo-Json -Depth 5 | Set-Content $compatFile -Encoding utf8
}

# A resumed conversation is replayed in full, images included - and these GGUFs are text-only, so
# llama-server answers "500 image input is not supported" and Claude Code retries it ten times
# because a 500 reads as transient. Nothing about that names the actual cause, and the session
# never recovers: the images are in the history, so every turn resends them.
#
# Caught the first time Hand over was pointed at a real conversation - this repo's own, which had
# 11 pasted screenshots in it. Any cloud session where you pasted an image has the same problem.
# Scanned by line rather than parsed: these transcripts are megabytes of tool output and the only
# question is whether the marker appears at all.
function Get-TranscriptImageCount($sessionId) {
    $root = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path $root)) { return 0 }
    # Session ids are unique, so the encoded directory name doesn't have to be reconstructed -
    # which is just as well, since it maps both ':' and '' to '-' and isn't reversible.
    $f = Get-ChildItem $root -Recurse -Filter "$sessionId.jsonl" -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if (-not $f) { return 0 }
    @(Select-String -Path $f.FullName -Pattern '"type"\s*:\s*"image"' -AllMatches -ErrorAction SilentlyContinue).Count
}

# A floor for the model list, not a measured requirement. Claude Code's own fixed overhead was
# measured here at ~1.1k tokens per request (379 for the background model, 1091 for the main one
# with 3 tools), counted through llama-swap's /v1/messages/count_tokens on payloads captured from
# a real session - nowhere near the 15-25k this script used to claim, and 32768 passes the probe
# directly. What actually eats a window is conversation history, file contents and tool output.
#
# So this is a "will not be miserable" line rather than a hard limit: a coding session accumulates
# fast, and 16384 leaves almost nothing after a couple of file reads. The probe is what decides
# whether a model works; this only keeps obviously cramped ones out of the list.
#
# It is also a floor rather than a typical case: the probe runs --bare, so a session carrying a
# user's own CLAUDE.md, plugins and MCP servers costs more than the numbers above.
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

# Best available agent model: among the runnable ones, whichever has the largest context - because
# context is what runs out first in a coding session. Deliberately not "the biggest model": a 20B
# at -c 16384 is useless here and a 14B at -c 65536 is not.
#
# Context is the tie-breaker, NOT the first sort key. A model that -Check has already watched fail
# Claude Code is never picked, and a verified one always beats an untested one - because the
# alternative is what this actually did: it handed every session to the largest-context model on
# the box, which was one that 400s on its own chat template, and the failure surfaced inside Claude
# Code where it reads as the handoff being broken. The panel filtered that model out of its
# dropdown and this function did not, so the two disagreed about the default.
function Select-AgentModel($ids, $facts) {
    $compat = Get-Compat
    $rank = {
        param($id)
        $c = $compat[$id]
        if ($null -eq $c) { 1 } elseif ($c.ok) { 0 } else { 2 }   # verified, untested, known-bad
    }
    # Parenthesised deliberately: `Test-Runnable $x -and $y` binds -and as a PARAMETER of
    # Test-Runnable rather than as an operator, and the filter then passes everything.
    $fit = @($ids | Where-Object { (Test-Runnable $facts[$_]) -and (& $rank $_) -lt 2 } |
             Sort-Object @{ Expression = { & $rank $_ } }, @{ Expression = { -$facts[$_].ctx } })
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
            # Say which of the four requirements nothing meets, rather than just "none found".
            $big = @($known | Where-Object { $facts[$_] -and $facts[$_].ctx -ge $MIN_AGENT_CTX })
            $compat = Get-Compat
            $rejected = @($known | Where-Object { (Test-Runnable $facts[$_]) -and $compat[$_] -and -not $compat[$_].ok })
            $report.problem = if ($rejected.Count) {
                "Every model that could run this has already been shown to fail Claude Code: " +
                "$(($rejected | ForEach-Object { "$_ ($($compat[$_].reason))" }) -join '; '). " +
                "Pass -Model to try one anyway, or add a model that works."
            } elseif ($big.Count) {
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
    Write-Warning ("'$Model' is configured with -c $($facts[$Model].ctx). Claude Code's own overhead is small " +
                   "(~1.1k tokens), but a coding session fills a window fast with file contents and tool output, " +
                   "so expect to be compacting constantly. Raise it to at least $MIN_AGENT_CTX.")
}

# What the session carries before you type anything. Every overhead number this repo has published
# for Claude Code (~1.1k tokens per request) came from the -Check probe, which runs --bare - so all
# of them are a floor that excludes precisely the things a real session loads. Measured here with
# /v1/messages/count_tokens against this repo: the CLAUDE.md chain alone is ~13,700 tokens, a third
# of a 40960 window, spent before the first message. Unstated, that arrives as "Context limit
# reached" on a session that has done nothing, and reads as the model or the handoff being broken.
#
# Counted, not estimated - the router is already up and count_tokens is free. @imports inside a
# CLAUDE.md are not followed, so this is still a floor, and skills and hooks are on top of it.
if (-not $Bare -and -not $Check -and -not $report.problem -and $Model) {
    $ctxFiles = @()
    $d = Get-Item -LiteralPath $(if ($Directory) { $Directory } else { (Get-Location).Path }) -ErrorAction SilentlyContinue
    while ($d) { $f = Join-Path $d.FullName 'CLAUDE.md'; if (Test-Path $f) { $ctxFiles += $f }; $d = $d.Parent }
    $g = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'
    if (Test-Path $g) { $ctxFiles += $g }
    if ($ctxFiles.Count) {
        $text = ($ctxFiles | ForEach-Object { Get-Content $_ -Raw }) -join "`n"
        # Body as explicit UTF-8 bytes. PowerShell 5.1 otherwise encodes the string as Latin-1, and
        # a CLAUDE.md full of em dashes then arrives as ill-formed UTF-8 - llama-swap answers 500
        # with an error OBJECT rather than an HTTP failure, so this doesn't throw either: it just
        # yields a null token count. Same bug local-llm.ps1 already carries the fix for.
        $payload = @{ model = $Model; messages = @(@{ role = 'user'; content = $text }) } | ConvertTo-Json -Depth 5
        $n = try {
            (Invoke-RestMethod "$base/v1/messages/count_tokens" -Method Post -ContentType 'application/json' `
                 -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 30).input_tokens
        } catch { $null }
        # A character estimate beats saying nothing, which is how this cost stayed invisible.
        if (-not $n) { $n = [int]($text.Length / 4) }
        $pct = [int](100 * $n / [Math]::Max(1, $report.context))
        $line = "CLAUDE.md will cost ~$n tokens ($pct% of this model's $($report.context)), before skills, hooks and your first message."
        if ($pct -ge 25) { Write-Warning "$line Add -Bare to leave all of it out." } else { Write-Host "  project docs: ~$n tokens ($pct%)" }
    }
}

if ($SessionId -and -not $report.problem) {
    $imgs = Get-TranscriptImageCount $SessionId
    if ($imgs) {
        Write-Warning ("That conversation contains $imgs image(s), and these models are text-only. Claude Code replays the " +
                       "whole history on resume, so llama-server will answer '500 image input is not supported' and the " +
                       "client will retry it ten times. Start a fresh session in this directory instead - the files are " +
                       "the same, only the chat history is lost.")
        Write-Host ""
    }
}

# 4. The endpoint Claude Code actually uses. /health being up says nothing about /v1/messages
#    working - that is the Anthropic-shaped surface, and it is what a handoff depends on.
if (-not $report.problem -and $Model) {
    # This request is what actually loads the weights, so on a cold start it is where all the time
    # goes - tens of seconds for a multi-GB model. Say so: with nothing printed, the console this
    # was launched into sits blank and the handoff looks hung.
    Write-Host "Warming '$Model' - this request is what loads the weights, so a cold start takes 10-60s..."
    try {
        $body = @{ model = $Model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'hi' }) } | ConvertTo-Json -Depth 5
        # 300s, matching healthCheckTimeout in config.yaml, not 60. A 27B loading from a cold page
        # cache overran the old 60s ceiling and the launch aborted with "/v1/messages failed" -
        # reporting a broken endpoint for a model that was simply still loading.
        $r = Invoke-RestMethod "$base/v1/messages" -Method Post -ContentType 'application/json' `
                 -Body $body -TimeoutSec $(if ($Check) { 900 } else { 300 })
        if (-not $r) { $report.problem = "/v1/messages returned nothing for '$Model'." }
    } catch {
        $report.problem = "/v1/messages failed for '$Model': $($_.Exception.Message)"
    }
}

# 5. The only probe that tells the truth: Claude Code itself, one shot, no tools needed. It costs
#    a model load and about half a minute, and it is the step that separates "the endpoint
#    answers" from "a session will hold together". Both known failures showed up here and nowhere
#    else - one in 29 seconds with a 400 from the chat template, one by never converging.
if ($Check -and -not $report.problem) {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        $report.problem = "Claude Code isn't on PATH, so the handoff can't be tested. Install it first."
    } else {
        # The probe has to make Claude Code actually CALL a tool, not just answer. A plain question
        # ("reply with the word ok") passed on a model that then died the instant real work started
        # with 'Failed to initialize samplers: failed to parse grammar' - llama.cpp compiles the
        # tool schemas into a GBNF grammar only when it constrains output to a tool call, so a
        # prompt that needs no tool never reaches the code that breaks. That false "verified" is
        # worse than no check at all, hence a scratch file with a deliberately unguessable
        # function name: the model cannot answer without reading it.
        $probeDir = Join-Path $env:TEMP 'localllm-agent-probe'
        New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
        Set-Content (Join-Path $probeDir 'probe_target.py') "def marmalade_sprocket(a, b):`n    return a + b`n" -Encoding utf8
        $logOut = Join-Path $probeDir 'out.txt'; $logErr = Join-Path $probeDir 'err.txt'

        Write-Host "Running Claude Code against '$Model' - it has to load the model and use a tool, so give it a minute..."
        Set-LocalEnv $report.context
        # Bounded, because "never converges" is one of the two ways this fails and an unbounded
        # probe would simply hang instead of reporting it.
        # --bare skips hooks, plugins and LSP. Without it the probe measures the user's Claude Code
        # setup rather than the model: on this machine a SessionStart hook's own output came back
        # as the answer ("Summary of previous conversation in SessionStart hook..."), failing a
        # model that had done nothing wrong. A compatibility verdict has to be about the model.
        # The path is absolute because Claude Code's Read tool requires one. Given a bare filename
        # a model does the right thing and asks for the absolute path - and in -p mode there is
        # nobody to answer, so the probe recorded a correct model as broken. The probe has to test
        # the model, not whether it can guess the working directory.
        # Start-Process joins -ArgumentList with spaces and does NOT quote elements that contain
        # spaces, so a prompt passed as one array element arrives word-split: claude saw -p "Read"
        # followed by loose garbage, and the model - correctly - replied that it did not know
        # which file was meant. Every element that can contain a space is quoted here by hand.
        $probeFile = Join-Path $probeDir 'probe_target.py'
        $prompt = "Read the file $probeFile and reply with only the name of the function it defines."
        $probeArgs = @('-p', "`"$prompt`"", '--bare', '--settings', "`"$(New-SessionSettings)`"")
        if ($Tools) { $probeArgs += @('--tools', $Tools) }
        $p = Start-Process -FilePath (Get-Command claude).Source -PassThru -WindowStyle Hidden `
                 -WorkingDirectory $probeDir -RedirectStandardOutput $logOut -RedirectStandardError $logErr `
                 -ArgumentList $probeArgs
        if (-not $p.WaitForExit($ProbeTimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            $report.problem = "Claude Code did not finish within $ProbeTimeoutSec s against '$Model' - it can answer, " +
                              "but it does not converge on a task that needs a tool call. Usable for direct questions, not for agent work."
        } else {
            $text = ((Get-Content $logOut, $logErr -ErrorAction SilentlyContinue) -join ' ').Trim()
            if ($text -match 'API Error|Jinja|failed to parse grammar|error:') {
                # Keep the model's own words - "System message must be at the beginning" and
                # "failed to parse grammar" are each the whole diagnosis.
                $one = ($text -replace '\s+', ' ')
                $m = [regex]::Match($one, '(API Error.*|Jinja.*|error:.*)')
                $report.problem = "Claude Code failed against '$Model': " +
                                  $(if ($m.Success) { $m.Value.Substring(0, [Math]::Min(220, $m.Value.Length)) } else { $one.Substring(0, [Math]::Min(220, $one.Length)) })
            } elseif ($text -notmatch 'marmalade_sprocket') {
                $report.problem = "Claude Code answered against '$Model' but got the tool-use probe wrong " +
                                  "(expected 'marmalade_sprocket', got: $(($text -replace '\s+', ' ').Substring(0, [Math]::Min(120, $text.Length))))."
            }
        }
    }
}

$report.ok = -not $report.problem
if ($Check -and $Model) { Set-Compat $Model $report.ok $report.problem }

if ($Json) { $report | ConvertTo-Json -Depth 5 -Compress; exit $(if ($report.ok) { 0 } else { 1 }) }

if ($Check) {
    if ($report.ok) {
        Write-Host "Ready. Claude Code drove '$($report.model)' through a tool call and got the right answer."
        Write-Host "  model:       $($report.model)  (-c $($report.context))"
        Write-Host "  small model: $($report.smallModel)"
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

# CLAUDE_CODE_MAX_CONTEXT_TOKENS, set inside Set-LocalEnv, is the one that decides whether this is
# usable at all. Claude Code doesn't recognise these model ids, so it assumes a 200k context window
# and runs auto-compact against that assumption - while the model behind it has whatever -c
# config.yaml gave it. Left unset against a 65536 model, a one-word question turned into 84
# requests over 27 minutes, with single responses of 3.6 MB: the client kept feeding a history the
# model could not hold, so it never converged.
#
# Same failure the rest of this stack already documents for open-webui and continue.dev - the
# client can only prune correctly if it knows the real budget - and the number is right here,
# parsed out of the model's own -c.
Set-LocalEnv $report.context

Write-Host "Claude Code -> $base"
Write-Host "  model:       $Model  (-c $($report.context))"
Write-Host "  small model: $SmallModel"
Write-Host "  directory:   $(Get-Location)"
Write-Host "  context:     $($report.context) tokens (told to Claude Code, which would otherwise assume 200k)"
Write-Host "  extras:      MCP $(if ($NoMcp) { 'off' } else { 'on' }), plugins $(if ($NoPlugins) { 'off' } else { 'on' }) - project CLAUDE.md, skills and built-in tools stay either way"
Write-Host ""
if (-not $Resume) { Write-Host "Picking up an existing session in this directory? Add -Resume." ; Write-Host "" }

$a = @('--settings', "`"$(New-SessionSettings)`"")
if ($NoMcp) { $a += '--strict-mcp-config' }   # see -NoMcp: MCP tool schemas are ~40% of a local window
# see -NoPlugins: user settings hold enabledPlugins, and one of them injects every past session
if ($NoPlugins) { $a += @('--setting-sources', 'project,local') }
if ($Bare)  { $a += '--bare' }                # see -Bare: CLAUDE.md + skills measured at ~20k here
# A specific session wins over "the most recent one" - if you picked it, you meant it.
if ($SessionId) { $a += @('--resume', $SessionId) }
elseif ($Resume) { $a += '--continue' }
if ($Prompt) { $a += @('-p', $Prompt) }
# Keeps the Workflow tool's 524288-character maxLength out of the request - see -Tools above.
if ($Tools) { $a += @('--tools', $Tools) }
$a += $ClaudeArgs
& claude @a
