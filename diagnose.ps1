<#
  DeepCharts Diagnose / Fix
  Runs a full health check, auto-repairs what it safely can (hosts entries,
  certificate trust, our own stale processes), and writes a plain-English
  report to C:\Deepchart\diagnostic-report.txt that you can send for support.
  Works even when the launcher won't start.
#>
$ErrorActionPreference = "Continue"

# ---- self-elevate ----
$me = $MyInvocation.MyCommand.Path
$idc = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($idc)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    try { Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$me`"" -ErrorAction Stop }
    catch { Write-Host "Diagnose needs administrator rights. Please re-run and click Yes."; Start-Sleep 5 }
    return
}

$appRoot  = "C:\Deepchart"
$caPath   = "$env:PROGRAMDATA\DeepCharts\certs\mitm_ca\ca.pem"
$hostsPath= "$env:SystemRoot\System32\drivers\etc\hosts"
$logDir   = "$env:LOCALAPPDATA\DeepCharts\logs"
$domains  = @("demoapi.cqg.com","api.cqg.com","depth-it.historical.deepcharts.com","data-b.historical.deepcharts.com")
$report   = "$appRoot\diagnostic-report.txt"
if (-not (Test-Path $appRoot)) { New-Item -ItemType Directory -Force -Path $appRoot | Out-Null }

$out = New-Object System.Collections.ArrayList
function Say($m, $color="Gray") { [void]$out.Add($m); Write-Host $m -ForegroundColor $color }
function Line() { Say ("-" * 60) }

Say "DeepCharts Diagnostic Report"
Say ("Generated : " + (Get-Date))
Say ("OS        : " + (Get-CimInstance Win32_OperatingSystem).Caption)
Say ("Arch      : " + $(if ([Environment]::Is64BitOperatingSystem) { "64-bit" } else { "32-bit" }) + "   Locale: " + (Get-Culture).Name)
Say ("User      : " + $env:USERNAME)
Line

$fails = 0; $warns = 0
function Fail($m) { $script:fails++; Say ("[FAIL] " + $m) Red }
function Warn($m) { $script:warns++; Say ("[WARN] " + $m) Yellow }
function Pass($m) { Say ("[PASS] " + $m) Green }

# --- 1. architecture ---
if (-not [Environment]::Is64BitOperatingSystem) { Fail "This is 32-bit Windows. DeepCharts requires 64-bit Windows and cannot run here." }
else { Pass "64-bit Windows." }

# --- 2. runtimes ---
$dx = @("d3dx9_43.dll","d3dx10_43.dll","d3dx11_43.dll","d3dcompiler_43.dll") | Where-Object { -not (Test-Path "$appRoot\app\$_") }
if ($dx.Count -gt 0) { Fail ("DirectX helper files missing from the app folder: " + ($dx -join ', ') + " -> re-run the installer.") } else { Pass "DirectX helper DLLs present." }
$rel = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -EA SilentlyContinue).Release
if (-not $rel -or $rel -lt 528040) { Fail ".NET Framework 4.8 is missing -> re-run the installer or install .NET 4.8." } else { Pass ".NET Framework 4.8 present." }
$vc = Test-Path "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
if (-not $vc) { Warn "Visual C++ 2015-2022 runtime not detected -> re-run the installer." } else { Pass "Visual C++ runtime present." }

# --- 3. app files present ---
$must = @("$appRoot\Deepchart.exe","$appRoot\app\Deepchart.Core.exe","$appRoot\proxy\DeepChartsProxy\DeepChartsProxy.exe","$appRoot\proxy\DeepChartsHistServer\DeepChartsHistServer.exe")
$miss = $must | Where-Object { -not (Test-Path $_) }
if ($miss.Count -gt 0) { Fail ("Program files are missing (antivirus may have removed them): " + (($miss | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') + " -> add a Defender exclusion for C:\Deepchart and re-run the installer.") } else { Pass "All program files present." }

# --- 4. hosts entries ---
$hostsRaw = @(Get-Content $hostsPath -Encoding UTF8 -EA SilentlyContinue)
$hostsOk = $true; $hostsBad = @()
foreach ($d in $domains) {
    $esc = [regex]::Escape($d)
    $active = @($hostsRaw | Where-Object { $_ -notmatch '^\s*#' -and $_ -match ("\s" + $esc + "(\s|$|#)") })
    $loop = @($active | Where-Object { $_ -match ("^\s*127\.0\.0\.1\s+" + $esc) })
    $foreign = @($active | Where-Object { $_ -notmatch ("^\s*127\.0\.0\.1\s+" + $esc) })
    if ($loop.Count -eq 0 -or $foreign.Count -gt 0) { $hostsOk = $false; $hostsBad += $d }
}
if ($hostsOk) { Pass "Data-feed hosts entries correct (all point to 127.0.0.1)." }
else { Fail ("Data-feed hosts entries wrong/missing/duplicated for: " + ($hostsBad -join ', ') + " (WILL AUTO-REPAIR below).") }

# --- 5. certificate trust ---
$caTrusted = $false
if (Test-Path $caPath) {
    try {
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($caPath)
        $tp = $cert.Thumbprint
        $caTrusted = [bool](@(Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -EA SilentlyContinue | Where-Object { $_.Thumbprint -eq $tp }).Count)
        if ($caTrusted) { Pass ("Security certificate is trusted (thumbprint " + $tp.Substring(0,12) + "...).") }
        else { Fail "Security certificate exists but is NOT trusted (antivirus may have removed it) (WILL AUTO-REPAIR below)." }
    } catch { Fail "Security certificate file is unreadable/corrupt -> re-run the installer." }
} else { Fail "Security certificate missing -> re-run the installer." }

# --- 6. upstream reachability ---
$ip = [Environment]::GetEnvironmentVariable("CQG_UPSTREAM_IP","Machine")
if (-not $ip) { $ip = "208.48.16.22" }
Say ("Market-data server IP: " + $ip)
try {
    $tcp = New-Object Net.Sockets.TcpClient
    $iar = $tcp.BeginConnect($ip, 443, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(4000) -and $tcp.Connected) { Pass "Can reach the market-data server (port 443)." ; $tcp.Close() }
    else { Warn "Could NOT reach the market-data server ($ip:443) - usually a firewall/VPN, or the server IP changed. Check firewall/VPN, or try on a normal network." ; try { $tcp.Close() } catch {} }
} catch { Warn "Could NOT reach the market-data server ($ip:443) - firewall/VPN or network issue." }

# --- 7. logon result ---
$bm = Get-ChildItem "$logDir\bridge_mitm_*.log" -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
if ($bm) {
    $c = Get-Content $bm.FullName -Raw
    $m = [regex]::Match($c, '\[LOGON\]\s*Result code=(\d+)')
    if ($m.Success -and $m.Groups[1].Value -eq "0") { Pass "CQG logon succeeded (feed authenticated)." }
    elseif ($m.Success) { Fail ("CQG logon was REJECTED (result code=" + $m.Groups[1].Value + "). The built-in demo account likely expired -> open DeepCharts, click Credentials, enter your own CQG login.") }
    elseif ($c -match 'Cannot establish upstream') { Warn "The proxy could not reach CQG (upstream connection failed) - firewall/VPN or server IP." }
    else { Warn "No CQG logon result yet in the log (feed may still be connecting)." }
} else { Warn "No proxy log found yet (has the app been launched?)." }

# --- 8. history engine ---
$vh = Get-ChildItem "$logDir\vol_hist_*.log" -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
if ($vh) {
    $vc2 = Get-Content $vh.FullName -Raw
    if ($vc2 -match 'protobufs NOT found') { Fail "History engine component missing -> re-run installer / add a Defender exclusion for C:\Deepchart." }
    elseif ($vc2 -match '\[SIGN\] FAILED' -or $vc2 -match 'SIGN.*Failed') { Warn "History signing is blocked by this PC's security policy - historical bars may not load (live data still works)." }
    else { Pass "History engine loaded OK." }
}

Line
# ================= AUTO-REPAIR =================
Say "AUTO-REPAIR:"
# hosts
if (-not $hostsOk) {
    try {
        Copy-Item $hostsPath "$hostsPath.deepcharts.bak" -Force -EA SilentlyContinue
        $kept = @($hostsRaw | Where-Object {
            $l = $_
            if ($l -match '^\s*#\s*DeepCharts CQG proxy entries') { return $false }
            foreach ($d in $domains) { if ($l -match ("\s" + [regex]::Escape($d) + "(\s|$|#)")) { return $false } }
            if ($l -match '\.cqg\.com(\s|$|#)' -and $l -notmatch '^\s*127\.0\.0\.1') { return $false }
            if ($l -match 'historical\.deepcharts\.com(\s|$|#)' -and $l -notmatch '^\s*127\.0\.0\.1') { return $false }
            return $true
        })
        $new = $kept + @("# DeepCharts CQG proxy entries") + ($domains | ForEach-Object { "127.0.0.1 $_" })
        $tmp = "$hostsPath.dctmp"
        $new | Set-Content -Path $tmp -Encoding UTF8 -Force
        [System.IO.File]::Replace($tmp, $hostsPath, "$hostsPath.deepcharts.bak")
        & ipconfig /flushdns | Out-Null
        Say "  [FIXED] Hosts entries repaired (backup at hosts.deepcharts.bak)." Green
    } catch { Say ("  [could not repair hosts: " + $_.Exception.Message + "]") Yellow }
}
# CA trust
if ((Test-Path $caPath) -and -not $caTrusted) {
    try {
        & certutil -addstore -f Root $caPath | Out-Null
        & certutil -user -addstore -f Root $caPath | Out-Null
        Say "  [FIXED] Re-added the security certificate to the trusted store." Green
    } catch { Say "  [could not re-add certificate - a security policy may block it]" Yellow }
}
# our own stale listeners (never foreign)
foreach ($n in @("DeepChartsProxy","DeepChartsHistServer")) {
    $procs = Get-Process -Name $n -EA SilentlyContinue
    if ($procs) { $procs | Stop-Process -Force -EA SilentlyContinue; Say ("  [FIXED] Stopped stale " + $n + " so it can restart cleanly.") Green }
}
if ($hostsOk -and $caTrusted) { Say "  Nothing needed auto-repair." }

Line
$verdict = if ($fails -gt 0) { "PROBLEMS FOUND ($fails) - see above." } elseif ($warns -gt 0) { "Mostly OK ($warns warnings)." } else { "Everything looks healthy." }
Say ("SUMMARY: " + $verdict)
Say ""
Say "The newest log tails are appended below for support."
Line
if ($bm) { Say ("=== bridge_mitm (" + $bm.Name + ") tail ==="); (Get-Content $bm.FullName -Tail 25) | ForEach-Object { [void]$out.Add($_) } }
if ($vh) { Say ("=== vol_hist (" + $vh.Name + ") tail ==="); (Get-Content $vh.FullName -Tail 15) | ForEach-Object { [void]$out.Add($_) } }

$out | Set-Content -Path $report -Encoding UTF8 -Force
Write-Host ""
Write-Host "Full report saved to: $report" -ForegroundColor Cyan
Write-Host "Opening it now - send that file for support if you need help." -ForegroundColor Cyan
try { Start-Process notepad $report } catch {}
if ($fails -gt 0 -or $warns -gt 0) { Write-Host ""; Read-Host "Press Enter to close" }
