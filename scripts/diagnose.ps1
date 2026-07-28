# DeepCharts Diagnostic Script
# Run: powershell -ExecutionPolicy Bypass -File diagnose.ps1

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $root

Write-Host "============================================"
Write-Host "  DeepCharts Portable - Full Diagnostic"
Write-Host "============================================"
Write-Host ""

# 1. Python
Write-Host "=== PYTHON ==="
. "$PSScriptRoot\find-python.ps1"
$pyExe = $script:PythonExe
if ($pyExe) {
    Write-Host "  Detected: $pyExe"
    if (Test-Path $pyExe) {
        $v = & $pyExe --version 2>&1
        Write-Host "  Version: $v"
        Write-Host "  EXISTS: YES"
    } else {
        Write-Host "  EXISTS: NO (path invalid)"
    }
} else {
    Write-Host "  Python: NOT FOUND"
}
$configPath = Join-Path $root ".python_path"
if (Test-Path $configPath) {
    $saved = (Get-Content $configPath -Raw).Trim()
    Write-Host "  .python_path: $saved"
    if (Test-Path $saved) { Write-Host "  saved path EXISTS: YES" } else { Write-Host "  saved path EXISTS: NO" }
} else { Write-Host "  .python_path: NOT FOUND" }
Write-Host ""

