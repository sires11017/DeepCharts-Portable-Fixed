<#
.SYNOPSIS
    Shared Python detection for DeepCharts.
    Dot-source this script to get $script:PythonExe.
.DESCRIPTION
    Searches for Python 3 using multiple methods:
    1. .python_path config file (from installer)
    2. py launcher (most reliable)
    3. python / python3 in PATH (filters out Windows Store stubs)
    4. Common install locations
    5. AppData\Local\Programs\Python
.EXAMPLE
    . .\find-python.ps1
    if ($script:PythonExe) { ... }
#>

$script:PythonExe = $null

# 0. Check PYTHON_EXE env var (set by launch.vbs)
if ($env:PYTHON_EXE -and (Test-Path $env:PYTHON_EXE)) {
    $script:PythonExe = $env:PYTHON_EXE
    return
}

# Helper: Test if a python path is real (not a Windows Store stub)
function Test-RealPython {
    param([string]$Path)
    if (-not $Path) { return $false }
    # Windows Store stubs live in WindowsApps
    if ($Path -match "WindowsApps") { return $false }
    # Try to get version
    try {
        $v = & $Path --version 2>&1
        if ($v -match "Python 3\.\d+") { return $true }
    } catch {}
    return $false
}

# 1. Check saved config from installer
$rootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pyPathFile = Join-Path $rootDir ".python_path"
if (Test-Path $pyPathFile) {
    try {
        $saved = (Get-Content $pyPathFile -Raw).Trim()
        if ($saved -and (Test-Path $saved)) {
            # Verify it's not a Store stub
            if ($saved -notmatch "WindowsApps") {
                $script:PythonExe = $saved
                return
            }
        }
    } catch {}
}

# 2. Try py launcher (most reliable - bypasses PATH issues)
try {
    $pyCmd = Get-Command "py" -ErrorAction SilentlyContinue
    if ($pyCmd) {
        $test = & $pyCmd.Source -3 --version 2>&1
        if ($test -match "Python 3") {
            $pyExe = & $pyCmd.Source -3 -c "import sys; print(sys.executable)" 2>&1
            if ($pyExe -and (Test-Path $pyExe) -and $pyExe -notmatch "WindowsApps") {
                $script:PythonExe = $pyExe
                return
            }
            # If we can't get the path, at least we know py works
            $script:PythonExe = $pyCmd.Source
            return
        }
    }
} catch {}

# 3. Try python/python3 in PATH (filter out Store stubs)
foreach ($cmd in @("python", "python3")) {
    try {
        $info = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($info -and $info.Source) {
            # Skip Windows Store stubs
            if ($info.Source -match "WindowsApps") {
                Write-Host "  (Skipping Store stub: $($info.Source))" -ForegroundColor Yellow
                continue
            }
            $v = & $info.Source --version 2>&1
            if ($v -match "Python 3\.\d+") {
                $script:PythonExe = $info.Source
                return
            }
        }
    } catch {}
}

# 4. Search common install locations (wildcards)
$searchPatterns = @(
    "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
    "C:\Python3*\python.exe",
    "$env:ProgramFiles\Python3*\python.exe",
    "$env:ProgramFiles(x86)\Python3*\python.exe"
)
foreach ($pattern in $searchPatterns) {
    try {
        $found = Resolve-Path $pattern -ErrorAction SilentlyContinue | Sort-Object Path -Descending | Select-Object -First 1
        if ($found) {
            if (Test-RealPython -Path $found.Path) {
                $script:PythonExe = $found.Path
                return
            }
        }
    } catch {}
}

# 5. AppData\Local\Programs\Python (python.org default)
$appDataPython = "$env:LOCALAPPDATA\Programs\Python"
if (Test-Path $appDataPython) {
    $dirs = Get-ChildItem $appDataPython -Filter "Python3*" -Directory -ErrorAction SilentlyContinue
    # Sort by numeric version (e.g. Python312 > Python311 > Python310)
    $dirs = $dirs | Sort-Object { [int]($_.Name -replace 'Python(\d)(\d+)', '$1$2') } -Descending
    foreach ($d in $dirs) {
        $exe = Join-Path $d.FullName "python.exe"
        if (Test-Path $exe) {
            $script:PythonExe = $exe; return
        }
    }
}

# 6. No Python found - return null (caller must handle)
$script:PythonExe = $null
