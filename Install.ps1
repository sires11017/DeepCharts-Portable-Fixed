<#
  DeepCharts Portable (Fixed) - one-click installer.
  Double-click "Install DeepCharts.bat" and click Yes on the admin prompt.
  Bundles + installs every prerequisite (Visual C++ runtimes, DirectX helpers),
  installs the app to C:\Deepchart, generates + trusts a per-machine certificate,
  configures the data feed, loads templates, makes a Desktop shortcut, and launches.
  Fully automatic. Keeps a log at C:\Deepchart\install-log.txt.
#>
$ErrorActionPreference = "Stop"
$appRoot = "C:\Deepchart"
$dataDir = "C:\Deepchart\data"
$me = $MyInvocation.MyCommand.Path
$src = Split-Path -Parent $me

# ---- self-elevate (one UAC prompt), gracefully ----
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host "DeepCharts installer - requesting administrator rights..." -ForegroundColor Yellow
    Write-Host "Please click YES on the Windows prompt."
    try {
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$me`"" -ErrorAction Stop
    } catch {
        Write-Host ""
        Write-Host "This installer needs administrator rights to run." -ForegroundColor Red
        Write-Host "Please re-run 'Install DeepCharts.bat' and click YES on the prompt."
        Start-Sleep -Seconds 6
    }
    return
}

# ---- elevated: transcript + one big guarded block so the window never vanishes silently ----
New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
try { Start-Transcript -Path "$appRoot\install-log.txt" -Force | Out-Null } catch {}
$ok = $false
try {
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  Installing DeepCharts Portable" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    # ---- 1. Defender exclusion FIRST (before we copy/run unsigned exes) ----
    Write-Host "[1/9] Preparing security settings..." -ForegroundColor White
    try { Add-MpPreference -ExclusionPath $appRoot -ErrorAction Stop; Write-Host "      Defender exclusion added for $appRoot" }
    catch { Write-Host "      (could not add a Defender exclusion - continuing; files will be verified after copy)" -ForegroundColor DarkYellow }

    # ---- 2. stop any running instance ----
    foreach ($n in @("Deepchart.Core","Deepchart","DeepChartsProxy","DeepChartsHistServer","BridgeWrapper","VolumetricaBridge")) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3

    # ---- 3. install bundled runtime prerequisites (no manual downloads) ----
    Write-Host "[2/9] Installing runtime components (Visual C++)..." -ForegroundColor White
    $prereq = Join-Path $src "prereqs"
    $vcList = @(
        @{ f = "vcredist2010_x64.exe"; a = @("/q") },
        @{ f = "vc_redist.x64.exe";    a = @("/install","/quiet","/norestart") },
        @{ f = "vc_redist.x86.exe";    a = @("/install","/quiet","/norestart") }
    )
    foreach ($vc in $vcList) {
        $p = Join-Path $prereq $vc.f
        if (Test-Path $p) {
            try { Start-Process $p -ArgumentList $vc.a -Wait -ErrorAction Stop; Write-Host "      installed $($vc.f)" }
            catch { Write-Host "      (skipped $($vc.f) - probably already present)" -ForegroundColor DarkGray }
        }
    }
    # .NET 4.8 check (in-box on current Windows; download only if genuinely missing)
    $rel = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue).Release
    if (-not $rel -or $rel -lt 528040) {
        Write-Host "      .NET Framework 4.8 not found - downloading..." -ForegroundColor DarkYellow
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $ndp = "$env:TEMP\ndp48.exe"
            Invoke-WebRequest "https://go.microsoft.com/fwlink/?linkid=2088631" -OutFile $ndp -UseBasicParsing -TimeoutSec 600
            Start-Process $ndp -ArgumentList "/q","/norestart" -Wait
        } catch { Write-Host "      (.NET 4.8 auto-install failed - if the app won't open, install .NET Framework 4.8 from microsoft.com)" -ForegroundColor DarkYellow }
    }

    # ---- 4. copy app (launcher + app + proxy), resilient + verified ----
    Write-Host "[3/9] Copying application files..." -ForegroundColor White
    $copied = $false
    for ($i = 0; $i -lt 6 -and -not $copied; $i++) {
        try { Copy-Item "$src\payload\Deepchart.exe" "$appRoot\Deepchart.exe" -Force -ErrorAction Stop; $copied = $true }
        catch { Start-Sleep -Seconds 2 }
    }
    if (-not $copied) { throw "Could not copy the launcher. Is DeepCharts still open? Close it and run the installer again." }
    robocopy "$src\payload\app"   "$appRoot\app"   /E   /R:3 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying the app files failed (robocopy code $LASTEXITCODE)." }
    robocopy "$src\payload\proxy" "$appRoot\proxy" /MIR /R:3 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying the data engine failed (robocopy code $LASTEXITCODE)." }
    $must = @(
        "$appRoot\Deepchart.exe",
        "$appRoot\app\Deepchart.Core.exe",
        "$appRoot\app\SlimDX.dll",
        "$appRoot\proxy\DeepChartsProxy\DeepChartsProxy.exe",
        "$appRoot\proxy\DeepChartsHistServer\DeepChartsHistServer.exe"
    )
    $missing = @($must | Where-Object { -not (Test-Path $_) })
    if ($missing.Count -gt 0) { throw "Files are missing after copy (antivirus likely removed them): $($missing -join ', '). Add a Defender exclusion for C:\Deepchart and retry." }

    # ---- 5. deploy templates to C:\Deepchart\data ----
    Write-Host "[4/9] Loading templates + workspaces..." -ForegroundColor White
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    foreach ($sub in @("Workspace","Template","Indicator Template")) {
        robocopy "$src\userdata\$sub" "$dataDir\$sub" /E /NFL /NDL /NJH /NJS /NP | Out-Null
    }
    if (-not (Test-Path "$dataDir\Settings") -and (Test-Path "$src\userdata\Settings")) {
        robocopy "$src\userdata\Settings" "$dataDir\Settings" /E /NFL /NDL /NJH /NJS /NP | Out-Null
    }

    # ---- 6. per-machine CA: generate (poll+retry), then trust + verify ----
    Write-Host "[5/9] Generating this PC's private certificate..." -ForegroundColor White
    $caDir = "$env:PROGRAMDATA\DeepCharts\certs\mitm_ca"
    New-Item -ItemType Directory -Force -Path $caDir | Out-Null
    if (-not (Test-Path "$caDir\ca.pem")) {
        $env:CA_DIR = $caDir; $env:BRIDGE_PROXY_PORT = "1450"; $env:LOG_DIR = "$env:TEMP\dc-cagen"
        New-Item -ItemType Directory -Force -Path $env:LOG_DIR | Out-Null
        foreach ($attempt in 1..2) {
            $gp = Start-Process "$appRoot\proxy\DeepChartsProxy\DeepChartsProxy.exe" -PassThru -WindowStyle Hidden
            for ($i = 0; $i -lt 90 -and -not (Test-Path "$caDir\ca.pem"); $i++) { Start-Sleep -Milliseconds 500 }
            if ($gp) { Stop-Process -Id $gp.Id -Force -ErrorAction SilentlyContinue }
            if (Test-Path "$caDir\ca.pem") { break }
            Write-Host "      certificate not ready yet - retrying..." -ForegroundColor DarkYellow
        }
        $env:CA_DIR = $null; $env:BRIDGE_PROXY_PORT = $null; $env:LOG_DIR = $null
    }
    if (-not (Test-Path "$caDir\ca.pem")) { throw "Certificate generation failed - the security proxy could not start (antivirus may have blocked it). Add a Defender exclusion for C:\Deepchart and retry." }

    Write-Host "[6/9] Trusting the certificate..." -ForegroundColor White
    & certutil -addstore -f Root "$caDir\ca.pem" | Out-Null
    & certutil -user -addstore -f Root "$caDir\ca.pem" | Out-Null
    $trusted = @(Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue | Where-Object { $_.Subject -match 'MITM CA' }).Count -gt 0
    if (-not $trusted) { throw "The certificate could not be added to the trusted store (a security policy may be blocking it)." }

    # ---- 7. hosts entries (idempotent) ----
    Write-Host "[7/9] Configuring the data feed..." -ForegroundColor White
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $domains = @("demoapi.cqg.com","api.cqg.com","depth-it.historical.deepcharts.com","data-b.historical.deepcharts.com")
    # resolve the REAL CQG IP now (via public DNS, before hosts redirects it) and bake it in
    try {
        $cqgip = (Resolve-DnsName -Name "demoapi.cqg.com" -Server 8.8.8.8 -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
        if ($cqgip) { [Environment]::SetEnvironmentVariable("CQG_UPSTREAM_IP", $cqgip, "Machine"); Write-Host "      CQG upstream resolved: $cqgip" }
    } catch { Write-Host "      (using the built-in CQG address)" -ForegroundColor DarkGray }
    $existing = @(Get-Content $hostsPath -Encoding ASCII -ErrorAction SilentlyContinue)
    $kept = @($existing | Where-Object {
        $l = $_
        if ($l -match '^\s*#\s*DeepCharts CQG proxy entries') { return $false }
        foreach ($d in $domains) { if ($l -match ("\s" + [regex]::Escape($d) + "(\s|$|#)")) { return $false } }
        return $true
    })
    ($kept + @("# DeepCharts CQG proxy entries") + ($domains | ForEach-Object { "127.0.0.1 $_" })) | Set-Content -Path $hostsPath -Encoding ASCII -Force
    & ipconfig /flushdns | Out-Null

    # ---- 8. machine settings: speed, loopback binding, firewall pre-approval ----
    Write-Host "[8/9] Applying settings..." -ForegroundColor White
    [Environment]::SetEnvironmentVariable("LOG_LEVEL","INFO","Machine")
    [Environment]::SetEnvironmentVariable("BRIDGE_PROXY_BIND_HOST","127.0.0.1","Machine")
    [Environment]::SetEnvironmentVariable("VOL_HIST_HOST","127.0.0.1","Machine")
    $env:LOG_LEVEL = "INFO"; $env:BRIDGE_PROXY_BIND_HOST = "127.0.0.1"; $env:VOL_HIST_HOST = "127.0.0.1"
    foreach ($fw in @("$appRoot\proxy\DeepChartsProxy\DeepChartsProxy.exe","$appRoot\proxy\DeepChartsHistServer\DeepChartsHistServer.exe")) {
        if (Test-Path $fw) { & netsh advfirewall firewall add rule name="DeepCharts" dir=in action=allow program="$fw" enable=yes profile=any | Out-Null }
    }
    New-Item -Path "HKCU:\Software\DeepCharts" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\Software\DeepCharts" -Name InstallPath -Value $appRoot

    # ---- 9. shortcuts (run-as-admin) ----
    Write-Host "[9/9] Creating shortcut..." -ForegroundColor White
    $wsh = New-Object -ComObject WScript.Shell
    foreach ($dir in (@([Environment]::GetFolderPath('Desktop'), "$env:PUBLIC\Desktop", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs") | Select-Object -Unique)) {
        try {
            $lnkPath = Join-Path $dir "DeepCharts.lnk"
            $lnk = $wsh.CreateShortcut($lnkPath)
            $lnk.TargetPath = "$appRoot\Deepchart.exe"
            $lnk.WorkingDirectory = $appRoot
            if (Test-Path "$appRoot\app\deepchart_icon_dark.ico") { $lnk.IconLocation = "$appRoot\app\deepchart_icon_dark.ico" }
            $lnk.Save()
            $lb = [IO.File]::ReadAllBytes($lnkPath); $lb[0x15] = $lb[0x15] -bor 0x20; [IO.File]::WriteAllBytes($lnkPath, $lb)
        } catch {}
    }

    $ok = $true
    Write-Host "`n==================================================" -ForegroundColor Green
    Write-Host "  Done! DeepCharts is installed. Launching now..." -ForegroundColor Green
    Write-Host "  From now on, open it with the DeepCharts icon on your Desktop." -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
    Start-Process "$appRoot\Deepchart.exe" -WorkingDirectory $appRoot
    Start-Sleep -Seconds 4
}
catch {
    Write-Host "`n==================================================" -ForegroundColor Red
    Write-Host "  INSTALL FAILED" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  A log was saved to: $appRoot\install-log.txt" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to close"
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
