<div align="center">

# 🏝️ JARVIS in<img width="1536" height="1024" alt="Jarvis Dynamic Island Emotion Gallery" src="https://github.com/user-attachments/assets/4fe6ab0f-549f-4c02-b4a1-05e5719ba787" />
 Dynamic Island for Windows

**An intelligent, futuristic Dynamic Island assistant for Windows featuring expressive OLED eye animations, sub-second local neural AI, high-accuracy Faster-Whisper voice recognition, and an integrated Clipboard History manager.**

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6?style=for-the-badge&logo=windows)](https://microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE?style=for-the-badge&logo=powershell)](https://github.com/PowerShell/PowerShell)
[![Local AI](https://img.shields.io/badge/Local%20AI-Ollama%20%7C%20Qwen%203.5-00F0A8?style=for-the-badge)](https://ollama.com)
[![Voice Engine](https://img.shields.io/badge/Speech%20Recognition-Faster--Whisper-FF6B8B?style=for-the-badge)](https://github.com/SYSTRAN/faster-whisper)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

</div>

---

## ⚡ 1-Command Installation (PowerShell)

Open **PowerShell** (Win + X → Terminal / PowerShell) and paste this single command:

```powershell
irm https://raw.githubusercontent.com/akashvernerkar007-cloud/jarvis-dynamic-island/main/install.ps1 | iex
```

This one-liner will automatically:
1. Clone the repository into your local application directory.
2. Setup the Python virtual environment and install speech dependencies (`faster-whisper`, `sounddevice`, `fastapi`).
3. Connect to your local Ollama AI engine and pull `qwen3.5:2b`.
4. Create a desktop shortcut (**`JARVIS.lnk`**).
5. Instantly launch the Dynamic Island at the top of your screen!

---

## 🚀 Alternative Manual Setup

If you prefer to clone and install manually:

```powershell
# 1. Clone the repository
git clone https://github.com/akashvernerkar007-cloud/jarvis-dynamic-island.git
cd jarvis-dynamic-island

# 2. Run the automated installer
.\install.ps1
```

Or just double-click **`launch.bat`**!

---

## ✨ Features

### 1. 🏝️ Sleek Dynamic Island Dock
- Docks seamlessly at the top center of your primary monitor.
- **Auto-Hide / Reveal**: Floats down smoothly when you hover your mouse near the top bezel, and docks back up when inactive.
- **Pin / Float**: Click the pin button to keep the island pinned permanently on top.
- **Glassmorphism Acrylic Design**: Obsidian black acrylic body with glowing neon cyan borders.

### 2. 👀 Expressive Emotion-Driven OLED Eyes
- Cyberpunk dual OLED robotic eyes that dynamically morph based on what you ask or say:
  - 🧐 **Curious / Inquisitive**: Questions (*"what is...", "why does...", "who was..."*).
  - 🤩 **Excited**: Fun topics, jokes, celebrations.
  - 💖 **Heart Eyes / Love**: Compliments and appreciation (*"thank you", "great job"*).
  - 😮 **Surprised**: Astronomy, cosmos, quantum science facts.
  - 😉 **Wink**: Confirming commands (*opening apps, taking screenshots*).
  - 😊 **Happy**: Standard friendly dialogue.
- **Mouth / Speech Pulse**: Eyes pulse naturally in sync with voice output when JARVIS speaks.
- Negative emotions (*angry, sad, dizzy*) have been permanently removed for a positive companion feel.

### 3. 🎙️ Sub-Second Local AI & Faster-Whisper Voice
- **Direct Answers Only**: No robotic filler (*"The system is processing your query..."*) and no hallucinated vision claims (*"I am scanning the room..."*).
- **Faster-Whisper Neural Speech Recognition**: Uses `faster-whisper` (`base.en` with int8 quantization and VAD filtering) running locally for near 100% voice accuracy in ~0.4s.
- **Sub-Second Q&A**: Powered by local Ollama (`qwen3.5:2b`) answering in 300ms–600ms.

### 4. 📋 Built-in Clipboard History Pop-Up Screen
- Automatically monitors your clipboard in the background—every `Ctrl+C` text clip is saved with a timestamp and character count.
- **Click `📋 Clip` in the island tray**: Opens a dedicated floating glass pop-up window.
- **Real-Time Search**: Filter through your historical clips instantly.
- **1-Click Copy**: Click any card to re-copy it to your active clipboard (flashes `✓ Copied!`).
- **Win+V Integration**: Includes a button to invoke Windows 11's native clipboard history.

### 5. 🛠️ Productivity Shortcuts
- **Open Apps**: Speak or type *"open chrome"*, *"open notepad"*, *"open vscode"*, *"open calc"*, *"open spotify"*, *"open settings"*.
- **Instant Screenshots**: Tap `📸 Shot` or say *"take screenshot"* to capture your screen directly to `Pictures\Screenshots` and copy it to your clipboard.
- **Color Accent Switcher**: Cycle island neon theme accents with a click.

---

## 📂 Project Structure

```
jarvis-dynamic-island/
├── JarvisIsland.ps1         # Native WPF Dynamic Island app (Zero machine-specific paths)
├── whisper_service.py       # Local Faster-Whisper FastAPI neural speech microservice
├── requirements.txt         # Python dependencies for voice recognition
├── jarvis.ico               # High-res Dynamic Island application icon
├── config.json              # Configurable endpoints, AI model, and timeouts
├── install.ps1              # 1-command installer script
├── launch.bat               # Double-click silent background launcher
├── .gitignore               # Clean git exclusions
├── LICENSE                  # MIT Open Source License
└── README.md                # Documentation & Quickstart
```

---

## ⚙️ Configuration (`config.json`)

You can customize JARVIS behavior without modifying code:

```json
{
  "ai": {
    "provider": "ollama",
    "endpoint": "http://127.0.0.1:11434",
    "model": "qwen3.5:2b",
    "temperature": 0.2,
    "max_tokens": 45
  },
  "voice": {
    "whisper_endpoint": "http://127.0.0.1:8765",
    "whisper_model": "base.en",
    "tts_rate": 1,
    "record_timeout_seconds": 6.5
  },
  "island": {
    "width": 290,
    "height": 175,
    "extended_height": 180,
    "auto_hide_seconds": 3.4,
    "clipboard_history_max": 50
  }
}
```

---

## 🛠️ Requirements

- **Operating System**: Windows 10 (1903+) or Windows 11 (64-bit).
- **PowerShell**: PowerShell 5.1 (built into Windows) or PowerShell 7+.
- **Ollama**: [Download Ollama for Windows](https://ollama.com/download) (for local sub-second AI).
- **Python (Optional for Whisper)**: Python 3.10+ (fallback Windows SAPI dictation is used if Python is not installed).

---

## 📤 How to Push This to Your GitHub Repository

1. Create a new repository on GitHub (e.g. `jarvis-dynamic-island`).
2. In PowerShell, navigate to this folder and run:

```powershell
cd "jarvis-dynamic-island"
git init
git add .
git commit -m "feat: Initial commit of JARVIS Dynamic Island for Windows"
git branch -M main
git remote add origin https://github.com/<YOUR_GITHUB_USERNAME>/jarvis-dynamic-island.git
git push -u origin main
```

Now anyone can install your project with the 1-liner command!

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
