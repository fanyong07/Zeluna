@echo off
setlocal
cd /d "%~dp0.."

where node >nul 2>nul
if errorlevel 1 (
  echo [anime] Node.js was not found. Install Node.js or run the Android APK instead.
  pause
  exit /b 1
)

set "PORT=5190"
set "HOST=127.0.0.1"
set "ALLOW_REMOTE_PROXY=0"
rem Clash/TUN fake-IP DNS returns public hosts inside 198.18.0.0/15.
rem This opt-in is scoped to this loopback-only local launcher.
set "ALLOW_SYNTHETIC_DNS=1"
start "" "http://127.0.0.1:%PORT%/"
node tools\dev_web_server.mjs
