[CmdletBinding()]
param(
    [string]$WorkDir = "D:\program\CPA",
    [string]$MirrorDir = "$env:USERPROFILE\.codex\protected-software\CPA"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security
$sourceDir = Join-Path $WorkDir "source"
$configPath = Join-Path $WorkDir "config.yaml"
$exePath = Join-Path $WorkDir "cli-proxy-api.exe"
$goExe = Join-Path $WorkDir ".tools\go\bin\go.exe"
$localDir = Join-Path $WorkDir ".protected"
$maintenanceDir = Join-Path $WorkDir "maintenance"
$entropy = [Text.Encoding]::UTF8.GetBytes("CPA-config-protection-v1")

function Get-ByteSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "")
    } finally {
        $sha.Dispose()
    }
}

function Set-PrivateDirectoryAcl([string]$Path) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, "FullControl", $inheritance, $propagation, $allow)))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", $inheritance, $propagation, $allow)))
    Set-Acl -LiteralPath $Path -AclObject $acl
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

function Assert-ProtectedArtifacts([string]$TargetDir, [System.Collections.IDictionary]$Expected) {
    $bundlePath = Join-Path $TargetDir "cpa-custom.bundle"
    $protectedConfigPath = Join-Path $TargetDir "config.yaml.dpapi"
    $protectedExePath = Join-Path $TargetDir "cli-proxy-api.exe"

    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $bundlePath).Hash -ne $Expected.bundleSha256) {
        throw "Protected Git bundle hash verification failed in $TargetDir."
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $protectedExePath).Hash -ne $Expected.binarySha256) {
        throw "Protected CPA executable hash verification failed in $TargetDir."
    }

    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        [IO.File]::ReadAllBytes($protectedConfigPath),
        $entropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    try {
        if ((Get-ByteSha256 $plain) -ne $Expected.configSha256) {
            throw "Protected CPA configuration hash verification failed in $TargetDir."
        }
    } finally {
        [Array]::Clear($plain, 0, $plain.Length)
    }

    Push-Location $sourceDir
    try {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            git bundle verify $bundlePath 2>&1 | Out-Null
            $bundleVerifyExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($bundleVerifyExitCode -ne 0) { throw "Protected Git bundle verification failed in $TargetDir." }
        $bundleHeads = (git bundle list-heads $bundlePath | Out-String)
        if ($LASTEXITCODE -ne 0 -or $bundleHeads -notmatch [regex]::Escape($Expected.requiredCustomizationCommit)) {
            throw "Protected Git bundle does not contain the required CPA customization."
        }
    } finally {
        Pop-Location
    }
}

foreach ($required in @($sourceDir, $configPath, $exePath, $goExe, $maintenanceDir)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required CPA path is missing: $required" }
}

Push-Location $sourceDir
try {
    $dirty = git status --porcelain
    if ($dirty) { throw "CPA source must be committed before protection artifacts are generated." }
    $head = (git rev-parse HEAD).Trim()
    if ((git branch --show-current).Trim() -ne "main") { throw "CPA protection must be generated from the main branch." }

    $buildInfo = (& $goExe version -m $exePath | Out-String)
    if ($buildInfo -notmatch ("vcs\.revision[=\s]+" + [regex]::Escape($head))) {
        throw "Installed CPA executable does not record source commit $head."
    }
    if ($buildInfo -match "vcs\.modified[=\s]+true") {
        throw "Refusing to protect a CPA executable built from modified source."
    }

    $bundleTemp = Join-Path $env:TEMP "cpa-custom-$([DateTime]::UtcNow.Ticks).bundle"
    git bundle create $bundleTemp HEAD main
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bundleTemp)) { throw "Failed to create CPA Git bundle." }
} finally {
    Pop-Location
}

try {
    foreach ($targetDir in @($localDir, $MirrorDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        Set-PrivateDirectoryAcl $targetDir

        Copy-Item -LiteralPath $bundleTemp -Destination (Join-Path $targetDir "cpa-custom.bundle") -Force
        Copy-Item -LiteralPath $exePath -Destination (Join-Path $targetDir "cli-proxy-api.exe") -Force
        Copy-Item -LiteralPath (Join-Path $maintenanceDir "restore_installation.ps1") -Destination (Join-Path $targetDir "restore_installation.ps1") -Force
        Copy-Item -LiteralPath (Join-Path $maintenanceDir "launch_cpa.ps1") -Destination (Join-Path $targetDir "launch_cpa.ps1") -Force
        Copy-Item -LiteralPath (Join-Path $maintenanceDir "protect_installation.ps1") -Destination (Join-Path $targetDir "protect_installation.ps1") -Force
        Copy-Item -LiteralPath (Join-Path $maintenanceDir "setup_autostart.ps1") -Destination (Join-Path $targetDir "setup_autostart.ps1") -Force
        Copy-Item -LiteralPath (Join-Path $maintenanceDir "cpa-service.vbs") -Destination (Join-Path $targetDir "cpa-service.vbs") -Force

        $encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
            [IO.File]::ReadAllBytes($configPath),
            $entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [IO.File]::WriteAllBytes((Join-Path $targetDir "config.yaml.dpapi"), $encrypted)

        $manifest = [ordered]@{
            schema = 1
            protectedAt = (Get-Date).ToUniversalTime().ToString("o")
            requiredCustomizationCommit = $head
            binarySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $exePath).Hash
            configSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash
            bundleSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $bundleTemp).Hash
            workDir = $WorkDir
        }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $targetDir "install-manifest.json") -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $targetDir "required-customization-commit.txt") -Value $head -Encoding ASCII
        Set-PrivateDirectoryAcl $targetDir
        Assert-ProtectedArtifacts $targetDir $manifest
    }

    Set-PrivateFileAcl $configPath
} finally {
    Remove-Item -LiteralPath $bundleTemp -Force -ErrorAction SilentlyContinue
}

Write-Host "CPA protection artifacts refreshed in $localDir and $MirrorDir" -ForegroundColor Green
