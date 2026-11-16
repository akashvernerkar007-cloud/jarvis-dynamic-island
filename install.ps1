# ==============================================================================
# JARVIS DYNAMIC ISLAND - 1-COMMAND AUTOMATED INSTALLER & LAUNCHER
# Supported: Windows 10 & Windows 11 (PowerShell 5.1 & PowerShell 7+)
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "JARVIS Dynamic Island Installer"

Write-Host @"

   ██╗ █████╗ ██████╗ ██╗   ██╗██╗███████╗
   ██║██╔══██╗██╔══██╗██║   ██║██║██╔════╝
   ██║███████║██████╔╝██║   ██║██║███████╗
   ██║██╔══██║██╔══██╗╚██╗ ██╔╝██║╚════██║
   ██║██║  ██║██║  ██║ ╚████╔╝ ██║███████║
   ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝
       DYNAMIC ISLAND FOR WINDOWS
"@ -ForegroundColor Cyan

Write-Host "`n[*] Starting automated deployment..." -ForegroundColor White

# 1. Determine Target Directory
$isLocal = ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "JarvisIsland.ps1")))
if ($isLocal) {
    $installDir = $PSScriptRoot
    Write-Host "[+] Installing from local directory: $installDir" -ForegroundColor Green
} else {
    $installDir = Join-Path $env:LOCALAPPDATA "JarvisDynamicIsland"
    Write-Host "[*] Target directory: $installDir" -ForegroundColor Gray
    
    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    $gitCmd = Get-Command "git.exe" -ErrorAction SilentlyContinue
    if ($gitCmd) {
        Write-Host "[*] Cloning repository via Git..." -ForegroundColor Gray
        git clone --depth 1 "https://github.com/akashvernerkar007-cloud/jarvis-dynamic-island.git" $installDir 2>$null
    } else {
        Write-Host "[*] Downloading latest release archive..." -ForegroundColor Gray
        $zipPath = "$env:TEMP\jarvis-dynamic-island.zip"
        $repoZipUrl = "https://github.com/akashvernerkar007-cloud/jarvis-dynamic-island/archive/refs/heads/main.zip"
        try {
            Invoke-RestMethod -Uri $repoZipUrl -OutFile $zipPath
            Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\jarvis_unzip" -Force
            Copy-Item "$env:TEMP\jarvis_unzip\jarvis-dynamic-island-main\*" $installDir -Recurse -Force
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:TEMP\jarvis_unzip" -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Host "[!] Note: Replace 'USER_OR_ORG' in install.ps1 with your GitHub username." -ForegroundColor Yellow
        }
    }
}

Set-Location $installDir

# 2. Setup Python & Faster-Whisper Voice Engine
Write-Host "`n[*] Checking Python & Speech Engine..." -ForegroundColor Cyan
$pythonCmd = (Get-Command "python.exe" -ErrorAction SilentlyContinue).Source
if (-not $pythonCmd) {
    # Check common user install paths
    $commonPy = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
    )
    foreach ($p in $commonPy) {
        if (Test-Path $p) { $pythonCmd = $p; break }
    }
}

if ($pythonCmd) {
    Write-Host "[+] Found Python at: $pythonCmd" -ForegroundColor Green
    $venvDir = Join-Path $installDir ".venv"
    if (-not (Test-Path $venvDir)) {
        Write-Host "[*] Creating dedicated virtual environment (.venv)..." -ForegroundColor Gray
        & $pythonCmd -m venv $venvDir
    }

    $pipExe = Join-Path $venvDir "Scripts\pip.exe"
    $reqFile = Join-Path $installDir "requirements.txt"
    if ((Test-Path $pipExe) -and (Test-Path $reqFile)) {
        Write-Host "[*] Installing neural speech dependencies (faster-whisper, sounddevice)..." -ForegroundColor Gray
        & $pipExe install -r $reqFile -q --no-warn-script-location
        Write-Host "[+] Speech engine ready!" -ForegroundColor Green
    }
} else {
    Write-Host "[!] Python not detected. JARVIS will use Windows SAPI dictation fallback." -ForegroundColor Yellow
    Write-Host "    To enable ultra-accurate Faster-Whisper, install Python 3.10+ from python.org" -ForegroundColor Gray
}

# 3. Check Ollama AI Engine
Write-Host "`n[*] Checking Ollama Local AI Engine..." -ForegroundColor Cyan
$ollamaCmd = (Get-Command "ollama.exe" -ErrorAction SilentlyContinue).Source
if (-not $ollamaCmd) {
    $standardOllama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    if (Test-Path $standardOllama) { $ollamaCmd = $standardOllama }
}

if ($ollamaCmd) {
    Write-Host "[+] Found Ollama: $ollamaCmd" -ForegroundColor Green
    # Check if model is pulled
    Write-Host "[*] Verifying AI model (qwen3.5:2b)..." -ForegroundColor Gray
    try {
        & $ollamaCmd serve 2>$null | Out-Null
        Start-Sleep -Seconds 1
        & $ollamaCmd pull qwen3.5:2b
        Write-Host "[+] AI model qwen3.5:2b is ready!" -ForegroundColor Green
    } catch {}
} else {
    Write-Host "[!] Ollama is not installed." -ForegroundColor Yellow
    Write-Host "    Install Ollama easily from: https://ollama.com/download" -ForegroundColor Gray
    Write-Host "    Then run: ollama run qwen3.5:2b" -ForegroundColor Gray
}

# 4. Create Desktop Shortcut
Write-Host "`n[*] Creating Desktop Shortcut..." -ForegroundColor Cyan
try {
    $wsh = New-Object -ComObject WScript.Shell
    $shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "JARVIS.lnk"
    $shortcut = $wsh.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "cmd.exe"
    $launchBat = Join-Path $installDir "launch.bat"
    $shortcut.Arguments = "/c `"$launchBat`""
    $shortcut.WorkingDirectory = $installDir
    $shortcut.WindowStyle = 7 # Minimized
    
    $iconPath = Join-Path $installDir "jarvis.ico"
    if (Test-Path $iconPath) {
        $shortcut.IconLocation = $iconPath
    } else {
        $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,238"
    }
    $shortcut.Save()
    Write-Host "[+] Desktop shortcut created: JARVIS.lnk" -ForegroundColor Green
} catch {
    Write-Host "[!] Could not create desktop shortcut: $_" -ForegroundColor Yellow
}

# 5. Launch JARVIS Dynamic Island
Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host " [+] INSTALLATION COMPLETE!" -ForegroundColor Green
Write-Host " [+] Launching JARVIS Dynamic Island now..." -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$batFile = Join-Path $installDir "launch.bat"
if (Test-Path $batFile) {
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$batFile`"" -WindowStyle Hidden
} else {
    $psScript = Join-Path $installDir "JarvisIsland.ps1"
    Start-Process powershell.exe -ArgumentList @("-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", "`"$psScript`"")
}

Write-Host "Look at the top center of your screen for your new Dynamic Island!" -ForegroundColor Green
Start-Sleep -Seconds 2
