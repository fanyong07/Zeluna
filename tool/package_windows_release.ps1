param(
    [switch]$SkipBuild,
    [string]$DeliveryDirectory
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$releaseSource = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$deliveryDirectory = if ([string]::IsNullOrWhiteSpace($DeliveryDirectory)) {
    Join-Path $projectRoot 'release'
}
else {
    [System.IO.Path]::GetFullPath($DeliveryDirectory)
}
$stagingDirectory = Join-Path $deliveryDirectory '.windows-staging'

$versionLine = Select-String -LiteralPath $pubspecPath -Pattern '^version:\s*(\S+)\s*$' |
    Select-Object -First 1
if ($null -eq $versionLine) {
    throw 'Unable to read the version from pubspec.yaml.'
}
$version = $versionLine.Matches[0].Groups[1].Value
$archivePath = Join-Path $deliveryDirectory "Zeluna-Windows-$version.zip"

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

if (-not (Test-Path -LiteralPath (Join-Path $releaseSource 'Zeluna.exe'))) {
    throw "Windows Release output is missing: $releaseSource"
}

New-Item -ItemType Directory -Path $deliveryDirectory -Force | Out-Null
if (Test-Path -LiteralPath $stagingDirectory) {
    Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingDirectory | Out-Null

try {
    Get-ChildItem -LiteralPath $releaseSource -Force |
        Where-Object { $_.Name -notlike '*.WebView2' } |
        Copy-Item -Destination $stagingDirectory -Recurse -Force

    Compress-Archive -Path (Join-Path $stagingDirectory '*') `
        -DestinationPath $archivePath -CompressionLevel Optimal -Force
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}

Write-Output "Windows package: $archivePath"
