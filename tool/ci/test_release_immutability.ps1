[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$testRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $projectRoot ("build\release-immutability-test-{0}" -f [Guid]::NewGuid().ToString('N')))
)
$testPrefix = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'build')).TrimEnd('\', '/') +
    [System.IO.Path]::DirectorySeparatorChar
if (-not $testRoot.StartsWith($testPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory escaped the project build directory.'
}

$versionLine = Select-String -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') `
    -Pattern '^version:\s*(\S+)\s*$' | Select-Object -First 1
if ($null -eq $versionLine) {
    throw 'Unable to read the version from pubspec.yaml.'
}
$version = $versionLine.Matches[0].Groups[1].Value
$manifestPath = Join-Path $projectRoot (
    "release\.immutability-test-{0}.json" -f [Guid]::NewGuid().ToString('N')
)

function Assert-ImmutableRefusal(
    [scriptblock]$Action,
    [string]$ExpectedMessage,
    [string]$SentinelPath
) {
    $before = (Get-FileHash -LiteralPath $SentinelPath -Algorithm SHA256).Hash
    try {
        & $Action
        throw "Expected immutable-output refusal for $SentinelPath"
    }
    catch {
        if ($_.Exception.Message -notmatch [Regex]::Escape($ExpectedMessage)) {
            throw
        }
    }
    $after = (Get-FileHash -LiteralPath $SentinelPath -Algorithm SHA256).Hash
    if ($before -ne $after) {
        throw "Immutable output changed: $SentinelPath"
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    $androidPath = Join-Path $testRoot "Zeluna-Android-$version-release.apk"
    [System.IO.File]::WriteAllText($androidPath, 'android-sentinel')
    Assert-ImmutableRefusal `
        -Action { & (Join-Path $projectRoot 'tool\package_android_release.ps1') -SkipBuild -DeliveryDirectory $testRoot } `
        -ExpectedMessage 'Refusing to overwrite immutable release output' `
        -SentinelPath $androidPath

    $windowsPath = Join-Path $testRoot "Zeluna-Windows-$version.zip"
    [System.IO.File]::WriteAllText($windowsPath, 'windows-sentinel')
    Assert-ImmutableRefusal `
        -Action { & (Join-Path $projectRoot 'tool\package_windows_release.ps1') -SkipBuild -DeliveryDirectory $testRoot } `
        -ExpectedMessage 'Refusing to overwrite immutable release output' `
        -SentinelPath $windowsPath

    [System.IO.File]::WriteAllText($manifestPath, 'manifest-sentinel')
    Assert-ImmutableRefusal `
        -Action {
            & (Join-Path $projectRoot 'tool\create_release_manifest.ps1') `
                -ArtifactPath $androidPath `
                -OutputPath $manifestPath
        } `
        -ExpectedMessage 'Refusing to overwrite immutable release manifest' `
        -SentinelPath $manifestPath

    Write-Output 'Release immutability checks passed.'
}
finally {
    if (Test-Path -LiteralPath $manifestPath) {
        Remove-Item -LiteralPath $manifestPath -Force
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
