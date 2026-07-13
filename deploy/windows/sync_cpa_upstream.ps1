[CmdletBinding()]
param(
    [string]$WorkDir = "D:\program\CPA",
    [switch]$NoPush
)

$ErrorActionPreference = "Stop"
$sourceDir = Join-Path $WorkDir "source"
$goExe = Join-Path $WorkDir ".tools\go\bin\go.exe"
$requiredFile = Join-Path $WorkDir ".protected\required-customization-commit.txt"
$upstream = "upstream"
$origin = "origin"
$branch = "main"

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $rawOutput = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $output = (($rawOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Git command '$($Arguments[0])' failed with exit code $exitCode. $output"
    }
    [PSCustomObject]@{ ExitCode = $exitCode; Output = $output }
}

function Assert-RequiredCustomization([string]$Commitish) {
    if (-not (Test-Path -LiteralPath $requiredFile)) { throw "Required customization marker is missing: $requiredFile" }
    $required = (Get-Content -LiteralPath $requiredFile -Raw).Trim()
    if ($required -notmatch '^[0-9a-f]{40}$') { throw "Required customization marker is invalid." }
    $result = Invoke-GitCommand -Arguments @("merge-base", "--is-ancestor", $required, $Commitish) -AllowFailure
    if ($result.ExitCode -ne 0) { throw "Required CPA customization $required is not an ancestor of $Commitish." }
}

if (-not (Test-Path -LiteralPath $sourceDir)) { throw "Fork source directory is missing: $sourceDir" }
if (-not (Test-Path -LiteralPath $goExe)) { throw "Bundled Go runtime is missing: $goExe" }

Push-Location $sourceDir
try {
    if ((Invoke-GitCommand -Arguments @("status", "--porcelain")).Output) {
        throw "Source checkout has local changes; refusing to merge over uncommitted work."
    }
    if ((Invoke-GitCommand -Arguments @("branch", "--show-current")).Output -ne $branch) {
        throw "CPA upstream synchronization must start on $branch."
    }
    Assert-RequiredCustomization "HEAD"

    $null = Invoke-GitCommand -Arguments @("config", "rerere.enabled", "true")
    $null = Invoke-GitCommand -Arguments @("config", "rerere.autoupdate", "true")

    Write-Host "[1/6] Fetching fork and upstream..."
    $null = Invoke-GitCommand -Arguments @("fetch", "--prune", $origin)
    $null = Invoke-GitCommand -Arguments @("fetch", "--prune", $upstream)

    $headBefore = (Invoke-GitCommand -Arguments @("rev-parse", "HEAD")).Output
    $ancestor = Invoke-GitCommand -Arguments @("merge-base", "--is-ancestor", "$upstream/$branch", "HEAD") -AllowFailure
    $needsMerge = $ancestor.ExitCode -ne 0
    $candidateBranch = $null

    if ($needsMerge) {
        $stamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$((New-Guid).ToString('N').Substring(0, 8))"
        $shortHead = (Invoke-GitCommand -Arguments @("rev-parse", "--short", "HEAD")).Output
        $safetyBranch = "safety/pre-sync-$stamp-$shortHead"
        $candidateBranch = "maintenance/sync-candidate-$stamp"
        $null = Invoke-GitCommand -Arguments @("branch", $safetyBranch, $headBefore)
        $null = Invoke-GitCommand -Arguments @("switch", "--quiet", "-c", $candidateBranch, $headBefore)

        Write-Host "[2/6] Merging $upstream/$branch on isolated candidate $candidateBranch..."
        $merge = Invoke-GitCommand -Arguments @("merge", "--no-commit", "--no-ff", "$upstream/$branch") -AllowFailure
        if ($merge.ExitCode -ne 0) {
            $null = Invoke-GitCommand -Arguments @("rerere") -AllowFailure
            $conflictOutput = (Invoke-GitCommand -Arguments @("diff", "--name-only", "--diff-filter=U")).Output
            $conflicts = @($conflictOutput -split '\r?\n' | Where-Object { $_ })
            if ($conflicts.Count -gt 0) {
                $conflicts | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
                throw "Automatic merge left unresolved conflicts. Main remains unchanged."
            }
        }
        $null = Invoke-GitCommand -Arguments @("add", "-A")
        $whitespace = Invoke-GitCommand -Arguments @("diff", "--cached", "--check") -AllowFailure
        if ($whitespace.ExitCode -ne 0) { throw "Merged tree has whitespace errors. $($whitespace.Output)" }
        $upstreamShort = (Invoke-GitCommand -Arguments @("rev-parse", "--short", "$upstream/$branch")).Output
        $null = Invoke-GitCommand -Arguments @("commit", "-m", "merge: sync upstream $upstreamShort and preserve CPA customizations")
    } else {
        Write-Host "[2/6] $upstream/$branch is already included."
    }

    Write-Host "[3/6] Verifying required customization ancestry..."
    Assert-RequiredCustomization "HEAD"

    Write-Host "[4/6] Running transport reuse and full regression tests..."
    & $goExe test ./internal/runtime/executor/helps
    if ($LASTEXITCODE -ne 0) { throw "Transport reuse tests failed." }
    & $goExe test ./...
    if ($LASTEXITCODE -ne 0) { throw "Full test suite failed. Main remains unchanged." }

    if ($candidateBranch) {
        $null = Invoke-GitCommand -Arguments @("switch", "--quiet", $branch)
        $null = Invoke-GitCommand -Arguments @("merge", "--ff-only", $candidateBranch)
        $null = Invoke-GitCommand -Arguments @("branch", "-d", $candidateBranch)
    }

    if ($NoPush) {
        Write-Host "[5/6] Push skipped by request."
    } else {
        Write-Host "[5/6] Pushing the verified customization fork..."
        $null = Invoke-GitCommand -Arguments @("push", $origin, $branch)
    }

    Write-Host "[6/6] Upstream synchronization complete: $((Invoke-GitCommand -Arguments @('rev-parse', '--short', 'HEAD')).Output)" -ForegroundColor Green
} catch {
    if (Test-Path -LiteralPath (Join-Path $sourceDir ".git\MERGE_HEAD")) {
        $null = Invoke-GitCommand -Arguments @("merge", "--abort") -AllowFailure
    }
    $currentBranch = (Invoke-GitCommand -Arguments @("branch", "--show-current") -AllowFailure).Output
    if ($currentBranch -and $currentBranch -ne $branch) {
        $null = Invoke-GitCommand -Arguments @("switch", "--quiet", $branch) -AllowFailure
    }
    throw
} finally {
    Pop-Location
}
