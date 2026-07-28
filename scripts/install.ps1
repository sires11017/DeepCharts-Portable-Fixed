<#
.SYNOPSIS
    One-time admin setup for DeepCharts Portable.
    Must be run as Administrator.
.DESCRIPTION
    - Verifies prerequisites (Python, .NET 4.8)
    - Generates CA certificates
    - Configures hosts file entries (127.0.0.1)
    - Installs Python dependencies
    - Compiles the Deepchart.exe launcher from C# source
    - Copies templates and settings to user Documents
    - Installs auto-start on boot via Windows Startup folder
    - Adds Windows Defender exclusions
.NOTES
    Run: Right-click -> Run with PowerShell (Admin)
    Run once after git pull or on a fresh machine.
    After install, DeepCharts auto-starts on every login.
#>

#Requires -RunAsAdministrator

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptRoot
$ErrorActionPreference = "Continue"

Write-Host "============================================"
Write-Host "  DeepCharts Portable Installer"
Write-Host "============================================"
Write-Host ""

Write-Host "[*] Repo root: $root"

# -- 0. Kill existing processes and check port conflicts --
Write-Host "[0/8] Stopping existing processes and checking port conflicts..."
Get-Process Deepchart* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process Volumetrica* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process BridgeWrapper -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# Only kill Python processes that are our proxies
Get-Process python -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        if ($cmdLine -match "bridge_mitm_proxy|vol_hist_server") {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
Start-Sleep -Seconds 3

# Check for port 443 conflicts
$port443 = Get-NetTCPConnection -LocalPort 443 -ErrorAction SilentlyContinue
if ($port443) {
    $pid443 = ($port443 | Select-Object -First 1).OwningProcess
    $procName = (Get-Process -Id $pid443 -ErrorAction SilentlyContinue).ProcessName
    Write-Host "[!] WARNING: Port 443 is already in use by: $procName (PID $pid443)"
    Write-Host "    DeepCharts needs port 443 for the MITM proxy."
    Write-Host ""
    Write-Host "    Common fixes:"
    Write-Host "    - If WinRM: net stop winrm"
    Write-Host "    - If IIS: net stop W3SVC"
    Write-Host "    - If iphlpsvc: netsh interface portproxy show all"
    Write-Host "    - If Docker: stop Docker Desktop"
    Write-Host "    - If WSL2 mirrored mode: set networkingMode=NAT in %USERPROFILE%\\.wslconfig"
    Write-Host ""

    $procPath = (Get-Process -Id $pid443 -ErrorAction SilentlyContinue).Path
    Write-Host "    Process path: $procPath"
    Write-Host ""
    $continue = Read-Host "    Continue anyway? (y/N)"
    if ($continue -ne "y") {
        Write-Host "    Aborting. Fix the port conflict and try again."
        exit 1
    }
}

# Check port 12010
$port12010 = Get-NetTCPConnection -LocalPort 12010 -ErrorAction SilentlyContinue
if ($port12010) {
    $pid12010 = ($port12010 | Select-Object -First 1).OwningProcess
    $procName = (Get-Process -Id $pid12010 -ErrorAction SilentlyContinue).ProcessName
    Write-Host "[!] WARNING: Port 12010 is already in use by: $procName (PID $pid12010)"
    Write-Host "    DeepCharts needs port 12010 for the historical mock server."
    Write-Host ""
}

Write-Host "[+] Cleaned up"

# -- 1. Prerequisites (auto-install if missing) --
Write-Host "[1/8] Checking prerequisites..."

# -- Check & auto-install Git --
$gitExe = $null
try {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) { $gitExe = $gitCmd.Source }
} catch {}
if (-not $gitExe -or -not (Test-Path $gitExe)) {
    # Check common install path
    $gitPaths = @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "$env:ProgramFiles(x86)\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    )
    foreach ($p in $gitPaths) {
        if (Test-Path $p) { $gitExe = $p; break }
    }
}

