# CrossLink POC runner for Windows
# Usage: powershell -File scripts/run-poc.ps1

$ErrorActionPreference = "Stop"
$GO = "$env:USERPROFILE\.local\go\bin\go.exe"
$GOPROXY = "https://goproxy.cn,direct"
$GOPATH = "$HOME\go-cache"

Write-Host "=== CrossLink POC End-to-End ===" -ForegroundColor Cyan

# Build
Write-Host "[1/3] Building..." -ForegroundColor Yellow
& $GO build -o "$env:TEMP\poc-signal.exe" .\poc\signal\
& $GO build -o "$env:TEMP\poc-agent.exe" .\poc\agent\
& $GO build -o "$env:TEMP\poc-client.exe" .\poc\client\

# Start signal server
Write-Host "[2/3] Starting signal server..." -ForegroundColor Yellow
$signalJob = Start-Job -ScriptBlock { & "$env:TEMP\poc-signal.exe" 2>&1 | Out-File "$env:TEMP\poc-signal.log" }
Start-Sleep -Seconds 1

# Start agent
Write-Host "[2/3] Starting agent..." -ForegroundColor Yellow
$agentJob = Start-Job -ScriptBlock { & "$env:TEMP\poc-agent.exe" 2>&1 | Out-File "$env:TEMP\poc-agent.log" }
Start-Sleep -Seconds 2

# Run client
Write-Host "[3/3] Running client..." -ForegroundColor Yellow
& "$env:TEMP\poc-client.exe"

# Cleanup
Stop-Job $signalJob, $agentJob -ErrorAction SilentlyContinue
Remove-Job $signalJob, $agentJob -ErrorAction SilentlyContinue

Write-Host "Done." -ForegroundColor Green
Write-Host "Logs: $env:TEMP\poc-signal.log, $env:TEMP\poc-agent.log"
