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

$root    = $PSScriptRoot
$startPs = Join-Path $root 'start.ps1'
$logDir  = Join-Path $root 'logs'

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

$miChat = Add-MenuItem 'Open chat UI'          { Start-Process "http://127.0.0.1:$script:WebuiPort" }
$miDash = Add-MenuItem 'Open llama-swap dashboard' { Start-Process "http://127.0.0.1:$script:SwapPort/ui" }
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-MenuItem 'Open logs folder'         { Start-Process explorer.exe $script:logDir })
[void](Add-MenuItem 'Restart stack'            { Start-Detached @('-Action', 'restart') })
[void](Add-MenuItem 'Stop stack'               { Start-Detached @('-Action', 'stop') })
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-MenuItem 'Exit (leaves stack running)' {
    $script:notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$notify.Add_DoubleClick({ Start-Process "http://127.0.0.1:$script:WebuiPort" })

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
