[CmdletBinding()]
param(
    [string]$ApkPath = "build/app/outputs/flutter-apk/app-release.apk",
    [string]$AabPath = "build/app/outputs/bundle/release/app-release.aab"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$projectRoot = Split-Path -Parent $PSScriptRoot

function Add-Failure([string]$Message) {
    $failures.Add($Message)
}

function Add-Warning([string]$Message) {
    $warnings.Add($Message)
}

function Resolve-ProjectPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

function Read-JavaProperties([string]$Path) {
    $properties = @{}
    foreach ($rawLine in Get-Content -Encoding utf8 $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.StartsWith("#") -or
            $line.StartsWith("!")) {
            continue
        }

        $separator = $line.IndexOf("=")
        if ($separator -lt 0) {
            $separator = $line.IndexOf(":")
        }
        if ($separator -lt 1) {
            continue
        }

        $name = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        $properties[$name] = $value
    }
    return $properties
}

function Test-PlaceholderValue([string]$Value) {
    return $Value -match '(?i)^(?:replace|change|your|todo|example|placeholder)(?:[-_ ].*)?$' -or
        $Value -match '^<[^>]+>$'
}

function Find-JavaHome {
    $candidates = @(
        $env:JAVA_HOME,
        $env:STUDIO_JDK
    )
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += Join-Path $env:ProgramFiles "Android\Android Studio\jbr"
    }

    $uninstallRegistryRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($registryRoot in $uninstallRegistryRoots) {
        $studioEntries = Get-ChildItem $registryRoot -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object {
                $displayNameProperty = $_.PSObject.Properties["DisplayName"]
                $null -ne $displayNameProperty -and
                    [string]$displayNameProperty.Value -like "*Android Studio*"
            }
        foreach ($entry in $studioEntries) {
            $installLocationProperty = $entry.PSObject.Properties["InstallLocation"]
            $displayIconProperty = $entry.PSObject.Properties["DisplayIcon"]
            $studioRoot = if ($null -eq $installLocationProperty) {
                ""
            } else {
                [string]$installLocationProperty.Value
            }
            if ([string]::IsNullOrWhiteSpace($studioRoot) -and
                $null -ne $displayIconProperty -and
                -not [string]::IsNullOrWhiteSpace([string]$displayIconProperty.Value)) {
                $studioExecutable = (
                    [string]$displayIconProperty.Value -split ','
                )[0].Trim('"')
                $studioRoot = Split-Path -Parent (Split-Path -Parent $studioExecutable)
            }
            if (-not [string]::IsNullOrWhiteSpace($studioRoot)) {
                $candidates += Join-Path $studioRoot "jbr"
            }
        }
    }

    $studioCommand = Get-Command studio64.exe -ErrorAction SilentlyContinue
    if ($null -eq $studioCommand) {
        $studioCommand = Get-Command studio.exe -ErrorAction SilentlyContinue
    }
    if ($null -ne $studioCommand) {
        $studioRoot = Split-Path -Parent (Split-Path -Parent $studioCommand.Source)
        $candidates += Join-Path $studioRoot "jbr"
    }

    $javaCommand = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($null -ne $javaCommand) {
        $candidates += Split-Path -Parent (Split-Path -Parent $javaCommand.Source)
    }

    foreach ($candidate in $candidates | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique) {
        if (Test-Path (Join-Path $candidate "bin/java.exe") -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Find-AndroidSdk {
    $candidates = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
    $localPropertiesPath = Join-Path $projectRoot "android/local.properties"
    if (Test-Path $localPropertiesPath -PathType Leaf) {
        $sdkLine = Get-Content -Encoding utf8 $localPropertiesPath |
            Where-Object { $_ -match '^sdk\.dir=' } |
            Select-Object -First 1
        if ($sdkLine) {
            $sdkPath = ($sdkLine -replace '^sdk\.dir=', '') -replace '\\\\', '\'
            $sdkPath = $sdkPath -replace '\\:', ':'
            $candidates += $sdkPath
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += Join-Path $env:LOCALAPPDATA "Android\Sdk"
    }

    foreach ($candidate in $candidates | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique) {
        if (Test-Path $candidate -PathType Container) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Find-ApkSigner([string]$SdkRoot) {
    if (-not [string]::IsNullOrWhiteSpace($SdkRoot)) {
        $buildToolsRoot = Join-Path $SdkRoot "build-tools"
        if (Test-Path $buildToolsRoot -PathType Container) {
            $buildToolDirectories = Get-ChildItem $buildToolsRoot -Directory |
                Sort-Object -Property @{
                    Expression = {
                        $versionText = $_.Name -replace '[^0-9.].*$', ''
                        try { [version]$versionText } catch { [version]"0.0" }
                    }
                    Descending = $true
                }
            foreach ($directory in $buildToolDirectories) {
                $candidate = Join-Path $directory.FullName "apksigner.bat"
                if (Test-Path $candidate -PathType Leaf) {
                    return $candidate
                }
            }
        }
    }

    $command = Get-Command apksigner.bat -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        $command = Get-Command apksigner -ErrorAction SilentlyContinue
    }
    if ($null -ne $command) {
        return $command.Source
    }
    return $null
}

function Get-ReleaseSourceFiles {
    $sourcePaths = @(
        "lib",
        "assets",
        "android/app/src",
        "android/app/build.gradle.kts",
        "android/build.gradle.kts",
        "android/settings.gradle.kts",
        "android/gradle.properties",
        "android/key.properties",
        "android/gradle/wrapper/gradle-wrapper.properties",
        "pubspec.yaml",
        "pubspec.lock"
    )
    foreach ($relativePath in $sourcePaths) {
        $resolvedPath = Join-Path $projectRoot $relativePath
        if (Test-Path $resolvedPath -PathType Container) {
            Get-ChildItem $resolvedPath -Recurse -File
        } elseif (Test-Path $resolvedPath -PathType Leaf) {
            Get-Item $resolvedPath
        }
    }
}

function Test-ArtifactFreshness(
    [string]$Label,
    [string]$Path,
    [System.IO.FileInfo]$NewestSource
) {
    if (-not (Test-Path $Path -PathType Leaf)) {
        Add-Failure "$Label not found: $Path"
        return
    }

    $artifact = Get-Item $Path
    if ($null -ne $NewestSource -and
        $artifact.LastWriteTimeUtc -lt $NewestSource.LastWriteTimeUtc) {
        Add-Failure (
            "$Label is older than source file $($NewestSource.FullName). " +
            "Rebuild the release artifact."
        )
    }
}

function Test-JarSignatureFiles([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entryNames = @($archive.Entries | ForEach-Object {
                $_.FullName.Replace("\", "/")
            })
        $hasSignatureFile = @($entryNames | Where-Object {
                $_ -match '(?i)^META-INF/[^/]+\.SF$'
            }).Count -gt 0
        $hasSignatureBlock = @($entryNames | Where-Object {
                $_ -match '(?i)^META-INF/[^/]+\.(?:RSA|DSA|EC)$'
            }).Count -gt 0
        return $hasSignatureFile -and $hasSignatureBlock
    } finally {
        $archive.Dispose()
    }
}

$androidGradlePath = Join-Path $projectRoot "android/app/build.gradle.kts"
$androidManifestPath = Join-Path $projectRoot "android/app/src/main/AndroidManifest.xml"
$pubspecPath = Join-Path $projectRoot "pubspec.yaml"
$webManifestPath = Join-Path $projectRoot "web/manifest.json"
$keyPropertiesPath = Join-Path $projectRoot "android/key.properties"

$androidGradle = Get-Content -Raw -Encoding utf8 $androidGradlePath
$androidManifest = Get-Content -Raw -Encoding utf8 $androidManifestPath
$pubspec = Get-Content -Raw -Encoding utf8 $pubspecPath
$webManifestText = Get-Content -Raw -Encoding utf8 $webManifestPath

if (-not (Test-Path $keyPropertiesPath -PathType Leaf)) {
    Add-Failure "android/key.properties is missing; production signing is not configured."
} else {
    $keyProperties = Read-JavaProperties $keyPropertiesPath
    $requiredKeys = @("storeFile", "storePassword", "keyAlias", "keyPassword")
    $missingKeys = @($requiredKeys | Where-Object {
            -not $keyProperties.ContainsKey($_) -or
            [string]::IsNullOrWhiteSpace([string]$keyProperties[$_])
        })
    if ($missingKeys.Count -gt 0) {
        Add-Failure (
            "android/key.properties is missing required fields: " +
            ($missingKeys -join ", ")
        )
    }

    $placeholderKeys = @($requiredKeys | Where-Object {
            $keyProperties.ContainsKey($_) -and
            -not [string]::IsNullOrWhiteSpace([string]$keyProperties[$_]) -and
            (Test-PlaceholderValue ([string]$keyProperties[$_]))
        })
    if ($placeholderKeys.Count -gt 0) {
        Add-Failure (
            "android/key.properties still contains placeholder values for: " +
            ($placeholderKeys -join ", ")
        )
    }

    if ($keyProperties.ContainsKey("keyAlias") -and
        [string]$keyProperties["keyAlias"] -match '(?i)^androiddebugkey$') {
        Add-Failure "android/key.properties points to the Android debug key alias."
    }

    if ($keyProperties.ContainsKey("storeFile") -and
        -not [string]::IsNullOrWhiteSpace([string]$keyProperties["storeFile"])) {
        $configuredStorePath = [string]$keyProperties["storeFile"]
        if ([System.IO.Path]::IsPathRooted($configuredStorePath)) {
            $resolvedStorePath = [System.IO.Path]::GetFullPath($configuredStorePath)
        } else {
            $resolvedStorePath = [System.IO.Path]::GetFullPath((
                    Join-Path (Join-Path $projectRoot "android/app") $configuredStorePath
                ))
        }
        if (-not (Test-Path $resolvedStorePath -PathType Leaf)) {
            Add-Failure "storeFile does not point to an existing keystore file."
        }
    }
}

if ($androidGradle -match 'applicationId\s*=\s*"(?:com\.example|app\.anime\.anime)"') {
    Add-Failure "Confirm the final Android applicationId before public release."
}
if ($androidGradle -match 'allowDebugReleaseSigning' -or
    $androidGradle -match 'release[\s\S]*?signingConfigs\.getByName\("debug"\)') {
    Add-Failure "Release configuration still allows the Android debug signing key."
}
if ($androidManifest -cmatch 'android:label="anime"') {
    Add-Failure "The Android application label is still generic."
}
if ($androidManifest -notmatch 'android:icon="@mipmap/ic_launcher"') {
    Add-Failure "The Android manifest does not reference the expected launcher icon."
}
if ($androidManifest -match 'android:usesCleartextTraffic="true"') {
    Add-Warning "Android still allows cleartext traffic globally; confirm the policy."
}
if ($pubspec -match '(?m)^version:\s*1\.0\.0\+1\s*$') {
    Add-Warning "Confirm whether 1.0.0+1 is the intended first public version."
}

# Known hashes of the Flutter template launcher icons across Android densities.
$flutterDefaultLauncherHashes = @(
    "6A7C8F0D703E3682108F9662F813302236240D3F8F638BB391E32BFB96055FEF",
    "C7C0C0189145E4E32A401C61C9BDC615754B0264E7AFAE24E834BB81049EAF81",
    "E14AA40904929BF313FDED22CF7E7FFCBF1D1AAC4263B5EF1BE8BFCE650397AA",
    "4D470BF22D5C17D84EDC5F82516D1BA8A1C09559CD761CEFB792F86D9F52B540",
    "3C34E1F298D0C9EA3455D46DB6B7759C8211A49E9EC6E44B635FC5C87DFB4180"
)
$launcherDensities = @("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")
foreach ($density in $launcherDensities) {
    $launcherRelativePath = "android/app/src/main/res/mipmap-$density/ic_launcher.png"
    $launcherPath = Join-Path $projectRoot $launcherRelativePath
    if (-not (Test-Path $launcherPath -PathType Leaf)) {
        Add-Failure "Android launcher icon is missing: $launcherRelativePath"
        continue
    }
    $launcherHash = (Get-FileHash $launcherPath -Algorithm SHA256).Hash
    if ($flutterDefaultLauncherHashes -contains $launcherHash) {
        Add-Failure "Android launcher icon still uses the Flutter default: $launcherRelativePath"
    }
}

try {
    $webManifest = $webManifestText | ConvertFrom-Json
    if ($webManifest.description -match 'A new Flutter project') {
        Add-Failure "The Web manifest still contains Flutter placeholder text."
    }
    if ($webManifest.PSObject.Properties.Name -contains "orientation" -and
        $webManifest.orientation -match '^portrait') {
        Add-Failure "The Web manifest still forces portrait orientation."
    }
} catch {
    Add-Failure "web/manifest.json is not valid JSON."
}

$brandIconMappings = @{
    "web/icons/Icon-192.png" = "assets/brand/anime_logo_app_icon_192.png"
    "web/icons/Icon-512.png" = "assets/brand/anime_logo_app_icon_512.png"
    "web/icons/Icon-maskable-192.png" = "assets/brand/anime_logo_app_icon_192.png"
    "web/icons/Icon-maskable-512.png" = "assets/brand/anime_logo_app_icon_512.png"
    "web/favicon.png" = "assets/brand/anime_logo_app_icon_192.png"
}
foreach ($destinationRelativePath in $brandIconMappings.Keys) {
    $destination = Join-Path $projectRoot $destinationRelativePath
    $brandSource = Join-Path $projectRoot $brandIconMappings[$destinationRelativePath]
    if (-not (Test-Path $brandSource -PathType Leaf)) {
        Add-Failure "Project brand asset is missing: $($brandIconMappings[$destinationRelativePath])"
    } elseif (-not (Test-Path $destination -PathType Leaf)) {
        Add-Failure "Web brand icon is missing: $destinationRelativePath"
    } elseif ((Get-FileHash $destination -Algorithm SHA256).Hash -ne
        (Get-FileHash $brandSource -Algorithm SHA256).Hash) {
        Add-Failure "Web icon still differs from the project brand asset: $destinationRelativePath"
    }
}

$resolvedAab = Resolve-ProjectPath $AabPath
$resolvedApk = Resolve-ProjectPath $ApkPath
$newestSource = Get-ReleaseSourceFiles |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
Test-ArtifactFreshness "AAB" $resolvedAab $newestSource
Test-ArtifactFreshness "APK" $resolvedApk $newestSource

$javaHome = Find-JavaHome
$jarsigner = $null
if ([string]::IsNullOrWhiteSpace($javaHome)) {
    Add-Failure "Java runtime not found; release signatures cannot be verified."
} else {
    $jarsigner = Join-Path $javaHome "bin/jarsigner.exe"
    if (-not (Test-Path $jarsigner -PathType Leaf)) {
        Add-Failure "jarsigner not found; AAB signature cannot be verified."
        $jarsigner = $null
    }
}

$androidSdk = Find-AndroidSdk
if ([string]::IsNullOrWhiteSpace($androidSdk)) {
    Add-Failure "Android SDK not found; APK signature cannot be verified."
}
$apksigner = Find-ApkSigner $androidSdk
if ([string]::IsNullOrWhiteSpace($apksigner)) {
    Add-Failure "apksigner not found; APK signature cannot be verified."
}

if ((Test-Path $resolvedAab -PathType Leaf) -and $null -ne $jarsigner) {
    $previousJavaHome = $env:JAVA_HOME
    try {
        $env:JAVA_HOME = $javaHome
        $aabVerification = & $jarsigner -verify -verbose -certs $resolvedAab 2>&1
        $aabExitCode = $LASTEXITCODE
    } finally {
        if ([string]::IsNullOrWhiteSpace($previousJavaHome)) {
            Remove-Item Env:JAVA_HOME -ErrorAction SilentlyContinue
        } else {
            $env:JAVA_HOME = $previousJavaHome
        }
    }
    $aabVerificationText = $aabVerification -join "`n"
    if ($aabExitCode -ne 0 -or
        -not (Test-JarSignatureFiles $resolvedAab)) {
        Add-Failure "AAB signature verification failed or the bundle is unsigned."
    } elseif ($aabVerificationText -match '(?i)Android Debug') {
        Add-Failure "AAB uses an Android Debug certificate."
    }
}

if ((Test-Path $resolvedApk -PathType Leaf) -and
    -not [string]::IsNullOrWhiteSpace($apksigner)) {
    $previousJavaHome = $env:JAVA_HOME
    try {
        if (-not [string]::IsNullOrWhiteSpace($javaHome)) {
            $env:JAVA_HOME = $javaHome
        }
        $apkVerification = & $apksigner verify --verbose --print-certs $resolvedApk 2>&1
        $apkExitCode = $LASTEXITCODE
    } finally {
        if ([string]::IsNullOrWhiteSpace($previousJavaHome)) {
            Remove-Item Env:JAVA_HOME -ErrorAction SilentlyContinue
        } else {
            $env:JAVA_HOME = $previousJavaHome
        }
    }
    $apkVerificationText = $apkVerification -join "`n"
    if ($apkExitCode -ne 0) {
        Add-Failure "APK signature verification failed."
    } elseif ($apkVerificationText -match '(?i)Android Debug') {
        Add-Failure "APK uses an Android Debug certificate."
    }
}

foreach ($warning in $warnings) {
    Write-Host "[WARN] $warning" -ForegroundColor Yellow
}
foreach ($failure in $failures) {
    Write-Host "[BLOCK] $failure" -ForegroundColor Red
}

if ($failures.Count -gt 0) {
    Write-Host "Release check failed with $($failures.Count) blocker(s)." -ForegroundColor Red
    exit 1
}

Write-Host "Release check passed." -ForegroundColor Green
