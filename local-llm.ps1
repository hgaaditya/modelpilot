# Run a prompt against the local stack and print only the answer.
#
# The point is delegation: an agent (Claude Code, or you) keeps planning and orchestration on a
# cloud model, and hands the token-heavy grinding to a local model that costs nothing per token.
# Only the result crosses back, so a 200k-token log never enters the cloud model's context.
#
#   .\local-llm.ps1 -Prompt "List every distinct error and how often it appears" -File logs\app.log
#   Get-Content big.json | .\local-llm.ps1 -Prompt "Extract every user id as one per line"
#   .\local-llm.ps1 -Prompt "Summarise" -File a.txt -Model gemma4-v2
#
# Claude Code cannot split its own traffic between two endpoints - ANTHROPIC_BASE_URL is global
# per process - so this is a tool it shells out to, not a second backend.

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt,

    # File(s) to feed in as context. Without this, reads stdin if piped.
    [string[]]$File,

    [string]$Model = 'gemma4-v2',

    [int]$Port = 9292,

    [int]$MaxTokens = 2048,

    # Roughly the model's -c minus room for the reply. Input above this is processed in chunks.
    [int]$ChunkTokens = 40000,

    # Print timing and chunk progress to stderr (stdout stays clean for piping).
    [switch]$ShowStats
)

$ErrorActionPreference = 'Stop'
$base = "http://127.0.0.1:$Port"

# Logs and dumps are exactly the input this tool is for, and they routinely contain bytes that
# aren't valid UTF-8 (ANSI fragments, terminal escapes, truncated writes). Decoding them to
# U+FFFD and stripping the result keeps the JSON body well-formed - llama-server rejects the
# whole request with a parse error otherwise.
function Read-AsCleanText($path) {
    # Share ReadWrite+Delete: the obvious input for this tool is a log a process is still writing
    # to, and ReadAllBytes asks for a share mode the live writer already denies - it fails with
    # "being used by another process" on exactly the files this exists for.
    $fs = [IO.File]::Open((Resolve-Path $path), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite,Delete')
    $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
    try { $text = $sr.ReadToEnd() } finally { $sr.Dispose(); $fs.Dispose() }
    ($text -replace '�', '') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
}

$body = if ($File) {
    ($File | ForEach-Object {
        if (-not (Test-Path $_)) { throw "No such file: $_" }
        "===== $_ =====`n" + (Read-AsCleanText $_)
    }) -join "`n`n"
} else {
    $piped = @($input) -join "`n"
    if (-not $piped) { throw "Give me -File <path> or pipe something in." }
    $piped -replace '�', '' -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
}

try { $null = Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 3 }
catch { throw "llama-swap isn't answering on $base - run '.\start.ps1' first." }

function Invoke-Local($text) {
    $payload = @{
        model       = $Model
        messages    = @(@{ role = 'user'; content = "$Prompt`n`n$text" })
        max_tokens  = $MaxTokens
        temperature = 0
    } | ConvertTo-Json -Depth 6 -Compress

    # A cold model load is multi-GB off disk; the request has to outlast it.
    # Body as explicit UTF-8 bytes: PowerShell 5.1 otherwise encodes the string as Latin-1, which
    # mangles any non-ASCII character into something llama-server rejects as invalid JSON.
    $r = Invoke-RestMethod "$base/v1/chat/completions" -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($payload)) `
        -ContentType 'application/json; charset=utf-8' -TimeoutSec 900
    if ($ShowStats -and $r.timings) {
        Write-Host ("  [{0} prompt tok @ {1:N0}/s, {2} gen @ {3:N0}/s]" -f `
            $r.usage.prompt_tokens, $r.timings.prompt_per_second,
            $r.usage.completion_tokens, $r.timings.predicted_per_second) -ForegroundColor DarkGray
    }
    $r.choices[0].message.content
}

# ~4 characters per token for English, the same figure the needle sizing in bench/run.py uses.
$chunkChars = $ChunkTokens * 4

if ($body.Length -le $chunkChars) {
    Invoke-Local $body
} else {
    # ponytail: map only, no reduce - each chunk is answered independently and the answers are
    # concatenated. Fine for extract/filter/list work, which is what this is for. If you need a
    # single coherent summary of the whole input, feed this output back through once more.
    $n = [math]::Ceiling($body.Length / $chunkChars)
    if ($ShowStats) { Write-Host "input is ~$([int]($body.Length/4)) tokens - splitting into $n chunks" -ForegroundColor DarkGray }
    for ($i = 0; $i -lt $n; $i++) {
        $slice = $body.Substring($i * $chunkChars, [math]::Min($chunkChars, $body.Length - $i * $chunkChars))
        if ($ShowStats) { Write-Host "chunk $($i+1)/$n" -ForegroundColor DarkGray }
        Invoke-Local $slice
    }
}
