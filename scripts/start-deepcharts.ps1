param(
    [switch]$Background
)

$ErrorActionPreference = "Stop"
$REPO = Split-Path -Parent $PSScriptRoot

function Write-Log($msg) { if (-not $Background) { Write-Host $msg } }
function Write-Err($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# -- 0. Kill old processes --
# Only kill Python processes that are our proxies (check command line)
Get-Process python -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        if ($cmdLine -match "bridge_mitm_proxy|vol_hist_server") {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            Write-Log "[*] Killed proxy process PID $($_.Id)"
        }
    } catch {}
}
Get-Process Deepchart* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process VolumetricaBridge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process BridgeWrapper -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# Wait for OS to release ports after killing processes
Start-Sleep -Seconds 3

# -- 1. Find Python --
. "$PSScriptRoot\find-python.ps1"
$python = $script:PythonExe
if (-not $python) {
    Write-Err "Python not found. Install Python 3 and run install.ps1."
    exit 1
}

# Verify Python is real (not Store stub)
if ($python -match "WindowsApps") {
    Write-Err "Detected Windows Store Python stub (not real Python)."
    Write-Err "Install Python from python.org with 'Add to PATH' checked."
    Write-Err "Or disable Store aliases: Settings > Apps > App execution aliases > OFF for python.exe"
    exit 1
}

# Verify Python works
try {
    $v = & $python --version 2>&1
    if ($v -notmatch "Python 3\.\d+") {
        Write-Err "Python detection failed. Got: $v"
        exit 1
    }
} catch {
    Write-Err "Python found at '$python' but cannot execute: $($_.Exception.Message)"
    exit 1
}

Write-Log "[+] Python: $python ($v)"

# Verify required Python packages are installed
$reqFile = Join-Path $REPO "proxy\mitm\requirements.txt"
if (Test-Path $reqFile) {
    $missing = @()
    foreach ($pkg in @("cryptography", "websockets", "protobuf")) {
        try {
            & $python -c "import $pkg" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $missing += $pkg }
        } catch { $missing += $pkg }
    }
    if ($missing.Count -gt 0) {
        Write-Host "[*] Installing missing Python packages: $($missing -join ', ')" -ForegroundColor Yellow
        & $python -m pip install -r $reqFile --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Failed to install Python packages. Run: $python -m pip install -r $reqFile"
        }
    }
}

# -- 1b. Pre-flight checks --
# Verify ports are available (after killing old processes)
$port443 = Get-NetTCPConnection -LocalPort 443 -ErrorAction SilentlyContinue
if ($port443) {
    $pid443 = ($port443 | Select-Object -First 1).OwningProcess
    $procName = (Get-Process -Id $pid443 -ErrorAction SilentlyContinue).ProcessName
    Write-Err "Port 443 is already in use by: $procName (PID $pid443)"
    Write-Err "Run install.ps1 to check and fix port conflicts, or stop the conflicting service."
    exit 1
}

# -- 2. Ensure hosts file has CQG entries --
$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsEntries = @(
    "127.0.0.1 demoapi.cqg.com",
    "127.0.0.1 api.cqg.com",
    "127.0.0.1 depth-it.historical.deepcharts.com",
    "127.0.0.1 data-b.historical.deepcharts.com"
)

try {
    $hostsContent = Get-Content $hostsFile -Raw -ErrorAction Stop
} catch {
    Write-Err "Cannot read hosts file: $($_.Exception.Message)"
    Write-Err "Run this script as Administrator or fix hosts file permissions."
    exit 1
}

$needsUpdate = $false
foreach ($entry in $hostsEntries) {
    $domain = ($entry -split "\s+")[1]
    if ($hostsContent -notmatch "127\.0\.0\.1\s+$([regex]::Escape($domain))") {
        $needsUpdate = $true
        break
    }
    if ($hostsContent -match "\d+\.\d+\.\d+\.\d+\s+$([regex]::Escape($domain))" -and $hostsContent -notmatch "127\.0\.0\.1\s+$([regex]::Escape($domain))") {
        $needsUpdate = $true
        break
    }
}

if ($needsUpdate) {
    $lines = Get-Content $hostsFile | Where-Object {
        $line = $_
        $keep = $true
        foreach ($entry in $hostsEntries) {
            $domain = ($entry -split "\s+")[1]
            if ($line -match "\s+$([regex]::Escape($domain))(\s|$)") {
                $keep = $false
                break
            }
        }
        $keep
    }
    $lines += ""
    $lines += "# DeepCharts CQG proxy entries"
    $lines += $hostsEntries
    try {
        $lines -join "`r`n" | Set-Content -Path $hostsFile -Force -ErrorAction Stop
        Write-Log "[+] Hosts file updated"
    } catch {
        Write-Err "Failed to update hosts file: $($_.Exception.Message)"
        Write-Err "Run as Administrator or add these entries manually to $hostsFile :"
        $hostsEntries | ForEach-Object { Write-Err "  $_" }
        exit 1
    }
}

