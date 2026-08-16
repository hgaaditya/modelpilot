# System stability diagnostics for a machine that crashes with no consistent signature.
#
#   .\diagnose.ps1                 # one-shot report -> logs\diag-<timestamp>.txt
#   .\diagnose.ps1 -Watch          # flight recorder: log system state every 5s until stopped
#   .\diagnose.ps1 -Watch -IntervalSec 2
#
# Why this exists: crashes here have produced three unrelated bugcheck codes (0x116 VIDEO_TDR,
# 0x50 PAGE_FAULT_IN_NONPAGED_AREA, 0x133 DPC_WATCHDOG_VIOLATION), several hard hangs that left
# no bugcheck at all, and a hang during cold boot. Scattered signatures across unrelated
# subsystems point at the platform - RAM, PSU, storage, board - rather than at any one driver.
# Diagnosing that needs evidence collected the same way every time, plus state captured from
# *before* the machine dies, which is what -Watch is for.

[CmdletBinding(PositionalBinding = $false)]
param(
    # Flight recorder mode: append a line of system state on an interval, flushed every write so
    # a hard power loss keeps everything up to the final sample.
    [switch]$Watch,

    [int]$IntervalSec = 5,

    # Resolved below rather than here: $PSScriptRoot isn't populated yet when PowerShell 5.1
    # evaluates parameter defaults under -File.
    [string]$OutDir
)

$ErrorActionPreference = 'Continue'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'logs' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---------------------------------------------------------------- flight recorder

