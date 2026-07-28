<#
.SYNOPSIS
    Build DeepCharts Portable installer (.exe)
.DESCRIPTION
    Compiles launcher (csc.exe), bundles proxy (PyInstaller), stages payload, compiles Inno Setup.
    Requires: Inno Setup 6.3+, Python 3.11+, .NET Framework 4.8 csc.exe
#>

param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Version = "1.0.0",
    [switch]$Sign,
    [string]$CertPath,
    [string]$CertPassword,
    [string]$TimestampUrl = "http://timestamp.sectigo.com"
)

$ErrorActionPreference = "Continue"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadDir = Join-Path $scriptRoot "payload"
$issFile = Join-Path $scriptRoot "DeepCharts.iss"
$outputDir = Join-Path (Split-Path -Parent $scriptRoot) "output"
$iscc = $null
$isccCandidates = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)
foreach ($candidate in $isccCandidates) {
    if (Test-Path $candidate) { $iscc = $candidate; break }
}
if (-not $iscc) { $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source }
if (-not $iscc) { throw "Inno Setup 6 (ISCC.exe) not found. Install from https://jrsoftware.org/isdl.php" }

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  DeepCharts Portable Installer Build" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# ─── 0. Find Python ─────────────────────────────────────────────────────────────
$python = $null
if ($env:PYTHON_EXE -and (Test-Path $env:PYTHON_EXE)) { $python = $env:PYTHON_EXE }
elseif (Test-Path (Join-Path $RepoRoot ".python_path")) {
    $python = (Get-Content (Join-Path $RepoRoot ".python_path") -Raw).Trim()
    if (-not (Test-Path $python)) { $python = $null }
}
if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source }
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source }
if (-not $python) { throw "Python not found. Set PYTHON_EXE or .python_path." }
Write-Host "  Python: $python" -ForegroundColor Gray

# ─── 1. Build Launcher (csc.exe) ────────────────────────────────────────────────
Write-Host "[1/6] Building Deepchart.exe (csc)..." -ForegroundColor White
$launcherSrc = Join-Path (Join-Path $RepoRoot "launcher") "Launcher.cs"
$launcherOut = Join-Path $payloadDir "Deepchart.exe"

$fwDir = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\"
if (-not (Test-Path $fwDir)) { $fwDir = "$env:windir\Microsoft.NET\Framework\v4.0.30319\" }
$csc = Join-Path $fwDir "csc.exe"
if (-not (Test-Path $csc)) { throw "C# compiler (csc.exe) not found" }

New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null

$cscArgs = @(
    "/target:winexe", "/platform:anycpu", "/nologo",
    "/out:$launcherOut",
    "/win32icon:$(Join-Path $RepoRoot "app\deepchart_icon_dark.ico")",
    "/reference:System.Windows.Forms.dll",
    "/reference:System.Drawing.dll",
    "/reference:System.Security.dll",
    "/reference:System.dll",
    "/reference:System.Core.dll",
    $launcherSrc
)
& $csc $cscArgs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $launcherOut)) { throw "Launcher build failed" }
Write-Host "  [+] Deepchart.exe built: $((Get-Item $launcherOut).Length) bytes" -ForegroundColor Green

# ─── 2. Build Proxy (PyInstaller) ───────────────────────────────────────────────
Write-Host "[2/6] Building proxy bundle (PyInstaller)..." -ForegroundColor White
$proxyMitmDir = Join-Path (Join-Path $RepoRoot "proxy") "mitm"
$proxyBuildDir = Join-Path (Join-Path $RepoRoot "build") "proxy"
$proxyDistDir = Join-Path (Join-Path $RepoRoot "build") "dist"
$proxyPayloadDir = Join-Path $payloadDir "proxy"

# Clean old build artifacts
if (Test-Path $proxyBuildDir) { Remove-Item $proxyBuildDir -Recurse -Force }
if (Test-Path $proxyDistDir) { Remove-Item $proxyDistDir -Recurse -Force }

# Bundle both proxy scripts into one directory
Write-Host "  Running PyInstaller for DeepChartsProxy..."
& $python -m PyInstaller --noconfirm --onedir --name DeepChartsProxy --add-data "$proxyMitmDir\config.py;." --add-data "$proxyMitmDir\requirements.txt;." --paths "$proxyMitmDir" --paths (Join-Path (Join-Path $RepoRoot "proxy") "cqg") --hidden-import WebAPI --hidden-import WebAPI.webapi_2_pb2 --hidden-import WebAPI.user_session_2_pb2 --hidden-import WebAPI.historical_2_pb2 --hidden-import WebAPI.market_data_2_pb2 --hidden-import common --hidden-import common.shared_1_pb2 --hidden-import common.decimal_pb2 --hidden-import queue --hidden-import google --hidden-import google.protobuf --collect-submodules WebAPI --collect-submodules common --collect-all google --distpath $proxyDistDir --workpath $proxyBuildDir (Join-Path $proxyMitmDir "bridge_mitm_proxy.py")
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $proxyDistDir "DeepChartsProxy"))) { throw "PyInstaller proxy build failed" }

Write-Host "  Running PyInstaller for DeepChartsHistServer..."
& $python -m PyInstaller --noconfirm --onedir --name DeepChartsHistServer --add-data "$proxyMitmDir\config.py;." --paths "$proxyMitmDir" --paths (Join-Path (Join-Path $RepoRoot "proxy") "cqg") --hidden-import WebAPI --hidden-import queue --hidden-import google --hidden-import google.protobuf --collect-submodules WebAPI --collect-submodules common --collect-all google --distpath $proxyDistDir --workpath $proxyBuildDir (Join-Path $proxyMitmDir "vol_hist_server.py")
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $proxyDistDir "DeepChartsHistServer"))) { throw "PyInstaller hist server build failed" }

