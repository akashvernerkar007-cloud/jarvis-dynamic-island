Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, System.Speech

# Compile C# SpeechBridge (pure dictation without Choices grammar so it never force-snaps to wrong commands!)
Add-Type -TypeDefinition @"
using System;
using System.Speech.Recognition;
using System.Globalization;

public class SpeechBridge {
    private SpeechRecognitionEngine sre;
    public string LastRecognized = null;
    public bool IsListening = false;
    public bool HasResult = false;

    public bool Initialize() {
        try {
            CultureInfo culture = new CultureInfo("en-US");
            sre = new SpeechRecognitionEngine(culture);
            sre.SetInputToDefaultAudioDevice();

            sre.EndSilenceTimeout = TimeSpan.FromSeconds(2.0);
            sre.EndSilenceTimeoutAmbiguous = TimeSpan.FromSeconds(2.0);
            sre.InitialSilenceTimeout = TimeSpan.FromSeconds(10.0);

            // Pure dictation grammar - NO forced choices that corrupt freeform questions!
            DictationGrammar dict = new DictationGrammar();
            sre.LoadGrammar(dict);

            sre.SpeechRecognized += (s, e) => {
                if (e.Result != null && !string.IsNullOrEmpty(e.Result.Text)) {
                    LastRecognized = e.Result.Text;
                    HasResult = true;
                    IsListening = false;
                }
            };
            sre.RecognizeCompleted += (s, e) => {
                IsListening = false;
            };
            return true;
        } catch {
            return false;
        }
    }

    public void StartListening() {
        if (sre != null) {
            LastRecognized = null;
            HasResult = false;
            IsListening = true;
            try { sre.RecognizeAsync(RecognizeMode.Single); } catch { IsListening = false; }
        }
    }

    public void StopListening() {
        if (sre != null) {
            IsListening = false;
            try { sre.RecognizeAsyncCancel(); } catch {}
        }
    }
}

public class WinKeyHelper {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
    public const int KEYEVENTF_KEYUP = 0x0002;
    public const byte VK_LWIN = 0x5B;
    public const byte VK_V = 0x56;
    public static void OpenWinV() {
        keybd_event(VK_LWIN, 0, 0, 0);
        keybd_event(VK_V, 0, 0, 0);
        keybd_event(VK_V, 0, KEYEVENTF_KEYUP, 0);
        keybd_event(VK_LWIN, 0, KEYEVENTF_KEYUP, 0);
    }
}
"@ -ReferencedAssemblies System.Speech

# ==============================================================================
# DYNAMIC PORTABLE PATH & CONFIGURATION INITIALIZATION
# ==============================================================================
$script:rootDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $script:rootDirectory) { $script:rootDirectory = (Get-Location).Path }

# Optional config.json
$script:configFile = Join-Path $script:rootDirectory "config.json"
$script:config = $null
if (Test-Path $script:configFile) {
    try { $script:config = Get-Content $script:configFile -Raw -Encoding utf8 | ConvertFrom-Json } catch {}
}

$script:ollamaEndpoint  = if ($script:config.ai.endpoint) { $script:config.ai.endpoint } else { "http://127.0.0.1:11434" }
$script:aiModel         = if ($script:config.ai.model) { $script:config.ai.model } else { "qwen3.5:2b" }
$script:whisperEndpoint = if ($script:config.voice.whisper_endpoint) { $script:config.voice.whisper_endpoint } else { "http://127.0.0.1:8765" }
$script:clipHistoryFile = Join-Path $script:rootDirectory "clipboard_history.json"

function Get-OllamaExe {
    $cmd = Get-Command "ollama.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $localApp = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    if (Test-Path $localApp) { return $localApp }
    $progFiles = "$env:ProgramFiles\Ollama\ollama.exe"
    if (Test-Path $progFiles) { return $progFiles }
    return $null
}

function Ensure-OllamaRunning {
    try {
        $null = Invoke-RestMethod -Uri "$script:ollamaEndpoint/api/tags" -TimeoutSec 1 -ErrorAction Stop
        return $true
    } catch {
        $ollamaExe = Get-OllamaExe
        if ($ollamaExe -and (Test-Path $ollamaExe)) {
            Start-Process $ollamaExe -ArgumentList "serve" -WindowStyle Hidden
            for ($i = 0; $i -lt 15; $i++) {
                Start-Sleep -Milliseconds 400
                try {
                    $null = Invoke-RestMethod -Uri "$script:ollamaEndpoint/api/tags" -TimeoutSec 1 -ErrorAction Stop
                    return $true
                } catch {}
            }
        }
        return $false
    }
}
$null = Ensure-OllamaRunning

