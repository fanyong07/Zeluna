function Get-ZelunaGitHead([string]$ProjectRoot) {
    $head = (& git -C $ProjectRoot rev-parse HEAD 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
        throw 'Unable to resolve the exact Git HEAD for this release.'
    }
    return $head
}

function Assert-ZelunaCleanWorktree([string]$ProjectRoot) {
    $status = @(& git -C $ProjectRoot status --porcelain --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the Git worktree before release.'
    }
    if ($status.Count -gt 0) {
        throw 'Release packaging requires a clean Git worktree.'
    }
}

function Read-ZelunaReleaseGate(
    [string]$ProjectRoot,
    [string]$GateReceiptPath
) {
    if ([string]::IsNullOrWhiteSpace($GateReceiptPath)) {
        throw 'GateReceiptPath is required for release packaging.'
    }
    $candidate = if ([System.IO.Path]::IsPathRooted($GateReceiptPath)) {
        $GateReceiptPath
    }
    else {
        Join-Path $ProjectRoot $GateReceiptPath
    }
    $resolved = [System.IO.Path]::GetFullPath($candidate)
    $rootPrefix = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/') +
        [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith(
        $rootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'GateReceiptPath must stay inside the repository.'
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Release gate receipt is missing: $resolved"
    }
    try {
        $receipt = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    }
    catch {
        throw 'Release gate receipt is not valid JSON.'
    }
    if ($receipt.schema -ne 'zeluna-release-head-gate-v1') {
        throw 'Release gate receipt schema is not supported.'
    }
    $head = Get-ZelunaGitHead $ProjectRoot
    if ([string]$receipt.git_sha -ne $head) {
        throw 'Quality Gates SHA does not match the release source HEAD.'
    }
    if ([string]$receipt.conclusion -ne 'success') {
        throw 'The exact release source HEAD does not have a successful Quality Gates run.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$receipt.ci_run_id)) {
        throw 'Release gate receipt is missing ci_run_id.'
    }
    if ([string]$receipt.workflow -ne 'Quality Gates') {
        throw 'Release gate receipt does not identify the required Quality Gates workflow.'
    }
    return $receipt
}
