# Shared APK checks. These inspect the ZIP without modifying or resigning it.
function Get-ZelunaAndroidAbis([string]$TargetPlatform) {
    switch ($TargetPlatform) {
        'universal' { return @('arm64-v8a', 'armeabi-v7a', 'x86_64') }
        'android-arm64' { return @('arm64-v8a') }
        'android-arm' { return @('armeabi-v7a') }
        'android-x64' { return @('x86_64') }
        default { throw "Unsupported Android target platform: $TargetPlatform" }
    }
}

function Get-ZelunaAndroidBuildArguments([string]$TargetPlatform) {
    $abis = @(Get-ZelunaAndroidAbis $TargetPlatform)
    $arguments = @('build', 'apk', '--release', '--suppress-analytics')
    if ($TargetPlatform -ne 'universal') {
        $arguments += @('--target-platform', $TargetPlatform, "-PzelunaTargetAbi=$($abis[0])")
    }
    return $arguments
}

function Get-ZelunaAndroidArchiveInfo([string]$Path, [string]$TargetPlatform) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expected = @(Get-ZelunaAndroidAbis $TargetPlatform)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = @($archive.Entries | ForEach-Object FullName)
        if ($names -notcontains 'AndroidManifest.xml') {
            throw 'APK is missing AndroidManifest.xml.'
        }
        if (@($names | Sort-Object -Unique).Count -ne $names.Count) {
            throw 'APK contains ambiguous duplicate entries.'
        }
        $abis = @($names | ForEach-Object {
            if ($_ -match '^lib/([^/]+)/[^/]+\.so$') { $Matches[1] }
        } | Sort-Object -Unique)
        if (($abis -join ',') -ne (($expected | Sort-Object) -join ',')) {
            throw "APK ABI mismatch: expected $($expected -join ','); found $($abis -join ',')."
        }
        foreach ($abi in $abis) {
            foreach ($library in @('libapp.so', 'libflutter.so')) {
                if ($names -notcontains "lib/$abi/$library") {
                    throw "APK is missing required Flutter library for $abi."
                }
            }
        }
    }
    finally { $archive.Dispose() }
    return [pscustomobject]@{
        native_abis = $abis
        bytes = (Get-Item -LiteralPath $Path).Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Read-ZelunaAndroidBuildReceipt(
    [string]$ApkPath, [string]$ReceiptPath, [string]$GitSha,
    [string]$Version, [string]$TargetPlatform
) {
    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
        throw 'APK build receipt is missing. Rebuild through the Android packaging helper; do not reuse an unverified APK.'
    }
    try { $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json }
    catch { throw 'APK build receipt is not valid JSON.' }
    if ($receipt.schema -ne 'zeluna.android-build.v1' -or $receipt.build_mode -ne 'release') {
        throw 'APK build receipt is not a release build receipt.'
    }
    if ([string]$receipt.git_sha -ne $GitSha -or [string]$receipt.version -ne $Version) {
        throw 'APK build receipt does not match the gated source SHA/version.'
    }
    if ([string]$receipt.target_platform -ne $TargetPlatform) {
        throw 'APK build receipt target platform does not match this package request.'
    }
    $actual = Get-ZelunaAndroidArchiveInfo $ApkPath $TargetPlatform
    if ([string]$receipt.sha256 -ne $actual.sha256 -or [long]$receipt.bytes -ne $actual.bytes) {
        throw 'APK bytes do not match its build receipt.'
    }
    if ((@($receipt.native_abis | Sort-Object) -join ',') -ne ($actual.native_abis -join ',')) {
        throw 'APK ABI metadata does not match its contents.'
    }
    return $receipt
}
