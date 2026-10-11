<#
.SYNOPSIS
    Runs assess-alm-accelerator.ps1 against a live Dataverse test environment
    and captures the output to a timestamped, gitignored folder.

.DESCRIPTION
    Manual/local only - never run in CI. Reads TENANT_ID, CLIENT_ID,
    CLIENT_SECRET, DATAVERSE_URL and TEST_ENVIRONMENT_NAME from the process
    environment, or from a KEY=VALUE file (default: .env.testing at the repo
    root, which is gitignored). Values from the file only affect this run.

    Output lands in tests/integration/output/<timestamp>-<scenario>/:
      run.log          full console transcript
      assessment.json  machine-readable report (Normal scenario)
      assessment.md    human-readable report   (Normal scenario)

    The output may contain tenant-specific names and GUIDs. Genericize it
    before copying anything into a committed file (see tests/integration/README.md).

.PARAMETER Scenario
    Normal     - run the assessment with the configured credentials.
    BadSecret  - run with a deliberately wrong client secret; passes when the
                 script exits 1 with a clear authentication message
                 (test matrix #9).

.PARAMETER RepoPath
    Local clone of the repository whose pipelines should be scanned.

.PARAMETER EnvFile
    KEY=VALUE file to load. Ignored if it does not exist.

.EXAMPLE
    ./tests/integration/Invoke-LiveAssessment.ps1 -RepoPath ../my-alm-repo

.EXAMPLE
    ./tests/integration/Invoke-LiveAssessment.ps1 -Scenario BadSecret
#>
[CmdletBinding()]
param(
    [ValidateSet('Normal', 'BadSecret')]
    [string]$Scenario = 'Normal',
    [string]$RepoPath,
    [string]$EnvFile = (Join-Path $PSScriptRoot '..' '..' '.env.testing')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).ProviderPath
$assessScript = Join-Path $repoRoot 'scripts' 'assess-alm-accelerator.ps1'
$required = @('TENANT_ID', 'CLIENT_ID', 'CLIENT_SECRET', 'DATAVERSE_URL')

function Import-EnvFile {
    param([string]$Path)
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $name, $value = $trimmed -split '=', 2
        $value = ($value -replace '\s+#.*$', '').Trim().Trim('"').Trim("'")
        if ($name -and $value) { Set-Item -Path "Env:$($name.Trim())" -Value $value }
    }
}

if (Test-Path -LiteralPath $EnvFile) {
    Write-Host "Loading settings from $EnvFile"
    Import-EnvFile -Path $EnvFile
}

$missing = @($required | Where-Object { -not [Environment]::GetEnvironmentVariable($_) })
if ($missing) {
    Write-Host "Missing: $($missing -join ', '). Set them in your shell or in .env.testing (see .env.example)." -ForegroundColor Red
    exit 2
}

$label = if ($env:TEST_ENVIRONMENT_NAME) { $env:TEST_ENVIRONMENT_NAME } else { 'unnamed' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $PSScriptRoot 'output' "$stamp-$Scenario"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$logPath = Join-Path $outDir 'run.log'

$arguments = @('-NoProfile', '-File', $assessScript)
if ($Scenario -eq 'Normal') { $arguments += @('-OutputPath', $outDir) }
if ($RepoPath) { $arguments += @('-RepoPath', $RepoPath) }

$originalSecret = $env:CLIENT_SECRET
if ($Scenario -eq 'BadSecret') { $env:CLIENT_SECRET = 'deliberately-invalid-secret' }

Write-Host "Scenario: $Scenario | Environment label: $label"
Write-Host "Output:   $outDir"
Write-Host ''
try {
    & pwsh @arguments 2>&1 | Tee-Object -FilePath $logPath
    $exitCode = $LASTEXITCODE
}
finally {
    $env:CLIENT_SECRET = $originalSecret
}

$log = Get-Content -Raw -LiteralPath $logPath
$passed = switch ($Scenario) {
    'Normal' { $exitCode -eq 0 }
    'BadSecret' { $exitCode -eq 1 -and $log -match 'Authentication failed' -and $log -notmatch '(?m)^\s+at ' }
}

Write-Host ''
Write-Host "Exit code: $exitCode"
if ($passed) {
    Write-Host "RESULT: PASS ($Scenario)" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: FAIL ($Scenario) - see $logPath" -ForegroundColor Red
exit 1
