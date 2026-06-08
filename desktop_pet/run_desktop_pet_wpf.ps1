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
$AnimationStates = [ordered]@{
    "idle" = @{ Label = "Idle"; Row = 0; Frames = 6; Durations = @(280, 110, 110, 140, 140, 320) }
    "running-right" = @{ Label = "Run right"; Row = 1; Frames = 8; Durations = @(120, 120, 120, 120, 120, 120, 120, 220) }
    "running-left" = @{ Label = "Run left"; Row = 2; Frames = 8; Durations = @(120, 120, 120, 120, 120, 120, 120, 220) }
    "waving" = @{ Label = "Wave"; Row = 3; Frames = 4; Durations = @(140, 140, 140, 280) }
    "jumping" = @{ Label = "Jump"; Row = 4; Frames = 5; Durations = @(140, 140, 140, 140, 280) }
    "failed" = @{ Label = "Failed"; Row = 5; Frames = 8; Durations = @(140, 140, 140, 140, 140, 140, 140, 240) }
    "waiting" = @{ Label = "Waiting"; Row = 6; Frames = 6; Durations = @(150, 150, 150, 150, 150, 260) }
    "running" = @{ Label = "Working"; Row = 7; Frames = 6; Durations = @(120, 120, 120, 120, 120, 220) }
    "review" = @{ Label = "Review"; Row = 8; Frames = 6; Durations = @(150, 150, 150, 150, 150, 280) }
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
$CurrentScale = Get-InitialScale
$CurrentState = "idle"
$ReturnToIdleAfterLoop = $false
$MenuOpen = $false
$Timer = New-Object System.Windows.Threading.DispatcherTimer
$IdleBlinkTimer = New-Object System.Windows.Threading.DispatcherTimer
$WalkTimer = New-Object System.Windows.Threading.DispatcherTimer
$WalkTicksRemaining = 0
$WalkStep = 0

function Set-CurrentPet {
    param([object]$Pet)

    $script:CurrentPet = $Pet
    $script:Window.Title = "$($Pet.DisplayName) Desktop Pet"
    Save-Selection -Pet $Pet
    Set-AnimationState -State "waving" -Once $true
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
    $script:Frames = New-Frames -Pet $script:CurrentPet -State $State
    if ($State -eq "idle" -and -not $Once -and $script:Frames.Count -gt 0) {
        $stillFrame = $script:Frames[0]
        $script:Frames = New-Object System.Collections.Generic.List[object]
        $script:Frames.Add($stillFrame)
        Schedule-IdleBlink
    }
    $script:FrameIndex = 0
    $script:Image.Source = $script:Frames[0]
    Update-ContextMenu
}

function Start-Walk {
    param([int]$Direction)

    $script:WalkTimer.Stop()
    $script:WalkStep = 8 * $Direction
    $script:WalkTicksRemaining = 28
    if ($Direction -lt 0) {
        Set-AnimationState -State "running-left"
    } else {
        Set-AnimationState -State "running-right"
    }
    $script:WalkTimer.Interval = [TimeSpan]::FromMilliseconds(80)
    $script:WalkTimer.Start()
}

function Schedule-IdleBlink {
    $script:IdleBlinkTimer.Stop()
    $script:IdleBlinkTimer.Interval = [TimeSpan]::FromMilliseconds((Get-Random -Minimum 14000 -Maximum 26000))
    $script:IdleBlinkTimer.Start()
}

function Invoke-IdleBlink {
    if ($script:MenuOpen -or $script:WalkTimer.IsEnabled -or $script:CurrentState -ne "idle") {
        Schedule-IdleBlink
        return
    }

    Set-AnimationState -State "idle" -Once $true
}

function Update-ContextMenu {
    $script:ContextMenu.Items.Clear()

    foreach ($pet in $script:Pets) {
        $item = New-Object System.Windows.Controls.MenuItem
        $prefix = if ($pet.Source -eq $script:CurrentPet.Source -and $pet.Id -eq $script:CurrentPet.Id) { "[current] " } else { "" }
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

    $scaleMenu = New-Object System.Windows.Controls.MenuItem
    $scaleMenu.Header = "Scale"
    foreach ($scaleOption in $ScaleOptions) {
        $scaleItem = New-Object System.Windows.Controls.MenuItem
        $percent = [int]($scaleOption * 100)
        $prefix = if ([Math]::Abs($scaleOption - $script:CurrentScale) -lt 0.001) { "[current] " } else { "" }
        $codexLabel = if ([Math]::Abs($scaleOption - $DefaultScale) -lt 0.001) { " (Codex-like)" } else { "" }
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
    $actions.Header = "Codex-like state"
    foreach ($stateName in $AnimationStates.Keys) {
        $stateInfo = $AnimationStates[$stateName]
        $item = New-Object System.Windows.Controls.MenuItem
        $prefix = if ($stateName -eq $script:CurrentState) { "[current] " } else { "" }
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
    $play.Header = "One-shot actions"
    foreach ($entry in @(
        @{ Label = "Wave once"; State = "waving" },
        @{ Label = "Jump once"; State = "jumping" },
        @{ Label = "Think once"; State = "review" }
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
    $moveLeft.Header = "Walk left"
    $moveLeft.Add_Click({ Start-Walk -Direction -1 })
    $script:ContextMenu.Items.Add($moveLeft) | Out-Null

    $moveRight = New-Object System.Windows.Controls.MenuItem
    $moveRight.Header = "Walk right"
    $moveRight.Add_Click({ Start-Walk -Direction 1 })
    $script:ContextMenu.Items.Add($moveRight) | Out-Null

    $separator2 = New-Object System.Windows.Controls.Separator
    $script:ContextMenu.Items.Add($separator2) | Out-Null

    $exit = New-Object System.Windows.Controls.MenuItem
    $exit.Header = "Exit"
    $exit.Add_Click({ $script:Window.Close() })
    $script:ContextMenu.Items.Add($exit) | Out-Null
}

$PetMouseHandler = {
    param($sender, $eventArgs)
    if ($eventArgs.ClickCount -ge 2) {
        Set-AnimationState -State "waving" -Once $true
    } else {
        $startLeft = $script:Window.Left
        Set-AnimationState -State "running" -Once $true
        $script:Window.DragMove()
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

$Image.Add_MouseLeftButtonDown($PetMouseHandler)
$PetSurface.Add_MouseLeftButtonDown($PetMouseHandler)

$ContextMenu.Add_Opened({
    $script:MenuOpen = $true
    Set-AnimationState -State "waiting"
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

$app = New-Object System.Windows.Application
$app.Run($Window) | Out-Null
