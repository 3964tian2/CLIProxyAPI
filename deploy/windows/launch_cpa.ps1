[CmdletBinding()]
param(
    [string]$WorkDir = "D:\program\CPA",
    [int]$ReadyTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$exePath = Join-Path $WorkDir "cli-proxy-api.exe"
$configPath = Join-Path $WorkDir "config.yaml"

function Get-CPAProcesses {
    $expectedPath = [IO.Path]::GetFullPath($exePath)
    @(Get-CimInstance Win32_Process -Filter "Name='cli-proxy-api.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            [IO.Path]::GetFullPath($_.ExecutablePath).Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)
        })
}

function Uses-ExplicitConfig([string]$CommandLine) {
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $hasConfigSwitch = $CommandLine -match '(?i)(?:^|\s)--?config(?:=|\s)'
    $hasExpectedPath = $CommandLine.IndexOf($configPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
    return $hasConfigSwitch -and $hasExpectedPath
}

if (-not (Test-Path -LiteralPath $exePath)) { throw "CPA executable is missing: $exePath" }
if (-not (Test-Path -LiteralPath $configPath)) { throw "CPA config is missing: $configPath" }

$running = @(Get-CPAProcesses)
$misconfigured = @($running | Where-Object { -not (Uses-ExplicitConfig $_.CommandLine) })
if ($misconfigured.Count -gt 0) {
    foreach ($process in $misconfigured) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }
    $deadline = (Get-Date).AddSeconds(10)
    while ((@(Get-CPAProcesses | Where-Object { -not (Uses-ExplicitConfig $_.CommandLine) })).Count -gt 0) {
        if ((Get-Date) -ge $deadline) { throw "CPA process with an incorrect config path did not stop." }
        Start-Sleep -Milliseconds 200
    }
    $running = @(Get-CPAProcesses)
}

if ($running.Count -eq 0) {
    $started = Start-Process -FilePath $exePath `
        -ArgumentList @("-config", $configPath) `
        -WorkingDirectory $WorkDir `
        -WindowStyle Hidden `
        -PassThru
}

$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    try {
        $request = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:8317/management.html")
        $request.Method = "GET"
        $request.Timeout = 1500
        $request.Proxy = $null
        $response = $request.GetResponse()
        $response.Close()
        return
    } catch {
        Start-Sleep -Milliseconds 500
    }
}

if ($started -and -not $started.HasExited) {
    Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue
}
throw "CPA did not become ready within $ReadyTimeoutSeconds seconds."
