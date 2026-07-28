# Code Signing Setup — Azure Trusted Signing

## Prerequisites

- Azure subscription (free tier works)
- Azure CLI installed (`winget install Microsoft.AzureCLI` or [aka.ms/installazurecli](https://aka.ms/installazurecli))
- Windows SDK 10+ (provides `signtool.exe`)
- Owner or Contributor role on the subscription

## 1. Create an Azure Trusted Signing Account

```powershell
# Login
az login

# Register the resource provider
az provider register --namespace Microsoft.CodeSigning

# Create resource group (change location if desired)
az group create --name DeepCharts-Signing --location westus

# Create the Trusted Signing account
az codesigning create `
  --resource-group DeepCharts-Signing `
  --account-name DeepCharts `
  --location westus `
  --sku Premium
```

> SKU `Premium` is required for individual code signing. `Basic` only supports CI/CD scenarios.

## 2. Create a Certificate Profile

```powershell
az codesigning certificate-profile create `
  --resource-group DeepCharts-Signing `
  --account-name DeepCharts `
  --profile-name DeepChartsCodeSigning `
  --profile-type PublicTrust `
  --identity-validation-type Individual
```

- `PublicTrust` = visible to Windows SmartScreen (no EV).
- `Individual` = for a person. Use `Organization` for a company (requires DUNS).

The Azure portal will guide you through identity validation (email + phone). Approvals typically take 1–2 business days.

## 3. Install SignTool (if not already present)

SignTool ships with the Windows SDK:

```powershell
# Option A: via winget
winget install "Windows SDK" -e

# Option B: Download manually from https://developer.microsoft.com/windows/downloads/windows-sdk/
```

Verify it works:

```powershell
signtool sign /?
```

If `signtool` is not on your PATH, locate it under:

```
C:\Program Files (x86)\Windows Kits\10\bin\<version>\x64\signtool.exe
```

## 4. Set Environment Variables

The build script reads signing configuration from these env vars:

```powershell
# PowerShell profile or CI pipeline
$env:AZURE_TRUSTED_SIGNING_ACCOUNT  = "DeepCharts"
$env:AZURE_TRUSTED_SIGNING_PROFILE  = "DeepChartsCodeSigning"
$env:AZURE_TRUSTED_SIGNING_ENDPOINT = "https://wus.codesigning.azure.net"
```

For persistent setup, add them to your PowerShell profile:

```powershell
# $PROFILE
$envVars = @{
  AZURE_TRUSTED_SIGNING_ACCOUNT  = "DeepCharts"
  AZURE_TRUSTED_SIGNING_PROFILE  = "DeepChartsCodeSigning"
  AZURE_TRUSTED_SIGNING_ENDPOINT = "https://wus.codesigning.azure.net"
}
foreach ($k in $envVars.Keys) {
  [Environment]::SetEnvironmentVariable($k, $envVars[$k], "User")
}
```

## 5. Authenticate for Signing

```powershell
az login
# Then set the subscription
az account set --subscription "<subscription-id-or-name>"
```

The Azure Trusted Signing SDK (used by `signtool`) authenticates via your Azure CLI session — no service principal required for dev machines.

## Dev Fallback — Self-Signed Certificate

When Azure Trusted Signing is unavailable (offline, no identity approval yet, CI without Azure), use a self-signed cert:

```powershell
# Create a self-signed code signing cert (5 year expiry)
$cert = New-SelfSignedCertificate `
  -Subject "CN=DeepCharts Development" `
  -FriendlyName "DeepCharts Dev Cert" `
  -Type CodeSigning `
  -CertStoreLocation "Cert:\CurrentUser\My" `
  -NotAfter (Get-Date).AddYears(5)

# Export to PFX (password-protected)
$password = ConvertTo-SecureString -String "devpassword" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath "C:\certs\deepcharts-dev.pfx" -Password $password

Write-Host "Cert thumbprint: $($cert.Thumbprint)"
```

Then sign with:

```powershell
signtool sign /fd SHA256 /a /sha1 <thumbprint> /v "path\to\file.exe"
```

> Self-signed certs trigger SmartScreen warnings on end-user machines. Only use for internal testing.

## Signing Function for build.ps1

The root `build.ps1` includes this function. It checks for `AZURE_TRUSTED_SIGNING_ACCOUNT` and skips gracefully when not configured:

```powershell
function Sign-File {
    param([string]$Path)
    $signAccount = $env:AZURE_TRUSTED_SIGNING_ACCOUNT
    if (-not $signAccount) { Write-Host "Skipping signing (no Azure account configured)"; return }
    & signtool sign /fd SHA256 /tr "http://timestamp.digicert.com" /td SHA256 /v "$Path"
}
```

Usage from a build script:

```powershell
.\build.ps1  # builds unsigned
$env:AZURE_TRUSTED_SIGNING_ACCOUNT = "DeepCharts"
.\build.ps1  # builds and signs
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `signtool` not found | Install Windows SDK or supply full path |
| `Access denied` signing | Run `az login` and ensure correct subscription |
| Certificate profile not found | Verify profile name and resource group region match |
| SmartScreen warning | Self-signed certs always trigger this. Deploy Azure Trusted Signing for production |
| Timestamp server unreachable | Use `http://timestamp.digicert.com` (works without auth) |
