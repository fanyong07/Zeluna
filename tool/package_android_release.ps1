[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$UseLegacyDebugSigning,
    [string]$DeliveryDirectory,
    [string]$GateReceiptPath,
    [ValidateSet("universal", "android-arm64", "android-arm", "android-x64")]
    [string]$TargetPlatform = "universal"
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$projectRootFull = [System.IO.Path]::GetFullPath($projectRoot)
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$releaseSource = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk'
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

$versionLine = Select-String -LiteralPath $pubspecPath -Pattern '^version:\s*(\S+)\s*$' |
    Select-Object -First 1
if ($null -eq $versionLine) {
    throw 'Unable to read the version from pubspec.yaml.'
}
$version = $versionLine.Matches[0].Groups[1].Value
$publicVersion = ($version -split '\+', 2)[0]
$deliveryPath = Join-Path $deliveryDirectory "Zeluna-v$publicVersion-Android.apk"
$checksumPath = "$deliveryPath.sha256"
$deliveryReceiptPath = "$deliveryPath.build.json"
$sourceReceiptPath = "$releaseSource.zeluna-build.json"

foreach ($outputPath in @($deliveryPath, $checksumPath, $deliveryReceiptPath)) {
    if (Test-Path -LiteralPath $outputPath) {
        throw "Refusing to overwrite immutable release output: $outputPath"
    }
}

. (Join-Path $PSScriptRoot 'release_gate.ps1')
. (Join-Path $PSScriptRoot 'android_release_archive.ps1')
Assert-ZelunaCleanWorktree $projectRootFull
$gate = Read-ZelunaReleaseGate $projectRootFull $GateReceiptPath
if ([string]$gate.version -ne $version) {
    throw 'Release gate version does not match pubspec.yaml.'
}

if (-not $SkipBuild) {
    $buildArguments = @(Get-ZelunaAndroidBuildArguments $TargetPlatform)
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
    Assert-ZelunaCleanWorktree $projectRootFull
    if ((Get-ZelunaGitHead $projectRootFull) -ne [string]$gate.git_sha) {
        throw 'Source HEAD changed during Android build.'
    }
    $built = Get-ZelunaAndroidArchiveInfo $releaseSource $TargetPlatform
    $buildReceipt = [ordered]@{
        schema = 'zeluna.android-build.v1'
        build_mode = 'release'
        version = $version
        git_sha = [string]$gate.git_sha
        target_platform = $TargetPlatform
        native_abis = @($built.native_abis)
        bytes = $built.bytes
        sha256 = $built.sha256
        ci_run_id = [string]$gate.ci_run_id
        legacy_debug_signing = [bool]$UseLegacyDebugSigning
    }
    [System.IO.File]::WriteAllText(
        $sourceReceiptPath, ($buildReceipt | ConvertTo-Json -Depth 4),
        [System.Text.UTF8Encoding]::new($false)
    )
}

if (-not (Test-Path -LiteralPath $releaseSource -PathType Leaf)) {
    throw "Android Release APK is missing: $releaseSource"
}

$verifiedBuild = Read-ZelunaAndroidBuildReceipt `
    $releaseSource $sourceReceiptPath ([string]$gate.git_sha) $version $TargetPlatform
if ([bool]$verifiedBuild.legacy_debug_signing -and -not $UseLegacyDebugSigning) {
    throw 'Legacy debug-signed APK requires explicit compatibility opt-in.'
}
New-Item -ItemType Directory -Path $deliveryDirectory -Force | Out-Null
[System.IO.File]::Copy($releaseSource, $deliveryPath, $false)
[System.IO.File]::Copy($sourceReceiptPath, $deliveryReceiptPath, $false)
# Validate delivered bytes too, not only the source inspected before copying.
$null = Read-ZelunaAndroidBuildReceipt `
    $deliveryPath $deliveryReceiptPath ([string]$gate.git_sha) $version $TargetPlatform

Write-Output "Android package: $deliveryPath"
$checksum = (Get-FileHash -LiteralPath $deliveryPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $checksumPath,
    "$checksum *$([System.IO.Path]::GetFileName($deliveryPath))$([Environment]::NewLine)",
    [System.Text.UTF8Encoding]::new($false)
)
Write-Output "Version: $version"
Write-Output "Git SHA: $($gate.git_sha)"
Write-Output "CI run: $($gate.ci_run_id)"
Write-Output "SHA-256: $checksum"
Write-Output "Checksum file: $checksumPath"

Write-Output "Architectures: $($verifiedBuild.native_abis -join ', ')"
Write-Output "Build receipt: $deliveryReceiptPath"