if (-not $gitExe -or -not (Test-Path $gitExe)) {
    Write-Host "[!] Git not found. Downloading and installing Git..."
    $gitUrl = "https://github.com/git-scm/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe"
    $gitInstaller = "$env:TEMP\GitInstaller.exe"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $gitUrl -OutFile $gitInstaller -UseBasicParsing
        Write-Host "    Installing Git (silent)..."
        $gitProcess = Start-Process -FilePath $gitInstaller -ArgumentList "/VERYSILENT", "/NORESTART", "/NOCANCEL", "/SP-", "/CLOSEAPPLICATIONS", "/RESTARTAPPLICATIONS", "/COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh" -Wait -PassThru
        if ($gitProcess.ExitCode -ne 0) {
            Write-Host "[!] Git installer returned exit code $($gitProcess.ExitCode)" -ForegroundColor Yellow
        }
        # Refresh PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        Remove-Item $gitInstaller -Force -ErrorAction SilentlyContinue
        try {
            $gitCmd = Get-Command git -ErrorAction SilentlyContinue
            if ($gitCmd) { $gitExe = $gitCmd.Source }
        } catch {}
        if (-not $gitExe -or -not (Test-Path $gitExe)) {
            # Re-check common paths after install
            foreach ($p in $gitPaths) {
                if (Test-Path $p) { $gitExe = $p; break }
            }
        }
    } catch {
        Write-Host "[!] Git download failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if (-not $gitExe -or -not (Test-Path $gitExe)) {
    Write-Host "[!] Git is required. Install from https://git-scm.com/download/win" -ForegroundColor Red
    exit 1
}
$gitVersion = & $gitExe --version 2>&1
Write-Host "[+] Git: $gitVersion"

# -- Check & auto-install Python --
. "$PSScriptRoot\find-python.ps1"
$pythonExe = $script:PythonExe
$pythonFull = $null

if (-not $pythonExe -or $pythonExe -eq "python") {
    # find-python.ps1 couldn't find a real Python, try harder
    $pythonExe = $null
    foreach ($exe in @("python", "python3")) {
        try {
            $info = Get-Command $exe -ErrorAction SilentlyContinue
            if ($info -and $info.Source -and $info.Source -notmatch "WindowsApps") {
                $v = & $exe --version 2>&1
                if ($v -match "Python 3\.\d+") {
                    $pythonExe = $exe
                    $pythonFull = $info.Source
                    Write-Host "[+] Python: $v ($pythonExe)"
                    break
                }
            }
        } catch {}
    }
    if (-not $pythonExe) {
        try {
            $v = & py -3 --version 2>&1
            if ($v -match "Python 3\.\d+") {
                $pythonExe = "py -3"
                try { $pythonFull = & py -3 -c "import sys; print(sys.executable)" 2>&1 } catch {}
                Write-Host "[+] Python: $v (py -3)"
            }
        } catch {}
    }
} else {
    try {
        $v = & $pythonExe --version 2>&1
        if ($v -match "Python 3\.\d+") { Write-Host "[+] Python: $v ($pythonExe)" }
    } catch {}
}

if (-not $pythonExe) {
    Write-Host "[!] Python 3 not found. Downloading and installing Python 3.12..."
    $pyUrl = "https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe"
    $pyInstaller = "$env:TEMP\PythonInstaller.exe"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $pyUrl -OutFile $pyInstaller -UseBasicParsing
        Write-Host "    Installing Python (silent, Add to PATH)..."
        $pyProcess = Start-Process -FilePath $pyInstaller -ArgumentList "/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_pip=1", "Include_launcher=1" -Wait -PassThru
        if ($pyProcess.ExitCode -ne 0 -and $pyProcess.ExitCode -ne 3010) {
            Write-Host "[!] Python installer returned exit code $($pyProcess.ExitCode)" -ForegroundColor Yellow
        }
        # Refresh PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        Remove-Item $pyInstaller -Force -ErrorAction SilentlyContinue
        # Re-detect
        . "$PSScriptRoot\find-python.ps1"
        $pythonExe = $script:PythonExe
        if ($pythonExe -and $pythonExe -ne "python") {
            try {
                $v = & $pythonExe --version 2>&1
                if ($v -match "Python 3\.\d+") { $pythonFull = $pythonExe; Write-Host "[+] Python installed: $v" }
            } catch {}
        }
    } catch {
        Write-Host "[!] Python download failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if (-not $pythonExe) {
    Write-Host "[!] Python 3 is required." -ForegroundColor Red
    Write-Host "    Install from https://www.python.org/downloads/" -ForegroundColor Red
    Write-Host "    IMPORTANT: Check 'Add Python to PATH' during install" -ForegroundColor Red
    exit 1
}

