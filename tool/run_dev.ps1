param(
    [string]$Device = 'windows',
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
$flutterPath = if ($null -ne $flutter) { $flutter.Source } else { $null }
if (-not $flutterPath) {
    $propertiesPath = Join-Path $projectRoot 'android/local.properties'
    if (Test-Path -LiteralPath $propertiesPath) {
        $sdkLine = Get-Content -LiteralPath $propertiesPath |
            Where-Object { $_ -match '^flutter\.sdk=' } | Select-Object -First 1
        if ($sdkLine) {
            $sdk = ($sdkLine -replace '^flutter\.sdk=', '').Replace('\\', '\')
            $candidate = Join-Path $sdk 'bin/flutter.bat'
            if (Test-Path -LiteralPath $candidate) { $flutterPath = $candidate }
        }
    }
}
if (-not $flutterPath) {
    throw 'Flutter SDK not found. Add flutter/bin to PATH or set flutter.sdk in android/local.properties.'
}
if ([string]::IsNullOrWhiteSpace($Device)) { throw 'A device ID is required.' }
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'lib/main.dart'))) {
    throw 'Run this launcher from the Zeluna source checkout.'
}
Write-Host 'Zeluna live debug (local development, not a release)'
Write-Host 'r = hot reload; R = hot restart; q = stop app'
Write-Host 'Keep this terminal open. Source changes do not auto-install on other devices.'
if ($Check) {
    Write-Host "Ready: $flutterPath | device=$Device | target=lib/main.dart"
    return
}
if ($Device -eq 'windows') {
    $expectedExe = Join-Path $projectRoot 'build/windows/x64/runner/Debug/Zeluna.exe'
    $running = Get-Process -Name Zeluna -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $expectedExe }
    if ($running) {
        Write-Warning 'This checkout already has a running Zeluna. Use its existing debug session, or close that window before starting another one.'
        exit 1
    }
}
Push-Location -LiteralPath $projectRoot
try {
    # No account reset, production deployment, signing override, or SDK upgrade.
    & $flutterPath run --debug -d $Device --target lib/main.dart
    $runExit = $LASTEXITCODE
}
finally {
    Pop-Location
}
exit $runExit
