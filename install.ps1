# One-command install of the client-only Hermes Desktop app on Windows.
#
#   irm https://raw.githubusercontent.com/namastex888/hermes-desktop-client/main/install.ps1 | iex
#
$ErrorActionPreference = "Stop"
$repo = "namastex888/hermes-desktop-client"

Write-Host "==> resolving latest release"
$rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" `
    -Headers @{ "User-Agent" = "hermes-desktop-client" }

$asset = $rel.assets | Where-Object { $_.name -like "*.exe" } | Select-Object -First 1
if (-not $asset) { throw "no .exe in the latest release" }

$out = Join-Path $env:TEMP $asset.name
Write-Host "==> downloading $($asset.name)"
Invoke-WebRequest $asset.browser_download_url -OutFile $out

Write-Host "==> launching installer"
# Unsigned build: SmartScreen may warn. Choose "More info" -> "Run anyway".
Start-Process -FilePath $out -Wait

Write-Host "==> done. Launch Hermes from the Start menu."