# Stage proxy bundles into payload
if (Test-Path $proxyPayloadDir) { Remove-Item $proxyPayloadDir -Recurse -Force }
New-Item -ItemType Directory -Path $proxyPayloadDir -Force | Out-Null
Copy-Item (Join-Path $proxyDistDir "DeepChartsProxy") (Join-Path $proxyPayloadDir "DeepChartsProxy") -Recurse -Force
Copy-Item (Join-Path $proxyDistDir "DeepChartsHistServer") (Join-Path $proxyPayloadDir "DeepChartsHistServer") -Recurse -Force

$proxySize = [math]::Round((Get-ChildItem $proxyPayloadDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host "  [+] Proxy bundles staged ($proxySize MB)" -ForegroundColor Green

# ─── 3. Stage app/ (Core + Bridge + DLLs) ───────────────────────────────────────
Write-Host "[3/6] Staging payload files..." -ForegroundColor White
$appSrc = Join-Path $RepoRoot "app"
$appDst = Join-Path $payloadDir "app"
robocopy $appSrc $appDst /E /XF *.pdb *.config.backup /NFL /NDL /NJH /NJS /NC /NS /NP 2>$null

# Ensure bridge config has xmlSerializerUseReflection
$bridgeCfg = Join-Path $appDst "bridge\VolumetricaBridge.exe.config"
if (Test-Path $bridgeCfg) {
    $cfg = Get-Content $bridgeCfg -Raw
    if ($cfg -notmatch "xmlSerializerUseReflection") {
        $cfg = $cfg.Replace('</runtime>', '        <xmlSerializerUseReflection enabled="true"/>' + "`n" + '    </runtime>')
        Set-Content -Path $bridgeCfg -Value $cfg -Encoding UTF8 -Force
    }
}

# ─── 4. Stage certs & userdata ──────────────────────────────────────────────────
$certsSrc = Join-Path $RepoRoot "certs\mitm_ca"
$certsDst = Join-Path $payloadDir "certs\mitm_ca"
New-Item -ItemType Directory -Path $certsDst -Force | Out-Null
if (Test-Path $certsSrc) {
    Copy-Item (Join-Path $certsSrc "*") $certsDst -Force -Exclude @("cert.pem", "key.pem", "ca.key")
}

$userdataSrc = Join-Path $RepoRoot "userdata"
$userdataDst = Join-Path $payloadDir "userdata"
if (Test-Path $userdataSrc) {
    robocopy $userdataSrc $userdataDst /E /NFL /NDL /NJH /NJS /NC /NS /NP 2>$null
}

# ─── 5. Remove built-in launchers from app/ (we ship our own) ───────────────────
# Only remove if it's the OLD legacy version (Deepchart.Core.exe exists)
$coreExe = Join-Path $appDst "Deepchart.Core.exe"
$newAppExe = Join-Path $appDst "Deepchart.exe"
if (Test-Path $coreExe) {
    # Legacy version - remove app Deepchart.exe (our custom launcher replaces it)
    if (Test-Path $newAppExe) { Remove-Item $newAppExe -Force }
    Write-Host "  Legacy mode: removed app/Deepchart.exe"
} else {
    # v15.6.7 - KEEP app/Deepchart.exe (official app launcher), remove only BridgeWrapper
    Write-Host "  v15.6.7 mode: keeping app/Deepchart.exe"
}
# BridgeWrapper.exe stays for legacy mode (needed by launcher)

# ============================================
# COMPILE INNO SETUP
# ============================================
Write-Host "[4/6] Compiling Inno Setup installer..." -ForegroundColor White
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$isccArgs = @(
    "/Qp",
    "/O$outputDir",
    "/FDeepCharts-Setup-$Version",
    "/DAppVersion=$Version",
    $issFile
)
& $iscc $isccArgs
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed (exit code: $LASTEXITCODE)" }

$setupExe = Get-ChildItem $outputDir -Filter "DeepCharts-Setup-$Version.exe" | Select-Object -First 1
if (-not $setupExe) { throw "Installer not found in output directory" }
Write-Host "  [+] Installer: $($setupExe.FullName) ($([math]::Round($setupExe.Length/1MB,1)) MB)" -ForegroundColor Green

# ============================================
# SIGN (OPTIONAL)
# ============================================
if ($Sign -and $CertPath) {
    Write-Host "[5/6] Signing installer..." -ForegroundColor White
    if (-not (Test-Path $CertPath)) { throw "Certificate not found: $CertPath" }
    & signtool sign /f $CertPath /p $CertPassword /tr $TimestampUrl /td sha256 /fd sha256 $setupExe.FullName
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [+] Signed successfully" -ForegroundColor Green
    } else { throw "Signing failed" }
}

# ============================================
# CLEAN BUILD ARTIFACTS
# ============================================
if (Test-Path $proxyBuildDir) { Remove-Item $proxyBuildDir -Recurse -Force }
if (Test-Path $proxyDistDir) { Remove-Item $proxyDistDir -Recurse -Force }

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  BUILD COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Launcher: $launcherOut" -ForegroundColor White
Write-Host "Proxy:    $proxyPayloadDir ($proxySize MB)" -ForegroundColor White
Write-Host "Setup:    $($setupExe.FullName) ($([math]::Round($setupExe.Length/1MB,1)) MB)" -ForegroundColor White
Write-Host "Version:  $Version" -ForegroundColor White
