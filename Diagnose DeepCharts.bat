@echo off
title DeepCharts Diagnose
echo Running DeepCharts diagnostics (a security prompt will appear - click Yes)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1"