function Get-PythonExe {
    # 1. Local repository virtual environment
    $localVenv = Join-Path $script:rootDirectory ".venv\Scripts\python.exe"
    if (Test-Path $localVenv) { return $localVenv }

    # 2. OpenJarvis virtual environment
    $openJarvis = "$env:LOCALAPPDATA\OpenJarvis\src\.venv\Scripts\python.exe"
    if (Test-Path $openJarvis) { return $openJarvis }

    # 3. System Python in PATH
    $sysPy = (Get-Command "python.exe" -ErrorAction SilentlyContinue).Source
    if ($sysPy) { return $sysPy }

    # 4. Standard Python installations in LocalAppData or ProgramFiles
    $pyDirs = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe",
        "C:\Python310\python.exe"
    )
    foreach ($p in $pyDirs) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Ensure-WhisperRunning {
    try {
        $null = Invoke-RestMethod -Uri "$script:whisperEndpoint/health" -TimeoutSec 1 -ErrorAction Stop
        return $true
    } catch {
        $pyExe = Get-PythonExe
        $svc = Join-Path $script:rootDirectory "whisper_service.py"
        if ($pyExe -and (Test-Path $svc)) {
            Start-Process $pyExe -ArgumentList "`"$svc`"" -WindowStyle Hidden
            for ($i = 0; $i -lt 15; $i++) {
                Start-Sleep -Milliseconds 400
                try {
                    $null = Invoke-RestMethod -Uri "$script:whisperEndpoint/health" -TimeoutSec 1 -ErrorAction Stop
                    return $true
                } catch {}
            }
        }
        return $false
    }
}
$null = Ensure-WhisperRunning

$screenW = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$islandW = 290
$islandH = 175
$posX = [int](($screenW - $islandW) / 2)

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="JARVIS Island"
        Width="$islandW" Height="$islandH"
        WindowStartupLocation="Manual" Left="$posX" Top="0"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False">
    <Grid>
        <!-- The Dynamic Island Pill -->
        <Border Name="IslandBorder"
                Width="260" Height="70"
                VerticalAlignment="Top" HorizontalAlignment="Center"
                Background="#040608"
                CornerRadius="0,0,26,26"
                BorderThickness="1,0,1,1" BorderBrush="#24ffffff"
                Cursor="Arrow"
                RenderTransformOrigin="0.5,0">
            <Border.RenderTransform>
                <TranslateTransform X="0" Y="0"/>
            </Border.RenderTransform>
            <Border.Effect>
                <DropShadowEffect BlurRadius="25" ShadowDepth="8" Opacity="0.85" Color="#000000"/>
            </Border.Effect>

            <Grid>
                <!-- Top Laptop Camera Notch Indicator -->
                <Ellipse Width="8" Height="8"
                         VerticalAlignment="Top" HorizontalAlignment="Center"
                         Margin="0,4,0,0"
                         Fill="#010204" Stroke="#223344" StrokeThickness="1.5"/>

                <!-- CLEAN FRAMELESS PIN ICON -->
                <TextBlock Name="PinIcon"
                           Text="📌" FontSize="11"
                           HorizontalAlignment="Right" VerticalAlignment="Top"
                           Margin="0,4,8,0"
                           Cursor="Hand"
                           Opacity="0.3"
                           Foreground="#ffffff"
                           ToolTip="Pin Open (Click to Lock)"/>

                <!-- Compact OLED Robot Eyes (Clickable for emotions) -->
                <Border Name="EyesClickArea"
                        Background="Transparent"
                        Cursor="Hand"
                        HorizontalAlignment="Center" VerticalAlignment="Top"
                        Margin="0,8,0,0"
                        ToolTip="Left-Click: Next Emotion | 2-Finger/Right-Click: Expand Tray">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                        <!-- Left Eye Frame -->
                        <Grid Name="LeftEyeFrame" Width="46" Height="46" HorizontalAlignment="Center" VerticalAlignment="Center">
                            <!-- Main OLED Rectangle Eye -->
                            <Rectangle Name="EyeLeft" Width="38" Height="38"
                                       RadiusX="13" RadiusY="13"
                                       Fill="#00f0ff"
                                       RenderTransformOrigin="0.5,0.5">
                                <Rectangle.Effect>
                                    <DropShadowEffect BlurRadius="22" ShadowDepth="0" Color="#00f0ff" Opacity="0.85"/>
                                </Rectangle.Effect>
                                <Rectangle.RenderTransform>
                                    <TransformGroup>
                                        <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        <TranslateTransform X="0" Y="0"/>
                                        <RotateTransform Angle="0"/>
                                    </TransformGroup>
                                </Rectangle.RenderTransform>
                            </Rectangle>

                            <!-- Happy Arc -->
                            <Path Name="HappyLeft" Width="38" Height="28"
                                  Visibility="Collapsed"
                                  Stroke="#00f0ff" StrokeThickness="6.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                  Data="M 3,24 A 16,16 0 0 1 35,24">
                                <Path.Effect>
                                    <DropShadowEffect BlurRadius="18" ShadowDepth="0" Color="#00f0ff" Opacity="0.9"/>
                                </Path.Effect>
                            </Path>

                            <!-- Glowing Valentine Heart -->
                            <Path Name="HeartLeft" Width="32" Height="30"
                                  Visibility="Collapsed"
                                  Fill="#ff2a6d" Stretch="Uniform"
                                  RenderTransformOrigin="0.5,0.5"
                                  Data="M 12,21.35 l -1.45,-1.32 C 5.4,15.36 2,12.28 2,8.5 C 2,5.42 4.42,3 7.5,3 c 1.74,0 3.41,0.81 4.5,2.09 C 13.09,3.81 14.76,3 16.5,3 C 19.58,3 22,5.42 22,8.5 c 0,3.78 -3.4,6.86 -8.55,11.54 L 12,21.35 z">
                                <Path.Effect>
                                    <DropShadowEffect BlurRadius="20" ShadowDepth="0" Color="#ff2a6d" Opacity="0.9"/>
                                </Path.Effect>
                                <Path.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1"/>
                                </Path.RenderTransform>
                            </Path>
                        </Grid>

                        <!-- Spacing -->
                        <Border Width="20" Height="10"/>

                        <!-- Right Eye Frame -->
                        <Grid Name="RightEyeFrame" Width="46" Height="46" HorizontalAlignment="Center" VerticalAlignment="Center">
                            <!-- Main OLED Rectangle Eye -->
                            <Rectangle Name="EyeRight" Width="38" Height="38"
                                       RadiusX="13" RadiusY="13"
                                       Fill="#00f0ff"
                                       RenderTransformOrigin="0.5,0.5">
                                <Rectangle.Effect>
                                    <DropShadowEffect BlurRadius="22" ShadowDepth="0" Color="#00f0ff" Opacity="0.85"/>
                                </Rectangle.Effect>
                                <Rectangle.RenderTransform>
                                    <TransformGroup>
                                        <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        <TranslateTransform X="0" Y="0"/>
                                        <RotateTransform Angle="0"/>
                                    </TransformGroup>
                                </Rectangle.RenderTransform>
                            </Rectangle>

                            <!-- Happy Arc -->
                            <Path Name="HappyRight" Width="38" Height="28"
                                  Visibility="Collapsed"
                                  Stroke="#00f0ff" StrokeThickness="6.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                  Data="M 3,24 A 16,16 0 0 1 35,24">
                                <Path.Effect>
                                    <DropShadowEffect BlurRadius="18" ShadowDepth="0" Color="#00f0ff" Opacity="0.9"/>
                                </Path.Effect>
                            </Path>

                            <!-- Glowing Valentine Heart -->
                            <Path Name="HeartRight" Width="32" Height="30"
                                  Visibility="Collapsed"
                                  Fill="#ff2a6d" Stretch="Uniform"
                                  RenderTransformOrigin="0.5,0.5"
                                  Data="M 12,21.35 l -1.45,-1.32 C 5.4,15.36 2,12.28 2,8.5 C 2,5.42 4.42,3 7.5,3 c 1.74,0 3.41,0.81 4.5,2.09 C 13.09,3.81 14.76,3 16.5,3 C 19.58,3 22,5.42 22,8.5 c 0,3.78 -3.4,6.86 -8.55,11.54 L 12,21.35 z">
                                <Path.Effect>
                                    <DropShadowEffect BlurRadius="20" ShadowDepth="0" Color="#ff2a6d" Opacity="0.9"/>
                                </Path.Effect>
                                <Path.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1"/>
                                </Path.RenderTransform>
                            </Path>
                        </Grid>
                    </StackPanel>
                </Border>

                <!-- Live Subtitle / Status Text -->
                <TextBlock Name="StatusText"
                           Text="JARVIS • Ready"
                           FontSize="9"
                           FontFamily="Segoe UI"
                           FontWeight="Medium"
                           Foreground="#8899aa"
                           HorizontalAlignment="Center"
                           VerticalAlignment="Top"
                           Margin="0,52,0,0"
                           MaxWidth="240"
                           TextTrimming="CharacterEllipsis"
                           ToolTip="Status / Live Subtitles"/>

                <!-- EXTENDED ACTION TRAY (Reveals on 2-Finger Tap / Right-Click) -->
                <StackPanel Name="ActionTray"
                            VerticalAlignment="Bottom" HorizontalAlignment="Center"
                            Margin="0,0,0,8"
                            Opacity="0"
                            Visibility="Collapsed">
                    <!-- Quick Actions Row -->
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,5">
                        <Border Name="MicBtn" Width="44" Height="24" CornerRadius="12"
                                Background="#1a00f0a8" BorderBrush="#00f0a8" BorderThickness="1"
                                Cursor="Hand" Margin="2,0" ToolTip="Voice (Click to Speak)">
                            <TextBlock Name="MicText" Text="🎙️ Mic" FontSize="9" FontWeight="Bold"
                                       Foreground="#00f0a8" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>

                        <Border Name="ClipBtn" Width="44" Height="24" CornerRadius="12"
                                Background="#1affffff" BorderBrush="#33ffffff" BorderThickness="1"
                                Cursor="Hand" Margin="2,0" ToolTip="Clipboard History (Click to Open Pop-Up)">
                            <TextBlock Text="📋 Clip" FontSize="9" FontWeight="SemiBold"
                                       Foreground="#ffffff" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>

                        <Border Name="ShotBtn" Width="44" Height="24" CornerRadius="12"
                                Background="#1affffff" BorderBrush="#33ffffff" BorderThickness="1"
                                Cursor="Hand" Margin="2,0" ToolTip="Take Screenshot">
                            <TextBlock Text="📸 Shot" FontSize="9" FontWeight="SemiBold"
                                       Foreground="#ffffff" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>

                        <Border Name="ColorBtn" Width="24" Height="24" CornerRadius="12"
                                Background="#1affffff" BorderBrush="#33ffffff" BorderThickness="1"
                                Cursor="Hand" Margin="2,0" ToolTip="Change Color">
                            <TextBlock Text="🎨" FontSize="9" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </StackPanel>

                    <!-- Type Input Box for AI -->
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                        <TextBox Name="ChatInput" Width="180" Height="22"
                                 Background="#141c24" BorderBrush="#33ffffff" BorderThickness="1"
                                 Foreground="#ffffff" FontSize="10" Padding="4,2"
                                 VerticalContentAlignment="Center"
                                 ToolTip="Type anything to ask Jarvis (Press Enter)"/>
                        <Border Name="SendBtn" Width="26" Height="22" CornerRadius="4"
                                Background="#00f0ff" Cursor="Hand" Margin="3,0,0,0" ToolTip="Send">
                            <TextBlock Text="➤" FontSize="10" FontWeight="Bold" Foreground="#000000"
                                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </StackPanel>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Element References
$islandBorder  = $window.FindName("IslandBorder")
$islandSlide   = $islandBorder.RenderTransform
$pinIcon       = $window.FindName("PinIcon")
$eyesClickArea = $window.FindName("EyesClickArea")
$statusText    = $window.FindName("StatusText")
$actionTray    = $window.FindName("ActionTray")
$micBtn        = $window.FindName("MicBtn")
$micText       = $window.FindName("MicText")
$clipBtn       = $window.FindName("ClipBtn")
$shotBtn       = $window.FindName("ShotBtn")
$colorBtn      = $window.FindName("ColorBtn")
$chatInput     = $window.FindName("ChatInput")
$sendBtn       = $window.FindName("SendBtn")

$eyeLeft       = $window.FindName("EyeLeft")
$eyeRight      = $window.FindName("EyeRight")
$happyLeft     = $window.FindName("HappyLeft")
$happyRight    = $window.FindName("HappyRight")
$heartLeft     = $window.FindName("HeartLeft")
$heartRight    = $window.FindName("HeartRight")

$scaleLeft  = $eyeLeft.RenderTransform.Children[0]
$transLeft  = $eyeLeft.RenderTransform.Children[1]
$rotLeft    = $eyeLeft.RenderTransform.Children[2]

$scaleRight = $eyeRight.RenderTransform.Children[0]
$transRight = $eyeRight.RenderTransform.Children[1]
$rotRight   = $eyeRight.RenderTransform.Children[2]

# State Variables
$script:isOpen = $true
$script:isPinned = $false
$script:isExtended = $false
$script:isThinking = $false
$script:isSpeaking = $false
$script:awayCounter = -90

# Friendly, Positive, Intelligent OLED Robot Emotions
$script:emotions = @(
    "neutral",    # Classic OLED rounded rectangle eyes with organic gaze
    "happy",      # Upward glowing smiles ^ ^
    "wink",       # Left wink ^, Right open eye O
    "love",       # Glowing pulse Valentine OLED hearts ♥ ♥
    "curious",    # Inquisitive asymmetrical brow tilt ("Hmm?")
    "surprised",  # Wide circular neon eyes O O
    "excited",    # Bouncy squash-and-stretch celebration!
    "sleepy"      # Relaxed horizontal slit eyes
)
$script:emotionIndex = 0

$script:colors = @(
    @{ Name = "Cyan";   Hex = "#00f0ff" },
    @{ Name = "Yellow"; Hex = "#ffd000" },
    @{ Name = "Green";  Hex = "#00f0a8" },
    @{ Name = "Pink";   Hex = "#ec4899" },
    @{ Name = "Blue";   Hex = "#3b82f6" },
    @{ Name = "Purple"; Hex = "#a855f7" }
)
$script:colorIndex = 0

# Speech Synthesis (Crisp, Fast, Natural Voice)
$script:synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$script:synth.Rate = 1
$installedVoices = $script:synth.GetInstalledVoices()
foreach ($v in $installedVoices) {
    if ($v.VoiceInfo.Name -like "*David*" -or $v.VoiceInfo.Name -like "*George*") {
        $script:synth.SelectVoice($v.VoiceInfo.Name)
        break
    }
}

function Speak-Jarvis([string]$text, [string]$emo = "happy") {
    try {
        $script:isSpeaking = $true
        Set-Emotion $emo
        $statusText.Text = $text
        $statusText.ToolTip = $text
        $dur = [Math]::Max(1.5, [Math]::Min(10.0, ($text.Length * 0.055)))
        if ($scaleLeft -ne $null -and $scaleRight -ne $null) {
            $talkAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
            $talkAnim.From = 1.0
            $talkAnim.To = 0.75
            $talkAnim.Duration = [TimeSpan]::FromMilliseconds(110)
            $talkAnim.AutoReverse = $true
            $talkAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::new([TimeSpan]::FromSeconds($dur))
            $scaleLeft.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $talkAnim)
            $scaleRight.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $talkAnim)
        }
        if ($script:synth -ne $null) {
            $script:synth.SpeakAsyncCancelAll()
            $script:synth.SpeakAsync($text) | Out-Null
        }
        $speechTimer = New-Object System.Windows.Threading.DispatcherTimer
        $speechTimer.Interval = [TimeSpan]::FromSeconds($dur + 0.4)
        $speechTimer.Add_Tick({
            $script:isSpeaking = $false
            $this.Stop()
            $restoreTimer = New-Object System.Windows.Threading.DispatcherTimer
            $restoreTimer.Interval = [TimeSpan]::FromSeconds(2.0)
            $restoreTimer.Add_Tick({
                if (-not $script:isSpeaking -and -not $script:isThinking) {
                    Set-Emotion "neutral"
                }
                $this.Stop()
            })
            $restoreTimer.Start()
        })
        $speechTimer.Start()
    } catch {
        $script:isSpeaking = $false
    }
}

# Slide Animation
function Animate-Island([double]$targetY) {
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.To = $targetY
    $anim.Duration = [TimeSpan]::FromMilliseconds(220)
    $anim.DecelerationRatio = 0.35
    $islandSlide.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $anim)
}

# Height Expand / Collapse Animation (for 2-Finger Tray)
function Toggle-Extend() {
    $script:isExtended = -not $script:isExtended

    $targetH = if ($script:isExtended) { 142.0 } else { 70.0 }
    $animH = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animH.To = $targetH
    $animH.Duration = [TimeSpan]::FromMilliseconds(240)
    $animH.DecelerationRatio = 0.35
    $islandBorder.BeginAnimation([System.Windows.Controls.Border]::HeightProperty, $animH)

    if ($script:isExtended) {
        $actionTray.Visibility = [System.Windows.Visibility]::Visible
        $animO = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [TimeSpan]::FromMilliseconds(220))
        $actionTray.BeginAnimation([System.Windows.Controls.StackPanel]::OpacityProperty, $animO)
        $chatInput.Focus() | Out-Null
    } else {
        $actionTray.Visibility = [System.Windows.Visibility]::Collapsed
    }
}

function Open-Island() {
    if (-not $script:isOpen) {
        $script:isOpen = $true
        $script:awayCounter = 0
        Animate-Island 0.0
    }
}

function Close-Island() {
    if ($script:isPinned -or $script:isExtended -or $script:isThinking -or $script:isSpeaking) { return }
    if ($script:isOpen) {
        $script:isOpen = $false
        Animate-Island -58.0
    }
}

# Toggle Pin Mode (Clean Frameless Pin!)
function Toggle-Pin() {
    $script:isPinned = -not $script:isPinned

    if ($script:isPinned) {
        Open-Island
        $pinIcon.Opacity = 1.0
        $pinIcon.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#00f0ff")
        $pinIcon.ToolTip = "Island PINNED (Click to Unpin)"
    } else {
        $pinIcon.Opacity = 0.3
        $pinIcon.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#ffffff")
        $pinIcon.ToolTip = "Pin Open (Click to Lock)"
        $script:awayCounter = 0
    }
}

# Color Function
function Set-EyeColor($hex) {
    $brush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex)
    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)

    $eyeLeft.Fill = $brush
    $eyeRight.Fill = $brush
    $eyeLeft.Effect.Color = $color
    $eyeRight.Effect.Color = $color
    $happyLeft.Stroke = $brush
    $happyRight.Stroke = $brush
}

# ==================== DYNAMIC EYE ANIMATION SUITE ====================

# 1. Bouncy Spring Animation (Excited / Happy)
function Play-BounceAnimation() {
    $animY = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $animY.Duration = [TimeSpan]::FromMilliseconds(400)

    $k1 = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame(-7.0, [TimeSpan]::FromMilliseconds(110))
    $k2 = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame(2.0, [TimeSpan]::FromMilliseconds(220))
    $k3 = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame(-3.0, [TimeSpan]::FromMilliseconds(310))
    $k4 = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame(0.0, [TimeSpan]::FromMilliseconds(400))

    $null = $animY.KeyFrames.Add($k1)
    $null = $animY.KeyFrames.Add($k2)
    $null = $animY.KeyFrames.Add($k3)
    $null = $animY.KeyFrames.Add($k4)

    $transLeft.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $animY)
    $transRight.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $animY)
}

# 2. Cute Wink Animation
function Play-WinkAnimation() {
    $animWink = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $animWink.Duration = [TimeSpan]::FromMilliseconds(360)

    $k1 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0.08, [TimeSpan]::FromMilliseconds(90))
    $k2 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0.08, [TimeSpan]::FromMilliseconds(220))
    $k3 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(1.0, [TimeSpan]::FromMilliseconds(360))

    $null = $animWink.KeyFrames.Add($k1)
    $null = $animWink.KeyFrames.Add($k2)
    $null = $animWink.KeyFrames.Add($k3)

    $scaleLeft.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $animWink)
}

# 3. Heartbeat Pulse Animation
function Play-Heartbeat() {
    $pulse = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $pulse.Duration = [TimeSpan]::FromMilliseconds(650)
    $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::new([TimeSpan]::FromSeconds(2.0))

    $k1 = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame(1.22, [TimeSpan]::FromMilliseconds(130))
    $k2 = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame(1.0, [TimeSpan]::FromMilliseconds(260))
    $k3 = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame(1.14, [TimeSpan]::FromMilliseconds(380))
    $k4 = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame(1.0, [TimeSpan]::FromMilliseconds(650))

    $null = $pulse.KeyFrames.Add($k1)
    $null = $pulse.KeyFrames.Add($k2)
    $null = $pulse.KeyFrames.Add($k3)
    $null = $pulse.KeyFrames.Add($k4)

    $heartLeft.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $pulse)
    $heartLeft.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $pulse)
    $heartRight.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $pulse)
    $heartRight.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $pulse)
}

# 4. Camera Shutter Snapshot Flash
function Play-ShutterAnimation() {
    Set-Emotion "surprised"
    Start-Sleep -Milliseconds 100

    $animShut = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.05, [TimeSpan]::FromMilliseconds(50))
    $animShut.AutoReverse = $true
    $scaleLeft.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $animShut)
    $scaleRight.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $animShut)

    $flashAnim = New-Object System.Windows.Media.Animation.ColorAnimation
    $flashAnim.To = [System.Windows.Media.Color]::FromArgb(255, 255, 255, 255)
    $flashAnim.Duration = [TimeSpan]::FromMilliseconds(80)
    $flashAnim.AutoReverse = $true
    $islandBorder.Effect.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::ColorProperty, $flashAnim)
}

# Real-Time Automatic Emotion Detector based on user speech/text
function Detect-QueryEmotion([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return "happy" }
    $t = $text.ToLower().Trim()

    # Love / Affection / Appreciation
    if ($t -match '\b(love|heart|friend|best|thank|thanks|cute|sweet|appreciate|awesome|great|amazing|wonderful|like you)\b') {
        return "love"
    }

    # Excitement / Fun / Jokes / Play
    if ($t -match '\b(joke|funny|laugh|haha|lol|party|dance|excited|yay|cool|celebrate|fun|game|play)\b') {
        return "excited"
    }

    # Wonder / Amazement / Big Universe / Sci-fi
    if ($t -match '\b(space|universe|galaxy|cosmos|black hole|quantum|fastest|biggest|billion|magic|wow|omg|super)\b') {
        return "surprised"
    }

    # Inquisitive / Questions
    if ($t -match '\b(why|how|what|who|where|when|which|explain|tell me|curious|hmm|wonder|reason|meaning|capital|city|country)\b') {
        return "curious"
    }

    # Sleep / Night / Rest
    if ($t -match '\b(sleep|night|bed|tired|rest|goodnight|standby|bye|goodbye|see you)\b') {
        return "sleepy"
    }

    # Wink / Confirmations
    if ($t -match '\b(wink|sure|okay|ok|ready|assist|help|open)\b') {
        return "wink"
    }

    return "happy"
}

# Emotion Switcher Function
function Set-Emotion($emo) {
    # 1. Reset all path visibilities to Collapsed
    $happyLeft.Visibility = [System.Windows.Visibility]::Collapsed
    $happyRight.Visibility = [System.Windows.Visibility]::Collapsed
    $heartLeft.Visibility = [System.Windows.Visibility]::Collapsed
    $heartRight.Visibility = [System.Windows.Visibility]::Collapsed

    # 2. Reset base rectangular eyes to Visible
    $eyeLeft.Visibility = [System.Windows.Visibility]::Visible
    $eyeRight.Visibility = [System.Windows.Visibility]::Visible

    # 3. Clear running transforms
    $scaleLeft.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $scaleRight.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $transLeft.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
    $transRight.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
    $transLeft.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    $transRight.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)

    $rotLeft.Angle = 0
    $rotRight.Angle = 0
    $transLeft.Y = 0
    $transRight.Y = 0
    $scaleLeft.ScaleX = 1.0
    $scaleLeft.ScaleY = 1.0
    $scaleRight.ScaleX = 1.0
    $scaleRight.ScaleY = 1.0

    $eyeLeft.Width = 38
    $eyeLeft.Height = 38
    $eyeLeft.RadiusX = 13
    $eyeLeft.RadiusY = 13
    $eyeRight.Width = 38
    $eyeRight.Height = 38
    $eyeRight.RadiusX = 13
    $eyeRight.RadiusY = 13

    switch ($emo) {
        "happy" {
            $eyeLeft.Visibility = [System.Windows.Visibility]::Collapsed
            $eyeRight.Visibility = [System.Windows.Visibility]::Collapsed
            $happyLeft.Visibility = [System.Windows.Visibility]::Visible
            $happyRight.Visibility = [System.Windows.Visibility]::Visible
        }
        "love" {
            $eyeLeft.Visibility = [System.Windows.Visibility]::Collapsed
            $eyeRight.Visibility = [System.Windows.Visibility]::Collapsed
            $heartLeft.Visibility = [System.Windows.Visibility]::Visible
            $heartRight.Visibility = [System.Windows.Visibility]::Visible
            Play-Heartbeat
        }
        "wink" {
            $eyeLeft.Visibility = [System.Windows.Visibility]::Collapsed
            $happyLeft.Visibility = [System.Windows.Visibility]::Visible
            $eyeRight.Visibility = [System.Windows.Visibility]::Visible
            $eyeRight.Width = 38
            $eyeRight.Height = 38
            $eyeRight.RadiusX = 19
            $eyeRight.RadiusY = 19
        }
        "curious" {
            $eyeLeft.Width = 40
            $eyeLeft.Height = 40
            $eyeLeft.RadiusX = 18
            $eyeLeft.RadiusY = 18
            $transLeft.Y = -5
            $rotLeft.Angle = -7

            $eyeRight.Width = 34
            $eyeRight.Height = 26
            $eyeRight.RadiusX = 10
            $eyeRight.RadiusY = 10
            $transRight.Y = 3
            $rotRight.Angle = 5
        }
        "surprised" {
            $eyeLeft.Width = 42
            $eyeLeft.Height = 42
            $eyeLeft.RadiusX = 21
            $eyeLeft.RadiusY = 21
            $eyeRight.Width = 42
            $eyeRight.Height = 42
            $eyeRight.RadiusX = 21
            $eyeRight.RadiusY = 21
        }
        "excited" {
            $eyeLeft.Visibility = [System.Windows.Visibility]::Collapsed
            $eyeRight.Visibility = [System.Windows.Visibility]::Collapsed
            $happyLeft.Visibility = [System.Windows.Visibility]::Visible
            $happyRight.Visibility = [System.Windows.Visibility]::Visible
            Play-BounceAnimation
        }
        "sleepy" {
            $eyeLeft.Height = 16
            $eyeRight.Height = 16
            $eyeLeft.RadiusX = 8
            $eyeLeft.RadiusY = 8
            $eyeRight.RadiusX = 8
            $eyeRight.RadiusY = 8
        }
    }
}

# Screenshot Function
function Take-Screenshot() {
    Play-ShutterAnimation
    Animate-Island -80.0
    Start-Sleep -Milliseconds 240

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($screen.X, $screen.Y, 0, 0, $screen.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)

    $saveDir = "$env:USERPROFILE\Pictures\Screenshots"
    if (-not (Test-Path $saveDir)) { New-Item -ItemType Directory -Path $saveDir -Force | Out-Null }
    $fileName = "Screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
    $fullPath = Join-Path $saveDir $fileName
    $bmp.Save($fullPath, [System.Drawing.Imaging.ImageFormat]::Png)

    [System.Windows.Forms.Clipboard]::SetImage($bmp)
    $g.Dispose()
    $bmp.Dispose()

    Animate-Island 0.0
    Speak-Jarvis "Screenshot captured and saved to your Screenshots folder." "wink"
}

# ==============================================================================
# JARVIS CLIPBOARD HISTORY POP-UP SCREEN & REAL-TIME TRACKER
# ==============================================================================
if (-not $script:clipHistoryFile) {
    $script:clipHistoryFile = Join-Path $script:rootDirectory "clipboard_history.json"
}
$script:clipHistory = [System.Collections.ArrayList]::new()

if (Test-Path $script:clipHistoryFile) {
    try {
        $loaded = Get-Content $script:clipHistoryFile -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($it in $loaded) {
            [void]$script:clipHistory.Add($it)
        }
    } catch {}
}

# Seed with current clipboard if non-empty and new
try {
    $seed = [System.Windows.Forms.Clipboard]::GetText()
    if (-not [string]::IsNullOrWhiteSpace($seed)) {
        $first = if ($script:clipHistory.Count -gt 0) { $script:clipHistory[0].text } else { $null }
        if ($seed -ne $first) {
            $entry = [PSCustomObject]@{
                id = [Guid]::NewGuid().ToString().Substring(0, 8)
                time = (Get-Date -Format "HH:mm:ss")
                date = (Get-Date -Format "dd MMM")
                text = $seed
                chars = $seed.Length
            }
            $script:clipHistory.Insert(0, $entry)
            Save-ClipboardHistory
        }
    }
} catch {}

function Save-ClipboardHistory {
    try {
        $toSave = @($script:clipHistory | Select-Object -First 50)
        $json = $toSave | ConvertTo-Json -Depth 3
        $json | Out-File -FilePath $script:clipHistoryFile -Encoding utf8 -Force
    } catch {}
}

# Real-Time Clipboard Poller
$script:lastClipboardText = if ($script:clipHistory.Count -gt 0) { $script:clipHistory[0].text } else { "" }
$clipMonitorTimer = New-Object System.Windows.Threading.DispatcherTimer
$clipMonitorTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$clipMonitorTimer.Add_Tick({
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $txt = [System.Windows.Forms.Clipboard]::GetText()
            if (-not [string]::IsNullOrWhiteSpace($txt) -and $txt -ne $script:lastClipboardText) {
                $script:lastClipboardText = $txt
                $entry = [PSCustomObject]@{
                    id = [Guid]::NewGuid().ToString().Substring(0, 8)
                    time = (Get-Date -Format "HH:mm:ss")
                    date = (Get-Date -Format "dd MMM")
                    text = $txt
                    chars = $txt.Length
                }
                $script:clipHistory.Insert(0, $entry)
                if ($script:clipHistory.Count -gt 50) {
                    $script:clipHistory.RemoveAt(50)
                }
                Save-ClipboardHistory

                # If clipboard popup is open, live refresh the cards!
                if ($script:clipWindow -ne $null -and $script:clipWindow.IsVisible) {
                    Render-ClipboardHistory
                }
            }
        }
    } catch {}
})
$clipMonitorTimer.Start()

# Clipboard History Window XAML
$clipXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="JARVIS Clipboard History"
        Width="440" Height="520"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Topmost="True"
        ShowInTaskbar="False"
        WindowStartupLocation="Manual">
    <Border Name="MainCard" Background="#0b0f15" CornerRadius="16" BorderBrush="#00f0a8" BorderThickness="1.5" Margin="10">
        <Border.Effect>
            <DropShadowEffect Color="#00f0a8" BlurRadius="28" ShadowDepth="4" Opacity="0.35"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <Border Name="ClipHeader" Grid.Row="0" Background="#111722" CornerRadius="14,14,0,0" Padding="14,10" BorderBrush="#1a2536" BorderThickness="0,0,0,1" Cursor="SizeAll">
                <Grid>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="📋" FontSize="15" Margin="0,0,8,0" VerticalAlignment="Center"/>
                        <TextBlock Text="JARVIS CLIPBOARD HISTORY" FontSize="11" FontWeight="Bold" Foreground="#00f0a8" VerticalAlignment="Center"/>
                        <Border Name="CountBadge" Background="#1c283a" CornerRadius="8" Padding="6,2" Margin="8,0,0,0" VerticalAlignment="Center">
                            <TextBlock Name="CountText" Text="0 items" FontSize="9" Foreground="#64d2ff" FontWeight="SemiBold"/>
                        </Border>
                    </StackPanel>

                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Border Name="WinVBtn" Background="#141c28" BorderBrush="#243448" BorderThickness="1" CornerRadius="6" Padding="6,3" Margin="0,0,6,0" Cursor="Hand" ToolTip="Open Windows 11 Clipboard (Win+V)">
                            <TextBlock Text="⚡ Win+V" FontSize="9" Foreground="#a0c0e0" FontWeight="SemiBold"/>
                        </Border>
                        <Border Name="ClearAllBtn" Background="#1c1622" BorderBrush="#442233" BorderThickness="1" CornerRadius="6" Padding="6,3" Margin="0,0,8,0" Cursor="Hand" ToolTip="Clear All History">
                            <TextBlock Text="🗑️ Clear" FontSize="9" Foreground="#ff6b8b" FontWeight="SemiBold"/>
                        </Border>
                        <Border Name="CloseBtn" Width="22" Height="22" CornerRadius="11" Background="#182230" Cursor="Hand" ToolTip="Close (Esc)">
                            <TextBlock Text="✕" FontSize="10" Foreground="#ffffff" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Search Filter -->
            <Grid Grid.Row="1" Margin="14,10,14,6">
                <Border Background="#121924" BorderBrush="#223348" BorderThickness="1" CornerRadius="8" Padding="8,4">
                    <Grid>
                        <TextBlock Name="SearchPlaceholder" Text="🔍 Filter copied items..." FontSize="11" Foreground="#4a6078" VerticalAlignment="Center" Margin="4,0,0,0" IsHitTestVisible="False"/>
                        <TextBox Name="SearchBox" Background="Transparent" BorderThickness="0" Foreground="#ffffff" FontSize="11" VerticalContentAlignment="Center"/>
                    </Grid>
                </Border>
            </Grid>

            <!-- Scrollable History List -->
            <ScrollViewer Grid.Row="2" Name="HistoryScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="14,4,14,6">
                <StackPanel Name="HistoryContainer"/>
            </ScrollViewer>

            <!-- Footer -->
            <Border Grid.Row="3" Background="#0e141c" CornerRadius="0,0,14,14" Padding="14,8" BorderBrush="#1a2536" BorderThickness="0,1,0,0">
                <Grid>
                    <TextBlock Name="FooterTip" Text="Click any card to copy • Press Esc to close" FontSize="9.5" Foreground="#5a7088" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                    <TextBlock Name="ToastText" Text="" FontSize="9.5" FontWeight="Bold" Foreground="#00f0a8" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
"@

$script:clipWindow = [System.Windows.Markup.XamlReader]::Parse($clipXaml)
$clipCloseBtn   = $script:clipWindow.FindName("CloseBtn")
$clipHeader     = $script:clipWindow.FindName("ClipHeader")
$clipSearchBox  = $script:clipWindow.FindName("SearchBox")
$clipSearchPh   = $script:clipWindow.FindName("SearchPlaceholder")
$clipContainer  = $script:clipWindow.FindName("HistoryContainer")
$clipCountText  = $script:clipWindow.FindName("CountText")
$clipClearAll   = $script:clipWindow.FindName("ClearAllBtn")
$clipWinVBtn    = $script:clipWindow.FindName("WinVBtn")
$clipToastText  = $script:clipWindow.FindName("ToastText")

$script:clipWindow.Add_Closing({
    param($s, $e)
    $e.Cancel = $true
    $script:clipWindow.Hide()
})

$clipCloseBtn.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:clipWindow.Hide()
})

$clipHeader.Add_MouseLeftButtonDown({
    param($s, $e)
    $script:clipWindow.DragMove()
})

$script:clipWindow.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
        $script:clipWindow.Hide()
    }
})

$clipSearchBox.Add_TextChanged({
    if ([string]::IsNullOrWhiteSpace($clipSearchBox.Text)) {
        $clipSearchPh.Visibility = [System.Windows.Visibility]::Visible
    } else {
        $clipSearchPh.Visibility = [System.Windows.Visibility]::Collapsed
    }
    Render-ClipboardHistory
})

$clipWinVBtn.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    try {
        [WinKeyHelper]::OpenWinV()
    } catch {}
})

$clipClearAll.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:clipHistory.Clear()
    Save-ClipboardHistory
    Render-ClipboardHistory
    Show-ClipToast "History Cleared"
})

function Show-ClipToast([string]$msg) {
    $clipToastText.Text = $msg
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2.0)
    $timer.Add_Tick({
        $clipToastText.Text = ""
        $this.Stop()
    })
    $timer.Start()
}

function Render-ClipboardHistory() {
    $clipContainer.Children.Clear()
    $filter = if ($clipSearchBox -ne $null) { $clipSearchBox.Text.ToLower().Trim() } else { "" }

    $items = @()
    foreach ($item in $script:clipHistory) {
        if ([string]::IsNullOrWhiteSpace($filter) -or ($item.text.ToLower() -like "*$filter*")) {
            $items += $item
        }
    }

    $clipCountText.Text = "$($items.Count) items"

    if ($items.Count -eq 0) {
        $emptyBorder = New-Object System.Windows.Controls.Border
        $emptyBorder.Padding = New-Object System.Windows.Thickness(20, 40, 20, 40)
        $emptyStack = New-Object System.Windows.Controls.StackPanel
        $emptyStack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center

        $emptyIcon = New-Object System.Windows.Controls.TextBlock
        $emptyIcon.Text = "📋"
        $emptyIcon.FontSize = 32
        $emptyIcon.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $emptyIcon.Opacity = 0.5
        $null = $emptyStack.Children.Add($emptyIcon)

        $emptyTitle = New-Object System.Windows.Controls.TextBlock
        $emptyTitle.Text = if ([string]::IsNullOrWhiteSpace($filter)) { "Clipboard History is Empty" } else { "No matches found" }
        $emptyTitle.FontSize = 12
        $emptyTitle.FontWeight = [System.Windows.FontWeights]::Bold
        $emptyTitle.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#5a7088")
        $emptyTitle.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $emptyTitle.Margin = New-Object System.Windows.Thickness(0, 10, 0, 4)
        $null = $emptyStack.Children.Add($emptyTitle)

        $emptyDesc = New-Object System.Windows.Controls.TextBlock
        $emptyDesc.Text = "Copy any text (Ctrl+C) to save here automatically."
        $emptyDesc.FontSize = 10
        $emptyDesc.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#3d4f63")
        $emptyDesc.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $null = $emptyStack.Children.Add($emptyDesc)

        $emptyBorder.Child = $emptyStack
        $null = $clipContainer.Children.Add($emptyBorder)
        return
    }

    foreach ($it in $items) {
        $card = New-Object System.Windows.Controls.Border
        $card.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#131a24")
        $card.BorderBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#223348")
        $card.BorderThickness = New-Object System.Windows.Thickness(1)
        $card.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $card.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        $card.Padding = New-Object System.Windows.Thickness(10, 8, 10, 8)
        $card.Cursor = [System.Windows.Input.Cursors]::Hand
        $card.Tag = $it

        $grid = New-Object System.Windows.Controls.Grid
        $row1 = New-Object System.Windows.Controls.RowDefinition; $row1.Height = [System.Windows.GridLength]::Auto
        $row2 = New-Object System.Windows.Controls.RowDefinition; $row2.Height = [System.Windows.GridLength]::Auto
        $grid.RowDefinitions.Add($row1)
        $grid.RowDefinitions.Add($row2)

        # Top row
        $topGrid = New-Object System.Windows.Controls.Grid
        [System.Windows.Controls.Grid]::SetRow($topGrid, 0)

        $metaText = New-Object System.Windows.Controls.TextBlock
        $metaText.Text = "🕒 $($it.time) • $($it.chars) chars"
        $metaText.FontSize = 9.5
        $metaText.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#00f0a8")
        $metaText.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $metaText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $null = $topGrid.Children.Add($metaText)

        $actStack = New-Object System.Windows.Controls.StackPanel
        $actStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $actStack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

        $copyBtn = New-Object System.Windows.Controls.Border
        $copyBtn.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#1c2d3a")
        $copyBtn.BorderBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#00f0a8")
        $copyBtn.BorderThickness = New-Object System.Windows.Thickness(1)
        $copyBtn.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $copyBtn.Padding = New-Object System.Windows.Thickness(6, 2, 6, 2)
        $copyBtn.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
        $copyBtn.Cursor = [System.Windows.Input.Cursors]::Hand

        $copyBtnText = New-Object System.Windows.Controls.TextBlock
        $copyBtnText.Text = "Copy"
        $copyBtnText.FontSize = 9
        $copyBtnText.FontWeight = [System.Windows.FontWeights]::SemiBold
        $copyBtnText.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#00f0a8")
        $copyBtn.Child = $copyBtnText
        $null = $actStack.Children.Add($copyBtn)

        $delBtn = New-Object System.Windows.Controls.Border
        $delBtn.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#201620")
        $delBtn.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $delBtn.Padding = New-Object System.Windows.Thickness(6, 2, 6, 2)
        $delBtn.Cursor = [System.Windows.Input.Cursors]::Hand
        $delBtn.ToolTip = "Delete this clip"

        $delBtnText = New-Object System.Windows.Controls.TextBlock
        $delBtnText.Text = "✕"
        $delBtnText.FontSize = 9
        $delBtnText.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#ff6b8b")
        $delBtn.Child = $delBtnText
        $null = $actStack.Children.Add($delBtn)

        $null = $topGrid.Children.Add($actStack)
        $null = $grid.Children.Add($topGrid)

        # Body text preview
        $txtPreview = New-Object System.Windows.Controls.TextBlock
        $txtPreview.Text = $it.text
        $txtPreview.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#dce6f0")
        $txtPreview.FontSize = 10.5
        $txtPreview.MaxHeight = 65
        $txtPreview.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $txtPreview.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $txtPreview.Margin = New-Object System.Windows.Thickness(0, 5, 0, 0)
        [System.Windows.Controls.Grid]::SetRow($txtPreview, 1)
        $null = $grid.Children.Add($txtPreview)

        $card.Child = $grid

        # Card Click to Copy
        $clipItemText = $it.text
        $copyAction = {
            param($s, $e)
            $e.Handled = $true
            try {
                [System.Windows.Forms.Clipboard]::SetText($clipItemText)
                $card.BorderBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#00f0a8")
                $copyBtnText.Text = "✓ Copied!"
                $copyBtnText.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#00ffbb")
                Show-ClipToast "Copied to clipboard!"
                $statusText.Text = "Copied clip to clipboard"
            } catch {}
        }

        $card.Add_MouseLeftButtonDown($copyAction)
        $copyBtn.Add_MouseLeftButtonDown($copyAction)

        # Delete Action
        $delId = $it.id
        $delBtn.Add_MouseLeftButtonDown({
            param($s, $e)
            $e.Handled = $true
            for ($i = 0; $i -lt $script:clipHistory.Count; $i++) {
                if ($script:clipHistory[$i].id -eq $delId) {
                    $script:clipHistory.RemoveAt($i)
                    break
                }
            }
            Save-ClipboardHistory
            Render-ClipboardHistory
            Show-ClipToast "Item removed"
        })

        # Hover effects
        $card.Add_MouseEnter({
            $this.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#182230")
        })
        $card.Add_MouseLeave({
            $this.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#131a24")
        })

        $null = $clipContainer.Children.Add($card)
    }
}

function Show-ClipboardHistoryWindow() {
    $screenW = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
    $script:clipWindow.Left = [int](($screenW - $script:clipWindow.Width) / 2)
    $script:clipWindow.Top = 85

    Render-ClipboardHistory
    $script:clipWindow.Show()
    $script:clipWindow.Activate() | Out-Null
    $clipSearchBox.Focus() | Out-Null
}

function Toggle-ClipboardHistoryWindow() {
    if ($script:clipWindow -ne $null -and $script:clipWindow.IsVisible) {
        $script:clipWindow.Hide()
    } else {
        Show-ClipboardHistoryWindow
    }
}

function Process-Clipboard() {
    Toggle-ClipboardHistoryWindow
}

# Voice & Query Command Execution - ONLY DIRECT FACTUAL ANSWERS!
function Execute-VoiceCommand([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return }
    $lower = $cmd.ToLower().Trim()
    $statusText.ToolTip = "You asked: $cmd"

    # Automatically morph eyes to match user's question / emotion immediately!
    $userEmotion = Detect-QueryEmotion $cmd
    Set-Emotion $userEmotion

    # 1. Screen capture
    if ($lower -like "*screenshot*" -or $lower -like "*screen short*" -or $lower -like "*capture screen*") {
        Take-Screenshot
        return
    }

    # 2. Clipboard History Pop-Up
    if ($lower -like "*clipboard*" -or $lower -like "*copy history*" -or $lower -like "*read copy*" -or $lower -like "*what is in clipboard*") {
        Show-ClipboardHistoryWindow
        Speak-Jarvis "Opening Clipboard History." "wink"
        return
    }

    # 3. App Opener
    if ($lower -match '^(?:please\s+)?(?:open|launch|start)\s+(.+)$') {
        $app = $matches[1].Trim()

        switch -Wildcard ($app) {
            "*chrome*" {
                Start-Process "chrome.exe"
                Speak-Jarvis "Opening Google Chrome." "wink"
                return
            }
            "*youtube*" {
                Start-Process "https://youtube.com"
                Speak-Jarvis "Opening YouTube." "wink"
                return
            }
            "*notepad*" {
                Start-Process "notepad.exe"
                Speak-Jarvis "Opening Notepad." "wink"
                return
            }
            "*calc*" {
                Start-Process "calc.exe"
                Speak-Jarvis "Opening Calculator." "wink"
                return
            }
            "*edge*" {
                Start-Process "msedge.exe"
                Speak-Jarvis "Opening Microsoft Edge." "wink"
                return
            }
            "*explorer*" {
                Start-Process "explorer.exe"
                Speak-Jarvis "Opening File Explorer." "wink"
                return
            }
            "*files*" {
                Start-Process "explorer.exe"
                Speak-Jarvis "Opening File Explorer." "wink"
                return
            }
            "*code*" {
                Start-Process "code" -ErrorAction SilentlyContinue
                Speak-Jarvis "Opening Visual Studio Code." "wink"
                return
            }
            "*vscode*" {
                Start-Process "code" -ErrorAction SilentlyContinue
                Speak-Jarvis "Opening Visual Studio Code." "wink"
                return
            }
            "*settings*" {
                Start-Process "ms-settings:"
                Speak-Jarvis "Opening Windows Settings." "wink"
                return
            }
            "*spotify*" {
                Start-Process "spotify.exe" -ErrorAction SilentlyContinue
                Speak-Jarvis "Opening Spotify." "wink"
                return
            }
            default {
                try {
                    Start-Process $app -ErrorAction Stop
                    Speak-Jarvis "Opening $app." "wink"
                } catch {
                    Start-Process "https://www.google.com/search?q=$([uri]::EscapeDataString($app))"
                    Speak-Jarvis "Searching for $app on Google." "wink"
                }
                return
            }
        }
    }

    # 4. Instant Ollama AI Query - ONLY Direct Answers, No Filler, Sub-Second Speed!
    $script:isThinking = $true
    $statusText.Text = "You: $cmd"
    $statusText.ToolTip = "You asked: $cmd"

    try {
        $bodyObj = @{
            model = $script:aiModel
            prompt = "You are JARVIS, an intelligent and helpful AI assistant.`nCRITICAL RULES:`n1. Give ONLY the direct, clear, factual answer immediately.`n2. NEVER say 'The system is processing your query', 'I am scanning the room', or any robotic filler.`n3. Be concise: 1 or 2 short sentences maximum.`n4. Do not use markdown, asterisks, or formatting.`nUser: $cmd`nAnswer:"
            stream = $false
            think = $false
            keep_alive = -1
            options = @{
                num_predict = 45
                temperature = 0.2
            }
        }
        $body = $bodyObj | ConvertTo-Json

        $res = Invoke-RestMethod -Uri "$script:ollamaEndpoint/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 10
        $script:isThinking = $false
        if ($res.response) {
            $reply = $res.response.Trim()
            $reply = $reply -replace '^Answer:\s*', '' -replace '^JARVIS:\s*', ''
            $reply = $reply -replace '\*\*', '' -replace '###', '' -replace '`', '' -replace '\[.*?\]', ''
            Speak-Jarvis $reply $userEmotion
            return
        }
    } catch {
        $script:isThinking = $false
        Speak-Jarvis "I am online and ready for your question." "happy"
    }
}

