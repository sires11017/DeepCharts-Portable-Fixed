@echo off
:: DeepCharts Connection Fix — double-click to run
:: Fixes the feed not connecting after another version of Deepchart runs

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Continue';" ^
  "$settingsDir='C:\Deepchart\data\Settings';" ^
  "$defaultDir='C:\Deepchart\app\Default';" ^
  "$symFile=Join-Path $settingsDir 'SymbolDatabaseList.xml';" ^
  "if(Test-Path $symFile){" ^
  "  $head=Get-Content $symFile -TotalCount 1;" ^
  "  if($head -notmatch '<\?xml'){" ^
  "    foreach($f in 'SymbolDatabaseList.xml','ExchangeList.xml','version.info'){" ^
  "      $s=Join-Path $defaultDir $f; $d=Join-Path $settingsDir $f;" ^
  "      if(Test-Path $s){Copy-Item $s $d -Force}" ^
  "    }" ^
  "    Write-Host 'Settings restored.' -ForegroundColor Green" ^
  "  } else { Write-Host 'Settings OK.' -ForegroundColor Green }" ^
  "};" ^
  "$cp=Join-Path $env:APPDATA 'Deepchart\connProp.settings';" ^
  "if(Test-Path $cp){" ^
  "  $x=Get-Content $cp -Raw;" ^
  "  $x=[regex]::Replace($x,'(<Name>UseVolServer</Name>\s*<Value[^>]*>)true(</Value>)','${1}false${2}');" ^
  "  $x=[regex]::Replace($x,'(<Name>AutoConnect</Name>\s*<Value[^>]*>)false(</Value>)','${1}true${2}');" ^
  "  Set-Content $cp $x -Encoding UTF8 -Force;" ^
  "  Write-Host 'Connection flags fixed.' -ForegroundColor Green" ^
  "} else { Write-Host 'connProp.settings not found - open DeepCharts once first then re-run.' -ForegroundColor Yellow };" ^
  "Write-Host '';" ^
  "Write-Host 'Done. Launch DeepCharts now.' -ForegroundColor Cyan;" ^
  "Start-Sleep 3"
