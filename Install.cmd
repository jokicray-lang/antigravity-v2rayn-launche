@echo off
rem Install the per-user launcher and redirect the matching Antigravity entry points.
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Launcher.ps1" %*
set "launcher_exit_code=%ERRORLEVEL%"
echo.
pause
exit /b %launcher_exit_code%
