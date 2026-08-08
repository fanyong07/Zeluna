[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$UseLegacyDebugSigning
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$releaseSource = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk'
$deliveryDirectory = Join-Path $projectRoot 'release'

$versionLine = Select-String -LiteralPath $pubspecPath -Pattern '^version:\s*(\S+)\s*$' |
    Select-Object -First 1
if ($null -eq $versionLine) {
    throw 'Unable to read the version from pubspec.yaml.'
}
$version = $versionLine.Matches[0].Groups[1].Value
$deliveryPath = Join-Path $deliveryDirectory "Zeluna-Android-$version-release.apk"
$checksumPath = "$deliveryPath.sha256"

if (-not $SkipBuild) {
    $buildArguments = @('build', 'apk', '--release', '--suppress-analytics')
    if ($UseLegacyDebugSigning) {
        $buildArguments += '-PallowLegacyDebugReleaseSigning=true'
    }

    Push-Location $projectRoot
    try {
        & flutter @buildArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Android Release build failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $releaseSource -PathType Leaf)) {
    throw "Android Release APK is missing: $releaseSource"
}

New-Item -ItemType Directory -Path $deliveryDirectory -Force | Out-Null
Copy-Item -LiteralPath $releaseSource -Destination $deliveryPath -Force

Write-Output "Android package: $deliveryPath"
$checksum = (Get-FileHash -LiteralPath $deliveryPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $checksumPath,
    "$checksum *$([System.IO.Path]::GetFileName($deliveryPath))$([Environment]::NewLine)",
    [System.Text.UTF8Encoding]::new($false)
)
Write-Output "Version: $version"
Write-Output "SHA-256: $checksum"
Write-Output "Checksum file: $checksumPath"
