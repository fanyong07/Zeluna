@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\run_dev.ps1" %*
if errorlevel 1 pause
