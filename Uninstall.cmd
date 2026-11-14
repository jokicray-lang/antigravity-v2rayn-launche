@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Launcher.ps1" -Uninstall %*
set "launcher_exit_code=%ERRORLEVEL%"
echo.
pause
exit /b %launcher_exit_code%
