@echo off
echo [%DATE% %TIME%] BAT started, running PS1 from: %~dp0 >> "%~dp0startup.log"
powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "%~dp0DiscordChannelViewer.ps1"
echo [%DATE% %TIME%] PS1 exited with code %ERRORLEVEL% >> "%~dp0startup.log"
