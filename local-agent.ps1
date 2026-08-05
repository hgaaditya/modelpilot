# Hand a whole task to a local coding agent (OpenCode driving a model on llama-swap).
#
# local-llm.ps1 is one prompt in, one answer out. This is the step up: OpenCode is an agent, so
# it reads files, edits them, runs commands and iterates - all locally, all free - while the
# cloud model that called it only sees the final summary.
#
#   .\local-agent.ps1 -Prompt "Add docstrings to every function in src\utils.py"
#   .\local-agent.ps1 -Prompt "Find and list every TODO with its file and line" -Directory C:\some\repo
#   .\local-agent.ps1 -Prompt "..." -Model gemma4-v2 -ReadOnly
#
# Worth being clear-eyed: agentic work leans hard on reliable tool-calling, and a local 27B is
# much weaker at that than a frontier model. Good for mechanical, well-specified, high-volume
# jobs. Bad for anything needing judgement - keep that on the cloud model that called this.

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt,

    # Must be a model id from llamaswap\config.yaml.
    [string]$Model = 'bonsai-27b',

    # Where the agent operates. Defaults to the current directory.
    [string]$Directory = (Get-Location).Path,

    # Refuse edits: appended as an instruction, since OpenCode has no hard read-only switch.
    # Treat it as a strong hint, not a sandbox - run against a clean git tree either way.
    [switch]$ReadOnly,

    # Let the agent apply edits without asking. Required for any task that writes, because
    # nothing can answer a permission prompt in a scripted run. It is exactly as risky as it
    # sounds with a local model driving - only use it on a clean git tree you can reset.
    [switch]$AutoApprove,

    [int]$Port = 9292,

    # Raw JSON event stream instead of formatted text, for scripting.
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$base = "http://127.0.0.1:$Port"

if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    throw "opencode isn't installed. Run: npm install -g opencode-ai"
}
try { $null = Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 3 }
catch { throw "llama-swap isn't answering on $base - run '.\start.ps1' first." }

$known = (Invoke-RestMethod "$base/v1/models" -TimeoutSec 5).data.id
if ($known -notcontains $Model) { throw "'$Model' isn't in config.yaml. Available: $($known -join ', ')" }
if (-not (Test-Path $Directory)) { throw "No such directory: $Directory" }

$task = $Prompt
if ($ReadOnly) {
    $task = "$Prompt`n`nIMPORTANT: do not modify, create or delete any file. Report your findings as text only."
}

# The provider id must match the one in ~\.config\opencode\opencode.json.
$modelRef = "localllm/$Model"

Write-Host "local-agent: $modelRef  in  $Directory" -ForegroundColor DarkGray

# --dir, not Push-Location: OpenCode resolves its own project root and ignores the caller's
# working directory, which silently sends it off to look at its own temp folder instead.
$cliArgs = @('run', '--model', $modelRef, '--dir', $Directory)
if ($Json)        { $cliArgs += @('--format', 'json') }
if ($AutoApprove) { $cliArgs += '--auto' }
elseif (-not $ReadOnly) {
    Write-Host "note: no -AutoApprove, so edits will stall on a permission prompt nothing can answer." -ForegroundColor DarkYellow
}

# Auto-update would swap the binary mid-run and needs the network; neither is wanted here.
$env:OPENCODE_DISABLE_AUTOUPDATE = '1'
& opencode @cliArgs $task
