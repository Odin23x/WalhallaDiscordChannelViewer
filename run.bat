@echo off
setlocal
cd /d "%~dp0"

if not exist "node_modules" (
  echo [WalhallaDiscordChannelViewer] Installing dependencies...
  where npm >nul 2>nul
  if errorlevel 1 (
    echo ERROR: npm not found. Install Node.js and restart Touch Portal.
    exit /b 1
  )
  npm install --silent
)

where node >nul 2>nul
if errorlevel 1 (
  echo ERROR: node not found. Install Node.js 18+ and restart Touch Portal.
  exit /b 1
)

node "%~dp0index.js"