# Initialize C# SpeechBridge (Fallback dictation)
$script:bridge = New-Object SpeechBridge
$bridgeOk = $script:bridge.Initialize()

# Whisper Voice Engine Integration
$script:isRecordingWhisper = $false
$script:recordMaxTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:recordMaxTimer.Interval = [TimeSpan]::FromSeconds(6.5)

function Stop-VoiceListening() {
    if (-not $script:isRecordingWhisper) { return }
    $script:isRecordingWhisper = $false
    $script:recordMaxTimer.Stop()

    $micText.Text = "🎙️ Mic"
    $micBtn.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#1a00f0a8")
    $statusText.Text = "Transcribing..."

    # Call whisper stop and transcribe with state-of-the-art accuracy
    try {
        $res = Invoke-RestMethod -Uri "$script:whisperEndpoint/stop" -Method Post -TimeoutSec 6
        if ($res.text -and -not [string]::IsNullOrWhiteSpace($res.text)) {
            $recognizedText = $res.text.Trim()
            $statusText.Text = "You: $recognizedText"
            $statusText.ToolTip = "You asked: $recognizedText"
            Execute-VoiceCommand $recognizedText
            return
        }
    } catch {}

    if ($statusText.Text -eq "Transcribing...") {
        $statusText.Text = "Could not hear clearly. Try again."
        Set-Emotion "neutral"
    }
}