# 2. Ports
Write-Host "=== PORTS ==="
$port443 = Get-NetTCPConnection -LocalPort 443 -ErrorAction SilentlyContinue
$port12010 = Get-NetTCPConnection -LocalPort 12010 -ErrorAction SilentlyContinue
if ($port443) {
    $p443 = $port443 | Select-Object -First 1
    Write-Host "  443: LISTENING (PID $($p443.OwningProcess))"
    $procName = (Get-Process -Id $p443.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    Write-Host "       Process: $procName"
    Write-Host "       State: $($p443.State)"
} else { Write-Host "  443: NOT LISTENING" }
if ($port12010) {
    $p12010 = $port12010 | Select-Object -First 1
    Write-Host "  12010: LISTENING (PID $($p12010.OwningProcess))"
    $procName = (Get-Process -Id $p12010.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    Write-Host "         Process: $procName"
    Write-Host "         State: $($p12010.State)"
} else { Write-Host "  12010: NOT LISTENING" }
Write-Host ""

# 3. Hosts file
Write-Host "=== HOSTS FILE ==="
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsEntries = Get-Content $hostsPath -Encoding ASCII -ErrorAction SilentlyContinue | Where-Object { $_ -match 'cqg\.com|deepcharts\.com' }
if ($hostsEntries) { $hostsEntries | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  NO CQG/deepcharts entries!" }
Write-Host ""

# 4. Processes
Write-Host "=== PROCESSES ==="
$pyProcs = Get-Process python -ErrorAction SilentlyContinue
$dcProcs = Get-Process Deepchart* -ErrorAction SilentlyContinue
$bridgeProcs = Get-Process Volumetrica* -ErrorAction SilentlyContinue
$wrapperProcs = Get-Process BridgeWrapper -ErrorAction SilentlyContinue
if ($pyProcs) { $pyProcs | ForEach-Object { Write-Host "  python PID $($_.Id) started $($_.StartTime)" } } else { Write-Host "  python: NOT RUNNING" }
if ($dcProcs) { $dcProcs | ForEach-Object { Write-Host "  Deepchart PID $($_.Id) started $($_.StartTime)" } } else { Write-Host "  Deepchart: NOT RUNNING" }
if ($bridgeProcs) { $bridgeProcs | ForEach-Object { Write-Host "  VolumetricaBridge PID $($_.Id) started $($_.StartTime)" } } else { Write-Host "  VolumetricaBridge: NOT RUNNING" }
if ($wrapperProcs) { $wrapperProcs | ForEach-Object { Write-Host "  BridgeWrapper PID $($_.Id) started $($_.StartTime)" } } else { Write-Host "  BridgeWrapper: NOT RUNNING" }
Write-Host ""

# 5. Connections
Write-Host "=== CONNECTIONS ==="
$bridgeToProxy = Get-NetTCPConnection -LocalPort 443 -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Established" }
$proxyToCQG = Get-NetTCPConnection -RemoteAddress "208.48.16.22" -ErrorAction SilentlyContinue
if ($bridgeToProxy) { Write-Host "  Bridge->Proxy (port 443): ESTABLISHED" } else { Write-Host "  Bridge->Proxy (port 443): NO CONNECTION" }
if ($proxyToCQG) { Write-Host "  Proxy->CQG (208.48.16.22): ESTABLISHED" } else { Write-Host "  Proxy->CQG (208.48.16.22): NO CONNECTION" }
Write-Host ""

# 6. Upstream CQG
Write-Host "=== UPSTREAM CQG ==="
try {
    $result = Test-NetConnection 208.48.16.22 -Port 443 -WarningAction SilentlyContinue
    if ($result.TcpTestSucceeded) { Write-Host "  208.48.16.22:443 REACHABLE" } else { Write-Host "  208.48.16.22:443 BLOCKED" }
} catch { Write-Host "  Test failed: $_" }
Write-Host ""

# 7. Installed files
Write-Host "=== INSTALLED FILES ==="
$checks = @(
    "Deepchart.exe",
    "app\Deepchart.Core.exe",
    "app\BridgeWrapper.exe",
    "app\bridge\VolumetricaBridge.exe",
    "proxy\mitm\bridge_mitm_proxy.py",
    "proxy\mitm\vol_hist_server.py",
    "proxy\mitm\config.py",
    "certs\mitm_ca\ca.pem",
    "certs\mitm_ca\ca.key"
)
foreach ($f in $checks) {
    $full = Join-Path $root $f
    if (Test-Path $full) { Write-Host "  [OK] $f" } else { Write-Host "  [MISSING] $f" }
}
Write-Host ""

# 8. Wrapper log
Write-Host "=== BRIDGE WRAPPER LOG ==="
$wrapperLog = Join-Path ([Environment]::GetFolderPath("ApplicationData")) "DeepCharts\bridge_wrapper.log"
if (Test-Path $wrapperLog) {
    Write-Host "  Last 20 lines:"
    Get-Content $wrapperLog -Tail 20 | ForEach-Object { Write-Host "    $_" }
} else { Write-Host "  No wrapper log found" }
Write-Host ""

# 9. Latest proxy logs
Write-Host "=== LATEST PROXY LOGS ==="
$logDir = Join-Path $root "logs"
if (Test-Path $logDir) {
    $proxyLogs = Get-ChildItem $logDir -Filter "bridge_mitm_*.log" | Sort-Object LastWriteTime | Select-Object -Last 1
    $histLogs = Get-ChildItem $logDir -Filter "vol_hist_*.log" | Sort-Object LastWriteTime | Select-Object -Last 1

    if ($proxyLogs) {
        Write-Host ""
        Write-Host "  Last bridge_mitm log: $($proxyLogs.Name)"
        Write-Host "  --- Last 40 lines ---"
        Get-Content $proxyLogs.FullName -Tail 40 | ForEach-Object { Write-Host "    $_" }
    } else { Write-Host "  No bridge_mitm logs found" }

    if ($histLogs) {
        Write-Host ""
        Write-Host "  Last vol_hist log: $($histLogs.Name)"
        Write-Host "  --- Last 20 lines ---"
        Get-Content $histLogs.FullName -Tail 20 | ForEach-Object { Write-Host "    $_" }
    } else { Write-Host "  No vol_hist logs found" }
} else { Write-Host "  logs/ directory not found" }

# 10. Launcher log
Write-Host ""
Write-Host "=== LAUNCHER LOG ==="
$launcherLog = Join-Path $root "logs\launcher.log"
if (Test-Path $launcherLog) {
    Write-Host "  Last 20 lines:"
    Get-Content $launcherLog -Tail 20 | ForEach-Object { Write-Host "    $_" }
} else { Write-Host "  No launcher log found" }
Write-Host ""
Write-Host "============================================"
Write-Host "  Copy ALL output above and send it."
Write-Host "============================================"
