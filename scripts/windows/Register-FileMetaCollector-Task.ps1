#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Register a Windows Scheduled Task that runs Collect-FileMeta-ToMongo.ps1 every 24 hours.

.DESCRIPTION
  Creates (or updates) task "Anno-FileMeta-Collector-24h" to execute the file-meta
  collector once every 24 hours under the SYSTEM account (or a specified user).

.PARAMETER CollectorScript
  Full path to Collect-FileMeta-ToMongo.ps1. Default: same folder as this script.

.PARAMETER TaskName
  Scheduled task name.

.PARAMETER StartTime
  First run time for the 24-hour repetition cycle (default: tonight 02:00 local).

.PARAMETER MongoUri
  Passed through to the collector.

.PARAMETER Database
  Passed through to the collector.

.PARAMETER Collection
  Passed through to the collector.

.PARAMETER Roots
  Optional scan roots (comma-separated in the task argument). Empty = all local drives.

.PARAMETER LookbackHours
  Passed through to the collector (default 24).

.PARAMETER Unregister
  Remove the scheduled task instead of creating it.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Register-FileMetaCollector-Task.ps1

.EXAMPLE
  .\Register-FileMetaCollector-Task.ps1 -Roots 'C:\Users,D:\' -StartTime 03:00
#>
[CmdletBinding()]
param(
    [string]$CollectorScript = "",
    [string]$TaskName = "Anno-FileMeta-Collector-24h",
    [string]$StartTime = "02:00",
    [string]$MongoUri = "mongodb://127.0.0.1:27017",
    [string]$Database = "filemonitor",
    [string]$Collection = "file_meta",
    [string]$Roots = "",
    [int]$LookbackHours = 24,
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $CollectorScript) {
    $CollectorScript = Join-Path $scriptDir "Collect-FileMeta-ToMongo.ps1"
}

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[OK] Unregistered task '$TaskName' (if it existed)."
    exit 0
}

if (-not (Test-Path -LiteralPath $CollectorScript)) {
    throw "Collector script not found: $CollectorScript"
}

# Resolve absolute path for the task action
$CollectorScript = (Resolve-Path -LiteralPath $CollectorScript).Path

$argParts = New-Object System.Collections.Generic.List[string]
[void]$argParts.Add("-NoProfile")
[void]$argParts.Add("-ExecutionPolicy Bypass")
[void]$argParts.Add("-File `"$CollectorScript`"")
[void]$argParts.Add("-LookbackHours $LookbackHours")
[void]$argParts.Add("-MongoUri `"$MongoUri`"")
[void]$argParts.Add("-Database `"$Database`"")
[void]$argParts.Add("-Collection `"$Collection`"")

if ($Roots) {
    $rootValues = @(
        $Roots -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    if ($rootValues.Count -gt 0) {
        $quotedRoots = ($rootValues | ForEach-Object { "`"$_`"" }) -join " "
        [void]$argParts.Add("-Roots $quotedRoots")
    }
}

$arguments = ($argParts -join " ")
Write-Host "Task action arguments:"
Write-Host "  powershell.exe $arguments"

# Parse StartTime (HH:mm) → today's/tomorrow DateTime
try {
    $parsed = [datetime]::ParseExact($StartTime, "HH:mm", [Globalization.CultureInfo]::InvariantCulture)
}
catch {
    throw "StartTime must be HH:mm (24h), got: $StartTime"
}
$start = (Get-Date).Date.AddHours($parsed.Hour).AddMinutes($parsed.Minute)
if ($start -le (Get-Date)) {
    $start = $start.AddDays(1)
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments -WorkingDirectory (Split-Path $CollectorScript)
$trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Hours 24) -RepetitionDuration ([TimeSpan]::MaxValue)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 10)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Every 24 hours: collect OS file metadata (last ${LookbackHours}h updates) into MongoDB ${Database}.${Collection}" |
    Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName

Write-Host ""
Write-Host "[OK] Scheduled task registered:" -ForegroundColor Green
Write-Host "  Name:        $($task.TaskName)"
Write-Host "  State:       $($task.State)"
Write-Host "  Next run:    $($info.NextRunTime)"
Write-Host "  Interval:    every 24 hours (from $StartTime)"
Write-Host "  Runs as:     SYSTEM"
Write-Host "  Script:      $CollectorScript"
Write-Host "  MongoDB:     $MongoUri / $Database.$Collection"
Write-Host ""
Write-Host "Manual test:"
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Get-Content `$env:ProgramData\AnnoFileMetaCollector\collect-*.log -Tail 50"
Write-Host ""
Write-Host "Unregister:"
Write-Host "  .\Register-FileMetaCollector-Task.ps1 -Unregister"
exit 0