$script:recordMaxTimer.Add_Tick({
    Stop-VoiceListening
})

function Toggle-Voice() {
    # Check if Whisper service is alive
    $whisperUp = $false
    try {
        $null = Invoke-RestMethod -Uri "$script:whisperEndpoint/health" -TimeoutSec 1 -ErrorAction Stop
        $whisperUp = $true
    } catch {
        $whisperUp = Ensure-WhisperRunning
    }

    if ($whisperUp) {
        if (-not $script:isRecordingWhisper) {
            # START RECORDING WITH WHISPER
            try {
                $null = Invoke-RestMethod -Uri "$script:whisperEndpoint/start" -Method Post -TimeoutSec 2
                $script:isRecordingWhisper = $true
                $micText.Text = "🔴 Hear"
                $micBtn.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#ffff0055")
                $statusText.Text = "Listening... Speak now"
                $statusText.ToolTip = "Listening with Whisper AI... Tap Mic when done"
                Set-Emotion "curious"
                $script:recordMaxTimer.Start()
            } catch {
                $script:isRecordingWhisper = $false
            }
        } else {
            # STOP RECORDING AND TRANSCRIBE
            Stop-VoiceListening
        }
        return
    }

    # Fallback to SpeechBridge (pure dictation without Choices grammar)
    if (-not $script:bridge.IsListening) {
        $micText.Text = "🔴 Hear"
        $micBtn.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#ffff0055")
        $statusText.Text = "Listening... (speak now)"
        Set-Emotion "curious"
        $script:bridge.StartListening()
    } else {
        $script:bridge.StopListening()
        $micText.Text = "🎙️ Mic"
        $micBtn.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#1a00f0a8")
        $statusText.Text = "JARVIS • Ready"
        Set-Emotion "neutral"
    }
}

