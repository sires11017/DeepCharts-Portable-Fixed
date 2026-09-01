@echo off
:: Run-Official-DeepCharts.bat
:: Clears the portable DeepCharts proxy so the OFFICIAL DeepCharts runs without interference.
:: Downloads the latest clear-proxy.ps1 from GitHub and runs it as Administrator.
:: Changes NO logins or credentials - it only stops the local proxy and undoes the hosts redirect.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

echo Fetching latest fix and clearing proxy interference...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $u='https://raw.githubusercontent.com/sires11017/DeepCharts-Portable-Fixed/main/clear-proxy.ps1'; iex (Invoke-RestMethod -Uri $u)"

echo.
pause
