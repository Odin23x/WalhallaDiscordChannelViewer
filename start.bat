@echo off
echo [%DATE% %TIME%] BAT gestartet >> "%~dp0startup.log"
powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "%~dp0DiscordChannelViewer.ps1"
echo [%DATE% %TIME%] PS beendet: %ERRORLEVEL% >> "%~dp0startup.log"
