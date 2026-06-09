param(
    [double]$Scale = 0.6,
    [switch]$Center,
    [switch]$ShowTaskbar,
    [switch]$DebugChrome
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DesktopPetNative {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
}

[StructLayout(LayoutKind.Sequential)]
public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO {
    public uint cbSize;
    public uint dwTime;
}
"@

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexPetsDir = Join-Path $env:USERPROFILE ".codex\pets"
$LocalPetsDir = Join-Path $ScriptDir "pets"
$ConfigPath = Join-Path $ScriptDir "config.json"
$ActivityLogPath = Join-Path $ScriptDir "activity_log.jsonl"
$AiUsageLogPath = Join-Path $ScriptDir "ai_usage_log.jsonl"
$DesktopPetErrorLogPath = Join-Path $ScriptDir "desktop_pet_error.log"
$FrameExtractor = Join-Path $ScriptDir "scripts\extract_idle_frames.py"
$FrameCacheRoot = Join-Path $ScriptDir "cache\frames"

$FrameWidth = 192
$FrameHeight = 208
$DefaultScale = 0.6
$ScaleOptions = @(0.5, 0.6, 0.75, 1.0, 1.25, 1.5, 2.0)
$MaxRecentActivities = 20
$DefaultAiEndpoint = "https://api.deepseek.com/chat/completions"
$DefaultAiModel = "deepseek-v4-flash"
$AiStablePersonaPrompt = @"
你是用户桌面上的小宠物，名字来自当前宠物资源。你的职责是陪伴、提醒、轻轻吐槽和短句互动。
你只能基于输入里明确给出的窗口标题、应用名、最近活动摘要和用户聊天内容发言。
你不能声称看到了屏幕截图、摄像头、隐私内容或 OCR 文本；如果信息不足，就用温和、不打扰的方式回应。
输出中文，自然、轻短、有陪伴感，不使用 Markdown，不解释自己是 AI。
"@
$AiContextTaskPrompt = "任务：根据最近活动说一句桌宠气泡短句。不超过 28 个中文字符。"
$AiChatTaskPrompt = "任务：和用户聊天。语气自然亲近，最多 80 个中文字符。可以参考最近活动，但不要编造看不到的屏幕细节。"
$ContextModeOptions = [ordered]@{
    "off" = "关闭"
    "low" = "低：当前应用"
    "medium" = "中：应用 + 标题/空闲"
    "high" = "高：本机屏幕采样"
}
$AnimationStates = [ordered]@{
    "idle" = @{ Label = "待机"; Row = 0; Frames = 6; Durations = @(280, 110, 110, 140, 140, 320) }
    "running-right" = @{ Label = "向右移动"; Row = 1; Frames = 8; Durations = @(120, 120, 120, 120, 120, 120, 120, 220) }
    "running-left" = @{ Label = "向左移动"; Row = 2; Frames = 8; Durations = @(120, 120, 120, 120, 120, 120, 120, 220) }
    "waving" = @{ Label = "挥手"; Row = 3; Frames = 4; Durations = @(140, 140, 140, 280) }
    "jumping" = @{ Label = "跳一下"; Row = 4; Frames = 5; Durations = @(140, 140, 140, 140, 280) }
    "failed" = @{ Label = "失败/沮丧"; Row = 5; Frames = 8; Durations = @(140, 140, 140, 140, 140, 140, 140, 240) }
    "waiting" = @{ Label = "等待"; Row = 6; Frames = 6; Durations = @(150, 150, 150, 150, 150, 260) }
    "running" = @{ Label = "工作中"; Row = 7; Frames = 6; Durations = @(120, 120, 120, 120, 120, 220) }
    "review" = @{ Label = "检查/思考"; Row = 8; Frames = 6; Durations = @(150, 150, 150, 150, 150, 280) }
}

function Write-DesktopPetError {
    param([object]$ErrorRecord)

    try {
        $message = if ($ErrorRecord -and $ErrorRecord.Exception) {
            [string]$ErrorRecord.Exception.ToString()
        } else {
            [string]$ErrorRecord
        }
        $line = "[{0}] {1}" -f ([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")), $message
        Add-Content -LiteralPath $DesktopPetErrorLogPath -Encoding UTF8 -Value $line
    } catch {
    }
}

function Get-JsonObject {
    param([string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $null
        }
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-PetsFromRoot {
    param(
        [string]$Root,
        [string]$Source,
        [string]$SourceLabel
    )

    $pets = @()
    if (-not (Test-Path -LiteralPath $Root)) {
        return $pets
    }

    Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name | ForEach-Object {
        $petDir = $_.FullName
        $manifestPath = Join-Path $petDir "pet.json"
        $manifest = Get-JsonObject $manifestPath
        if (-not $manifest) {
            return
        }

        $petId = if ($manifest.id) { [string]$manifest.id } else { $_.Name }
        $displayName = if ($manifest.displayName) { [string]$manifest.displayName } else { $petId }
        $description = if ($manifest.description) { [string]$manifest.description } else { "" }
        $spritesheetName = if ($manifest.spritesheetPath) { [string]$manifest.spritesheetPath } else { "spritesheet.webp" }
        $spritesheetPath = Join-Path $petDir $spritesheetName
        if (-not (Test-Path -LiteralPath $spritesheetPath)) {
            return
        }

        $pets += [pscustomobject]@{
            Source = $Source
            SourceLabel = $SourceLabel
            Id = $petId
            DisplayName = $displayName
            Description = $description
            Directory = $petDir
            SpritesheetPath = (Resolve-Path -LiteralPath $spritesheetPath).Path
            MenuLabel = "$displayName [$SourceLabel]"
        }
    }

    return $pets
}

function Get-AllPets {
    $pets = @()
    $pets += Get-PetsFromRoot -Root $CodexPetsDir -Source "codex" -SourceLabel "Codex"
    $pets += Get-PetsFromRoot -Root $LocalPetsDir -Source "local" -SourceLabel "Local"
    return $pets
}

function Get-InitialPet {
    param([object[]]$Pets)

    if (-not $Pets -or $Pets.Count -eq 0) {
        return $null
    }

    $config = Get-JsonObject $ConfigPath
    if ($config -and $config.source -and $config.id) {
        $saved = $Pets | Where-Object { $_.Source -eq [string]$config.source -and $_.Id -eq [string]$config.id } | Select-Object -First 1
        if ($saved) {
            return $saved
        }
    }

    $liuying = $Pets | Where-Object { $_.Source -eq "codex" -and $_.Id -eq "liuying" } | Select-Object -First 1
    if ($liuying) {
        return $liuying
    }

    return $Pets[0]
}

function Save-Selection {
    param([object]$Pet)

    $payload = [ordered]@{
        source = $Pet.Source
        id = $Pet.Id
        scale = $script:CurrentScale
        contextMode = $script:ContextMode
        aiEnabled = $script:AiEnabled
        aiEndpoint = $script:AiEndpoint
        aiModel = $script:AiModel
        aiApiKey = $script:AiApiKey
    }
    $payload | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Normalize-Scale {
    param([object]$Value)

    try {
        $candidate = [double]$Value
    } catch {
        return $DefaultScale
    }

    if ($candidate -le 0) {
        return $DefaultScale
    }

    $nearest = $ScaleOptions[0]
    $nearestDistance = [Math]::Abs($candidate - $nearest)
    foreach ($option in $ScaleOptions) {
        $distance = [Math]::Abs($candidate - $option)
        if ($distance -lt $nearestDistance) {
            $nearest = $option
            $nearestDistance = $distance
        }
    }
    return $nearest
}

function Get-InitialScale {
    $config = Get-JsonObject $ConfigPath
    if (-not $PSBoundParameters.ContainsKey("Scale") -and $config -and $config.scale) {
        return Normalize-Scale $config.scale
    }

    return Normalize-Scale $Scale
}

function Get-InitialContextMode {
    $config = Get-JsonObject $ConfigPath
    $mode = if ($config -and $config.contextMode) { [string]$config.contextMode } else { "low" }
    if ($ContextModeOptions.Contains($mode)) {
        return $mode
    }
    return "low"
}

function Get-InitialBooleanSetting {
    param(
        [string]$Name,
        [bool]$DefaultValue
    )

    $config = Get-JsonObject $ConfigPath
    if ($config -and $config.PSObject.Properties.Name -contains $Name) {
        try {
            return [bool]$config.$Name
        } catch {
            return $DefaultValue
        }
    }
    return $DefaultValue
}

function Get-InitialStringSetting {
    param(
        [string]$Name,
        [string]$DefaultValue
    )

    $config = Get-JsonObject $ConfigPath
    if ($config -and $config.PSObject.Properties.Name -contains $Name -and -not [string]::IsNullOrWhiteSpace([string]$config.$Name)) {
        return [string]$config.$Name
    }
    return $DefaultValue
}

function Get-WindowWidthForScale {
    param([double]$Value)
    return [Math]::Max($FrameWidth, $FrameWidth * $Value)
}

function Get-WindowHeightForScale {
    param([double]$Value)
    return [Math]::Max($FrameHeight, $FrameHeight * $Value)
}

function Get-PythonRuntime {
    $candidates = @()
    $localPython = Join-Path $ScriptDir ".venv\Scripts\python.exe"
    $bundledPython = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"

    if (Test-Path -LiteralPath $localPython) {
        $candidates += $localPython
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $candidates += $python.Source
    }

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        $candidates += $pyLauncher.Source
    }

    if (Test-Path -LiteralPath $bundledPython) {
        $candidates += $bundledPython
    }

    foreach ($candidate in $candidates) {
        & $candidate -c "import PIL" *> $null
        if ($LASTEXITCODE -eq 0) {
            return $candidate
        }
    }

    return $null
}

function Get-FrameCacheDir {
    param([object]$Pet)

    $safeName = "$($Pet.Source)-$($Pet.Id)" -replace '[^a-zA-Z0-9_.-]', '_'
    return Join-Path $FrameCacheRoot $safeName
}

function Get-CachedFramePaths {
    param(
        [object]$Pet,
        [string]$State
    )

    $cacheDir = Get-FrameCacheDir -Pet $Pet
    $stateInfo = $AnimationStates[$State]
    $framePaths = @(0..($stateInfo.Frames - 1) | ForEach-Object { Join-Path $cacheDir "$State-$_.png" })
    $needsRefresh = $false

    if (-not (Test-Path -LiteralPath $cacheDir)) {
        $needsRefresh = $true
    } else {
        $sheetTime = (Get-Item -LiteralPath $Pet.SpritesheetPath).LastWriteTimeUtc
        foreach ($framePath in $framePaths) {
            if (-not (Test-Path -LiteralPath $framePath) -or (Get-Item -LiteralPath $framePath).LastWriteTimeUtc -lt $sheetTime) {
                $needsRefresh = $true
                break
            }
        }
    }

    if ($needsRefresh) {
        $python = Get-PythonRuntime
        if ($python -and (Test-Path -LiteralPath $FrameExtractor)) {
            & $python $FrameExtractor $Pet.SpritesheetPath $cacheDir
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract PNG frames for $($Pet.MenuLabel)."
            }
        }
    }

    if (($framePaths | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -gt 0) {
        return $null
    }

    return $framePaths
}

function New-Frames {
    param(
        [object]$Pet,
        [string]$State
    )

    $cachedFramePaths = Get-CachedFramePaths -Pet $Pet -State $State
    if ($cachedFramePaths) {
        $frames = New-Object System.Collections.Generic.List[object]
        foreach ($framePath in $cachedFramePaths) {
            $frame = New-Object System.Windows.Media.Imaging.BitmapImage
            $frame.BeginInit()
            $frame.UriSource = [Uri]$framePath
            $frame.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $frame.EndInit()
            $frame.Freeze()
            $frames.Add($frame)
        }
        return $frames
    }

    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.UriSource = [Uri]$Pet.SpritesheetPath
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.EndInit()
    $bitmap.Freeze()

    $frames = New-Object System.Collections.Generic.List[object]
    $stateInfo = $AnimationStates[$State]
    for ($column = 0; $column -lt $stateInfo.Frames; $column++) {
        $rect = New-Object System.Windows.Int32Rect ($column * $FrameWidth), ($stateInfo.Row * $FrameHeight), $FrameWidth, $FrameHeight
        $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap $bitmap, $rect
        $crop.Freeze()
        $frames.Add($crop)
    }
    return $frames
}

$Pets = Get-AllPets
$CurrentPet = Get-InitialPet -Pets $Pets
$CurrentScale = Get-InitialScale
$ContextMode = Get-InitialContextMode
$AiEnabled = Get-InitialBooleanSetting -Name "aiEnabled" -DefaultValue $false
$AiEndpoint = Get-InitialStringSetting -Name "aiEndpoint" -DefaultValue $DefaultAiEndpoint
$AiModel = Get-InitialStringSetting -Name "aiModel" -DefaultValue $DefaultAiModel
$AiApiKey = Get-InitialStringSetting -Name "aiApiKey" -DefaultValue ""

if (-not $CurrentPet) {
    [System.Windows.MessageBox]::Show("No valid pets found in $CodexPetsDir or $LocalPetsDir.", "Desktop Pet") | Out-Null
    exit 1
}

$Window = New-Object System.Windows.Window
$Window.WindowStyle = [System.Windows.WindowStyle]::None
$Window.AllowsTransparency = $true
$Window.Background = if ($DebugChrome) { [System.Windows.Media.Brushes]::DeepSkyBlue } else { [System.Windows.Media.Brushes]::Transparent }
$Window.Topmost = $true
$Window.Width = Get-WindowWidthForScale $CurrentScale
$Window.Height = Get-WindowHeightForScale $CurrentScale
$Window.ShowInTaskbar = [bool]$ShowTaskbar
$Window.ResizeMode = [System.Windows.ResizeMode]::NoResize

$Image = New-Object System.Windows.Controls.Image
$Image.Width = $FrameWidth
$Image.Height = $FrameHeight
$Image.Stretch = [System.Windows.Media.Stretch]::None
$Image.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $CurrentScale, $CurrentScale
$Image.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
$Image.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

$PetSurface = New-Object System.Windows.Controls.Grid
$PetSurface.Width = $Window.Width
$PetSurface.Height = $Window.Height
$PetSurface.Background = [System.Windows.Media.Brushes]::Transparent
$PetSurface.Children.Add($Image) | Out-Null

$BubbleText = New-Object System.Windows.Controls.TextBlock
$BubbleText.Foreground = [System.Windows.Media.Brushes]::Black
$BubbleText.FontSize = 13
$BubbleText.TextWrapping = [System.Windows.TextWrapping]::Wrap
$BubbleText.MaxWidth = 160

$BubbleBorder = New-Object System.Windows.Controls.Border
$BubbleBorder.Background = [System.Windows.Media.Brushes]::White
$BubbleBorder.BorderBrush = [System.Windows.Media.Brushes]::LightGray
$BubbleBorder.BorderThickness = New-Object System.Windows.Thickness 1
$BubbleBorder.CornerRadius = New-Object System.Windows.CornerRadius 8
$BubbleBorder.Padding = New-Object System.Windows.Thickness 8, 4, 8, 4
$BubbleBorder.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
$BubbleBorder.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
$BubbleBorder.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
$BubbleBorder.Opacity = 0.95
$BubbleBorder.Visibility = [System.Windows.Visibility]::Collapsed
$BubbleBorder.Child = $BubbleText
[System.Windows.Controls.Panel]::SetZIndex($BubbleBorder, 10)
$PetSurface.Children.Add($BubbleBorder) | Out-Null

if ($DebugChrome) {
    $Border = New-Object System.Windows.Controls.Border
    $Border.BorderBrush = [System.Windows.Media.Brushes]::Red
    $Border.BorderThickness = New-Object System.Windows.Thickness 4
    $Border.Background = [System.Windows.Media.Brushes]::DeepSkyBlue
    $Border.Child = $PetSurface
    $Window.Content = $Border
} else {
    $Window.Content = $PetSurface
}

$ContextMenu = New-Object System.Windows.Controls.ContextMenu
$Image.ContextMenu = $ContextMenu
$PetSurface.ContextMenu = $ContextMenu

$FrameIndex = 0
$Frames = $null
$CurrentState = "idle"
$ReturnToIdleAfterLoop = $false
$SlowIdle = $true
$MenuOpen = $false
$MouseSenseEnabled = $true
$MessagesEnabled = $true
$LastContextSignature = ""
$LastContextReactionAt = [DateTime]::MinValue
$LastActivitySignature = ""
$RecentActivities = New-Object System.Collections.Generic.List[object]
$LastAiContextAt = [DateTime]::MinValue
$LastAiErrorAt = [DateTime]::MinValue
$AiPendingJobs = New-Object System.Collections.Generic.List[object]
$ChatWindow = $null
$ChatHistoryBox = $null
$ChatInputBox = $null
$ChatTranscript = New-Object System.Collections.Generic.List[object]
$SettingsWindow = $null
$MouseWasNear = $false
$MouseNearSince = $null
$LastMouseX = $null
$LastMouseY = $null
$LastMouseCheckAt = [DateTime]::UtcNow
$LastMouseReactionAt = [DateTime]::MinValue
$Timer = New-Object System.Windows.Threading.DispatcherTimer
$IdleBlinkTimer = New-Object System.Windows.Threading.DispatcherTimer
$MouseSenseTimer = New-Object System.Windows.Threading.DispatcherTimer
$ContextSenseTimer = New-Object System.Windows.Threading.DispatcherTimer
$AiJobTimer = New-Object System.Windows.Threading.DispatcherTimer
$BubbleTimer = New-Object System.Windows.Threading.DispatcherTimer
$WalkTimer = New-Object System.Windows.Threading.DispatcherTimer
$WalkTicksRemaining = 0
$WalkStep = 0

function Set-CurrentPet {
    param([object]$Pet)

    if (-not $Pet) {
        Write-DesktopPetError "Set-CurrentPet called with null pet."
        return
    }

    $script:CurrentPet = $Pet
    if ($script:Window) {
        $script:Window.Title = "$($Pet.DisplayName) Desktop Pet"
    }
    Save-Selection -Pet $Pet
    Set-AnimationState -State "waving" -Once $true
    Show-PetMessage -Text "你好，我是 $($Pet.DisplayName)"
    Update-ContextMenu
}

function Set-PetScale {
    param([double]$NewScale)

    $newScale = Normalize-Scale $NewScale
    $centerX = $script:Window.Left + ($script:Window.Width / 2)
    $centerY = $script:Window.Top + ($script:Window.Height / 2)

    $script:CurrentScale = $newScale
    $script:Window.Width = Get-WindowWidthForScale $newScale
    $script:Window.Height = Get-WindowHeightForScale $newScale
    $script:PetSurface.Width = $script:Window.Width
    $script:PetSurface.Height = $script:Window.Height
    $script:Image.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $newScale, $newScale
    Show-PetMessage -Text "大小调整好了"

    $maxLeft = [System.Windows.SystemParameters]::PrimaryScreenWidth - $script:Window.Width
    $maxTop = [System.Windows.SystemParameters]::PrimaryScreenHeight - $script:Window.Height
    $script:Window.Left = [Math]::Min([Math]::Max(0, $centerX - ($script:Window.Width / 2)), $maxLeft)
    $script:Window.Top = [Math]::Min([Math]::Max(0, $centerY - ($script:Window.Height / 2)), $maxTop)

    Save-Selection -Pet $script:CurrentPet
    Update-ContextMenu
}

function Set-AnimationState {
    param(
        [string]$State,
        [bool]$Once = $false
    )

    if (-not $AnimationStates.Contains($State)) {
        Write-DesktopPetError "Unknown animation state: $State"
        return
    }
    if (-not $script:CurrentPet) {
        Write-DesktopPetError "Cannot set animation state '$State' because CurrentPet is null."
        return
    }
    if (-not $script:Image) {
        Write-DesktopPetError "Cannot set animation state '$State' because Image control is null."
        return
    }

    try {
        $frames = New-Frames -Pet $script:CurrentPet -State $State
        if (-not $frames -or $frames.Count -eq 0) {
            throw "No frames loaded for state '$State' from $($script:CurrentPet.SpritesheetPath)."
        }

        $script:CurrentState = $State
        $script:ReturnToIdleAfterLoop = $Once
        $script:SlowIdle = ($State -eq "idle" -and -not $Once)
        $script:Frames = $frames
        $script:FrameIndex = 0
        $script:Image.Source = $script:Frames[0]
        if ($script:ContextMenu) {
            Update-ContextMenu
        }
    } catch {
        Write-DesktopPetError $_
        if ($State -ne "idle" -and $AnimationStates.Contains("idle")) {
            Set-AnimationState -State "idle"
        }
    }
}

function Show-PetMessage {
    param(
        [string]$Text,
        [int]$DurationMs = 1800
    )

    if (-not $script:MessagesEnabled -or [string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    if (-not $script:BubbleTimer -or -not $script:BubbleText -or -not $script:BubbleBorder) {
        Write-DesktopPetError "Cannot show message because bubble controls are not ready."
        return
    }

    try {
        $script:BubbleTimer.Stop()
        $script:BubbleText.Text = $Text
        $script:BubbleBorder.Visibility = [System.Windows.Visibility]::Visible
        $script:BubbleTimer.Interval = [TimeSpan]::FromMilliseconds($DurationMs)
        $script:BubbleTimer.Start()
    } catch {
        Write-DesktopPetError $_
    }
}

function New-UiBrush {
    param([string]$Hex)
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

function New-UiTextBlock {
    param(
        [string]$Text,
        [int]$Size = 13,
        [string]$Color = "#27313F",
        [string]$Weight = "Normal"
    )

    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontSize = $Size
    $block.Foreground = New-UiBrush $Color
    $block.TextWrapping = [System.Windows.TextWrapping]::Wrap
    if ($Weight -eq "SemiBold") {
        $block.FontWeight = [System.Windows.FontWeights]::SemiBold
    }
    return $block
}

function New-UiButton {
    param(
        [string]$Text,
        [bool]$Primary = $false
    )

    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    $button.MinWidth = 76
    $button.Height = 34
    $button.Padding = New-Object System.Windows.Thickness 12, 0, 12, 0
    $button.BorderThickness = New-Object System.Windows.Thickness 0
    $button.Background = if ($Primary) { New-UiBrush "#2F80ED" } else { New-UiBrush "#E8EDF5" }
    $button.Foreground = if ($Primary) { [System.Windows.Media.Brushes]::White } else { New-UiBrush "#243044" }
    return $button
}

function Start-Walk {
    param([int]$Direction)

    $script:WalkTimer.Stop()
    $script:WalkStep = 8 * $Direction
    $script:WalkTicksRemaining = 28
    if ($Direction -lt 0) {
        Set-AnimationState -State "running-left"
        Show-PetMessage -Text "往左走走"
    } else {
        Set-AnimationState -State "running-right"
        Show-PetMessage -Text "往右走走"
    }
    $script:WalkTimer.Interval = [TimeSpan]::FromMilliseconds(80)
    $script:WalkTimer.Start()
}

function Schedule-IdleBlink {
    $script:IdleBlinkTimer.Stop()
    $script:IdleBlinkTimer.Interval = [TimeSpan]::FromMilliseconds((Get-Random -Minimum 18000 -Maximum 32000))
    $script:IdleBlinkTimer.Start()
}

function Invoke-IdleBlink {
    if ($script:MenuOpen -or $script:WalkTimer.IsEnabled -or $script:CurrentState -ne "idle") {
        Schedule-IdleBlink
        return
    }

    if ($script:SlowIdle) {
        Schedule-IdleBlink
        return
    }

    Set-AnimationState -State "idle" -Once $true
}

function Get-MouseDistanceFromPet {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $centerX = $script:Window.Left + ($script:Window.Width / 2)
    $centerY = $script:Window.Top + ($script:Window.Height / 2)
    $dx = [double]$cursor.X - [double]$centerX
    $dy = [double]$cursor.Y - [double]$centerY

    return [pscustomobject]@{
        X = [double]$cursor.X
        Y = [double]$cursor.Y
        Distance = [Math]::Sqrt(($dx * $dx) + ($dy * $dy))
    }
}

function Invoke-MouseSense {
    if (-not $script:MouseSenseEnabled -or $script:MenuOpen -or $script:WalkTimer.IsEnabled) {
        return
    }

    $now = [DateTime]::UtcNow
    $mouse = Get-MouseDistanceFromPet
    $elapsedSeconds = [Math]::Max(0.05, ($now - $script:LastMouseCheckAt).TotalSeconds)
    $speed = 0.0

    if ($null -ne $script:LastMouseX -and $null -ne $script:LastMouseY) {
        $moveX = $mouse.X - $script:LastMouseX
        $moveY = $mouse.Y - $script:LastMouseY
        $speed = [Math]::Sqrt(($moveX * $moveX) + ($moveY * $moveY)) / $elapsedSeconds
    }

    $script:LastMouseX = $mouse.X
    $script:LastMouseY = $mouse.Y
    $script:LastMouseCheckAt = $now

    $near = $mouse.Distance -lt 120
    $attention = $mouse.Distance -lt 210
    $cooldownReady = ($now - $script:LastMouseReactionAt).TotalSeconds -gt 4

    if ($attention -and $speed -gt 900 -and $cooldownReady) {
        $script:LastMouseReactionAt = $now
        $script:MouseWasNear = $near
        $script:MouseNearSince = if ($near) { $now } else { $null }
        Set-AnimationState -State "jumping" -Once $true
        Show-PetMessage -Text "哇，吓我一跳"
        return
    }

    if ($near) {
        if (-not $script:MouseWasNear) {
            $script:MouseWasNear = $true
            $script:MouseNearSince = $now
            if ($script:CurrentState -eq "idle") {
                Set-AnimationState -State "waiting"
                Show-PetMessage -Text "你来啦？"
            }
            return
        }

        if (
            $script:MouseNearSince -and
            ($now - $script:MouseNearSince).TotalSeconds -gt 1.4 -and
            ($now - $script:LastMouseReactionAt).TotalSeconds -gt 9
        ) {
            $script:LastMouseReactionAt = $now
            Set-AnimationState -State "waving" -Once $true
            Show-PetMessage -Text "嗨～"
            return
        }
    } else {
        if ($script:MouseWasNear) {
            $script:MouseWasNear = $false
            $script:MouseNearSince = $null
            if ($script:CurrentState -eq "waiting") {
                Set-AnimationState -State "idle"
            }
        }
    }
}

function Get-UserIdleSeconds {
    $info = New-Object LASTINPUTINFO
    $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][LASTINPUTINFO])
    if (-not [DesktopPetNative]::GetLastInputInfo([ref]$info)) {
        return 0
    }

    $tick = [Environment]::TickCount
    $idleMs = [uint32]$tick - $info.dwTime
    return [Math]::Max(0, [double]$idleMs / 1000.0)
}

function Get-ForegroundContext {
    $hwnd = [DesktopPetNative]::GetForegroundWindow()
    $foregroundProcessId = [uint32]0
    [void][DesktopPetNative]::GetWindowThreadProcessId($hwnd, [ref]$foregroundProcessId)

    $processName = ""
    try {
        $process = Get-Process -Id ([int]$foregroundProcessId) -ErrorAction Stop
        $processName = $process.ProcessName
    } catch {
        $processName = ""
    }

    $length = [DesktopPetNative]::GetWindowTextLength($hwnd)
    $builder = New-Object System.Text.StringBuilder ([Math]::Max(1, $length + 1))
    [void][DesktopPetNative]::GetWindowText($hwnd, $builder, $builder.Capacity)
    $title = $builder.ToString()

    $rect = New-Object RECT
    [void][DesktopPetNative]::GetWindowRect($hwnd, [ref]$rect)
    $width = [Math]::Max(0, $rect.Right - $rect.Left)
    $height = [Math]::Max(0, $rect.Bottom - $rect.Top)
    $screenWidth = [System.Windows.SystemParameters]::PrimaryScreenWidth
    $screenHeight = [System.Windows.SystemParameters]::PrimaryScreenHeight
    $isFullscreen = ($width -ge ($screenWidth * 0.95) -and $height -ge ($screenHeight * 0.90))

    return [pscustomobject]@{
        Hwnd = $hwnd
        ProcessName = $processName
        Title = $title
        Left = $rect.Left
        Top = $rect.Top
        Width = $width
        Height = $height
        IsFullscreen = $isFullscreen
        IdleSeconds = Get-UserIdleSeconds
    }
}

function Get-WindowGlance {
    param([object]$Context)

    if ($Context.Width -le 0 -or $Context.Height -le 0) {
        return $null
    }

    $sampleWidth = [Math]::Min(64, [int]$Context.Width)
    $sampleHeight = [Math]::Min(64, [int]$Context.Height)
    $bitmap = New-Object System.Drawing.Bitmap $sampleWidth, $sampleHeight
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $sourceX = [int]($Context.Left + [Math]::Max(0, ($Context.Width - $sampleWidth) / 2))
        $sourceY = [int]($Context.Top + [Math]::Max(0, ($Context.Height - $sampleHeight) / 2))
        $graphics.CopyFromScreen($sourceX, $sourceY, 0, 0, (New-Object System.Drawing.Size $sampleWidth, $sampleHeight))

        $brightness = 0.0
        $saturation = 0.0
        $count = 0
        for ($x = 0; $x -lt $sampleWidth; $x += 4) {
            for ($y = 0; $y -lt $sampleHeight; $y += 4) {
                $pixel = $bitmap.GetPixel($x, $y)
                $max = [Math]::Max($pixel.R, [Math]::Max($pixel.G, $pixel.B))
                $min = [Math]::Min($pixel.R, [Math]::Min($pixel.G, $pixel.B))
                $brightness += (($pixel.R + $pixel.G + $pixel.B) / 3.0) / 255.0
                if ($max -gt 0) {
                    $saturation += (($max - $min) / [double]$max)
                }
                $count += 1
            }
        }

        return [pscustomobject]@{
            Brightness = if ($count -gt 0) { $brightness / $count } else { 0 }
            Saturation = if ($count -gt 0) { $saturation / $count } else { 0 }
        }
    } catch {
        return $null
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-CleanWindowTitle {
    param(
        [string]$Title,
        [string]$Process
    )

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return ""
    }

    $clean = $Title.Trim()
    $clean = $clean -replace "\s+-\s+Google Chrome$", ""
    $clean = $clean -replace "\s+-\s+Microsoft Edge$", ""
    $clean = $clean -replace "\s+—\s+Mozilla Firefox$", ""
    $clean = $clean -replace "\s+-\s+Mozilla Firefox$", ""
    $clean = $clean -replace "\s+-\s+Visual Studio Code$", ""
    $clean = $clean -replace "\s+-\s+Cursor$", ""
    $clean = $clean -replace "\s+-\s+Notion$", ""
    $clean = $clean -replace "\s+-\s+Obsidian$", ""
    $clean = $clean -replace "\s+-\s+Slack$", ""
    $clean = $clean -replace "\s+\|\s+.*$", ""
    $clean = $clean.Trim()

    if ($clean.Length -gt 36) {
        return $clean.Substring(0, 34) + "…"
    }
    return $clean
}

function Get-TitleSubject {
    param([string]$Title)

    $subject = Get-CleanWindowTitle -Title $Title -Process ""
    if ([string]::IsNullOrWhiteSpace($subject)) {
        return ""
    }

    $subject = $subject -replace "^(Chat with|Conversation with|聊天对象|与)\s*", ""
    $subject = $subject -replace "\s*(聊天|对话)$", ""
    return $subject.Trim()
}

function Get-ContextReaction {
    param(
        [object]$Context,
        [string]$Mode
    )

    $process = $Context.ProcessName.ToLowerInvariant()
    $title = $Context.Title.ToLowerInvariant()
    $cleanTitle = Get-CleanWindowTitle -Title $Context.Title -Process $Context.ProcessName
    $titleSubject = Get-TitleSubject -Title $Context.Title

    if ($Mode -eq "medium" -or $Mode -eq "high") {
        if ($Context.IdleSeconds -gt 180) {
            return @{ State = "idle"; Message = "你休息一下也挺好" }
        }
        if ($Context.IsFullscreen) {
            return @{ State = "waiting"; Message = "全屏模式，我安静点" }
        }
    }

    if ($Mode -eq "medium" -or $Mode -eq "high") {
        if ($process -match "wechat|weixin|qq|telegram|discord|slack|teams|dingtalk|feishu|lark") {
            if (-not [string]::IsNullOrWhiteSpace($titleSubject)) {
                return @{ State = "waiting"; Message = "在和「$titleSubject」聊天吗？" }
            }
            return @{ State = "waiting"; Message = "像是在聊天，我安静陪着" }
        }

        if ($process -match "chrome|edge|firefox|browser" -and $title -match "chatgpt|claude|gemini|poe|slack|discord|telegram|whatsapp|messenger|wechat|微信|qq|飞书|lark|teams") {
            if (-not [string]::IsNullOrWhiteSpace($titleSubject)) {
                return @{ State = "waiting"; Message = "在网页里聊天：$titleSubject" }
            }
            return @{ State = "waiting"; Message = "在网页里聊天吗？" }
        }
    }

    if ($process -match "code|cursor|devenv|idea|pycharm|webstorm|codex") {
        if (($Mode -eq "medium" -or $Mode -eq "high") -and -not [string]::IsNullOrWhiteSpace($cleanTitle)) {
            return @{ State = "running"; Message = "在写「$cleanTitle」" }
        }
        return @{ State = "running"; Message = "写代码中，我陪你盯着" }
    }
    if ($process -match "powershell|cmd|windowsterminal|wt|terminal") {
        return @{ State = "review"; Message = "终端输出我帮你盯着" }
    }
    if ($process -match "chrome|edge|firefox|browser") {
        if (($Mode -eq "medium" -or $Mode -eq "high") -and $title -match "github|pull request|issue|docs|documentation") {
            if (-not [string]::IsNullOrWhiteSpace($cleanTitle)) {
                return @{ State = "review"; Message = "在看资料：$cleanTitle" }
            }
            return @{ State = "review"; Message = "像是在查资料" }
        }
        if (($Mode -eq "medium" -or $Mode -eq "high") -and -not [string]::IsNullOrWhiteSpace($cleanTitle)) {
            return @{ State = "waiting"; Message = "在逛：$cleanTitle" }
        }
        return @{ State = "waiting"; Message = "在浏览网页吗？" }
    }
    if ($process -match "obsidian|notion|word|onenote|excel|powerpnt") {
        if (($Mode -eq "medium" -or $Mode -eq "high") -and -not [string]::IsNullOrWhiteSpace($cleanTitle)) {
            return @{ State = "review"; Message = "在整理：$cleanTitle" }
        }
        return @{ State = "review"; Message = "整理内容中" }
    }
    if ($process -match "photoshop|figma|blender|paint|canva") {
        return @{ State = "review"; Message = "创作时间" }
    }
    if ($process -match "steam|game|player|vlc|potplayer") {
        return @{ State = "idle"; Message = "娱乐一下，我不打扰" }
    }

    if ($Mode -eq "high") {
        $glance = Get-WindowGlance -Context $Context
        if ($glance) {
            if ($glance.Brightness -lt 0.18) {
                return @{ State = "waiting"; Message = "画面好暗，我安静陪着" }
            }
            if ($glance.Saturation -gt 0.42) {
                return @{ State = "jumping"; Message = "画面挺热闹" }
            }
        }
    }

    return @{ State = "idle"; Message = "" }
}

function Get-AiApiKey {
    $config = Get-JsonObject $ConfigPath
    if ($env:DEEPSEEK_API_KEY) {
        return $env:DEEPSEEK_API_KEY
    }
    if ($env:PET_AI_API_KEY) {
        return $env:PET_AI_API_KEY
    }
    if (-not [string]::IsNullOrWhiteSpace($script:AiApiKey)) {
        return $script:AiApiKey
    }
    if ($config -and $config.aiApiKey) {
        return [string]$config.aiApiKey
    }
    if ($env:OPENAI_API_KEY) {
        return $env:OPENAI_API_KEY
    }
    return ""
}

function Get-SafeActivityTitle {
    param([object]$Context)

    $title = Get-CleanWindowTitle -Title $Context.Title -Process $Context.ProcessName
    if ($title.Length -gt 80) {
        return $title.Substring(0, 78) + "..."
    }
    return $title
}

function Add-ActivityRecord {
    param(
        [object]$Context,
        [hashtable]$Reaction
    )

    $title = Get-SafeActivityTitle -Context $Context
    if ($title -match "Desktop Pet|和桌宠聊天") {
        return
    }

    $signature = "$($Context.ProcessName)|$title|$($Reaction.State)"
    if ($signature -eq $script:LastActivitySignature) {
        return
    }
    $script:LastActivitySignature = $signature

    $record = [pscustomobject]@{
        at = [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")
        process = [string]$Context.ProcessName
        title = $title
        state = [string]$Reaction.State
        message = [string]$Reaction.Message
    }

    $script:RecentActivities.Add($record)
    while ($script:RecentActivities.Count -gt $MaxRecentActivities) {
        $script:RecentActivities.RemoveAt(0)
    }

    try {
        $record | ConvertTo-Json -Compress | Add-Content -LiteralPath $ActivityLogPath -Encoding UTF8
    } catch {
    }
}

function Get-RecentActivitySummary {
    if (-not $script:RecentActivities -or $script:RecentActivities.Count -eq 0) {
        return "暂无最近活动。"
    }

    $start = [Math]::Max(0, $script:RecentActivities.Count - 8)
    $lines = New-Object System.Collections.Generic.List[string]
    for ($index = $start; $index -lt $script:RecentActivities.Count; $index++) {
        $item = $script:RecentActivities[$index]
        $titlePart = if ([string]::IsNullOrWhiteSpace($item.title)) { "" } else { " - $($item.title)" }
        $lines.Add("$($item.at) $($item.process)$titlePart")
    }
    return ($lines -join "`n")
}

function New-AiBaseMessages {
    param([string]$TaskPrompt)

    $messages = New-Object System.Collections.Generic.List[object]
    $messages.Add(@{ role = "system"; content = $AiStablePersonaPrompt })
    $messages.Add(@{ role = "system"; content = $TaskPrompt })
    return $messages
}

function Get-UsageNumber {
    param(
        [object]$Usage,
        [string]$Name
    )

    if ($Usage -and $Usage.PSObject.Properties.Name -contains $Name) {
        try {
            return [int64]$Usage.$Name
        } catch {
            return 0
        }
    }
    return 0
}

function Write-AiUsageRecord {
    param(
        [string]$Kind,
        [object]$Usage
    )

    if (-not $Usage) {
        return
    }

    $hit = Get-UsageNumber -Usage $Usage -Name "prompt_cache_hit_tokens"
    $miss = Get-UsageNumber -Usage $Usage -Name "prompt_cache_miss_tokens"
    $prompt = Get-UsageNumber -Usage $Usage -Name "prompt_tokens"
    $total = Get-UsageNumber -Usage $Usage -Name "total_tokens"
    $rate = if (($hit + $miss) -gt 0) { [Math]::Round($hit / [double]($hit + $miss), 4) } else { 0 }

    $record = [pscustomobject]@{
        at = [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")
        kind = $Kind
        model = $script:AiModel
        promptTokens = $prompt
        totalTokens = $total
        promptCacheHitTokens = $hit
        promptCacheMissTokens = $miss
        promptCacheHitRate = $rate
    }

    try {
        $record | ConvertTo-Json -Compress | Add-Content -LiteralPath $AiUsageLogPath -Encoding UTF8
    } catch {
    }
}

function Invoke-AiCompletion {
    param(
        [object[]]$Messages,
        [int]$MaxTokens = 80
    )

    $apiKey = Get-AiApiKey
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "未配置 AI API Key。请设置环境变量 DEEPSEEK_API_KEY，或在 config.json 里添加 aiApiKey。"
    }

    $payload = [ordered]@{
        model = $script:AiModel
        messages = $Messages
        stream = $false
        temperature = 0.8
        max_tokens = $MaxTokens
    }

    $response = Invoke-RestMethod `
        -Method Post `
        -Uri $script:AiEndpoint `
        -Headers @{ Authorization = "Bearer $apiKey" } `
        -ContentType "application/json; charset=utf-8" `
        -Body ($payload | ConvertTo-Json -Depth 8) `
        -TimeoutSec 25

    $content = $response.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "AI 没有返回内容。"
    }
    return ([string]$content).Trim()
}

function Start-AiCompletionJob {
    param(
        [object[]]$Messages,
        [int]$MaxTokens,
        [string]$Kind
    )

    $apiKey = Get-AiApiKey
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "未配置 AI API Key。请设置环境变量 DEEPSEEK_API_KEY，或在 config.json 里添加 aiApiKey。"
    }

    $messagesJson = $Messages | ConvertTo-Json -Depth 8
    $job = Start-Job -ScriptBlock {
        param($Endpoint, $Model, $ApiKey, $MessagesJson, $MaxTokens)

        try {
            $messages = $MessagesJson | ConvertFrom-Json
            $payload = [ordered]@{
                model = $Model
                messages = $messages
                stream = $false
                temperature = 0.8
                max_tokens = $MaxTokens
            }
            $response = Invoke-RestMethod `
                -Method Post `
                -Uri $Endpoint `
                -Headers @{ Authorization = "Bearer $ApiKey" } `
                -ContentType "application/json; charset=utf-8" `
                -Body ($payload | ConvertTo-Json -Depth 8) `
                -TimeoutSec 25

            $content = [string]$response.choices[0].message.content
            if ([string]::IsNullOrWhiteSpace($content)) {
                throw "AI 没有返回内容。"
            }
            [pscustomobject]@{ ok = $true; content = $content.Trim(); usage = $response.usage } | ConvertTo-Json -Compress -Depth 8
        } catch {
            [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
        }
    } -ArgumentList $script:AiEndpoint, $script:AiModel, $apiKey, $messagesJson, $MaxTokens

    $script:AiPendingJobs.Add([pscustomobject]@{
        Job = $job
        Kind = $Kind
        StartedAt = [DateTime]::UtcNow
    })
    $script:AiJobTimer.Start()
}

function Handle-AiJobResults {
    if (-not $script:AiPendingJobs -or $script:AiPendingJobs.Count -eq 0) {
        $script:AiJobTimer.Stop()
        return
    }

    for ($index = $script:AiPendingJobs.Count - 1; $index -ge 0; $index--) {
        $entry = $script:AiPendingJobs[$index]
        $job = $entry.Job
        if ($job.State -eq "Running" -and ([DateTime]::UtcNow - $entry.StartedAt).TotalSeconds -lt 35) {
            continue
        }

        $raw = Receive-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $script:AiPendingJobs.RemoveAt($index)

        $result = $null
        try {
            if ($raw) {
                $result = ($raw -join "`n") | ConvertFrom-Json
            }
        } catch {
            $result = $null
        }

        if ($result -and $result.ok) {
            Write-AiUsageRecord -Kind $entry.Kind -Usage $result.usage
            $text = [string]$result.content
            if ($entry.Kind -eq "chat") {
                Append-ChatLine -Speaker $script:CurrentPet.DisplayName -Text $text
                Show-PetMessage -Text $text -DurationMs 2800
                Set-AnimationState -State "waving" -Once $true
            } else {
                Show-PetMessage -Text $text -DurationMs 2600
                if ($script:CurrentState -eq "idle" -or $script:CurrentState -eq "waiting") {
                    Set-AnimationState -State "waving" -Once $true
                }
            }
        } else {
            $errorText = if ($result -and $result.error) { [string]$result.error } else { "AI 请求超时或无响应。" }
            if ($entry.Kind -eq "chat") {
                Append-ChatLine -Speaker $script:CurrentPet.DisplayName -Text $errorText
                Show-PetMessage -Text "AI 暂时连不上" -DurationMs 2200
            } elseif (([DateTime]::UtcNow - $script:LastAiErrorAt).TotalSeconds -gt 120) {
                $script:LastAiErrorAt = [DateTime]::UtcNow
                Show-PetMessage -Text "AI 暂时连不上，我先本地陪你" -DurationMs 2600
            }
            Set-AnimationState -State "failed" -Once $true
        }
    }

    if ($script:AiPendingJobs.Count -eq 0) {
        $script:AiJobTimer.Stop()
    }
}

function Start-AiContextMessage {
    param(
        [object]$Context,
        [hashtable]$Reaction
    )

    if (-not $script:AiEnabled -or $script:AiPendingJobs.Count -gt 0) {
        return
    }

    $now = [DateTime]::UtcNow
    if (($now - $script:LastAiContextAt).TotalSeconds -lt 75) {
        return
    }

    try {
        $messages = New-AiBaseMessages -TaskPrompt $AiContextTaskPrompt
        $messages.Add(@{
            role = "user"
            content = "动态上下文：`n当前应用：$($Context.ProcessName)`n当前标题：$(Get-SafeActivityTitle -Context $Context)`n本地推断：$($Reaction.Message)`n最近活动：`n$(Get-RecentActivitySummary)"
        })
        Start-AiCompletionJob -Messages $messages.ToArray() -MaxTokens 60 -Kind "context"
        $script:LastAiContextAt = $now
    } catch {
        if (($now - $script:LastAiErrorAt).TotalSeconds -gt 120) {
            $script:LastAiErrorAt = $now
            Show-PetMessage -Text "先设置 DEEPSEEK_API_KEY" -DurationMs 2600
        }
    }
}

function Append-ChatLine {
    param(
        [string]$Speaker,
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $script:ChatTranscript.Add([pscustomobject]@{
        role = if ($Speaker -eq "你") { "user" } else { "assistant" }
        content = $Text
    })
    while ($script:ChatTranscript.Count -gt 12) {
        $script:ChatTranscript.RemoveAt(0)
    }

    if ($script:ChatHistoryBox) {
        $existing = $script:ChatHistoryBox.Text
        if (-not [string]::IsNullOrWhiteSpace($existing)) {
            $existing += "`r`n`r`n"
        }
        $script:ChatHistoryBox.Text = "$existing$Speaker：$Text"
        $script:ChatHistoryBox.ScrollToEnd()
    }
}

function Send-ChatMessage {
    $text = if ($script:ChatInputBox) { $script:ChatInputBox.Text.Trim() } else { "" }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    $script:ChatInputBox.Clear()
    Append-ChatLine -Speaker "你" -Text $text
    Set-AnimationState -State "review"

    try {
        $historyMessages = New-AiBaseMessages -TaskPrompt $AiChatTaskPrompt
        $lastIndex = $script:ChatTranscript.Count - 1
        for ($index = 0; $index -lt $script:ChatTranscript.Count; $index++) {
            $line = $script:ChatTranscript[$index]
            $content = [string]$line.content
            if ($index -eq $lastIndex -and $line.role -eq "user") {
                $content = "$content`n`n本轮动态上下文（仅供参考）：`n$(Get-RecentActivitySummary)"
            }
            $historyMessages.Add(@{ role = $line.role; content = $content })
        }

        Start-AiCompletionJob -Messages $historyMessages.ToArray() -MaxTokens 180 -Kind "chat"
        Show-PetMessage -Text "我想一下" -DurationMs 1600
    } catch {
        $message = $_.Exception.Message
        Append-ChatLine -Speaker $script:CurrentPet.DisplayName -Text $message
        Show-PetMessage -Text "先配置 API Key，我就能聊天啦" -DurationMs 2600
        Set-AnimationState -State "failed" -Once $true
    }
}

function Show-ChatWindow {
    if ($script:ChatWindow -and $script:ChatWindow.IsVisible) {
        $script:ChatWindow.Activate() | Out-Null
        return
    }

    $chat = New-Object System.Windows.Window
    $chat.Title = "和桌宠聊天"
    $chat.Width = 420
    $chat.Height = 560
    $chat.MinWidth = 360
    $chat.MinHeight = 460
    $chat.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $chat.Topmost = $true
    $chat.Background = New-UiBrush "#F5F7FB"

    $root = New-Object System.Windows.Controls.Grid
    $root.Margin = New-Object System.Windows.Thickness 18
    $row1 = New-Object System.Windows.Controls.RowDefinition
    $row1.Height = [System.Windows.GridLength]::Auto
    $row2 = New-Object System.Windows.Controls.RowDefinition
    $row2.Height = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $row3 = New-Object System.Windows.Controls.RowDefinition
    $row3.Height = [System.Windows.GridLength]::Auto
    $root.RowDefinitions.Add($row1)
    $root.RowDefinitions.Add($row2)
    $root.RowDefinitions.Add($row3)

    $header = New-Object System.Windows.Controls.StackPanel
    $header.Margin = New-Object System.Windows.Thickness 0, 0, 0, 14
    [System.Windows.Controls.Grid]::SetRow($header, 0)
    $headerTitle = New-UiTextBlock -Text "$($script:CurrentPet.DisplayName)" -Size 20 -Color "#172033" -Weight "SemiBold"
    $header.Children.Add($headerTitle) | Out-Null
    $headerSub = New-UiTextBlock -Text "我会参考最近活动，但不会截图或 OCR。" -Size 12 -Color "#687386"
    $headerSub.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0
    $header.Children.Add($headerSub) | Out-Null
    $root.Children.Add($header) | Out-Null

    $history = New-Object System.Windows.Controls.TextBox
    $history.IsReadOnly = $true
    $history.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $history.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $history.AcceptsReturn = $true
    $history.FontSize = 14
    $history.BorderThickness = New-Object System.Windows.Thickness 0
    $history.Background = [System.Windows.Media.Brushes]::White
    $history.Foreground = New-UiBrush "#253044"
    $history.Padding = New-Object System.Windows.Thickness 12

    $historyBorder = New-Object System.Windows.Controls.Border
    $historyBorder.Background = [System.Windows.Media.Brushes]::White
    $historyBorder.BorderBrush = New-UiBrush "#DFE6F0"
    $historyBorder.BorderThickness = New-Object System.Windows.Thickness 1
    $historyBorder.CornerRadius = New-Object System.Windows.CornerRadius 10
    $historyBorder.Child = $history
    [System.Windows.Controls.Grid]::SetRow($historyBorder, 1)
    $root.Children.Add($historyBorder) | Out-Null

    $inputPanel = New-Object System.Windows.Controls.DockPanel
    $inputPanel.Margin = New-Object System.Windows.Thickness 0, 12, 0, 0
    [System.Windows.Controls.Grid]::SetRow($inputPanel, 2)

    $sendButton = New-UiButton -Text "发送" -Primary $true
    $sendButton.Width = 74
    $sendButton.Height = 38
    $sendButton.Margin = New-Object System.Windows.Thickness 10, 0, 0, 0
    [System.Windows.Controls.DockPanel]::SetDock($sendButton, [System.Windows.Controls.Dock]::Right)
    $inputPanel.Children.Add($sendButton) | Out-Null

    $input = New-Object System.Windows.Controls.TextBox
    $input.MinHeight = 38
    $input.FontSize = 14
    $input.Padding = New-Object System.Windows.Thickness 10, 7, 10, 7
    $input.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Center
    $inputPanel.Children.Add($input) | Out-Null
    $root.Children.Add($inputPanel) | Out-Null

    $script:ChatWindow = $chat
    $script:ChatHistoryBox = $history
    $script:ChatInputBox = $input
    $chat.Content = $root

    $sendButton.Add_Click({ Send-ChatMessage })
    $input.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
            $eventArgs.Handled = $true
            Send-ChatMessage
        }
    })
    $chat.Add_Closed({
        $script:ChatWindow = $null
        $script:ChatHistoryBox = $null
        $script:ChatInputBox = $null
    })

    if ($script:ChatTranscript.Count -eq 0) {
        Append-ChatLine -Speaker $script:CurrentPet.DisplayName -Text "我在。可以直接跟我聊，也可以去设置里打开 AI 发言。"
    } else {
        foreach ($line in $script:ChatTranscript) {
            $speaker = if ($line.role -eq "user") { "你" } else { $script:CurrentPet.DisplayName }
            $existing = $script:ChatHistoryBox.Text
            if (-not [string]::IsNullOrWhiteSpace($existing)) {
                $existing += "`r`n`r`n"
            }
            $script:ChatHistoryBox.Text = "$existing$speaker：$($line.content)"
        }
        $script:ChatHistoryBox.ScrollToEnd()
    }
    $chat.Show()
    $input.Focus() | Out-Null
}

function Show-SettingsWindow {
    if ($script:SettingsWindow -and $script:SettingsWindow.IsVisible) {
        $script:SettingsWindow.Activate() | Out-Null
        return
    }

    $settings = New-Object System.Windows.Window
    $settings.Title = "桌宠设置"
    $settings.Width = 480
    $settings.Height = 640
    $settings.MinWidth = 420
    $settings.MinHeight = 520
    $settings.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $settings.Topmost = $true
    $settings.Background = New-UiBrush "#F6F8FB"

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness 20
    $scroll.Content = $root

    $title = New-UiTextBlock -Text "桌宠设置" -Size 22 -Color "#172033" -Weight "SemiBold"
    $root.Children.Add($title) | Out-Null
    $subtitle = New-UiTextBlock -Text "把低频选项放在这里，右键菜单只保留常用入口。" -Size 12 -Color "#687386"
    $subtitle.Margin = New-Object System.Windows.Thickness 0, 4, 0, 18
    $root.Children.Add($subtitle) | Out-Null

    $aiSection = New-UiTextBlock -Text "AI 互动" -Size 15 -Color "#172033" -Weight "SemiBold"
    $aiSection.Margin = New-Object System.Windows.Thickness 0, 6, 0, 8
    $root.Children.Add($aiSection) | Out-Null

    $aiEnabledBox = New-Object System.Windows.Controls.CheckBox
    $aiEnabledBox.Content = "开启 AI 发言"
    $aiEnabledBox.IsChecked = $script:AiEnabled
    $aiEnabledBox.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
    $root.Children.Add($aiEnabledBox) | Out-Null

    $apiLabel = New-UiTextBlock -Text "API Key" -Size 12 -Color "#687386"
    $root.Children.Add($apiLabel) | Out-Null
    $apiBox = New-Object System.Windows.Controls.PasswordBox
    $apiBox.Password = $script:AiApiKey
    $apiBox.Height = 34
    $apiBox.Margin = New-Object System.Windows.Thickness 0, 4, 0, 10
    $root.Children.Add($apiBox) | Out-Null

    $endpointLabel = New-UiTextBlock -Text "Endpoint" -Size 12 -Color "#687386"
    $root.Children.Add($endpointLabel) | Out-Null
    $endpointBox = New-Object System.Windows.Controls.TextBox
    $endpointBox.Text = $script:AiEndpoint
    $endpointBox.Height = 34
    $endpointBox.Margin = New-Object System.Windows.Thickness 0, 4, 0, 10
    $root.Children.Add($endpointBox) | Out-Null

    $modelLabel = New-UiTextBlock -Text "Model" -Size 12 -Color "#687386"
    $root.Children.Add($modelLabel) | Out-Null
    $modelBox = New-Object System.Windows.Controls.TextBox
    $modelBox.Text = $script:AiModel
    $modelBox.Height = 34
    $modelBox.Margin = New-Object System.Windows.Thickness 0, 4, 0, 16
    $root.Children.Add($modelBox) | Out-Null

    $behaviorSection = New-UiTextBlock -Text "行为" -Size 15 -Color "#172033" -Weight "SemiBold"
    $behaviorSection.Margin = New-Object System.Windows.Thickness 0, 4, 0, 8
    $root.Children.Add($behaviorSection) | Out-Null

    $mouseBox = New-Object System.Windows.Controls.CheckBox
    $mouseBox.Content = "鼠标感知"
    $mouseBox.IsChecked = $script:MouseSenseEnabled
    $mouseBox.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
    $root.Children.Add($mouseBox) | Out-Null

    $messageBox = New-Object System.Windows.Controls.CheckBox
    $messageBox.Content = "互动消息气泡"
    $messageBox.IsChecked = $script:MessagesEnabled
    $messageBox.Margin = New-Object System.Windows.Thickness 0, 0, 0, 12
    $root.Children.Add($messageBox) | Out-Null

    $contextLabel = New-UiTextBlock -Text "上下文感知" -Size 12 -Color "#687386"
    $root.Children.Add($contextLabel) | Out-Null
    $contextBox = New-Object System.Windows.Controls.ComboBox
    $contextBox.Height = 34
    $contextBox.Margin = New-Object System.Windows.Thickness 0, 4, 0, 10
    foreach ($modeKey in $ContextModeOptions.Keys) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $ContextModeOptions[$modeKey]
        $item.Tag = $modeKey
        $contextBox.Items.Add($item) | Out-Null
        if ($modeKey -eq $script:ContextMode) {
            $contextBox.SelectedItem = $item
        }
    }
    $root.Children.Add($contextBox) | Out-Null

    $scaleLabel = New-UiTextBlock -Text "缩放" -Size 12 -Color "#687386"
    $root.Children.Add($scaleLabel) | Out-Null
    $scaleBox = New-Object System.Windows.Controls.ComboBox
    $scaleBox.Height = 34
    $scaleBox.Margin = New-Object System.Windows.Thickness 0, 4, 0, 10
    foreach ($scaleOption in $ScaleOptions) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $percent = [int]($scaleOption * 100)
        $codexLabel = if ([Math]::Abs($scaleOption - $DefaultScale) -lt 0.001) { "（接近 Codex）" } else { "" }
        $item.Content = "$percent%$codexLabel"
        $item.Tag = $scaleOption
        $scaleBox.Items.Add($item) | Out-Null
        if ([Math]::Abs($scaleOption - $script:CurrentScale) -lt 0.001) {
            $scaleBox.SelectedItem = $item
        }
    }
    $root.Children.Add($scaleBox) | Out-Null

    $petLabel = New-UiTextBlock -Text "宠物" -Size 12 -Color "#687386"
    $root.Children.Add($petLabel) | Out-Null
    $petBox = New-Object System.Windows.Controls.ComboBox
    $petBox.Height = 34
    $petBox.Margin = New-Object System.Windows.Thickness 0, 4, 0, 18
    foreach ($pet in $script:Pets) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $pet.MenuLabel
        $item.Tag = $pet
        $petBox.Items.Add($item) | Out-Null
        if ($pet.Source -eq $script:CurrentPet.Source -and $pet.Id -eq $script:CurrentPet.Id) {
            $petBox.SelectedItem = $item
        }
    }
    $root.Children.Add($petBox) | Out-Null

    $hint = New-UiTextBlock -Text "API Key 会保存到 config.json。若你使用环境变量 DEEPSEEK_API_KEY，可以把这里留空。" -Size 12 -Color "#687386"
    $hint.Margin = New-Object System.Windows.Thickness 0, 0, 0, 18
    $root.Children.Add($hint) | Out-Null

    $buttonPanel = New-Object System.Windows.Controls.StackPanel
    $buttonPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttonPanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

    $cancelButton = New-UiButton -Text "取消"
    $cancelButton.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    $buttonPanel.Children.Add($cancelButton) | Out-Null

    $saveButton = New-UiButton -Text "保存" -Primary $true
    $buttonPanel.Children.Add($saveButton) | Out-Null
    $root.Children.Add($buttonPanel) | Out-Null

    $cancelButton.Add_Click({
        if ($script:SettingsWindow) {
            $script:SettingsWindow.Close()
        }
    })
    $saveButton.Add_Click({
        $script:AiEnabled = [bool]$aiEnabledBox.IsChecked
        $script:AiApiKey = $apiBox.Password.Trim()
        if (-not [string]::IsNullOrWhiteSpace($endpointBox.Text)) {
            $script:AiEndpoint = $endpointBox.Text.Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($modelBox.Text)) {
            $script:AiModel = $modelBox.Text.Trim()
        }
        $script:MouseSenseEnabled = [bool]$mouseBox.IsChecked
        $script:MessagesEnabled = [bool]$messageBox.IsChecked
        if (-not $script:MessagesEnabled) {
            $script:BubbleBorder.Visibility = [System.Windows.Visibility]::Collapsed
            $script:BubbleTimer.Stop()
        }
        if ($contextBox.SelectedItem) {
            $script:ContextMode = [string]$contextBox.SelectedItem.Tag
            $script:LastContextSignature = ""
        }
        if ($scaleBox.SelectedItem) {
            Set-PetScale -NewScale ([double]$scaleBox.SelectedItem.Tag)
        }
        if ($petBox.SelectedItem) {
            $selectedPet = $petBox.SelectedItem.Tag
            if ($selectedPet.Source -ne $script:CurrentPet.Source -or $selectedPet.Id -ne $script:CurrentPet.Id) {
                Set-CurrentPet -Pet $selectedPet
            }
        }
        Save-Selection -Pet $script:CurrentPet
        Update-ContextMenu
        Show-PetMessage -Text "设置已保存"
        if ($script:SettingsWindow) {
            $script:SettingsWindow.Close()
        }
    })

    $settings.Content = $scroll
    $script:SettingsWindow = $settings
    $settings.Add_Closed({ $script:SettingsWindow = $null })
    $settings.Show()
}

function Invoke-ContextSense {
    if ($script:ContextMode -eq "off" -or $script:MenuOpen -or $script:WalkTimer.IsEnabled) {
        return
    }

    $context = Get-ForegroundContext
    if (-not $context -or [string]::IsNullOrWhiteSpace($context.ProcessName)) {
        return
    }

    $signature = if ($script:ContextMode -eq "low") {
        "$($script:ContextMode)|$($context.ProcessName)"
    } elseif ($script:ContextMode -eq "medium") {
        "$($script:ContextMode)|$($context.ProcessName)|$($context.Title)|$($context.IsFullscreen)|$([int]($context.IdleSeconds / 30))"
    } else {
        "$($script:ContextMode)|$($context.ProcessName)|$($context.Title)|$($context.IsFullscreen)|$([int]($context.IdleSeconds / 30))"
    }

    $now = [DateTime]::UtcNow
    if ($signature -eq $script:LastContextSignature -and ($now - $script:LastContextReactionAt).TotalSeconds -lt 25) {
        return
    }

    $reaction = Get-ContextReaction -Context $context -Mode $script:ContextMode
    Add-ActivityRecord -Context $context -Reaction $reaction
    $script:LastContextSignature = $signature
    $script:LastContextReactionAt = $now

    if ($reaction.State -and $reaction.State -ne $script:CurrentState) {
        Set-AnimationState -State $reaction.State -Once ($reaction.State -eq "jumping")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$reaction.Message)) {
        Show-PetMessage -Text ([string]$reaction.Message) -DurationMs 2200
    }
    Start-AiContextMessage -Context $context -Reaction $reaction
}

