[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $projectRoot 'tool\release_gate.ps1')
$testRoot = Join-Path $projectRoot (
    'build\release-gate-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
$head = Get-ZelunaGitHead $projectRoot

function Write-Receipt([string]$Path, [string]$Sha, [string]$Conclusion) {
    $value = [ordered]@{
        schema = 'zeluna-release-head-gate-v1'
        version = '1.0.0+test'
        git_sha = $Sha
        workflow = 'Quality Gates'
        conclusion = $Conclusion
        ci_run_id = '123456'
        ci_run_url = 'https://example.invalid/actions/runs/123456'
    }
    [System.IO.File]::WriteAllText(
        $Path,
        (($value | ConvertTo-Json -Depth 3) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Assert-ReceiptRejected([string]$Path, [string]$ExpectedMessage) {
    try {
        Read-ZelunaReleaseGate $projectRoot $Path | Out-Null
        throw "Expected release gate rejection for $Path"
    }
    catch {
        if ($_.Exception.Message -notmatch [Regex]::Escape($ExpectedMessage)) {
            throw
        }
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $valid = Join-Path $testRoot 'valid.json'
    Write-Receipt $valid $head 'success'
    $receipt = Read-ZelunaReleaseGate $projectRoot $valid
    if ($receipt.git_sha -ne $head -or $receipt.ci_run_id -ne '123456') {
        throw 'Valid exact-HEAD receipt did not round-trip.'
    }

    $wrongSha = Join-Path $testRoot 'wrong-sha.json'
    Write-Receipt $wrongSha ('0' * 40) 'success'
    Assert-ReceiptRejected $wrongSha 'Quality Gates SHA does not match'

    $failed = Join-Path $testRoot 'failed.json'
    Write-Receipt $failed $head 'failure'
    Assert-ReceiptRejected $failed 'does not have a successful Quality Gates run'

    Write-Output 'Release exact-HEAD gate checks passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
