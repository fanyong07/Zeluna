@echo off
setlocal
cd /d "%~dp0.."

where node >nul 2>nul
if errorlevel 1 (
  echo [anime] Node.js was not found. Install Node.js or run the Android APK instead.
  pause
  exit /b 1
)

set PORT=5190
start "" "http://127.0.0.1:%PORT%/"
node tools\dev_web_server.mjs