# Save full path
if (-not $pythonFull) {
    try {
        $cmdInfo = Get-Command $pythonExe -ErrorAction SilentlyContinue
        if ($cmdInfo -and $cmdInfo.Source) { $pythonFull = $cmdInfo.Source }
    } catch {}
    if (-not $pythonFull) { $pythonFull = $pythonExe }
}
$pythonConfig = Join-Path $root ".python_path"
Set-Content -Path $pythonConfig -Value $pythonFull -NoNewline
Write-Host "[+] Python path saved: $pythonFull"

# -- .NET Framework 4.8 --
$dotnet = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\" -Name Release -ErrorAction SilentlyContinue
if (-not $dotnet -or $dotnet.Release -lt 528040) {
    Write-Host "[!] .NET Framework 4.8+ required."
    exit 1
}
Write-Host "[+] .NET Framework 4.8+"

# -- 2. Generate CA certificates --
Write-Host "[2/8] Generating CA certificates..."
try {
    Push-Location (Join-Path $root "proxy\mitm")
    try {
        & $pythonFull -c "import config; from bridge_mitm_proxy import ensure_ca; ensure_ca()"
        Write-Host "[+] CA certificates ready"
    } finally {
        Pop-Location
    }
} catch {
    Write-Host "  (will generate at first proxy launch)"
}

# -- 3. Configure hosts file --
Write-Host "[3/8] Configuring hosts file..."
$hostsIp = "127.0.0.1"
$hostnames = @(
    "demoapi.cqg.com",
    "api.cqg.com",
    "depth-it.historical.deepcharts.com",
    "data-b.historical.deepcharts.com"
)
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"

try {
    $hostsContent = Get-Content $hostsPath -Encoding ASCII -ErrorAction Stop
} catch {
    Write-Host "[!] Cannot read hosts file: $($_.Exception.Message)"
    Write-Host "    Add these entries manually to $hostsPath :"
    $hostnames | ForEach-Object { Write-Host "    $hostsIp $_" }
    $hostsContent = @()
}

if (-not $hostsContent) { $hostsContent = @() }
$changed = $false

foreach ($hostname in $hostnames) {
    $existingLine = $hostsContent | Where-Object { $_ -match "\s+$hostname\s*$" -or $_ -match "\s+$hostname$" }
    if ($existingLine) {
        $oldIp = ($existingLine -split "\s+")[0]
        if ($oldIp -ne $hostsIp) {
            $hostsContent = @($hostsContent | Where-Object { $_ -notmatch "\s+$hostname\s*$" -and $_ -notmatch "\s+$hostname$" })
            $hostsContent += "$hostsIp $hostname"
            Write-Host "  [FIX] $hostname $oldIp -> $hostsIp"
            $changed = $true
        } else {
            Write-Host "  [OK] $hostname already correct ($hostsIp)"
        }
    } else {
        $hostsContent += "$hostsIp $hostname"
        Write-Host "  [ADD] $hostsIp $hostname"
        $changed = $true
    }
}
if ($changed) {
    try {
        $hostsContent | Out-File $hostsPath -Encoding ascii -Force -ErrorAction Stop
        ipconfig /flushdns | Out-Null
        Write-Host "  DNS cache flushed"
    } catch {
        Write-Host "  [!] Failed to write hosts file: $($_.Exception.Message)"
        Write-Host "      Add entries manually to $hostsPath"
    }
}

# -- 4. Install Python dependencies --
Write-Host "[4/8] Installing Python dependencies..."
$req = Join-Path (Join-Path $root "proxy") "mitm\requirements.txt"
if (Test-Path $req) {
    try { & $pythonFull -m pip install -r $req -q 2>$null } catch { Write-Host "  (pip warning - dependencies may already be installed)" }
    Write-Host "[+] Dependencies installed"
}

# -- 5. Build the launcher and wrapper --
Write-Host "[5/8] Building launcher and wrapper..."
$buildScript = Join-Path $scriptRoot "build_launcher.ps1"
if (Test-Path $buildScript) {
    & $buildScript -OutputDir $root
}

