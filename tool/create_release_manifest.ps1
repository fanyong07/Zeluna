[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$ArtifactPath,
    [string]$OutputPath = "release/release-manifest.json",
    [string]$Version,
    [string]$GateReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$releaseRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot "release"))
$pathComparison = [System.StringComparison]::OrdinalIgnoreCase
. (Join-Path $PSScriptRoot 'release_gate.ps1')

function Resolve-ProjectFile([string]$Path, [string]$Label) {
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path $projectRoot $Path
    }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    $rootPrefix = $projectRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, $pathComparison)) {
        throw "$Label must stay inside the repository: $Path"
    }
    return $fullPath
}

function Read-Version {
    $line = Select-String -LiteralPath (Join-Path $projectRoot "pubspec.yaml") `
        -Pattern '^version:\s*(\S+)\s*$' | Select-Object -First 1
    if ($null -eq $line) {
        throw "Unable to read the version from pubspec.yaml."
    }
    return $line.Matches[0].Groups[1].Value
}

$resolvedOutput = Resolve-ProjectFile $OutputPath "OutputPath"
$outputPrefix = $releaseRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedOutput.StartsWith($outputPrefix, $pathComparison)) {
    throw "OutputPath must stay inside the release directory."
}
if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to overwrite immutable release manifest: $resolvedOutput"
}

$resolvedArtifacts = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($path in $ArtifactPath) {
    $resolved = Resolve-ProjectFile $path "ArtifactPath"
    if ($resolved -eq $resolvedOutput) {
        throw "OutputPath cannot also be an artifact."
    }
    if (-not $seen.Add($resolved)) {
        throw "ArtifactPath contains a duplicate: $path"
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Artifact does not exist: $path"
    }
    $resolvedArtifacts.Add((Get-Item -LiteralPath $resolved))
}

$resolvedVersion = if ([string]::IsNullOrWhiteSpace($Version)) {
    Read-Version
} else {
    $Version.Trim()
}
if ($resolvedVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9]+)?$') {
    throw "Version must be a semantic Flutter version such as 1.2.3+4."
}

$commit = (& git -C $projectRoot rev-parse HEAD 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{7,64}$') {
    throw "Unable to resolve the current Git commit."
}
$gate = Read-ZelunaReleaseGate $projectRoot $GateReceiptPath
Assert-ZelunaCleanWorktree $projectRoot
if ([string]$gate.version -ne $resolvedVersion) {
    throw 'Release gate version does not match pubspec.yaml.'
}

foreach ($existingPath in Get-ChildItem -LiteralPath $releaseRoot -File -Filter '*manifest*.json' -ErrorAction SilentlyContinue) {
    try {
        $existing = Get-Content -LiteralPath $existingPath.FullName -Raw | ConvertFrom-Json
    }
    catch {
        continue
    }
    if (
        [string]$existing.version -eq $resolvedVersion -and
        -not [string]::IsNullOrWhiteSpace([string]$existing.git_sha) -and
        [string]$existing.git_sha -ne $commit
    ) {
        throw 'The same version is already bound to a different Git SHA.'
    }
}

$artifacts = foreach ($artifact in $resolvedArtifacts | Sort-Object FullName) {
    $relative = $artifact.FullName.Substring($projectRoot.Length).TrimStart('\', '/')
    [ordered]@{
        name = $artifact.Name
        path = $relative.Replace('\', '/')
        bytes = $artifact.Length
        sha256 = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$manifest = [ordered]@{
    schema = "zeluna-release-manifest-v2"
    version = $resolvedVersion
    git_sha = $commit
    generated_utc = [DateTime]::UtcNow.ToString("o")
    ci_run_id = [string]$gate.ci_run_id
    ci_run_url = [string]$gate.ci_run_url
    quality_workflow = [string]$gate.workflow
    artifacts = @($artifacts)
}

$outputDirectory = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$json = $manifest | ConvertTo-Json -Depth 5
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($resolvedOutput, $json + [Environment]::NewLine, $utf8)
Write-Output "Release manifest: $resolvedOutput"
