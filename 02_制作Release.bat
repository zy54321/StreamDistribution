@echo off
setlocal
cd /d "%~dp0"
if errorlevel 1 (
    set "CODE=1"
    goto Finish
)
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
    set "CODE=9009"
    goto Finish
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\dev\make-release.ps1"
set "CODE=%ERRORLEVEL%"
:Finish
if not "%CODE%"=="0" echo [Release] incomplete, exit code %CODE%
echo Press any key to close...
pause >nul
exit /b %CODE%
