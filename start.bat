@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo.
echo ╔══════════════════════════════════════════════════╗
echo ║       CrossLink Agent — One-Click Launcher       ║
echo ╚══════════════════════════════════════════════════╝
echo.

REM ── Locate Go ──────────────────────────────────────
for /f "delims=" %%i in ('where go 2^>nul') do set GO_BIN=%%i
if "%GO_BIN%"=="" (
    echo [ERROR] Go not found in PATH. Install from https://go.dev/dl/
    pause
    exit /b 1
)
echo [OK] Go: %GO_BIN%

REM ── Project root ────────────────────────────────────
cd /d "%~dp0poc"
set ROOT=%~dp0
set BIN_DIR=%ROOT%bin
if not exist "%BIN_DIR%" mkdir "%BIN_DIR%"

REM ── Config (override via env vars) ──────────────────
if "%RELAY_ADDR%"=="" set RELAY_ADDR=ws://45.197.144.16:18080/agent
if "%SIGNAL_ADDR%"=="" set SIGNAL_ADDR=ws://45.197.144.16:18080
if "%TURN_SERVER%"=="" set TURN_SERVER=turn:45.197.144.16:3478?transport=tcp
REM Load .env if present (contains DEEPSEEK_API_KEY etc.)
if exist "%~dp0.env" for /f "tokens=*" %%a in ('type "%~dp0.env" 2^>nul') do set %%a
if "%DEEPSEEK_API_KEY%"=="" echo [WARN] DEEPSEEK_API_KEY not set — DeepSeek backend will fail
if "%CLAUDE_PATH%"=="" set CLAUDE_PATH=%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe
if "%CLAUDE_MODEL%"=="" set CLAUDE_MODEL=sonnet

echo [CFG] Relay  : %RELAY_ADDR%
echo [CFG] DeepSeek: %DEEPSEEK_API_KEY:~0,12%... (auto)
echo [CFG] Signal : %SIGNAL_ADDR%
echo [CFG] TURN   : %TURN_SERVER%
echo [CFG] Claude : %CLAUDE_PATH%
if exist "%CLAUDE_PATH%" (
    echo [CFG]         model=%CLAUDE_MODEL% ^(ready^)
) else (
    echo [CFG]         not installed, will skip
)

REM ── Check first argument for mode ─────────────────────
set MODE=%1
if "%MODE%"=="" set MODE=full

REM ── Check relay server ─────────────────────────────
if "%MODE%"=="full" (
    echo [NET] Checking relay server...
    curl -s --connect-timeout 5 http://45.197.144.16:18080/health >nul 2>&1
    if errorlevel 1 (
        echo [WARN] Relay server unreachable — agent will retry
    ) else (
        echo [OK]   Relay server reachable
    )
)

REM ── Build agent ─────────────────────────────────────
echo [BUILD] Building agent...
set GOPROXY=https://goproxy.cn,direct
go build -o "%BIN_DIR%crosslink-agent.exe" ./ollama-agent/
if errorlevel 1 (
    echo [ERROR] Build failed!
    pause
    exit /b 1
)
echo [OK]   Built: %BIN_DIR%crosslink-agent.exe

REM ── Launch (skip if build-only) ──────────────────────
if "%MODE%"=="build-only" (
    echo [OK]   Build-only mode — skipping launch.
    endlocal
    exit /b 0
)

echo.
echo ╔══════════════════════════════════════════════════╗
echo ║  Agent starting in interactive mode...           ║
echo ║  Press Ctrl+C to stop                            ║
echo ╚══════════════════════════════════════════════════╝
echo.

"%BIN_DIR%crosslink-agent.exe"
echo.
echo [INFO] Agent stopped.
pause
