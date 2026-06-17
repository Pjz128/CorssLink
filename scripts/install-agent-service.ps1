# CrossLink Agent — Register as Windows Scheduled Task (auto-start at logon).
# Run once from elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\install-agent-service.ps1
#
# To remove:
#   Unregister-ScheduledTask -TaskName "CrossLink Agent Watchdog" -Confirm:$false

$ErrorActionPreference = "Stop"

$TaskName = "CrossLink Agent Watchdog"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WatchdogPath = Join-Path $ScriptDir "watchdog.sh"
$WorkingDir = Split-Path -Parent $ScriptDir

# Find Git Bash
$BashPath = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $BashPath)) {
    $BashPath = "C:\Program Files (x86)\Git\bin\bash.exe"
}
if (-not (Test-Path $BashPath)) {
    Write-Error "Git Bash not found. Please install Git for Windows."
    exit 1
}

Write-Host "Installing CrossLink Agent as a scheduled task..."
Write-Host "  Bash:      $BashPath"
Write-Host "  Watchdog:  $WatchdogPath"
Write-Host "  Work dir:  $WorkingDir"
Write-Host ""

$Action = New-ScheduledTaskAction `
    -Execute $BashPath `
    -Argument "-c `"cd '$WorkingDir'; bash '$WatchdogPath'`"" `
    -WorkingDirectory $WorkingDir

$Trigger = New-ScheduledTaskTrigger -AtLogon

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 365) `
    -MultipleInstances IgnoreNew

$Principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

$task = Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Principal $Principal `
    -Description "Keeps CrossLink PC Agent running — auto-restarts on crash or PC reboot." `
    -Force

Write-Host "[OK] CrossLink Agent will start automatically at user logon."
Write-Host ""
Write-Host "To start now:  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "To stop:       Stop-ScheduledTask -TaskName '$TaskName'"
Write-Host "To remove:     Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
