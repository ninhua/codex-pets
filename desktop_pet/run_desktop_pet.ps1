$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppPath = Join-Path $ScriptDir "app.py"
$LocalPython = Join-Path $ScriptDir ".venv\Scripts\python.exe"
$BundledPython = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"

function Test-PetPython {
    param([string]$PythonPath)

    if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath)) {
        return $false
    }

    & $PythonPath -c "import tkinter; import PIL" *> $null
    return ($LASTEXITCODE -eq 0)
}

$Candidates = @()
if (Test-Path -LiteralPath $LocalPython) {
    $Candidates += $LocalPython
}
$Python = Get-Command python -ErrorAction SilentlyContinue
if ($Python) {
    $Candidates += $Python.Source
}
$PyLauncher = Get-Command py -ErrorAction SilentlyContinue
if ($PyLauncher) {
    $Candidates += $PyLauncher.Source
}
if (Test-Path -LiteralPath $BundledPython) {
    $Candidates += $BundledPython
}

foreach ($Candidate in $Candidates) {
    if (Test-PetPython $Candidate) {
        & $Candidate $AppPath
        if ($LASTEXITCODE -eq 0) {
            exit 0
        }
        break
    }
}

$WpfLauncher = Join-Path $ScriptDir "run_desktop_pet_wpf.ps1"
if (Test-Path -LiteralPath $WpfLauncher) {
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $WpfLauncher
    exit $LASTEXITCODE
}

Write-Host "No usable desktop pet runtime was found. Install Python with Pillow and Tcl/Tk, or use run_desktop_pet_wpf.ps1."
exit 1