# Polling timer for fallback SpeechBridge results
$voicePollTimer = New-Object System.Windows.Threading.DispatcherTimer
$voicePollTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$voicePollTimer.Add_Tick({
    if ($script:bridge -ne $null -and -not $script:isRecordingWhisper) {
        if ($script:bridge.HasResult) {
            $script:bridge.HasResult = $false
            $q = $script:bridge.LastRecognized
            $script:bridge.LastRecognized = $null
            $micText.Text = "🎙️ Mic"
            $micBtn.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#1a00f0a8")
            if (-not [string]::IsNullOrWhiteSpace($q)) {
                Execute-VoiceCommand $q
            }
        } elseif (-not $script:bridge.IsListening -and $micText.Text -eq "🔴 Hear") {
            $micText.Text = "🎙️ Mic"
            $micBtn.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#1a00f0a8")
            if ($statusText.Text -eq "Listening... (speak now)") {
                $statusText.Text = "JARVIS • Ready"
            }
        }
    }
})
$voicePollTimer.Start()

# Blink Timer (With Organic Single & Double Blinks!)
$blinkTimer = New-Object System.Windows.Threading.DispatcherTimer
$blinkTimer.Interval = [TimeSpan]::FromSeconds(2.8)
$blinkTimer.Add_Tick({
    if ($script:isOpen) {
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
        $anim.From = 1.0
        $anim.To = 0.05
        $anim.Duration = [TimeSpan]::FromMilliseconds(100)
        $anim.AutoReverse = $true

        $scaleLeft.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $anim)
        $scaleRight.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $anim)

        # 25% chance of an organic playful double-blink!
        if ((Get-Random -Minimum 1 -Maximum 5) -eq 1) {
            $doubleBlinkTimer = New-Object System.Windows.Threading.DispatcherTimer
            $doubleBlinkTimer.Interval = [TimeSpan]::FromMilliseconds(230)
            $doubleBlinkTimer.Add_Tick({
                $scaleLeft.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $anim)
                $scaleRight.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $anim)
                $this.Stop()
            })
            $doubleBlinkTimer.Start()
        }
    }

    $rngSec = (Get-Random -Minimum 20 -Maximum 48) / 10.0
    $blinkTimer.Interval = [TimeSpan]::FromSeconds($rngSec)
})
$blinkTimer.Start()

