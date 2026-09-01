# DeepCharts Connection Fix
# Run as Administrator — fixes the two flags that stop the feed connecting
# and restores settings if they got corrupted by another version of Deepchart.

param()

# Self-elevate if not already admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "Continue"
$log = "$PSScriptRoot\fix-connection.log"
"=== DeepCharts Connection Fix  $(Get-Date) ===" | Set-Content $log

# --- 1. Restore XML settings if corrupted (another Deepchart version may have overwritten them) ---
$settingsDir = "C:\Deepchart\data\Settings"
$defaultDir  = "C:\Deepchart\app\Default"
$symFile     = Join-Path $settingsDir "SymbolDatabaseList.xml"

if (Test-Path $symFile) {
    $head = Get-Content $symFile -TotalCount 1
    if ($head -notmatch '<\?xml') {
        Write-Host "Settings corrupted (JSON format detected) — restoring..." -ForegroundColor Yellow
        foreach ($f in "SymbolDatabaseList.xml","ExchangeList.xml","version.info") {
            $src = Join-Path $defaultDir $f
            $dst = Join-Path $settingsDir $f
            if (Test-Path $src) { Copy-Item $src $dst -Force; Write-Host "  Restored: $f" }
        }
        "Settings restored from Default" | Add-Content $log
    } else {
        Write-Host "Settings OK" -ForegroundColor Green
        "Settings OK" | Add-Content $log
    }
} else {
    Write-Host "Settings folder not found at $settingsDir — skipping" -ForegroundColor Yellow
    "Settings folder not found" | Add-Content $log
}

# --- 2. Fix connProp.settings flags ---
$cp = Join-Path $env:APPDATA "Deepchart\connProp.settings"
if (Test-Path $cp) {
    $x = Get-Content $cp -Raw
    $o = $x
    $x = [regex]::Replace($x, '(<Name>UseVolServer</Name>\s*<Value[^>]*>)true(</Value>)',  '${1}false${2}')
    $x = [regex]::Replace($x, '(<Name>AutoConnect</Name>\s*<Value[^>]*>)false(</Value>)', '${1}true${2}')
    if ($x -ne $o) {
        Set-Content $cp $x -Encoding UTF8 -Force
        Write-Host "Connection flags fixed (UseVolServer=false, AutoConnect=true)" -ForegroundColor Green
        "Flags fixed" | Add-Content $log
    } else {
        Write-Host "Connection flags already correct" -ForegroundColor Green
        "Flags already correct" | Add-Content $log
    }
} else {
    Write-Host "connProp.settings not found — open DeepCharts once first then re-run this script" -ForegroundColor Yellow
    "connProp.settings not found" | Add-Content $log
}

Write-Host ""
Write-Host "Done. Now launch DeepCharts normally." -ForegroundColor Cyan
"=== done ===" | Add-Content $log

Start-Sleep -Seconds 3
