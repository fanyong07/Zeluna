function New-ZelunaWindowsReleaseArchive(
    [string]$ProjectRoot,
    [string]$ReleaseSource,
    [string]$StagingDirectory,
    [string]$ArchivePath,
    [string]$Version,
    [string]$Commit,
    [string]$CiRunId
) {
    $projectRootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
    $rootPrefix = $projectRootFull.TrimEnd('\', '/') +
        [System.IO.Path]::DirectorySeparatorChar
    foreach ($path in @($ReleaseSource, $StagingDirectory, $ArchivePath)) {
        $resolved = [System.IO.Path]::GetFullPath($path)
        if (-not $resolved.StartsWith(
            $rootPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'Windows archive paths must stay inside the project.'
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseSource 'Zeluna.exe'))) {
        throw "Windows Release output is missing: $ReleaseSource"
    }
    if (Test-Path -LiteralPath $ArchivePath) {
        throw "Refusing to overwrite immutable Windows archive: $ArchivePath"
    }
    if (Test-Path -LiteralPath $StagingDirectory) {
        Remove-Item -LiteralPath $StagingDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $StagingDirectory | Out-Null

    try {
        Get-ChildItem -LiteralPath $ReleaseSource -Force |
            Where-Object { $_.Name -notlike '*.WebView2' } |
            Copy-Item -Destination $StagingDirectory -Recurse -Force

        foreach ($noticeName in @('LICENSE', 'THIRD_PARTY_NOTICES.md')) {
            $noticeSource = Join-Path $projectRootFull $noticeName
            if (-not (Test-Path -LiteralPath $noticeSource -PathType Leaf)) {
                throw "Required release notice is missing: $noticeName"
            }
            Copy-Item -LiteralPath $noticeSource -Destination $StagingDirectory
        }

        $metadata = [ordered]@{
            schema = 'zeluna-windows-package-v1'
            product = 'Zeluna'
            version = $Version
            commit = $Commit
            ci_run_id = $CiRunId
            built_utc = [DateTime]::UtcNow.ToString('o')
        }
        $metadataPath = Join-Path $StagingDirectory 'Zeluna-release-metadata.json'
        [System.IO.File]::WriteAllText(
            $metadataPath,
            (($metadata | ConvertTo-Json -Depth 3) + [Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false)
        )

        Compress-Archive -Path (Join-Path $StagingDirectory '*') `
            -DestinationPath $ArchivePath -CompressionLevel Optimal
    }
    finally {
        if (Test-Path -LiteralPath $StagingDirectory) {
            Remove-Item -LiteralPath $StagingDirectory -Recurse -Force
        }
    }
}
