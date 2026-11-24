# Write SHA256SUMS for a release stage. Dot-source only.
# Paths stay Unicode. The file is UTF-8 without a BOM.

function Get-ReleaseRelativePath([string]$Root, [string]$FullName) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fileFull = [IO.Path]::GetFullPath($FullName)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $fileFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "checksum file is outside the stage: $fileFull"
    }
    $relative = $fileFull.Substring($prefix.Length).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        throw 'checksum relative path is empty'
    }
    return $relative
}

function Write-ReleaseChecksumManifest {
    param([Parameter(Mandatory = $true)][string]$StageRoot)
    if (-not (Test-Path -LiteralPath $StageRoot)) {
        throw "checksum stage is missing: $StageRoot"
    }
    $root = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\', '/')
    $checksumFile = Join-Path $root 'SHA256SUMS'
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force |
        Where-Object { $_.FullName -ne $checksumFile } |
        Sort-Object FullName)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) {
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower()
        $relative = Get-ReleaseRelativePath -Root $root -FullName $file.FullName
        [void]$lines.Add(('{0}  {1}' -f $hash, $relative))
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllLines($checksumFile, $lines.ToArray(), $utf8)
}
