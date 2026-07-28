<# DeepCharts Portable - uninstaller. Removes app, hosts entries, CA trust, shortcuts. #>
$ErrorActionPreference = "Continue"
$me = $MyInvocation.MyCommand.Path
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$me`""
    return
}
Write-Host "Uninstalling DeepCharts..." -ForegroundColor Yellow

foreach ($n in @("Deepchart.Core","Deepchart","DeepChartsProxy","DeepChartsHistServer","BridgeWrapper","VolumetricaBridge")) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

# remove hosts entries
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$domains = @("demoapi.cqg.com","api.cqg.com","depth-it.historical.deepcharts.com","data-b.historical.deepcharts.com")
$existing = @(Get-Content $hostsPath -Encoding ASCII -ErrorAction SilentlyContinue)
$kept = @($existing | Where-Object {
    $l = $_
    if ($l -match '^\s*#\s*DeepCharts CQG proxy entries') { return $false }
    foreach ($d in $domains) { if ($l -match ("\s" + [regex]::Escape($d) + "(\s|$|#)")) { return $false } }
    return $true
})
$kept | Set-Content -Path $hostsPath -Encoding ASCII -Force
& ipconfig /flushdns | Out-Null

# untrust + remove CA
Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -match 'Bridge MITM CA|DeepCharts MITM CA' } |
    ForEach-Object { Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue }

# remove files + settings + shortcuts
[Environment]::SetEnvironmentVariable("LOG_LEVEL",$null,"Machine")
Remove-Item "C:\Deepchart" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:PROGRAMDATA\DeepCharts" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "HKCU:\Software\DeepCharts" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ([Environment]::GetFolderPath('Desktop') + "\DeepCharts.lnk") -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\DeepCharts.lnk" -Force -ErrorAction SilentlyContinue

Write-Host "DeepCharts uninstalled. (Your data in C:\Deepchart\data was removed too.)" -ForegroundColor Green
Start-Sleep -Seconds 3
