[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$DeliveryDirectory,
    [string]$GateReceiptPath
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$projectRootFull = [System.IO.Path]::GetFullPath($projectRoot)
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$releaseSource = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$deliveryDirectory = if ([string]::IsNullOrWhiteSpace($DeliveryDirectory)) {
    Join-Path $projectRoot 'release'
}
else {
    [System.IO.Path]::GetFullPath($DeliveryDirectory)
}
$deliveryPrefix = $projectRootFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $deliveryDirectory.StartsWith($deliveryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'DeliveryDirectory must stay inside the project directory.'
}
$stagingDirectory = Join-Path $deliveryDirectory '.windows-staging'

$versionLine = Select-String -LiteralPath $pubspecPath -Pattern '^version:\s*(\S+)\s*$' |
    Select-Object -First 1
if ($null -eq $versionLine) {
    throw 'Unable to read the version from pubspec.yaml.'
}
$version = $versionLine.Matches[0].Groups[1].Value
$publicVersion = ($version -split '\+', 2)[0]
$archivePath = Join-Path $deliveryDirectory "Zeluna-v$publicVersion-Windows.zip"
$checksumPath = "$archivePath.sha256"

foreach ($outputPath in @($archivePath, $checksumPath)) {
    if (Test-Path -LiteralPath $outputPath) {
        throw "Refusing to overwrite immutable release output: $outputPath"
    }
}

. (Join-Path $PSScriptRoot 'release_gate.ps1')
. (Join-Path $PSScriptRoot 'windows_release_archive.ps1')
Assert-ZelunaCleanWorktree $projectRootFull
$gate = Read-ZelunaReleaseGate $projectRootFull $GateReceiptPath

$commit = (& git -C $projectRootFull rev-parse HEAD 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{7,64}$') {
    throw 'Unable to resolve the current Git commit for release provenance.'
}

if (-not $SkipBuild) {
    Push-Location $projectRoot
    try {
        flutter build windows --release --suppress-analytics
        if ($LASTEXITCODE -ne 0) {
            throw "Windows Release build failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}

New-Item -ItemType Directory -Path $deliveryDirectory -Force | Out-Null
New-ZelunaWindowsReleaseArchive `
    -ProjectRoot $projectRootFull `
    -ReleaseSource $releaseSource `
    -StagingDirectory $stagingDirectory `
    -ArchivePath $archivePath `
    -Version $version `
    -Commit $commit `
    -CiRunId ([string]$gate.ci_run_id)

Write-Output "Windows package: $archivePath"
$checksum = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $checksumPath,
    "$checksum *$([System.IO.Path]::GetFileName($archivePath))$([Environment]::NewLine)",
    [System.Text.UTF8Encoding]::new($false)
)
Write-Output "Version: $version"
Write-Output "Commit: $commit"
Write-Output "CI run: $($gate.ci_run_id)"
Write-Output "SHA-256: $checksum"
Write-Output "Checksum file: $checksumPath"
