@echo off
setlocal
rem SPDX-License-Identifier: MIT
rem ExecutionPolicy applies to this PowerShell process only.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Antigravity.ps1" %*
set "launcher_exit_code=%ERRORLEVEL%"
if not "%launcher_exit_code%"=="0" (
    echo.
    echo See README.md for troubleshooting. Exit code: %launcher_exit_code%
    pause
)
exit /b %launcher_exit_code%
