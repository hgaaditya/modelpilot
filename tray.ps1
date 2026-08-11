# LocalLLM tray indicator - a system-tray dot showing whether the stack is up.
#
# Launched automatically by start.ps1 after a successful start (suppress with -NoTray),
# or on its own:  powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File .\tray.ps1
#
#   green   both services answering /health
#   yellow  one of the two is down
#   red     neither is answering
#
# Double-click opens the chat UI; right-click for the menu. It notifies when the stack
# goes down on its own, which is the whole point - a backend that dies at 2am is otherwise
# invisible until you try to use it.

param(
    [int]$SwapPort  = 9292,
    [int]$WebuiPort = 8080
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

$root       = $PSScriptRoot
$startPs    = Join-Path $root 'start.ps1'
$logDir     = Join-Path $root 'logs'
$swapConfig = Join-Path $root 'llamaswap\config.yaml'

# One tray icon per machine. start.ps1 fires this off on every successful launch without
# checking, so a duplicate just exits here instead of stacking up dots in the notification area.
$mutex = New-Object System.Threading.Mutex($false, 'Global\LocalLLM.Tray', [ref]$null)
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

# 16x16 filled circle, drawn at runtime - beats shipping .ico files for three coloured dots.
function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 2, 2, 11, 11)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90, 0, 0, 0)), 1
    $g.DrawEllipse($pen, 2, 2, 11, 11)
    $brush.Dispose(); $pen.Dispose(); $g.Dispose()
    # The handle leaks, but there are exactly three of these and they live as long as the process.
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$icons = @{
    up      = New-DotIcon ([System.Drawing.Color]::FromArgb(60, 190, 90))
    partial = New-DotIcon ([System.Drawing.Color]::FromArgb(235, 175, 45))
    down    = New-DotIcon ([System.Drawing.Color]::FromArgb(215, 65, 60))
}

function Test-Endpoint($url) {
    try { (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop).StatusCode -eq 200 }
    catch { $false }
}

# Which model llama-swap currently has loaded, if any - the useful signal for "is the GPU busy".
function Get-LoadedModel {
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$SwapPort/running" -TimeoutSec 1 -ErrorAction Stop
        $m = @($r.running | Where-Object { $_.state -ne 'stopped' })
        if ($m.Count) { return $m[0].model }
    } catch { }
    $null
}

function Start-Detached($argList) {
    Start-Process powershell -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startPs) + $argList)
}

# The control panel is the app's main window; the tray is what it minimises to. Closing the
# window leaves the panel server running, so this is how you get back to it - and ui.ps1 is
# single-instance, so it focuses the existing window rather than opening a second.
function Open-Panel {
    $ui = Join-Path $script:root 'ui.ps1'
    if (-not (Test-Path $ui)) { return }
    Start-Process powershell -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $ui
}

# The configured models, straight from config.yaml so the list is right whether or not the stack
# is up. Each entry carries the weight path so a model whose .gguf went missing can be greyed out
# instead of silently failing the moment it's selected.
function Get-ConfiguredModels {
    if (-not (Test-Path $script:swapConfig)) { return @() }
    # Drop whole-line comments before parsing: config.yaml documents its own tuning in prose, and
    # a comment quoting a flag or a path would otherwise be read as configuration for whichever
    # model it happens to sit under.
    $text = ((Get-Content $script:swapConfig) | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $parts = [regex]::Split($text, '(?m)^\s{2,}"([^"]+)"\s*:\s*$')
    $out = @()
    for ($i = 1; $i -lt $parts.Count; $i += 2) {
        $m = [regex]::Match($parts[$i + 1], '-m\s+"?([^"\r\n]+?\.gguf)"?')
        $out += [pscustomobject]@{
            Id      = $parts[$i]
            Path    = if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null }
            Present = $m.Success -and (Test-Path $m.Groups[1].Value.Trim())
        }
    }
    $out
}

# Asking llama-swap for a completion is what makes it swap the model in; one token is enough.
# Fire and forget - waiting for a multi-GB model to load would freeze the tray.
function Request-ModelLoad($id) {
    $body = @{ model = $id; messages = @(@{ role = 'user'; content = 'hi' }); max_tokens = 1 } | ConvertTo-Json -Compress -Depth 4
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    $content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
    [void]$client.PostAsync("http://127.0.0.1:$script:SwapPort/v1/chat/completions", $content)
}

