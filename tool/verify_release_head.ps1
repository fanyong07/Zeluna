[CmdletBinding()]
param(
    [string]$Repository,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'release_gate.ps1')

& gh auth status 1>$null 2>$null
if ($LASTEXITCODE -ne 0 -and ($env:GITHUB_TOKEN -or $env:GH_TOKEN)) {
    Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
    & gh auth status 1>$null 2>$null
}
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI authentication is unavailable.'
}

Assert-ZelunaCleanWorktree $projectRoot
$head = Get-ZelunaGitHead $projectRoot
$versionLine = Select-String -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') `
    -Pattern '^version:\s*(\S+)\s*$' | Select-Object -First 1
if ($null -eq $versionLine) {
    throw 'Unable to read the version from pubspec.yaml.'
}
$version = $versionLine.Matches[0].Groups[1].Value

if ([string]::IsNullOrWhiteSpace($Repository)) {
    $repositoryJson = & gh repo view --json nameWithOwner 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to resolve the GitHub repository with gh.'
    }
    $Repository = ($repositoryJson | ConvertFrom-Json).nameWithOwner
}

$runsJson = & gh run list `
    --repo $Repository `
    --workflow quality.yml `
    --commit $head `
    --limit 20 `
    --json databaseId,headSha,status,conclusion,url,workflowName,createdAt 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query GitHub Quality Gates runs.'
}
$run = @($runsJson | ConvertFrom-Json) |
    Where-Object {
        $_.headSha -eq $head -and
        $_.status -eq 'completed' -and
        $_.conclusion -eq 'success' -and
        $_.workflowName -eq 'Quality Gates'
    } |
    Sort-Object createdAt -Descending |
    Select-Object -First 1
if ($null -eq $run) {
    throw 'No successful Quality Gates run exists for the exact release source HEAD.'
}

$shortHead = $head.Substring(0, 12)
$resolvedOutput = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $projectRoot "release/release-gate-$version-$shortHead.json"
}
elseif ([System.IO.Path]::IsPathRooted($OutputPath)) {
    [System.IO.Path]::GetFullPath($OutputPath)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $projectRoot $OutputPath))
}
$releaseRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'release'))
$releasePrefix = $releaseRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedOutput.StartsWith(
    $releasePrefix,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw 'OutputPath must stay inside the release directory.'
}
if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to overwrite immutable release gate receipt: $resolvedOutput"
}

$receipt = [ordered]@{
    schema = 'zeluna-release-head-gate-v1'
    version = $version
    git_sha = $head
    workflow = 'Quality Gates'
    conclusion = 'success'
    ci_run_id = [string]$run.databaseId
    ci_run_url = [string]$run.url
    verified_utc = [DateTime]::UtcNow.ToString('o')
}
New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutput) -Force | Out-Null
[System.IO.File]::WriteAllText(
    $resolvedOutput,
    (($receipt | ConvertTo-Json -Depth 3) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)
Write-Output "Release gate: $resolvedOutput"
Write-Output "Git SHA: $head"
Write-Output "CI run: $($run.databaseId)"
