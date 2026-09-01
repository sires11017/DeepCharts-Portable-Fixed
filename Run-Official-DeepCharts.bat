@echo off
:: Run-Official-DeepCharts.bat
:: Clears the portable DeepCharts proxy so the OFFICIAL DeepCharts can run without interference.
:: Stops the local proxy/historical processes and removes the hosts-file redirect so
:: traffic goes straight to the real servers again. Does NOT change any logins.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

echo Clearing portable DeepCharts proxy interference...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Continue';" ^
  ":: stop the portable proxy stack (unique names, won't touch the official app);" ^
  "Get-Process -Name 'DeepChartsProxy','DeepChartsHistServer' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue;" ^
  "Start-Sleep -Seconds 1;" ^
  "$free443 = -not (Get-NetTCPConnection -LocalPort 443 -EA SilentlyContinue);" ^
  "$free12010 = -not (Get-NetTCPConnection -LocalPort 12010 -EA SilentlyContinue);" ^
  "if($free443){Write-Host 'Port 443 free' -ForegroundColor Green}else{Write-Host 'Port 443 still in use (close old DeepCharts launcher first)' -ForegroundColor Yellow};" ^
  "if($free12010){Write-Host 'Port 12010 free' -ForegroundColor Green}else{Write-Host 'Port 12010 still in use' -ForegroundColor Yellow};" ^
  "$h=\"$env:SystemRoot\System32\drivers\etc\hosts\";" ^
  "$lines=Get-Content $h;" ^
  "$out=$lines | ForEach-Object {" ^
  "  if(($_ -match 'cqg\.com' -or $_ -match 'deepcharts\.com') -and $_ -notmatch '^\s*#'){ '# DC-OFF ' + $_ }" ^
  "  else { $_ }" ^
  "};" ^
  "Set-Content $h $out -Encoding ASCII -Force;" ^
  "ipconfig /flushdns | Out-Null;" ^
  "Write-Host 'Hosts redirect disabled, DNS flushed' -ForegroundColor Green;" ^
  "Write-Host '';" ^
  "Write-Host 'Done. Open the official DeepCharts now.' -ForegroundColor Cyan;" ^
  "Start-Sleep 4"
