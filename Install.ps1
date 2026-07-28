<#
  DeepCharts Portable (Fixed) - one-click installer.
  Run "Install DeepCharts.bat" (double-click, then approve the admin prompt).
  Does everything automatically: installs the app, generates + trusts a per-machine
  certificate, sets the hosts entries, loads your templates, makes a Desktop shortcut,
  and launches. One admin prompt, fully automatic.
#>
$ErrorActionPreference = "Stop"

# ---- self-elevate (one UAC prompt) ----
$me = $MyInvocation.MyCommand.Path
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host "Requesting administrator rights (click Yes)..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$me`""
    return
}

$src     = Split-Path -Parent $me
$appRoot = "C:\Deepchart"
$dataDir = "C:\Deepchart\data"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Installing DeepCharts Portable (Fixed)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ---- 1. stop any running instance ----
foreach ($n in @("Deepchart.Core","Deepchart","DeepChartsProxy","DeepChartsHistServer","BridgeWrapper","VolumetricaBridge")) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

# ---- 2. copy app (launcher + app + rebuilt proxy) ----
Write-Host "[1/7] Copying application files..." -ForegroundColor White
New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
Copy-Item "$src\payload\Deepchart.exe" "$appRoot\Deepchart.exe" -Force
robocopy "$src\payload\app"   "$appRoot\app"   /E   /NFL /NDL /NJH /NJS /NP | Out-Null
robocopy "$src\payload\proxy" "$appRoot\proxy" /MIR /NFL /NDL /NJH /NJS /NP | Out-Null

# ---- 3. deploy templates to C:\Deepchart\data ----
Write-Host "[2/7] Loading templates + workspaces..." -ForegroundColor White
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
foreach ($sub in @("Workspace","Template","Indicator Template")) {
    robocopy "$src\userdata\$sub" "$dataDir\$sub" /E /NFL /NDL /NJH /NJS /NP | Out-Null
}
# default Settings only on a fresh machine (never clobber an existing config)
if (-not (Test-Path "$dataDir\Settings") -and (Test-Path "$src\userdata\Settings")) {
    robocopy "$src\userdata\Settings" "$dataDir\Settings" /E /NFL /NDL /NJH /NJS /NP | Out-Null
}

# ---- 4. per-machine CA: generate (via the proxy) then trust it ----
Write-Host "[3/7] Generating this PC's private certificate..." -ForegroundColor White
$caDir = "$env:PROGRAMDATA\DeepCharts\certs\mitm_ca"
New-Item -ItemType Directory -Force -Path $caDir | Out-Null
if (-not (Test-Path "$caDir\ca.pem")) {
    $env:CA_DIR = $caDir; $env:BRIDGE_PROXY_PORT = "1450"; $env:LOG_DIR = "$env:TEMP\dc-cagen"
    New-Item -ItemType Directory -Force -Path $env:LOG_DIR | Out-Null
    $gp = Start-Process "$appRoot\proxy\DeepChartsProxy\DeepChartsProxy.exe" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 7
    if ($gp) { Stop-Process -Id $gp.Id -Force -ErrorAction SilentlyContinue }
    $env:CA_DIR = $null; $env:BRIDGE_PROXY_PORT = $null; $env:LOG_DIR = $null
}
Write-Host "[4/7] Trusting the certificate..." -ForegroundColor White
if (Test-Path "$caDir\ca.pem") {
    & certutil -addstore -f Root "$caDir\ca.pem" | Out-Null
    & certutil -user -addstore -f Root "$caDir\ca.pem" | Out-Null
} else {
    Write-Warning "Certificate generation failed - the data feed may not connect."
}

# ---- 5. hosts entries (idempotent, preserves everything else) ----
Write-Host "[5/7] Configuring hosts file..." -ForegroundColor White
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$domains = @("demoapi.cqg.com","api.cqg.com","depth-it.historical.deepcharts.com","data-b.historical.deepcharts.com")
$existing = @(Get-Content $hostsPath -Encoding ASCII -ErrorAction SilentlyContinue)
$kept = @($existing | Where-Object {
    $l = $_
    if ($l -match '^\s*#\s*DeepCharts CQG proxy entries') { return $false }
    foreach ($d in $domains) { if ($l -match ("\s" + [regex]::Escape($d) + "(\s|$|#)")) { return $false } }
    return $true
})
($kept + @("# DeepCharts CQG proxy entries") + ($domains | ForEach-Object { "127.0.0.1 $_" })) | Set-Content -Path $hostsPath -Encoding ASCII -Force
& ipconfig /flushdns | Out-Null

# ---- 6. speed setting + install record ----
Write-Host "[6/7] Applying settings..." -ForegroundColor White
[Environment]::SetEnvironmentVariable("LOG_LEVEL","INFO","Machine")
$env:LOG_LEVEL = "INFO"
New-Item -Path "HKCU:\Software\DeepCharts" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\DeepCharts" -Name InstallPath -Value $appRoot

# ---- 7. shortcuts + launch ----
Write-Host "[7/7] Creating shortcut and launching..." -ForegroundColor White
$wsh = New-Object -ComObject WScript.Shell
$shortcutDirs = @([Environment]::GetFolderPath('Desktop'), "$env:PUBLIC\Desktop", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs")
foreach ($dir in ($shortcutDirs | Select-Object -Unique)) {
    try {
        $lnkPath = Join-Path $dir "DeepCharts.lnk"
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath = "$appRoot\Deepchart.exe"
        $lnk.WorkingDirectory = $appRoot
        if (Test-Path "$appRoot\app\deepchart_icon_dark.ico") { $lnk.IconLocation = "$appRoot\app\deepchart_icon_dark.ico" }
        $lnk.Save()
        # mark the shortcut "Run as administrator" (the launcher needs elevation to manage the proxies)
        $lb = [IO.File]::ReadAllBytes($lnkPath)
        $lb[0x15] = $lb[0x15] -bor 0x20
        [IO.File]::WriteAllBytes($lnkPath, $lb)
    } catch {}
}
Start-Process "$appRoot\Deepchart.exe" -WorkingDirectory $appRoot

Write-Host "`n==================================================" -ForegroundColor Green
Write-Host "  Done! DeepCharts is installed and launching." -ForegroundColor Green
Write-Host "  From now on, open it with the DeepCharts icon" -ForegroundColor Green
Write-Host "  on your Desktop." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Start-Sleep -Seconds 4