#requires -version 3
# clear-proxy.ps1
# Clears the portable DeepCharts proxy interference so the OFFICIAL DeepCharts runs clean.
# Searches for whatever is holding the proxy ports / running the proxy scripts, stops it,
# and disables every hosts-file redirect for CQG/DeepCharts. Changes NO logins or credentials.

$ErrorActionPreference = 'Continue'
Write-Host ''
Write-Host '=== Clear DeepCharts proxy interference ===' -ForegroundColor Cyan
Write-Host ''

$killed = @()

# 1. Stop anything LISTENING on the proxy ports 443 / 12010 that looks like the proxy
foreach ($port in 443, 12010) {
    $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if ($p) {
            if ($p.ProcessName -match 'python|DeepCharts|BridgeWrapper|Volumetrica') {
                Write-Host ("Stopping {0} (holding port {1})" -f $p.ProcessName, $port) -ForegroundColor Yellow
                try { $p | Stop-Process -Force -ErrorAction SilentlyContinue; $killed += $p.ProcessName } catch {}
            } else {
                Write-Host ("Port {0} held by {1} - left alone (not the proxy)" -f $port, $p.ProcessName) -ForegroundColor DarkGray
            }
        }
    }
}

# 2. Stop any python process whose command line is running the proxy scripts (name-independent)
$pyProxies = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'bridge_mitm_proxy|vol_hist_server' }
foreach ($pp in $pyProxies) {
    Write-Host ("Stopping proxy script (pid {0})" -f $pp.ProcessId) -ForegroundColor Yellow
    try { Stop-Process -Id $pp.ProcessId -Force -ErrorAction SilentlyContinue; $killed += 'proxy-script' } catch {}
}

# 3. Stop remaining known proxy-stack processes by name
Get-Process -Name 'DeepChartsProxy','DeepChartsHistServer','BridgeWrapper' -ErrorAction SilentlyContinue |
    ForEach-Object { try { $_ | Stop-Process -Force -ErrorAction SilentlyContinue; $killed += $_.ProcessName } catch {} }

Start-Sleep -Seconds 1
if ($killed.Count -eq 0) {
    Write-Host 'No proxy processes were running.' -ForegroundColor Green
} else {
    Write-Host ("Stopped: {0}" -f (($killed | Select-Object -Unique) -join ', ')) -ForegroundColor Green
}
Write-Host ''

# 4. Disable every hosts redirect for cqg / deepcharts (any 127.x IP, any spacing)
$h = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$lines = Get-Content $h -ErrorAction SilentlyContinue
$changed = 0
$out = foreach ($line in $lines) {
    if ($line -match '^\s*127\.' -and ($line -match 'cqg\.com' -or $line -match 'deepcharts\.com')) {
        $changed++
        '# DC-OFF ' + $line
    } else {
        $line
    }
}
if ($lines) {
    Set-Content $h $out -Encoding ASCII -Force
    Start-Process ipconfig -ArgumentList '/flushdns' -NoNewWindow -Wait -ErrorAction SilentlyContinue
}
if ($changed -gt 0) {
    Write-Host ("Disabled {0} hosts redirect line(s), DNS flushed" -f $changed) -ForegroundColor Green
} else {
    Write-Host 'No active hosts redirects found (already clear)' -ForegroundColor Green
}
Write-Host ''

# 5. Final verification
$still = @()
foreach ($port in 443, 12010) {
    if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { $still += $port }
}
if ($still.Count -gt 0) {
    Write-Host ("WARNING: port(s) still in use: {0} - close any open DeepCharts launcher window and run this again" -f ($still -join ', ')) -ForegroundColor Red
} else {
    Write-Host 'Ports 443 and 12010 are clear.' -ForegroundColor Green
}
Write-Host ''
Write-Host 'Done. Open the official DeepCharts now.' -ForegroundColor Cyan
Start-Sleep -Seconds 5
