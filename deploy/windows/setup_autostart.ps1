[CmdletBinding()]
param([string]$WorkDir = "D:\program\CPA")

$ErrorActionPreference = "Stop"
$source = Join-Path $WorkDir "maintenance\cpa-service.vbs"
$startup = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\cpa-service.vbs"

if (-not (Test-Path -LiteralPath $source)) { throw "Canonical CPA startup stub is missing: $source" }
New-Item -ItemType Directory -Path (Split-Path -Parent $startup) -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $startup -Force
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne
    (Get-FileHash -Algorithm SHA256 -LiteralPath $startup).Hash) {
    throw "CPA auto-start stub verification failed: $startup"
}
Write-Host "CPA auto-start now points to the canonical maintenance launcher: $startup" -ForegroundColor Green