function Invoke-UnloadAll {
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$script:SwapPort/api/models/unload" -Method Post -TimeoutSec 5 | Out-Null } catch { }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-MenuItem($text, $action) {
    $item = $menu.Items.Add($text)
    $item.Add_Click($action)
    $item
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $icons.down
$notify.Text = 'LocalLLM: checking...'
$notify.ContextMenuStrip = $menu
$notify.Visible = $true

$miPanel = Add-MenuItem 'Open LocalLLM'        { Open-Panel }
$miPanel.Font = New-Object System.Drawing.Font($miPanel.Font, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miChat = Add-MenuItem 'Open chat UI'          { Start-Process "http://127.0.0.1:$script:WebuiPort" }
$miDash = Add-MenuItem 'Open llama-swap dashboard' { Start-Process "http://127.0.0.1:$script:SwapPort/ui" }
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miModels = New-Object System.Windows.Forms.ToolStripMenuItem 'Models'
[void]$menu.Items.Add($miModels)
[void](Add-MenuItem 'Unload all models' { Invoke-UnloadAll })

# Rebuilt when the menu opens rather than on the status timer: config.yaml changes while the tray
# is running (that's what add-model does), and rebuilding under a menu the user has open is rude.
$menu.Add_Opening({
    $script:miModels.DropDownItems.Clear()
    $models = Get-ConfiguredModels
    if (-not $models) {
        $none = $script:miModels.DropDownItems.Add('(none configured)')
        $none.Enabled = $false
        return
    }
    $loaded = Get-LoadedModel
    foreach ($m in $models) {
        $label = $m.Id
        if ($m.Id -eq $loaded) { $label = "* $label  (loaded)" }
        elseif (-not $m.Present) { $label = "$label  (file missing)" }
        $item = $script:miModels.DropDownItems.Add($label)
        if (-not $m.Present) {
            $item.Enabled = $false
            $item.ToolTipText = "Not on disk: $($m.Path)"
        } else {
            $id = $m.Id   # capture per iteration, not by reference to the loop variable
            $item.ToolTipText = $m.Path
            $item.Add_Click({ Request-ModelLoad $id }.GetNewClosure())
        }
    }
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-MenuItem 'Open logs folder'         { Start-Process explorer.exe $script:logDir })

# Reloading just llama-swap is the common case: it only reads config.yaml at startup, so a model
# added while the stack is up isn't routable until it bounces - and open-webui has no reason to.
[void](Add-MenuItem 'Reload models (restart llama-swap)' { Start-Detached @('-Action', 'restart', '-Component', 'swap') })

$miRestart = New-Object System.Windows.Forms.ToolStripMenuItem 'Restart'
[void]$menu.Items.Add($miRestart)
[void]$miRestart.DropDownItems.Add('Whole stack').Add_Click({ Start-Detached @('-Action', 'restart') })
[void]$miRestart.DropDownItems.Add('llama-swap only').Add_Click({ Start-Detached @('-Action', 'restart', '-Component', 'swap') })
[void]$miRestart.DropDownItems.Add('open-webui only').Add_Click({ Start-Detached @('-Action', 'restart', '-Component', 'webui') })

$miStop = New-Object System.Windows.Forms.ToolStripMenuItem 'Stop'
[void]$menu.Items.Add($miStop)
[void]$miStop.DropDownItems.Add('Whole stack').Add_Click({ Start-Detached @('-Action', 'stop') })
[void]$miStop.DropDownItems.Add('llama-swap only').Add_Click({ Start-Detached @('-Action', 'stop', '-Component', 'swap') })
[void]$miStop.DropDownItems.Add('open-webui only').Add_Click({ Start-Detached @('-Action', 'stop', '-Component', 'webui') })
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-MenuItem 'Exit (leaves stack running)' {
    $script:notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

# Double-click opens the control panel, not the chat UI: the panel is this app's main window,
# and restoring it is what a user expects from double-clicking a tray icon.
$notify.Add_DoubleClick({ Open-Panel })

$script:lastState = $null

function Update-Status {
    $swapUp  = Test-Endpoint "http://127.0.0.1:$script:SwapPort/health"
    $webuiUp = Test-Endpoint "http://127.0.0.1:$script:WebuiPort/health"

    $state = if ($swapUp -and $webuiUp) { 'up' } elseif ($swapUp -or $webuiUp) { 'partial' } else { 'down' }
    $script:notify.Icon = $script:icons[$state]

    $model = if ($swapUp) { Get-LoadedModel } else { $null }
    $text = "LocalLLM  router:$(if ($swapUp) { 'up' } else { 'DOWN' })  ui:$(if ($webuiUp) { 'up' } else { 'DOWN' })"
    if ($model) { $text += "  [$model]" }
    # NotifyIcon.Text throws above 63 characters, and a long model id blows past that.
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
    $script:notify.Text = $text

    $script:miChat.Enabled = $webuiUp
    $script:miDash.Enabled = $swapUp

    if ($script:lastState -and $state -ne $script:lastState -and $state -ne 'up') {
        $down = @()
        if (-not $swapUp)  { $down += 'llama-swap' }
        if (-not $webuiUp) { $down += 'open-webui' }
        $script:notify.BalloonTipTitle = 'LocalLLM stack is down'
        $script:notify.BalloonTipText  = "$($down -join ' and ') stopped answering. Check logs\ or restart from this menu."
        $script:notify.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Warning
        $script:notify.ShowBalloonTip(8000)
    }
    $script:lastState = $state
}

# ponytail: polls on the UI thread with a 1s timeout - a hung endpoint stalls the menu for a
# beat. Move to a background runspace only if that ever actually annoys someone.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Status })
$timer.Start()

Update-Status
[System.Windows.Forms.Application]::Run()

$notify.Dispose()
$mutex.ReleaseMutex()
