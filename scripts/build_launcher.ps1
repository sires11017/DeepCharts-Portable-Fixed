param(
    [string]$OutputDir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptRoot
$src = Join-Path (Join-Path $root "launcher") "Launcher.cs"
$out = Join-Path $OutputDir "Deepchart.exe"

if (-not (Test-Path $src)) {
    Write-Host "[!] Source not found: $src"
    exit 1
}

$fwDir = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\"
if (-not (Test-Path $fwDir)) {
    $fwDir = "$env:windir\Microsoft.NET\Framework\v4.0.30319\"
}

$csc = Join-Path $fwDir "csc.exe"
if (-not (Test-Path $csc)) {
    Write-Host "[!] C# compiler (csc.exe) not found at: $csc"
    exit 1
}

$refs = @(
    "System.Windows.Forms.dll",
    "System.Drawing.dll",
    "System.Security.dll",
    "System.dll",
    "System.Core.dll"
)

$args = @(
    "/target:winexe",
    "/platform:anycpu",
    "/out:$out",
    "/nologo"
)
foreach ($r in $refs) { $args += "/reference:$r" }
$args += $src

Write-Host "[*] Compiling launcher..."
Write-Host "    Compiler: $csc"
Write-Host "    Source:   $src"
Write-Host "    Output:   $out"

& $csc $args

if ($LASTEXITCODE -eq 0 -and (Test-Path $out)) {
    Write-Host "[+] Launcher built: $out ($((Get-Item $out).Length) bytes)"
} else {
    Write-Host "[!] Compilation failed (exit code: $LASTEXITCODE)"
    exit 1
}

# Generate mscorlib.XmlSerializers.dll for VolumetricaBridge
$bridgeDir = Join-Path $root "app\bridge"
$serializerDll = Join-Path $bridgeDir "mscorlib.XmlSerializers.dll"
$serializerIl = Join-Path $scriptRoot "serializer.il"

if (-not (Test-Path $serializerDll) -and (Test-Path $serializerIl)) {
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
                    Write-Host "[+] mscorlib.XmlSerializers.dll generated ($dllSize bytes)"
                }
            }
        } catch { }
    }
}