# Tracking & Auto-Hide Loop (every 40ms)
$trackTimer = New-Object System.Windows.Threading.DispatcherTimer
$trackTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$trackTimer.Add_Tick({
    $mousePos = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

    $islandCenterX = $screen.Width / 2
    $distFromCenterX = [Math]::Abs($mousePos.X - $islandCenterX)

    # 1. TRIGGER OPEN: Mouse reaches top edge near center (Y <= 25)
    if ($mousePos.Y -le 25 -and $distFromCenterX -lt 180) {
        Open-Island
    }

    # 2. TRIGGER AUTO-HIDE: Mouse moves away from top area (ONLY IF NOT PINNED/EXTENDED/THINKING/SPEAKING!)
    if ($script:isOpen -and (-not $script:isPinned) -and (-not $script:isExtended) -and (-not $script:isThinking) -and (-not $script:isSpeaking) -and (-not $script:isRecordingWhisper)) {
        if ($mousePos.Y -gt 110 -or $distFromCenterX -gt 220) {
            $script:awayCounter++
            if ($script:awayCounter -gt 85) { # ~3.4 seconds of inactivity
                Close-Island
            }
        } else {
            $script:awayCounter = 0
        }
    }

    # 3. EYE TRACKING (With living micro-saccades!)
    if ($script:isOpen) {
        $dx = (($mousePos.X - $islandCenterX) / $islandCenterX) * 12
        $dy = (($mousePos.Y - 50) / $screen.Height) * 10

        if ($dx -gt 11) { $dx = 11 } elseif ($dx -lt -11) { $dx = -11 }
        if ($dy -gt 8)  { $dy = 8 }  elseif ($dy -lt -5)  { $dy = -5 }

        $transLeft.X = $dx
        $transLeft.Y = $dy
        $transRight.X = $dx
        $transRight.Y = $dy
    }
})
$trackTimer.Start()