$cscPaths = @(
    "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $null
foreach ($p in $cscPaths) { if (Test-Path $p) { $csc = $p; break } }

if ($csc) {
    $wrapperSrc = Join-Path $root "launcher\BridgeWrapper.cs"
    $wrapperOut = Join-Path $root "app\BridgeWrapper.exe"
    if (Test-Path $wrapperSrc) {
        & $csc /out:$wrapperOut /target:exe /nologo /optimize /platform:x64 $wrapperSrc 2>&1 | Out-Null
        if (Test-Path $wrapperOut) { Write-Host "[+] BridgeWrapper.exe built" }
        else { Write-Host "  (BridgeWrapper build failed)" }
    }

    # Fix bridge XML serialization (required for IPC to Deepchart.Core)
    $bridgeConfig = Join-Path $root "app\bridge\VolumetricaBridge.exe.config"
    $serializerDll = Join-Path $root "app\bridge\mscorlib.XmlSerializers.dll"

    # Remove any broken/old XmlSerializers stub
    if (Test-Path $serializerDll) {
        $dllSize = (Get-Item $serializerDll).Length
        if ($dllSize -lt 10000) {
            Remove-Item $serializerDll -Force
            Write-Host "  Removed broken XmlSerializers stub ($dllSize bytes)"
        }
    }

    # Add xmlSerializerUseReflection to bridge config (bypasses need for pre-generated DLL)
    if (Test-Path $bridgeConfig) {
        $cfg = Get-Content $bridgeConfig -Raw
        if ($cfg -notmatch "xmlSerializerUseReflection") {
            $cfg = $cfg.Replace("</configuration>", @"
    <system.xml.serialization>
      <xmlSerializerUseReflection enabled="true"/>
    </system.xml.serialization>
</configuration>
"@)
            Set-Content -Path $bridgeConfig -Value $cfg -Force
            Write-Host "[+] Bridge config updated: xmlSerializerUseReflection=true"
        } else {
            Write-Host "[+] Bridge config already has xmlSerializerUseReflection"
        }
    }

    # Generate mscorlib.XmlSerializers.dll (required by VolumetricaBridge for XML serialization)
    # Without this DLL, the bridge shows "system cannot find the file specified" error
    $bridgeExe = Join-Path $root "app\bridge\VolumetricaBridge.exe"
    $serializerIl = Join-Path $scriptRoot "serializer.il"

    # Method 1: Try sgen.exe (generates from actual assembly metadata - best quality)
    $sgenPaths = @(
        "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\sgen.exe",
        "C:\Windows\Microsoft.NET\Framework\v4.0.30319\sgen.exe"
    )
    $sgen = $null
    foreach ($p in $sgenPaths) { if (Test-Path $p) { $sgen = $p; break } }

    $serializerGenerated = $false
    if ($sgen -and (Test-Path $bridgeExe)) {
        try {
            & $sgen /a:$bridgeExe /f 2>&1 | Out-Null
            if (Test-Path $serializerDll) {
                $dllSize = (Get-Item $serializerDll).Length
                if ($dllSize -gt 1000) {
                    Write-Host "[+] mscorlib.XmlSerializers.dll generated via sgen ($dllSize bytes)"
                    $serializerGenerated = $true
                }
            }
        } catch { }
    }

    # Method 2: If sgen failed or unavailable, use ilasm with stub IL
    if (-not $serializerGenerated -and (Test-Path $serializerIl)) {
        $ilasmPaths = @(
            "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\ilasm.exe",
            "C:\Windows\Microsoft.NET\Framework\v4.0.30319\ilasm.exe"
        )
        $ilasm = $null
        foreach ($p in $ilasmPaths) { if (Test-Path $p) { $ilasm = $p; break } }

        if ($ilasm) {
            try {
                & $ilasm /dll /output:$serializerDll $serializerIl 2>&1 | Out-Null
                if (Test-Path $serializerDll) {
                    $dllSize = (Get-Item $serializerDll).Length
                    if ($dllSize -gt 1000) {
                        Write-Host "[+] mscorlib.XmlSerializers.dll generated via ilasm ($dllSize bytes)"
                        $serializerGenerated = $true
                    }
                }
            } catch { }
        }
    }

    if (-not $serializerGenerated) {
        Write-Host "  [!] Could not generate mscorlib.XmlSerializers.dll"
        Write-Host "      Bridge will still work (BridgeWrapper suppresses the error dialog)"
    }

} else {
    Write-Host "  [!] C# compiler (csc.exe) not found"
}

# -- 6. Copy templates --
Write-Host "[6/8] Copying templates and settings..."
$tempsDir = Join-Path $root "userdata"
$targetDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Deepchart"
if (Test-Path $tempsDir) {
    Get-ChildItem $tempsDir -Directory | ForEach-Object {
        $dst = Join-Path $targetDir $_.Name
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Get-ChildItem $_.FullName -File | ForEach-Object {
            $tf = Join-Path $dst $_.Name
            if (-not (Test-Path $tf)) { Copy-Item $_.FullName $tf; Write-Host "  [COPY] $($_.Name)" }
        }
    }
    Get-ChildItem $tempsDir -File | ForEach-Object {
        $tf = Join-Path $targetDir $_.Name
        if (-not (Test-Path $tf)) { Copy-Item $_.FullName $tf; Write-Host "  [COPY] $($_.Name)" }
    }
    Write-Host "[+] Templates copied to $targetDir"
} else {
    Write-Host "  (userdata/ not found - run template backup first)"
}

# -- 7. Create auto-start on boot --
Write-Host "[7/8] Setting up auto-start on boot..."

# Save install path to registry so startup.bat can find the repo at runtime
$regPath = "HKCU:\Software\DeepCharts"
try {
    New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -Path $regPath -Name "InstallPath" -Value $root -Force -ErrorAction Stop
    Write-Host "[+] Install path saved to registry: $root"
} catch {
    Write-Host "  [!] Failed to write registry: $($_.Exception.Message)"
}

$startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$startupTarget = Join-Path $startupFolder "DeepCharts-startup.bat"
$startupSrc = Join-Path $scriptRoot "startup.bat"
if (Test-Path $startupSrc) {
    Copy-Item -Path $startupSrc -Destination $startupTarget -Force
    Write-Host "[+] Startup script installed to $startupTarget"
    Write-Host "    DeepCharts will auto-start on every login (no admin needed)"
} else {
    Write-Host "  [!] startup.bat not found in scripts/"
}

# -- 8. Add Windows Defender exclusions --
Write-Host "[8/8] Adding Windows Defender exclusions..."
$paths = @($root, (Join-Path $root "app"))
foreach ($p in $paths) {
    if (Test-Path $p) {
        try { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue; Write-Host "  [EXCL] $p" }
        catch { Write-Host "  (skipped exclusion for $p)" }
    }
}

Write-Host ""
Write-Host "============================================"
Write-Host "  INSTALLATION COMPLETE!"
Write-Host "============================================"

# Create desktop shortcut
$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop "DeepCharts.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $root "Deepchart.exe"
$shortcut.WorkingDirectory = $root
$shortcut.Description = "DeepCharts Portable - One-Click Launch"
$shortcut.Save()
Write-Host "[+] Desktop shortcut created: $shortcutPath"

# Quick proxy test
Write-Host ""
Write-Host "[*] Verifying proxy can start..."
$testResult = & $pythonFull -c "import sys; print('OK')" 2>&1
if ($testResult -eq "OK") {
    Write-Host "[+] Python can execute scripts"
    try {
        Push-Location (Join-Path $root "proxy\mitm")
        $importTest = & $pythonFull -c "import config; print('config OK')" 2>&1
        Pop-Location
        if ($importTest -eq "config OK") {
            Write-Host "[+] Proxy config loads correctly"
        } else {
            Write-Host "[!] Proxy config import failed: $importTest"
        }
    } catch {
        Write-Host "[!] Proxy config test failed"
    }
} else {
    Write-Host "[!] Python test failed: $testResult"
}
Write-Host ""

# Open the folder so user can pin to taskbar
Write-Host "[+] Opening folder: $root"
Invoke-Item $root

Write-Host ""
Write-Host "  NEXT STEPS:"
Write-Host "  ----------"
Write-Host "  1. The repo folder is now open in Explorer"
Write-Host "  2. Right-click Deepchart.exe -> Pin to taskbar"
Write-Host "  3. From now on, just click the taskbar icon OR"
Write-Host "     double-click the DeepCharts desktop shortcut"
Write-Host ""
Write-Host "  One click. Everything starts automatically. No console windows."
Write-Host "============================================"