function Update-ContextMenu {
    if (-not $script:ContextMenu) {
        Write-DesktopPetError "Cannot update context menu because ContextMenu is null."
        return
    }

    $script:ContextMenu.Items.Clear()

    $chatItem = New-Object System.Windows.Controls.MenuItem
    $chatItem.Header = "打开聊天"
    $chatItem.Add_Click({ Show-ChatWindow })
    $script:ContextMenu.Items.Add($chatItem) | Out-Null

    $settingsItem = New-Object System.Windows.Controls.MenuItem
    $settingsItem.Header = "设置..."
    $settingsItem.Add_Click({ Show-SettingsWindow })
    $script:ContextMenu.Items.Add($settingsItem) | Out-Null

    $separator = New-Object System.Windows.Controls.Separator
    $script:ContextMenu.Items.Add($separator) | Out-Null

    $play = New-Object System.Windows.Controls.MenuItem
    $play.Header = "动作"
    foreach ($entry in @(
        @{ Label = "挥手一次"; State = "waving" },
        @{ Label = "跳一下"; State = "jumping" },
        @{ Label = "思考一下"; State = "review" }
    )) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = $entry.Label
        $item.Tag = $entry.State
        $item.Add_Click({
            param($sender, $eventArgs)
            Set-AnimationState -State ([string]$sender.Tag) -Once $true
        })
        $play.Items.Add($item) | Out-Null
    }

    $moveLeft = New-Object System.Windows.Controls.MenuItem
    $moveLeft.Header = "向左走"
    $moveLeft.Add_Click({ Start-Walk -Direction -1 })
    $play.Items.Add($moveLeft) | Out-Null

    $moveRight = New-Object System.Windows.Controls.MenuItem
    $moveRight.Header = "向右走"
    $moveRight.Add_Click({ Start-Walk -Direction 1 })
    $play.Items.Add($moveRight) | Out-Null
    $script:ContextMenu.Items.Add($play) | Out-Null

    $petMenu = New-Object System.Windows.Controls.MenuItem
    $petMenu.Header = "切换宠物"
    foreach ($pet in $script:Pets) {
        $item = New-Object System.Windows.Controls.MenuItem
        $prefix = if ($pet.Source -eq $script:CurrentPet.Source -and $pet.Id -eq $script:CurrentPet.Id) { "[当前] " } else { "" }
        $item.Header = "$prefix$($pet.MenuLabel)"
        $item.Tag = $pet
        $item.Add_Click({
            param($sender, $eventArgs)
            Set-CurrentPet -Pet $sender.Tag
        })
        $petMenu.Items.Add($item) | Out-Null
    }
    $script:ContextMenu.Items.Add($petMenu) | Out-Null

    $separator2 = New-Object System.Windows.Controls.Separator
    $script:ContextMenu.Items.Add($separator2) | Out-Null

    $exit = New-Object System.Windows.Controls.MenuItem
    $exit.Header = "退出"
    $exit.Add_Click({ $script:Window.Close() })
    $script:ContextMenu.Items.Add($exit) | Out-Null
}