if ($Watch) {
    $csv = Join-Path $OutDir 'flight-recorder.csv'
    $new = -not (Test-Path $csv)
    # AutoFlush: a buffered writer loses precisely the seconds that matter.
    $w = New-Object IO.StreamWriter($csv, $true)
    $w.AutoFlush = $true
    if ($new) { $w.WriteLine('timestamp,uptime_s,cpu_pct,ram_used_mb,ram_free_mb,gpu_temp_c,gpu_power_w,gpu_clock_mhz,gpu_mem_mb,gpu_util_pct,disk_queue,top_proc') }

    Write-Host "Flight recorder -> $csv  (every ${IntervalSec}s, Ctrl-C to stop)"
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    try {
        while ($true) {
            $os  = Get-CimInstance Win32_OperatingSystem
            $ramFree = [int]($os.FreePhysicalMemory / 1KB)
            $ramUsed = [int](($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB)
            $cpu = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue).PercentProcessorTime
            $dq  = (Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue).CurrentDiskQueueLength

            $g = @('', '', '', '', '')
            $smi = nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.sm,memory.used,utilization.gpu --format=csv,noheader,nounits 2>$null
            if ($smi) { $g = ($smi -split ',') | ForEach-Object { $_.Trim() } }

            $top = (Get-Process | Sort-Object CPU -Descending | Select-Object -First 1).ProcessName

            $w.WriteLine(('{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11}' -f `
                (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
                [int]((Get-Date) - $boot).TotalSeconds,
                $cpu, $ramUsed, $ramFree, $g[0], $g[1], $g[2], $g[3], $g[4], $dq, $top))
            Start-Sleep -Seconds $IntervalSec
        }
    } finally { $w.Close() }
    return
}

# ---------------------------------------------------------------- one-shot report

$out = Join-Path $OutDir ("diag-" + (Get-Date -Format 'yyyy-MM-ddTHH-mm-ss') + ".txt")
$sb = New-Object Text.StringBuilder
# Write-Host inside a try: piping this script through Select-Object -First closes the host
# pipeline, and without the guard that kills the run before the report is ever saved.
function Add-Line($s) {
    [void]$sb.AppendLine($s)
    try { Write-Host $s } catch { }
    try { $sb.ToString() | Set-Content -Path $script:out -Encoding utf8 } catch { }
}
function Add-Section($t) { Add-Line ""; Add-Line ("=" * 70); Add-Line "  $t"; Add-Line ("=" * 70) }

Add-Line "LocalLLM stability report - $(Get-Date)"
Add-Line "host: $env:COMPUTERNAME"

Add-Section "CRASH HISTORY"
# Kernel-Power 41 with no matching bugcheck means the machine died without getting a chance to
# write one: a hard hang, a reset, or power loss. That distinction matters more than the count.
$bugchecks = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001} -MaxEvents 40 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'bugcheck was' } |
    ForEach-Object {
        [pscustomobject]@{
            Time = $_.TimeCreated
            Code = [regex]::Match($_.Message, '0x[0-9A-Fa-f]{8}').Value
            Args = [regex]::Match($_.Message, '\(([^)]*)\)').Groups[1].Value
        }
    })
$k41 = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=41} -MaxEvents 40 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TimeCreated)

Add-Line "unexpected shutdowns (Kernel-Power 41): $($k41.Count)"
Add-Line "bugchecks recorded:                     $($bugchecks.Count)"
Add-Line "-> $($k41.Count - $bugchecks.Count) died without writing a bugcheck (hard hang / reset / power loss)"
Add-Line ""
if ($bugchecks) {
    Add-Line "bugcheck codes seen:"
    $bugchecks | Group-Object Code | Sort-Object Count -Descending | ForEach-Object {
        $meaning = switch ($_.Name) {
            '0x00000116' { 'VIDEO_TDR_ERROR - GPU stopped responding' }
            '0x00000117' { 'VIDEO_TDR_TIMEOUT' }
            '0x00000050' { 'PAGE_FAULT_IN_NONPAGED_AREA - classic bad RAM' }
            '0x0000001A' { 'MEMORY_MANAGEMENT - RAM or memory corruption' }
            '0x00000133' { 'DPC_WATCHDOG_VIOLATION - a driver stalled, often storage' }
            '0x00000124' { 'WHEA_UNCORRECTABLE_ERROR - hardware fault reported by the CPU' }
            '0x0000007E' { 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED' }
            '0x000000D1' { 'DRIVER_IRQL_NOT_LESS_OR_EQUAL' }
            default      { 'see https://learn.microsoft.com/windows-hardware/drivers/debugger/bug-check-code-reference2' }
        }
        Add-Line ("  {0} x{1,-3} {2}" -f $_.Name, $_.Count, $meaning)
    }
    $distinct = ($bugchecks | Select-Object -ExpandProperty Code -Unique).Count
    if ($distinct -ge 3) {
        Add-Line ""
        Add-Line "  NOTE: $distinct distinct codes across unrelated subsystems. A single faulty driver"
        Add-Line "        usually produces one repeating code; scattered codes point at the platform"
        Add-Line "        (RAM, PSU, storage, board) rather than at software."
    }
    Add-Line ""
    Add-Line "most recent:"
    $bugchecks | Select-Object -First 10 | ForEach-Object { Add-Line ("  {0}  {1}  ({2})" -f $_.Time, $_.Code, $_.Args) }
}
Add-Line ""
Add-Line "recent unexpected shutdowns:"
$k41 | Select-Object -First 12 | ForEach-Object { Add-Line "  $_" }

Add-Section "EVIDENCE PIPELINE (can the next crash even be diagnosed?)"
$cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
$dumpType = switch ($cc.CrashDumpEnabled) { 0 {'NONE'} 1 {'complete'} 2 {'kernel'} 3 {'small (minidump)'} 7 {'automatic'} default {"unknown ($($cc.CrashDumpEnabled))"} }
Add-Line "crash dump mode : $dumpType"
$mini = @(Get-ChildItem 'C:\Windows\Minidump' -ErrorAction SilentlyContinue)
Add-Line "minidumps on disk: $($mini.Count)"
$memdmp = Get-Item C:\Windows\MEMORY.DMP -ErrorAction SilentlyContinue
Add-Line "MEMORY.DMP       : $(if ($memdmp) { '{0:N0} MB, {1}' -f ($memdmp.Length/1MB), $memdmp.LastWriteTime } else { 'absent' })"
$ss = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -ErrorAction SilentlyContinue
Add-Line "Storage Sense    : $(if ($ss.'01' -eq 1) { 'ON - deletes crash dumps, which is why the folder can be empty' } else { 'off' })"
if ($bugchecks.Count -gt 0 -and $mini.Count -eq 0) {
    Add-Line ""
    Add-Line "  PROBLEM: bugchecks are being recorded but no dump survives, so there is nothing"
    Add-Line "           to analyse. Fix this before chasing anything else (see NEXT STEPS)."
}

Add-Section "MEMORY"
Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    Add-Line ("  {0,-22} {1,3} GB  running {2} MT/s  rated {3}  {4} {5}" -f `
        $_.DeviceLocator, ($_.Capacity/1GB), $_.ConfiguredClockSpeed, $_.Speed, $_.Manufacturer, $_.PartNumber)
}
$os = Get-CimInstance Win32_OperatingSystem
Add-Line ("  in use: {0:N1} GB of {1:N1} GB" -f (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory)/1MB), ($os.TotalVisibleMemorySize/1MB))
$mem = @(Get-CimInstance Win32_PhysicalMemory)
if ($mem -and ($mem[0].ConfiguredClockSpeed -lt $mem[0].Speed)) {
    Add-Line "  note: modules are rated $($mem[0].Speed) MT/s but running at $($mem[0].ConfiguredClockSpeed)."
    Add-Line "        If an XMP/EXPO profile is enabled in BIOS, disabling it is a fast stability test."
}

Add-Section "STORAGE"
Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    Add-Line ("  {0,-24} {1,-5} {2,-8} {3,5} GB" -f $_.FriendlyName, $_.MediaType, $_.HealthStatus, [int]($_.Size/1GB))
}
$c = Get-PSDrive C
Add-Line ("  C: {0:N0} GB free of {1:N0} GB" -f ($c.Free/1GB), (($c.Free + $c.Used)/1GB))
# SMART. Both routes to it - Get-StorageReliabilityCounter and the root\wmi failure-prediction
# classes - are admin-only and fail with "Access to a CIM resource was not available" otherwise.
# Unelevated they return an object with every field empty, which prints as a clean bill of health
# for a drive nothing was ever read from. So the report says which of the two it is; a blank row
# here would be the most dangerous line in the file.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Add-Line "  SMART: not read - needs an elevated shell. Re-run from an admin PowerShell for"
    Add-Line "         wear, power-on hours and uncorrected read/write errors per drive."
} else {
    $predict = @{}
    Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue |
        ForEach-Object { $predict[$_.InstanceName] = $_.PredictFailure }
    foreach ($d in Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $c = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        if (-not $c) { Add-Line ("  SMART {0,-24} unavailable (the drive reports no counters)" -f $d.FriendlyName); continue }
        Add-Line ("  SMART {0,-24} wear {1} | {2} h | uncorrected read {3} write {4} | {5} C" -f
            $d.FriendlyName,
            $(if ($null -ne $c.Wear) { "$($c.Wear)%" } else { 'n/a' }),
            $(if ($null -ne $c.PowerOnHours) { $c.PowerOnHours } else { 'n/a' }),
            $(if ($null -ne $c.ReadErrorsUncorrected) { $c.ReadErrorsUncorrected } else { 'n/a' }),
            $(if ($null -ne $c.WriteErrorsUncorrected) { $c.WriteErrorsUncorrected } else { 'n/a' }),
            $(if ($null -ne $c.Temperature) { $c.Temperature } else { 'n/a' }))
    }
    $failing = @($predict.GetEnumerator() | Where-Object { $_.Value })
    if ($failing) {
        Add-Line "  SMART FAILURE PREDICTED on: $(($failing | ForEach-Object { $_.Key }) -join ', ')"
        Add-Line "  -> back up now; a drive saying this is the whole diagnosis."
    } elseif ($predict.Count) {
        Add-Line "  SMART failure prediction: none of $($predict.Count) drive(s) reporting a problem"
    }
}

