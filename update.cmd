@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\50-update.ps1" %*
pause