$PetMouseHandler = {
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    if ($eventArgs.ClickCount -ge 2) {
        Show-ChatWindow
    } else {
        $startLeft = $script:Window.Left
        $startTop = $script:Window.Top
        Set-AnimationState -State "running" -Once $true
        if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
            try {
                $script:Window.DragMove()
            } catch [System.InvalidOperationException] {
                Set-AnimationState -State "idle"
                return
            }
        }
        $delta = $script:Window.Left - $startLeft
        $deltaY = $script:Window.Top - $startTop
        if ([Math]::Abs($delta) -le 4 -and [Math]::Abs($deltaY) -le 4) {
            Set-AnimationState -State "waving" -Once $true
            Show-ChatWindow
        } elseif ($delta -gt 12) {
            Set-AnimationState -State "running-right" -Once $true
        } elseif ($delta -lt -12) {
            Set-AnimationState -State "running-left" -Once $true
        } else {
            Set-AnimationState -State "idle"
        }
    }
}

$PetSurface.Add_MouseLeftButtonDown($PetMouseHandler)

$ContextMenu.Add_Opened({
    $script:MenuOpen = $true
    Set-AnimationState -State "waiting"
    Show-PetMessage -Text "需要我做什么？"
})

$ContextMenu.Add_Closed({
    $script:MenuOpen = $false
    if ($script:CurrentState -eq "waiting") {
        Set-AnimationState -State "idle"
    }
})

