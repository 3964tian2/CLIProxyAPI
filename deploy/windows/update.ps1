[CmdletBinding()]
param(
    [string]$WorkDir = "D:\program\CPA",
    [switch]$NoPush
)

$ErrorActionPreference = "Stop"
$sourceDir = Join-Path $WorkDir "source"
$deployDir = Join-Path $sourceDir "deploy\windows"
$maintenanceDir = Join-Path $WorkDir "maintenance"
$exePath = Join-Path $WorkDir "cli-proxy-api.exe"
$backupDir = Join-Path $WorkDir "backup"
$goExe = Join-Path $WorkDir ".tools\go\bin\go.exe"
$requiredFile = Join-Path $WorkDir ".protected\required-customization-commit.txt"

function Get-CPAProcesses {
    $expectedPath = [IO.Path]::GetFullPath($exePath)
    @(Get-CimInstance Win32_Process -Filter "Name='cli-proxy-api.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            [IO.Path]::GetFullPath($_.ExecutablePath).Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)
        })
}

function Stop-CPA {
    foreach ($process in @(Get-CPAProcesses)) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }
    $deadline = (Get-Date).AddSeconds(10)
    while ((@(Get-CPAProcesses)).Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if ((@(Get-CPAProcesses)).Count -gt 0) { throw "CPA process did not stop before executable replacement." }
}

function Assert-RequiredCustomization([string]$Commitish) {
    if (-not (Test-Path -LiteralPath $requiredFile)) { throw "Required customization marker is missing: $requiredFile" }
    $required = (Get-Content -LiteralPath $requiredFile -Raw).Trim()
    if ($required -notmatch '^[0-9a-f]{40}$') { throw "Required customization marker is invalid." }
    git merge-base --is-ancestor $required $Commitish
    if ($LASTEXITCODE -ne 0) { throw "Required CPA customization $required is not an ancestor of $Commitish." }
}

foreach ($requiredPath in @($sourceDir, $deployDir, $exePath, $goExe)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Required CPA path is missing: $requiredPath" }
}

Write-Host "[1/8] Synchronizing the verified customization fork..."
& (Join-Path $deployDir "sync_cpa_upstream.ps1") -WorkDir $WorkDir -NoPush:$NoPush

$stagedExe = $null
Push-Location $sourceDir
try {
    if (git status --porcelain) { throw "Source checkout is dirty after synchronization." }
    Assert-RequiredCustomization "HEAD"
    $head = (git rev-parse HEAD).Trim()

    Write-Host "[2/8] Running deployment-critical tests..."
    & $goExe test ./internal/runtime/executor/helps ./internal/api/handlers/management ./internal/usageledger
    if ($LASTEXITCODE -ne 0) { throw "Deployment-critical tests failed." }

    Write-Host "[3/8] Building a clean fork executable..."
    $stagedExe = Join-Path $env:TEMP "cli-proxy-api.fork-$([DateTime]::UtcNow.Ticks).exe"
    & $goExe build -trimpath -o $stagedExe ./cmd/server
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $stagedExe)) { throw "Fork build failed." }

    $buildInfo = (& $goExe version -m $stagedExe | Out-String)
    if ($buildInfo -notmatch ("vcs\.revision[=\s]+" + [regex]::Escape($head))) { throw "Built executable does not record source commit $head." }
    if ($buildInfo -match "vcs\.modified[=\s]+true") { throw "Refusing to install a dirty build." }
} catch {
    if ($stagedExe) { Remove-Item -LiteralPath $stagedExe -Force -ErrorAction SilentlyContinue }
    throw
} finally {
    Pop-Location
}

Write-Host "[4/8] Deploying canonical maintenance files..."
New-Item -ItemType Directory -Path $maintenanceDir -Force | Out-Null
Copy-Item -Path (Join-Path $deployDir "*") -Destination $maintenanceDir -Recurse -Force
Copy-Item -LiteralPath (Join-Path $maintenanceDir "cpa-service.vbs") -Destination (Join-Path $WorkDir "cpa-service.vbs") -Force

Write-Host "[5/8] Backing up and replacing CPA..."
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupPath = Join-Path $backupDir "cli-proxy-api.exe.bak_$timestamp"
$wasRunning = (@(Get-CPAProcesses)).Count -gt 0
Copy-Item -LiteralPath $exePath -Destination $backupPath -Force
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $exePath).Hash -ne
    (Get-FileHash -Algorithm SHA256 -LiteralPath $backupPath).Hash) {
    throw "CPA executable backup verification failed; replacement was cancelled."
}
if ($wasRunning) { Stop-CPA }

try {
    Copy-Item -LiteralPath $stagedExe -Destination $exePath -Force
    Write-Host "[6/8] Starting CPA with the explicit config path..."
    & (Join-Path $maintenanceDir "launch_cpa.ps1") -WorkDir $WorkDir

    Write-Host "[7/8] Refreshing encrypted protection artifacts..."
    & (Join-Path $maintenanceDir "protect_installation.ps1") -WorkDir $WorkDir
    & (Join-Path $maintenanceDir "setup_autostart.ps1") -WorkDir $WorkDir
} catch {
    Stop-CPA
    Copy-Item -LiteralPath $backupPath -Destination $exePath -Force
    if ($wasRunning) { & (Join-Path $maintenanceDir "launch_cpa.ps1") -WorkDir $WorkDir }
    throw
} finally {
    Remove-Item -LiteralPath $stagedExe -Force -ErrorAction SilentlyContinue
}

Get-ChildItem -LiteralPath $backupDir -Filter "cli-proxy-api.exe.bak_*" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 8 |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "[8/8] Installed and protected CPA fork $head; backup: $backupPath" -ForegroundColor Green
