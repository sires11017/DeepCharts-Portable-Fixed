<#
.SYNOPSIS
    One-click offline setup for DeepCharts Portable — no internet needed.
.DESCRIPTION
    Run this script (right-click → "Run with PowerShell" as Administrator) after
    extracting the ZIP. Everything required is already included in the package:
      1. Installs Python 3.12 (from prereqs/python-3.12.7-amd64.exe) if missing
      2. Installs Python packages from local wheels (prereqs/wheels/)
      3. Installs DeepCharts from the pre-built installer at repo root
      4. Configures hosts file, CA cert trust, Defender exclusions, desktop shortcut
    No internet connection required. All files are in the ZIP.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  DeepCharts Portable — Offline Setup" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

# Locate local prereqs
$pyInstaller = Join-Path $scriptRoot "prereqs" "python-3.12.7-amd64.exe"
$wheelDir = Join-Path $scriptRoot "prereqs" "wheels"
$prebuiltInstaller = Join-Path $scriptRoot "DeepCharts-Setup-1.0.0.exe"

# ── Step 1: Install Python from local installer ───────────────────────────
Write-Host "[1/4] Checking Python..." -ForegroundColor Yellow
$pyExe = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $pyExe) {
    if (Test-Path $pyInstaller) {
        Write-Host "  Python not found. Installing from prereqs/python-3.12.7-amd64.exe ..." -ForegroundColor Yellow
        Start-Process -FilePath $pyInstaller -ArgumentList "/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_pip=1", "Include_launcher=1" -Wait
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        $pyExe = (Get-Command python -ErrorAction SilentlyContinue).Source
        if (-not $pyExe) {
            $latest = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Directory | Sort-Object Name -Descending | Select-Object -First 1
            if ($latest) { $pyExe = Join-Path $latest.FullName "python.exe" }
        }
    } else {
        Write-Host "  [SKIP] Python installer not found at prereqs/python-3.12.7-amd64.exe" -ForegroundColor Yellow
    }
}
if ($pyExe -and (Test-Path $pyExe)) {
    Write-Host "  [+] Python: $(& $pyExe --version 2>&1)" -ForegroundColor Green
} else {
    Write-Host "  [WARN] Python not available. Continuing without." -ForegroundColor Yellow
}