# Hover opens
$islandBorder.Add_MouseEnter({ Open-Island })

# PIN CLICK
$pinIcon.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true
    Toggle-Pin
})

# EYES CLICK (Cycles through friendly, cool emotions)
$eyesClickArea.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true
    $script:emotionIndex = ($script:emotionIndex + 1) % $script:emotions.Count
    $emo = $script:emotions[$script:emotionIndex]
    Set-Emotion $emo

    # Show emotion badge briefly in subtitle
    $statusText.Text = "JARVIS • $([char]::ToUpper($emo[0]))$($emo.Substring(1))"
})

# 2-FINGER TAP / RIGHT CLICK -> Smoothly Extends the Action Tray!
$islandBorder.Add_MouseRightButtonDown({
    param($sender, $e)
    $e.Handled = $true
    Toggle-Extend
})

# BUTTON HANDLERS IN EXTENDED TRAY
$micBtn.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true
    Toggle-Voice
})

$clipBtn.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true
    Process-Clipboard
})

$shotBtn.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true
    Take-Screenshot
})

$colorBtn.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true
    $script:colorIndex = ($script:colorIndex + 1) % $script:colors.Count
    Set-EyeColor $script:colors[$script:colorIndex].Hex
    Play-WinkAnimation
})

# Chat input enter key and send button
$chatInput.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
        $e.Handled = $true
        $q = $chatInput.Text
        $chatInput.Text = ""
        if (-not [string]::IsNullOrWhiteSpace($q)) {
            Execute-VoiceCommand $q
        }
    }
})

$sendBtn.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true
    $q = $chatInput.Text
    $chatInput.Text = ""
    if (-not [string]::IsNullOrWhiteSpace($q)) {
        Execute-VoiceCommand $q
    }
})

# Escape key closes extended tray
$window.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
        if ($script:isExtended) {
            Toggle-Extend
        }
    }
})

# Quick background warmup so AI model is instantly responsive
try {
    $warmup = @{
        model = $script:aiModel
        prompt = "Hello"
        stream = $false
        think = $false
        keep_alive = -1
        options = @{ num_predict = 1 }
    } | ConvertTo-Json
    $null = Invoke-RestMethod -Uri "$script:ollamaEndpoint/api/generate" -Method Post -Body $warmup -ContentType "application/json" -TimeoutSec 3 -ErrorAction SilentlyContinue
} catch {}

# Startup Greeting
Speak-Jarvis "Ready for your questions." "happy"

# Show Window
$window.ShowDialog() | Out-Null