$Timer.Add_Tick({
    try {
        if (-not $script:Image -or -not $script:Frames -or $script:Frames.Count -eq 0) {
            return
        }
        if (-not $AnimationStates.Contains($script:CurrentState)) {
            $script:CurrentState = "idle"
        }
        if ($script:FrameIndex -lt 0 -or $script:FrameIndex -ge $script:Frames.Count) {
            $script:FrameIndex = 0
        }

        $script:Image.Source = $script:Frames[$script:FrameIndex]
        $durations = $AnimationStates[$script:CurrentState].Durations
        if (-not $durations -or $durations.Count -eq 0) {
            $durations = @(180)
        }
        $delay = $durations[$script:FrameIndex % $durations.Count]
        if ($script:SlowIdle) {
            $delay = [int]($delay * 3.5)
        }
        $script:FrameIndex = ($script:FrameIndex + 1) % $script:Frames.Count
        if ($script:ReturnToIdleAfterLoop -and $script:FrameIndex -eq 0) {
            Set-AnimationState -State "idle"
            return
        }
        $script:Timer.Interval = [TimeSpan]::FromMilliseconds($delay)
    } catch {
        Write-DesktopPetError $_
        if ($script:Timer) {
            $script:Timer.Interval = [TimeSpan]::FromMilliseconds(500)
        }
        return
    }
})

