[CmdletBinding()]
param(
    [string]$WorkDir = "D:\program\CPA",
    [string]$ProtectedDir = "$env:USERPROFILE\.codex\protected-software\CPA",
    [switch]$ForceConfig,
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security
$sourceDir = Join-Path $WorkDir "source"
$maintenanceDir = Join-Path $WorkDir "maintenance"
$configPath = Join-Path $WorkDir "config.yaml"
$exePath = Join-Path $WorkDir "cli-proxy-api.exe"
$backupDir = Join-Path $WorkDir "backup"
$entropy = [Text.Encoding]::UTF8.GetBytes("CPA-config-protection-v1")

function Get-ByteSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "")
    } finally {
        $sha.Dispose()
    }
}

function Set-PrivateFileAcl([string]$Path) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, "FullControl", $allow)))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", $allow)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-CPAProcesses {
    if (-not (Test-Path -LiteralPath $exePath)) { return @() }
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
    while ((@(Get-CPAProcesses)).Count -gt 0) {
        if ((Get-Date) -ge $deadline) { throw "CPA process did not stop before restoration." }
        Start-Sleep -Milliseconds 200
    }
}

function Read-AndVerifyProtectedSet {
    foreach ($required in @("cpa-custom.bundle", "cli-proxy-api.exe", "config.yaml.dpapi", "install-manifest.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $ProtectedDir $required))) {
            throw "Protected CPA artifact is missing: $required"
        }
    }

    $manifest = Get-Content -LiteralPath (Join-Path $ProtectedDir "install-manifest.json") -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1) { throw "Unsupported CPA protection manifest schema: $($manifest.schema)" }
    if ($manifest.requiredCustomizationCommit -notmatch '^[0-9a-f]{40}$') {
        throw "Protected CPA manifest has an invalid customization commit."
    }

    $bundlePath = Join-Path $ProtectedDir "cpa-custom.bundle"
    $protectedExePath = Join-Path $ProtectedDir "cli-proxy-api.exe"
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $bundlePath).Hash -ne $manifest.bundleSha256) {
        throw "Protected CPA Git bundle hash does not match the manifest."
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $protectedExePath).Hash -ne $manifest.binarySha256) {
        throw "Protected CPA executable hash does not match the manifest."
    }

    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        [IO.File]::ReadAllBytes((Join-Path $ProtectedDir "config.yaml.dpapi")),
        $entropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    if ((Get-ByteSha256 $plain) -ne $manifest.configSha256) {
        [Array]::Clear($plain, 0, $plain.Length)
        throw "Protected CPA configuration hash does not match the manifest."
    }

    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    $verifyRepo = Join-Path $tempRoot "cpa-bundle-verify-$([Guid]::NewGuid().ToString('N'))"
    try {
        git clone --quiet $bundlePath $verifyRepo
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $verifyRepo ".git"))) {
            throw "Protected CPA Git bundle cannot be cloned."
        }
        Push-Location $verifyRepo
        try {
            git merge-base --is-ancestor $manifest.requiredCustomizationCommit HEAD
            if ($LASTEXITCODE -ne 0) { throw "Protected Git bundle does not contain the required customization commit." }
            if (-not (Test-Path -LiteralPath (Join-Path $verifyRepo "deploy\windows\restore_installation.ps1"))) {
                throw "Protected Git bundle does not contain the canonical recovery scripts."
            }
        } finally {
            Pop-Location
        }
    } finally {
        if (Test-Path -LiteralPath $verifyRepo) {
            $resolved = [IO.Path]::GetFullPath($verifyRepo)
            if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove unexpected verification path: $resolved"
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }

    [PSCustomObject]@{ Manifest = $manifest; ConfigBytes = $plain }
}

$verified = Read-AndVerifyProtectedSet
if ($VerifyOnly) {
    [Array]::Clear($verified.ConfigBytes, 0, $verified.ConfigBytes.Length)
    Write-Host "CPA protected artifacts are complete, decryptable, and restorable." -ForegroundColor Green
    return
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $sourceDir ".git"))) {
    if (Test-Path -LiteralPath $sourceDir) { throw "Source directory exists but is not a Git checkout: $sourceDir" }
    git clone --quiet (Join-Path $ProtectedDir "cpa-custom.bundle") $sourceDir
    if ($LASTEXITCODE -ne 0) { throw "Failed to restore CPA source from the protected bundle." }
} else {
    Push-Location $sourceDir
    try {
        if (git status --porcelain) { throw "Existing CPA source is dirty; refusing to replace it during recovery." }
        git merge-base --is-ancestor $verified.Manifest.requiredCustomizationCommit HEAD
        if ($LASTEXITCODE -ne 0) { throw "Existing CPA source does not contain the protected customization commit." }
    } finally {
        Pop-Location
    }
}

New-Item -ItemType Directory -Path $maintenanceDir -Force | Out-Null
$deployDir = Join-Path $sourceDir "deploy\windows"
if (-not (Test-Path -LiteralPath $deployDir)) { throw "Restored CPA source does not contain deploy/windows." }
Copy-Item -Path (Join-Path $deployDir "*") -Destination $maintenanceDir -Recurse -Force

New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$binaryBackup = $null
if (Test-Path -LiteralPath $exePath) {
    $binaryBackup = Join-Path $backupDir "cli-proxy-api.exe.before_restore_$timestamp"
    Copy-Item -LiteralPath $exePath -Destination $binaryBackup -Force
}

$wasRunning = (@(Get-CPAProcesses)).Count -gt 0
if ($wasRunning) { Stop-CPA }

try {
    Copy-Item -LiteralPath (Join-Path $ProtectedDir "cli-proxy-api.exe") -Destination $exePath -Force
    if ($ForceConfig -or -not (Test-Path -LiteralPath $configPath)) {
        [IO.File]::WriteAllBytes($configPath, $verified.ConfigBytes)
    }
    if (-not (Test-Path -LiteralPath $configPath)) { throw "CPA configuration is still missing after recovery." }
    Set-PrivateFileAcl $configPath

    Copy-Item -LiteralPath (Join-Path $maintenanceDir "cpa-service.vbs") -Destination (Join-Path $WorkDir "cpa-service.vbs") -Force
    & (Join-Path $maintenanceDir "setup_autostart.ps1") -WorkDir $WorkDir
    & (Join-Path $maintenanceDir "launch_cpa.ps1") -WorkDir $WorkDir
} catch {
    Stop-CPA
    if ($binaryBackup -and (Test-Path -LiteralPath $binaryBackup)) {
        Copy-Item -LiteralPath $binaryBackup -Destination $exePath -Force
        if ($wasRunning) { & (Join-Path $maintenanceDir "launch_cpa.ps1") -WorkDir $WorkDir }
    }
    throw
} finally {
    [Array]::Clear($verified.ConfigBytes, 0, $verified.ConfigBytes.Length)
}

Write-Host "CPA restored from protected artifacts and started with the explicit config path." -ForegroundColor Green
