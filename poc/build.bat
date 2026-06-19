@echo off
cd /d "C:\mySpace\CorssLink\poc"
echo === Go Build ===
go build ./...
if %ERRORLEVEL% NEQ 0 (
    echo BUILD FAILED
    pause
    exit /b 1
)
echo === Build OK ===
echo.
echo === Go Test ===
go test ./pairing/ ./ollama/ -v
echo.
echo === Done ===
pause
