@echo off
cd /d C:\mySpace\CorssLink\poc
C:\Users\22730\.local\go\bin\go.exe build ./... 2>&1
echo EXIT CODE: %ERRORLEVEL%
