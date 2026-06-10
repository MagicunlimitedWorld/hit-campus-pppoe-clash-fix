@echo off
set "SCRIPT_DIR=%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT_DIR%Start-HitNetClashFix.ps1"
