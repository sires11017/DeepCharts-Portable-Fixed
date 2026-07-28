@echo off
title DeepCharts Portable - Installer
echo Starting the DeepCharts installer...
echo A Windows security prompt will appear - click YES.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
echo.
echo If a window closed too fast or you saw an error, right-click this file
echo and choose "Run as administrator".
pause
