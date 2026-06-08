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
$FrameExtractor = Join-Path $ScriptDir "scripts\extract_idle_frames.py"
$FrameCacheRoot = Join-Path $ScriptDir "cache\frames"

$FrameWidth = 192
$FrameHeight = 208
$DefaultScale = 0.6
$ScaleOptions = @(0.5, 0.6, 0.75, 1.0, 1.25, 1.5, 2.0)
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
$BubbleTimer = New-Object System.Windows.Threading.DispatcherTimer
$WalkTimer = New-Object System.Windows.Threading.DispatcherTimer
$WalkTicksRemaining = 0
$WalkStep = 0

function Set-CurrentPet {
    param([object]$Pet)

    $script:CurrentPet = $Pet
    $script:Window.Title = "$($Pet.DisplayName) Desktop Pet"
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
        return
    }

    $script:CurrentState = $State
    $script:ReturnToIdleAfterLoop = $Once
    $script:SlowIdle = ($State -eq "idle" -and -not $Once)
    $script:Frames = New-Frames -Pet $script:CurrentPet -State $State
    $script:FrameIndex = 0
    $script:Image.Source = $script:Frames[0]
    Update-ContextMenu
}

function Show-PetMessage {
    param(
        [string]$Text,
        [int]$DurationMs = 1800
    )

    if (-not $script:MessagesEnabled -or [string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $script:BubbleTimer.Stop()
    $script:BubbleText.Text = $Text
    $script:BubbleBorder.Visibility = [System.Windows.Visibility]::Visible
    $script:BubbleTimer.Interval = [TimeSpan]::FromMilliseconds($DurationMs)
    $script:BubbleTimer.Start()
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

function Get-ContextReaction {
    param(
        [object]$Context,
        [string]$Mode
    )

    $process = $Context.ProcessName.ToLowerInvariant()
    $title = $Context.Title.ToLowerInvariant()

    if ($Mode -eq "medium" -or $Mode -eq "high") {
        if ($Context.IdleSeconds -gt 180) {
            return @{ State = "idle"; Message = "你休息一下也挺好" }
        }
        if ($Context.IsFullscreen) {
            return @{ State = "waiting"; Message = "全屏模式，我安静点" }
        }
    }

    if ($process -match "code|cursor|devenv|idea|pycharm|webstorm|codex") {
        return @{ State = "running"; Message = "写代码中，我陪你盯着" }
    }
    if ($process -match "powershell|cmd|windowsterminal|wt|terminal") {
        return @{ State = "review"; Message = "终端输出我帮你盯着" }
    }
    if ($process -match "chrome|edge|firefox|browser") {
        if (($Mode -eq "medium" -or $Mode -eq "high") -and $title -match "github|pull request|issue|docs|documentation") {
            return @{ State = "review"; Message = "像是在查资料" }
        }
        return @{ State = "waiting"; Message = "在浏览网页吗？" }
    }
    if ($process -match "obsidian|notion|word|onenote|excel|powerpnt") {
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
    $script:LastContextSignature = $signature
    $script:LastContextReactionAt = $now

    if ($reaction.State -and $reaction.State -ne $script:CurrentState) {
        Set-AnimationState -State $reaction.State -Once ($reaction.State -eq "jumping")
    }
    if (-not [string]::IsNullOrWhiteSpace($reaction.Message)) {
        Show-PetMessage -Text $reaction.Message -DurationMs 2200
    }
}

function Update-ContextMenu {
    $script:ContextMenu.Items.Clear()

    foreach ($pet in $script:Pets) {
        $item = New-Object System.Windows.Controls.MenuItem
        $prefix = if ($pet.Source -eq $script:CurrentPet.Source -and $pet.Id -eq $script:CurrentPet.Id) { "[当前] " } else { "" }
        $item.Header = "$prefix$($pet.MenuLabel)"
        $item.Tag = $pet
        $item.Add_Click({
            param($sender, $eventArgs)
            Set-CurrentPet -Pet $sender.Tag
        })
        $script:ContextMenu.Items.Add($item) | Out-Null
    }

    $separator = New-Object System.Windows.Controls.Separator
    $script:ContextMenu.Items.Add($separator) | Out-Null

    $mouseSense = New-Object System.Windows.Controls.MenuItem
    $mouseSense.Header = if ($script:MouseSenseEnabled) { "[当前] 鼠标感知" } else { "鼠标感知" }
    $mouseSense.Add_Click({
        $script:MouseSenseEnabled = -not $script:MouseSenseEnabled
        if (-not $script:MouseSenseEnabled -and $script:CurrentState -eq "waiting") {
            Set-AnimationState -State "idle"
        }
        Update-ContextMenu
    })
    $script:ContextMenu.Items.Add($mouseSense) | Out-Null

    $messages = New-Object System.Windows.Controls.MenuItem
    $messages.Header = if ($script:MessagesEnabled) { "[当前] 互动消息" } else { "互动消息" }
    $messages.Add_Click({
        $script:MessagesEnabled = -not $script:MessagesEnabled
        if (-not $script:MessagesEnabled) {
            $script:BubbleBorder.Visibility = [System.Windows.Visibility]::Collapsed
            $script:BubbleTimer.Stop()
        } else {
            Show-PetMessage -Text "互动消息已开启"
        }
        Update-ContextMenu
    })
    $script:ContextMenu.Items.Add($messages) | Out-Null

    $contextMenu = New-Object System.Windows.Controls.MenuItem
    $contextMenu.Header = "上下文感知"
    foreach ($modeKey in $ContextModeOptions.Keys) {
        $modeItem = New-Object System.Windows.Controls.MenuItem
        $prefix = if ($modeKey -eq $script:ContextMode) { "[当前] " } else { "" }
        $modeItem.Header = "$prefix$($ContextModeOptions[$modeKey])"
        $modeItem.Tag = $modeKey
        $modeItem.Add_Click({
            param($sender, $eventArgs)
            $script:ContextMode = [string]$sender.Tag
            Save-Selection -Pet $script:CurrentPet
            if ($script:ContextMode -eq "off") {
                Show-PetMessage -Text "上下文感知已关闭"
            } else {
                Show-PetMessage -Text "上下文感知：$($ContextModeOptions[$script:ContextMode])"
                $script:LastContextSignature = ""
            }
            Update-ContextMenu
        })
        $contextMenu.Items.Add($modeItem) | Out-Null
    }
    $script:ContextMenu.Items.Add($contextMenu) | Out-Null

    $scaleMenu = New-Object System.Windows.Controls.MenuItem
    $scaleMenu.Header = "缩放"
    foreach ($scaleOption in $ScaleOptions) {
        $scaleItem = New-Object System.Windows.Controls.MenuItem
        $percent = [int]($scaleOption * 100)
        $prefix = if ([Math]::Abs($scaleOption - $script:CurrentScale) -lt 0.001) { "[当前] " } else { "" }
        $codexLabel = if ([Math]::Abs($scaleOption - $DefaultScale) -lt 0.001) { "（接近 Codex）" } else { "" }
        $scaleItem.Header = "$prefix$percent%$codexLabel"
        $scaleItem.Tag = $scaleOption
        $scaleItem.Add_Click({
            param($sender, $eventArgs)
            Set-PetScale -NewScale ([double]$sender.Tag)
        })
        $scaleMenu.Items.Add($scaleItem) | Out-Null
    }
    $script:ContextMenu.Items.Add($scaleMenu) | Out-Null

    $actions = New-Object System.Windows.Controls.MenuItem
    $actions.Header = "状态"
    foreach ($stateName in $AnimationStates.Keys) {
        $stateInfo = $AnimationStates[$stateName]
        $item = New-Object System.Windows.Controls.MenuItem
        $prefix = if ($stateName -eq $script:CurrentState) { "[当前] " } else { "" }
        $item.Header = "$prefix$($stateInfo.Label)"
        $item.Tag = $stateName
        $item.Add_Click({
            param($sender, $eventArgs)
            Set-AnimationState -State ([string]$sender.Tag)
        })
        $actions.Items.Add($item) | Out-Null
    }
    $script:ContextMenu.Items.Add($actions) | Out-Null

    $play = New-Object System.Windows.Controls.MenuItem
    $play.Header = "临时动作"
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
    $script:ContextMenu.Items.Add($play) | Out-Null

    $moveLeft = New-Object System.Windows.Controls.MenuItem
    $moveLeft.Header = "向左走"
    $moveLeft.Add_Click({ Start-Walk -Direction -1 })
    $script:ContextMenu.Items.Add($moveLeft) | Out-Null

    $moveRight = New-Object System.Windows.Controls.MenuItem
    $moveRight.Header = "向右走"
    $moveRight.Add_Click({ Start-Walk -Direction 1 })
    $script:ContextMenu.Items.Add($moveRight) | Out-Null

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
        Set-AnimationState -State "waving" -Once $true
    } else {
        $startLeft = $script:Window.Left
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
        if ($delta -gt 12) {
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
    if (-not $script:Frames -or $script:Frames.Count -eq 0) {
        return
    }
    $script:Image.Source = $script:Frames[$script:FrameIndex]
    $durations = $AnimationStates[$script:CurrentState].Durations
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

$BubbleTimer.Add_Tick({
    $script:BubbleTimer.Stop()
    $script:BubbleBorder.Visibility = [System.Windows.Visibility]::Collapsed
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

$app = New-Object System.Windows.Application
$app.Run($Window) | Out-Null