$diskErr = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='disk','stornvme','storahci','Ntfs'} -MaxEvents 20 -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -in 'Error','Warning' })
Add-Line "  disk/NTFS errors or warnings logged: $($diskErr.Count)"
$diskErr | Select-Object -First 6 | ForEach-Object { Add-Line ("    {0} id={1} {2}" -f $_.TimeCreated, $_.Id, (($_.Message -split "`n")[0].Trim())) }

# When they started matters more than what the last six say, and a tail hides it. Measured here:
# all 16 controller resets in a 41-day log fall on two days, none before the day the BIOS settings
# were changed - which a six-line tail showed as "recent disk errors" and nothing more. The log's
# own start date is printed too, because "none before X" means nothing without knowing whether
# the log reaches back past X.
# Its own query, uncapped: $diskErr is the last 20 events for the tail above, and counting a
# 41-day total out of a 20-event window would quietly understate it on any busier machine.
$resets = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='disk','stornvme','storahci'; Id=129} -ErrorAction SilentlyContinue)
if ($resets.Count -gt 1) {
    $oldestLog = (Get-WinEvent -LogName System -MaxEvents 1 -Oldest -ErrorAction SilentlyContinue).TimeCreated
    Add-Line ("    -> {0} controller resets between {1:yyyy-MM-dd} and {2:yyyy-MM-dd}; System log starts {3:yyyy-MM-dd}" -f
        $resets.Count, $resets[-1].TimeCreated, $resets[0].TimeCreated, $oldestLog)
    $days = @($resets | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd') } | Sort-Object -Unique)
    Add-Line ("    -> on {0} distinct day(s): {1}" -f $days.Count, ($days -join ', '))
}

Add-Section "GPU"
$smi = nvidia-smi --query-gpu=name,driver_version,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.max.sm,memory.used --format=csv,noheader 2>$null
Add-Line "  $smi"
$whea = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'} -MaxEvents 20 -ErrorAction SilentlyContinue)
Add-Line "  WHEA hardware events logged: $($whea.Count)"
$whea | Select-Object -First 5 | ForEach-Object { Add-Line ("    {0} id={1}" -f $_.TimeCreated, $_.Id) }

Add-Section "NEXT STEPS"
Add-Line @'
  Work down this list. Each step changes ONE variable and has a clear pass/fail, because
  chasing an intermittent fault by changing several things at once proves nothing.

  0. MAKE THE NEXT CRASH READABLE  (do this first - it costs minutes)
     - Turn Storage Sense OFF: Settings > System > Storage > Storage Sense.
       It deletes the dumps we need.
     - Set dump type to "Automatic memory dump" rather than "Small memory dump":
       Settings > System > About > Advanced system settings > Startup and Recovery.
     Without a dump, every later step is guesswork.

  1. MEMORY  (highest prior: 0x50, plus scattered codes and a cold-boot hang)
     - Run MemTest86 from a USB stick, not the Windows tool - it tests memory the OS is
       using and runs for hours. Let it complete at least 4 passes, ideally overnight.
     - Then test EACH STICK ALONE, in the SAME slot. That separates a bad module from a
       bad slot. Two sticks, two runs.
     - Any error at all is conclusive. Zero errors over 4+ passes clears memory.

  2. FIRMWARE / SETTINGS  (free, fast)
     - Disable XMP/EXPO if enabled; run memory at JEDEC defaults for a few days.
     - Update BIOS and chipset drivers.

  3. POWER  (fits crashes at idle AND a cold-boot hang, which memory alone does not)
     - Note PSU make, model, wattage and age. Budget or aged units fail exactly like this:
       different bugchecks each time, hangs before the OS loads.
     - Cheap test: cap the GPU with "nvidia-smi -pl 140" (admin) and run normally for a
       day. If crashes stop, suspect power delivery, not the GPU itself.

  4. STORAGE  (0x133 is often a stalled storage driver)
     - Re-run this script from an ADMIN PowerShell: SMART wear, power-on hours and
       uncorrected errors need elevation, and are blank above without it.
     - "chkdsk C: /scan"; CrystalDiskInfo if you want the vendor attributes too.
     - Both drives here are budget brands; a failing boot NVMe can hang a cold boot and
       stall DPCs.

  5. THERMAL / SEATING
     - Reseat RAM and the GPU, check case airflow and CPU cooler mounting.

  A cold-boot hang happens before Windows exists, so it excludes every software explanation
  on its own. Steps 1, 3 and 4 are the ones that can produce it.
'@

$sb.ToString() | Set-Content -Path $out -Encoding utf8
Write-Host ""
Write-Host "saved -> $out" -ForegroundColor Green
