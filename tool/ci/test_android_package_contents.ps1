[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $projectRoot 'tool/android_release_archive.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('zeluna-apk-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Assert-Rejected([scriptblock]$Action, [string]$Expected) {
    $rejected = $false
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch [Regex]::Escape($Expected)) { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Expected rejection was not raised: $Expected" }
}
$arm64Arguments = @(Get-ZelunaAndroidBuildArguments 'android-arm64')
if (($arm64Arguments -join ' ') -ne 'build apk --release --suppress-analytics --target-platform android-arm64 -PzelunaTargetAbi=arm64-v8a') {
    throw 'Single-ABI build must filter native libraries without split/version-code offsets.'
}
if ((@(Get-ZelunaAndroidBuildArguments 'universal') -join ' ') -ne 'build apk --release --suppress-analytics') {
    throw 'Default packaging must retain universal compatibility.'
}
$apk = Join-Path $testRoot 'fixture.apk'
$zip = [IO.Compression.ZipFile]::Open($apk, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in @('AndroidManifest.xml', 'lib/arm64-v8a/libapp.so', 'lib/arm64-v8a/libflutter.so')) {
        $entry = $zip.CreateEntry($name)
        $writer = [IO.StreamWriter]::new($entry.Open())
        try { $writer.Write('synthetic fixture, not a release') } finally { $writer.Dispose() }
    }
} finally { $zip.Dispose() }
$info = Get-ZelunaAndroidArchiveInfo $apk 'android-arm64'
if (($info.native_abis -join ',') -ne 'arm64-v8a' -or $info.bytes -le 0) { throw 'Invalid ABI accounting.' }
Assert-Rejected { Get-ZelunaAndroidArchiveInfo $apk 'universal' } 'ABI mismatch'
Assert-Rejected { Get-ZelunaAndroidArchiveInfo $apk 'android-x64' } 'ABI mismatch'
Assert-Rejected { Get-ZelunaAndroidAbis 'unknown' } 'Unsupported Android target'
$receiptPath = "$apk.build.json"
$sha = 'a' * 40
$version = '2.0.0+100'
Assert-Rejected { Read-ZelunaAndroidBuildReceipt $apk $receiptPath $sha $version 'android-arm64' } 'build receipt is missing'
$receipt = [ordered]@{
    schema = 'zeluna.android-build.v1'; build_mode = 'release'
    git_sha = $sha; version = $version; target_platform = 'android-arm64'
    native_abis = @($info.native_abis); bytes = $info.bytes; sha256 = $info.sha256
    legacy_debug_signing = $false
}
function Write-Receipt { [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false)) }
Write-Receipt
$result = Read-ZelunaAndroidBuildReceipt $apk $receiptPath $sha $version 'android-arm64'
if ($result.sha256 -ne $info.sha256) { throw 'Receipt did not verify exact APK.' }
Assert-Rejected { Read-ZelunaAndroidBuildReceipt $apk $receiptPath ('b' * 40) $version 'android-arm64' } 'source SHA/version'
Assert-Rejected { Read-ZelunaAndroidBuildReceipt $apk $receiptPath $sha '2.0.1+101' 'android-arm64' } 'source SHA/version'
Assert-Rejected { Read-ZelunaAndroidBuildReceipt $apk $receiptPath $sha $version 'universal' } 'target platform'
$receipt.sha256 = '0' * 64; Write-Receipt
Assert-Rejected { Read-ZelunaAndroidBuildReceipt $apk $receiptPath $sha $version 'android-arm64' } 'bytes do not match'
$receipt.sha256 = $info.sha256; $receipt.native_abis = @('x86_64'); Write-Receipt
Assert-Rejected { Read-ZelunaAndroidBuildReceipt $apk $receiptPath $sha $version 'android-arm64' } 'ABI metadata'
$receipt.native_abis = @('arm64-v8a'); $receipt.build_mode = 'profile'; Write-Receipt
Assert-Rejected { Read-ZelunaAndroidBuildReceipt $apk $receiptPath $sha $version 'android-arm64' } 'not a release build'
$incomplete = Join-Path $testRoot 'incomplete.apk'
$zip = [IO.Compression.ZipFile]::Open($incomplete, [IO.Compression.ZipArchiveMode]::Create)
try { $null = $zip.CreateEntry('AndroidManifest.xml'); $null = $zip.CreateEntry('lib/arm64-v8a/libapp.so') }
finally { $zip.Dispose() }
Assert-Rejected { Get-ZelunaAndroidArchiveInfo $incomplete 'android-arm64' } 'missing required Flutter library'
# Remove only files this test created, never an enumerated or recursive target.
[IO.File]::Delete($apk)
[IO.File]::Delete($receiptPath)
[IO.File]::Delete($incomplete)
[IO.Directory]::Delete($testRoot, $false)
Write-Output 'Android package contents and provenance checks passed (15 cases).'