# ── Step 2: Install Python packages from local wheels ─────────────────────
if ($pyExe -and (Test-Path $pyExe) -and (Test-Path $wheelDir)) {
    Write-Host "[2/4] Installing Python packages from local wheels..." -ForegroundColor Yellow
    $wheels = Get-ChildItem $wheelDir -Filter "*.whl"
    if ($wheels) {
        & $pyExe -m pip install --no-index --find-links $wheelDir pyinstaller protobuf cryptography websockets --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [+] $($wheels.Count) wheels installed" -ForegroundColor Green
        } else {
            Write-Host "  [!] Wheel install had issues — check output above" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "[2/4] Skipping Python packages (Python or wheels not available)" -ForegroundColor Yellow
}

# ── Step 3: Install DeepCharts from pre-built installer ───────────────────
Write-Host "[3/4] Installing DeepCharts..." -ForegroundColor Yellow
if (Test-Path $prebuiltInstaller) {
    Write-Host "  Using pre-built installer: $prebuiltInstaller" -ForegroundColor Cyan
    Write-Host "  Size: $('{0:N0} KB' -f ((Get-Item $prebuiltInstaller).Length / 1KB))" -ForegroundColor Cyan
    Start-Process -FilePath $prebuiltInstaller -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait
    Write-Host "  [+] DeepCharts installed" -ForegroundColor Green
} else {
    Write-Host "  [WARN] Pre-built installer not found at root." -ForegroundColor Yellow
    Write-Host "  Attempting build from source instead..." -ForegroundColor Yellow
    $installerBuild = Join-Path $scriptRoot "installer" "build.ps1"
    if (Test-Path $installerBuild) {
        & $installerBuild -RepoRoot $scriptRoot
        $outputDir = Join-Path $scriptRoot "output"
        $builtInstaller = Get-ChildItem $outputDir -Filter "DeepCharts*.exe" | Select-Object -First 1
        if ($builtInstaller) {
            Start-Process -FilePath $builtInstaller.FullName -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait
            Write-Host "  [+] DeepCharts installed (from source build)" -ForegroundColor Green
        } else {
            Write-Host "  [ERROR] Build failed — no installer produced." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "  [ERROR] No installer found at root and build script missing." -ForegroundColor Red
        exit 1
    }
}

# ── Step 4: Runtime configuration ─────────────────────────────────────────
Write-Host "[4/4] Configuring system..." -ForegroundColor Yellow
$appDir = "$env:ProgramFiles\DeepCharts"
if (-not (Test-Path $appDir)) { $appDir = "${env:ProgramFiles(x86)}\DeepCharts" }

$commonAppData = [Environment]::GetFolderPath("CommonApplicationData")
$caDir = Join-Path $commonAppData "DeepCharts" "certs"

if (Test-Path $appDir) {
    # CA certificate trust
    $caCert = Join-Path $caDir "mitm_ca" "ca.pem"
    if (Test-Path $caCert) {
        try {
            Import-Certificate -FilePath $caCert -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [+] CA certificate installed (Trusted Root)" -ForegroundColor Green
        } catch { Write-Host "  [!] Could not install CA cert: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    # Hosts file entries (redirect CQG/DeepCharts domains to localhost)
    $hostsEntries = @(
        "127.0.0.1 demoapi.cqg.com",
        "127.0.0.1 api.cqg.com",
        "127.0.0.1 depth-it.historical.deepcharts.com",
        "127.0.0.1 data-b.historical.deepcharts.com"
    )
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    try {
        $hosts = Get-Content $hostsPath -Encoding ASCII -ErrorAction Stop
        $changed = $false
        foreach ($entry in $hostsEntries) {
            $hostname = ($entry -split "\s+")[1]
            $existing = $hosts | Where-Object { $_ -match "\s+$hostname\s*$" -or $_ -match "\s+$hostname`$" }
            if (-not $existing) {
                $hosts += $entry; $changed = $true
                Write-Host "  [+] Hosts entry: $entry" -ForegroundColor Green
            }
        }
        if ($changed) {
            $hosts | Out-File $hostsPath -Encoding ascii -Force
            ipconfig /flushdns | Out-Null
        }
    } catch { Write-Host "  [!] Could not update hosts file (run as Admin)" -ForegroundColor Yellow }

    # Windows Defender exclusion
    try {
        Add-MpPreference -ExclusionPath $appDir -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  [+] Defender exclusion added" -ForegroundColor Green
    } catch { Write-Host "  [!] Could not add Defender exclusion" -ForegroundColor Yellow }

    # Desktop shortcut
    $desktop = [Environment]::GetFolderPath("Desktop")
    $deepchartExe = Join-Path $appDir "Deepchart.exe"
    if (Test-Path $deepchartExe) {
        $shortcut = Join-Path $desktop "DeepCharts.lnk"
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($shortcut)
        $lnk.TargetPath = $deepchartExe
        $lnk.WorkingDirectory = $appDir
        $lnk.Description = "DeepCharts Portable"
        $lnk.Save()
        Write-Host "  [+] Desktop shortcut created" -ForegroundColor Green
    }
} else {
    Write-Host "  [!] $appDir not found — DeepCharts may not have installed correctly." -ForegroundColor Yellow
}

# ── Done ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  DONE! DeepCharts Portable is installed." -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Click the DeepCharts desktop shortcut to launch." -ForegroundColor White
Write-Host "  (Right-click → Pin to taskbar for one-click access)" -ForegroundColor White
Write-Host ""
