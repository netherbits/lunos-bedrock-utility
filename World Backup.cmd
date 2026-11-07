@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Launch-Toolbox.ps1" -Tool Backup
exit /b %errorlevel%