$WalkTimer.Add_Tick({
    if ($script:WalkTicksRemaining -le 0) {
        $script:WalkTimer.Stop()
        Set-AnimationState -State "idle"
        return
    }

    $nextLeft = $script:Window.Left + $script:WalkStep
    $maxLeft = [System.Windows.SystemParameters]::PrimaryScreenWidth - $script:Window.Width
    $script:Window.Left = [Math]::Min([Math]::Max(0, $nextLeft), $maxLeft)
    $script:WalkTicksRemaining -= 1
})

$IdleBlinkTimer.Add_Tick({
    Invoke-IdleBlink
})

$MouseSenseTimer.Add_Tick({
    Invoke-MouseSense
})

$ContextSenseTimer.Add_Tick({
    Invoke-ContextSense
})

$AiJobTimer.Add_Tick({
    Handle-AiJobResults
})

$BubbleTimer.Add_Tick({
    try {
        if ($script:BubbleTimer) {
            $script:BubbleTimer.Stop()
        }
        if ($script:BubbleBorder) {
            $script:BubbleBorder.Visibility = [System.Windows.Visibility]::Collapsed
        }
    } catch {
        Write-DesktopPetError $_
    }
})

$screenWidth = [System.Windows.SystemParameters]::PrimaryScreenWidth
$screenHeight = [System.Windows.SystemParameters]::PrimaryScreenHeight
if ($Center) {
    $Window.Left = [Math]::Max(0, ($screenWidth - $Window.Width) / 2)
    $Window.Top = [Math]::Max(0, ($screenHeight - $Window.Height) / 2)
} else {
    $Window.Left = [Math]::Max(0, $screenWidth - $Window.Width - 80)
    $Window.Top = [Math]::Max(0, $screenHeight - $Window.Height - 120)
}

Set-CurrentPet -Pet $CurrentPet
$Timer.Interval = [TimeSpan]::FromMilliseconds(1)
$Timer.Start()
Schedule-IdleBlink
$MouseSenseTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$MouseSenseTimer.Start()
$ContextSenseTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$ContextSenseTimer.Start()
$AiJobTimer.Interval = [TimeSpan]::FromMilliseconds(500)

$app = [System.Windows.Application]::Current
if (-not $app) {
    $app = New-Object System.Windows.Application
}

$app.Add_DispatcherUnhandledException({
    param($sender, $eventArgs)
    Write-DesktopPetError $eventArgs.Exception
    $eventArgs.Handled = $true
})

try {
    if (-not $Window) {
        throw "Desktop pet window was not created."
    }
    $app.Run($Window) | Out-Null
} catch {
    Write-DesktopPetError $_
    throw
}










