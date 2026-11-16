@echo off
cd /d "%~dp0"

REM 1. Start Ollama local AI server if available and not already running
tasklist /FI "IMAGENAME eq ollama.exe" 2>NUL | find /I /N "ollama.exe">NUL
if "%ERRORLEVEL%"=="1" (
    where ollama >NUL 2>&1
    if "%ERRORLEVEL%"=="0" (
        start "" /B ollama serve
    ) else if exist "%LOCALAPPDATA%\Programs\Ollama\ollama.exe" (
        start "" /B "%LOCALAPPDATA%\Programs\Ollama\ollama.exe" serve
    )
)

REM 2. Launch JARVIS Dynamic Island in STA mode silently
start "" powershell.exe -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0JarvisIsland.ps1"