# -- 3. Start proxies --
$proxyMitmDir = Join-Path $REPO "proxy\mitm"
$histScript = Join-Path $proxyMitmDir "vol_hist_server.py"
$bridgeProxy = Join-Path $proxyMitmDir "bridge_mitm_proxy.py"

if (-not (Test-Path $histScript) -or -not (Test-Path $bridgeProxy)) {
    Write-Err "Proxy scripts not found at $proxyMitmDir"
    exit 1
}

# Try starting proxies with retry
$proxyStarted = $false
$proxyRetries = 3
for ($attempt = 1; $attempt -le $proxyRetries; $attempt++) {
    try {
        $histProc = Start-Process -FilePath $python -ArgumentList "`"$histScript`"" -WorkingDirectory $proxyMitmDir -WindowStyle Hidden -PassThru -ErrorAction Stop
        Write-Log "[+] vol_hist_server started (PID $($histProc.Id))"
        Start-Sleep -Seconds 2
        $proxyProc = Start-Process -FilePath $python -ArgumentList "`"$bridgeProxy`"" -WorkingDirectory $proxyMitmDir -WindowStyle Hidden -PassThru -ErrorAction Stop
        Write-Log "[+] bridge_mitm_proxy started (PID $($proxyProc.Id))"
        $proxyStarted = $true
        break
    } catch {
        Write-Err "Attempt $attempt/$proxyRetries failed to start proxies: $($_.Exception.Message)"
        if ($attempt -lt $proxyRetries) {
            Start-Sleep -Seconds 3
            # Kill any leftover processes
            Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }
}

if (-not $proxyStarted) {
    Write-Err "Failed to start proxies after $proxyRetries attempts."
    Write-Err "Check if Python dependencies are installed: pip install -r proxy\mitm\requirements.txt"
    exit 1
}

# -- 4. Verify proxies started and wait for ports --
$proxyReady = $false
$maxWait = 30
for ($i = 0; $i -lt $maxWait; $i++) {
    Start-Sleep -Seconds 1
    $p443 = netstat -ano 2>$null | findstr ":443 " | findstr "LISTENING"
    $p12010 = netstat -ano 2>$null | findstr ":12010 " | findstr "LISTENING"
    if ($p443 -and $p12010) {
        $proxyReady = $true
        break
    }
    if ($histProc.HasExited) {
        Write-Err "vol_hist_server exited unexpectedly (exit code: $($histProc.ExitCode))"
        break
    }
    if ($proxyProc.HasExited) {
        Write-Err "bridge_mitm_proxy exited unexpectedly (exit code: $($proxyProc.ExitCode))"
        break
    }
}

if (-not $proxyReady) {
    # Show what ports are in use for diagnostics
    Write-Err "Proxy ports not ready after ${maxWait}s."
    Write-Err "Port 443 status:"
    netstat -ano 2>$null | findstr ":443 " | ForEach-Object { Write-Err "  $_" }
    Write-Err "Port 12010 status:"
    netstat -ano 2>$null | findstr ":12010 " | ForEach-Object { Write-Err "  $_" }
    Write-Err "Check logs/ for Python errors."
    exit 1
}
Write-Log "[+] Proxy ports verified (443, 12010)"

# -- 5. Start bridge via wrapper --
$bridgeExe = Join-Path $REPO "app\bridge\VolumetricaBridge.exe"
$wrapperExe = Join-Path $REPO "app\BridgeWrapper.exe"
$bridgeDir = Join-Path $REPO "app\bridge"

if (Test-Path $bridgeExe) {
    if (Test-Path $wrapperExe) {
        Start-Process -FilePath $wrapperExe -ArgumentList "--wait" -WorkingDirectory $bridgeDir -WindowStyle Hidden
        Write-Log "[+] Bridge started via wrapper"
    } else {
        Start-Process -FilePath $bridgeExe -WorkingDirectory $bridgeDir -WindowStyle Hidden
        Write-Log "[+] Bridge started directly"
    }
    Start-Sleep -Seconds 2
} else {
    Write-Err "VolumetricaBridge.exe not found at $bridgeExe"
}

# -- 6. Start Deepchart --
$coreExe = Join-Path $REPO "app\Deepchart.Core.exe"
if (Test-Path $coreExe) {
    Start-Process -FilePath $coreExe -WorkingDirectory $REPO
    Write-Log "[+] Deepchart.Core started"
} else {
    Write-Err "Deepchart.Core.exe not found at $coreExe"
}

if (-not $Background) {
    Write-Host "DeepCharts started successfully"
}
