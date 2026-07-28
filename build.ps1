<#
.SYNOPSIS
    Root build script for DeepCharts Portable
.DESCRIPTION
    Orchestrates the full build: launcher compilation, payload staging,
    installer packaging, and optional code signing via Azure Trusted Signing.
#>

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  DeepCharts Portable - Build" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Delegate to the installer build script
$installerBuild = Join-Path (Join-Path $repoRoot "installer") "build.ps1"
if (-not (Test-Path $installerBuild)) {
    throw "Installer build script not found at $installerBuild"
}

& $installerBuild @PSBoundParameters
