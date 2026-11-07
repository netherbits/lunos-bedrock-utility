@echo off
start "" conhost.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Server.ps1"
