[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$testRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $projectRoot ('build\windows-package-test-{0}' -f [Guid]::NewGuid().ToString('N')))
)
$buildPrefix = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'build')).TrimEnd('\', '/') +
    [System.IO.Path]::DirectorySeparatorChar
if (-not $testRoot.StartsWith($buildPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Windows package test directory escaped build/.'
}

$head = (& git -C $projectRoot rev-parse HEAD).Trim()
$versionLine = Select-String -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') `
    -Pattern '^version:\s*(\S+)\s*$' | Select-Object -First 1
if ($null -eq $versionLine) {
    throw 'Unable to read the version from pubspec.yaml.'
}
$version = $versionLine.Matches[0].Groups[1].Value

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $gatePath = Join-Path $testRoot 'gate.json'
    $gate = [ordered]@{
        schema = 'zeluna-release-head-gate-v1'
        version = $version
        git_sha = $head
        workflow = 'Quality Gates'
        conclusion = 'success'
        ci_run_id = 'windows-package-content-test'
        ci_run_url = 'https://example.invalid/actions/runs/test'
    }
    [System.IO.File]::WriteAllText(
        $gatePath,
        (($gate | ConvertTo-Json -Depth 3) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )

    & (Join-Path $projectRoot 'tool\package_windows_release.ps1') `
        -SkipBuild `
        -DeliveryDirectory $testRoot `
        -GateReceiptPath $gatePath | Out-Null

    $archive = Join-Path $testRoot "Zeluna-Windows-$version.zip"
    $expanded = Join-Path $testRoot 'expanded'
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    foreach ($relative in @(
        'Zeluna.exe',
        'flutter_windows.dll',
        'data\app.so',
        'LICENSE',
        'THIRD_PARTY_NOTICES.md',
        'Zeluna-release-metadata.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $expanded $relative) -PathType Leaf)) {
            throw "Windows release package is missing: $relative"
        }
    }
    $metadata = Get-Content -LiteralPath (
        Join-Path $expanded 'Zeluna-release-metadata.json'
    ) -Raw | ConvertFrom-Json
    if ($metadata.version -ne $version -or $metadata.commit -ne $head) {
        throw 'Windows release metadata does not match version and HEAD.'
    }
    Write-Output 'Windows release package content checks passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
