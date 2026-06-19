@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo.
echo ╔══════════════════════════════════════════════════╗
echo ║  CrossLink Agent — Windows Service Installer     ║
echo ╚══════════════════════════════════════════════════╝
echo.

REM ── Check admin ─────────────────────────────────────
net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Administrator privileges required!
    echo         Right-click this file ^> Run as Administrator
    pause
    exit /b 1
)
echo [OK] Administrator: yes

REM ── Build first ─────────────────────────────────────
cd /d "%~dp0"
call start.bat build-only 2>nul
if not exist "%~dp0bin\crosslink-agent.exe" (
    echo [FAIL] Build failed — run start.bat first to verify.
    pause
    exit /b 1
)

REM ── Install service ─────────────────────────────────
echo [SVC] Installing Windows service...
"%~dp0bin\crosslink-agent.exe" install
if errorlevel 1 (
    echo.
    echo [FAIL] Service installation failed.
    echo         The agent already installed? Try 'bin\crosslink-agent.exe uninstall' first.
    pause
    exit /b 1
)

echo.
echo ╔══════════════════════════════════════════════════╗
echo ║  Service installed successfully!                 ║
echo ║                                                  ║
echo ║  • Starts automatically on boot                  ║
echo ║  • Auto-restarts on crash (5s → 10s → 30s)       ║
echo ║  • Logs: C:\ProgramData\CrossLink\agent.log     ║
echo ║                                                  ║
echo ║  Manage via:                                     ║
echo ║    sc query CrossLinkAgent                       ║
echo ║    sc stop  CrossLinkAgent                       ║
echo ║    sc start CrossLinkAgent                       ║
echo ║    bin\crosslink-agent.exe uninstall              ║
echo ╚══════════════════════════════════════════════════╝
echo.
pause
