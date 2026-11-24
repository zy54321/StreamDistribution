function Normalize-SemVer([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $trimmed = $Value.Trim().TrimStart('v', 'V')
    if ($trimmed -notmatch '^(\d+)\.(\d+)\.(\d+)$') { return $null }
    return [version]$trimmed
}

function Get-RemoteOriginUrl([string]$RepoRoot) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $url = (& git -C $RepoRoot remote get-url origin 2>$null | Out-String).Trim()
    $ErrorActionPreference = $prev
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }
    return $url
}

function Get-GitHubRepoFromOrigin([string]$OriginUrl) {
    if ($OriginUrl -match '^(https://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/]+)/([^/]+?)(\.git)?$') {
        return @{ Owner = $Matches[2]; Repo = $Matches[3] }
    }
    return $null
}

function Get-RemoteTagVersions([string]$RepoRoot) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C $RepoRoot fetch --tags origin 2>$null | Out-Null
    $lines = @(& git -C $RepoRoot ls-remote --tags origin 2>$null)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { throw '无法读取 GitHub 远程 Tag。' }
    $versions = New-Object System.Collections.Generic.List[version]
    foreach ($line in $lines) {
        if ([string]$line -match 'refs/tags/v?(\d+\.\d+\.\d+)(\^\{\})?$') {
            $parsed = Normalize-SemVer $Matches[1]
            if ($null -ne $parsed) { [void]$versions.Add($parsed) }
        }
    }
    return $versions
}

function Get-GitHubCredentialToken {
    $previousInput = [Console]::InputEncoding
    $savedPrompt = $env:GIT_TERMINAL_PROMPT
    $savedGcm = $env:GCM_INTERACTIVE
    $token = $null
    try {
        [Console]::InputEncoding = New-Object Text.UTF8Encoding $false
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git'
        $psi.Arguments = 'credential fill'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $writer = New-Object IO.StreamWriter($proc.StandardInput.BaseStream, (New-Object Text.UTF8Encoding $false))
        $writer.NewLine = "`n"
        $writer.WriteLine('protocol=https')
        $writer.WriteLine('host=github.com')
        $writer.WriteLine('')
        $writer.Flush()
        $writer.Close()
        $outMs = New-Object IO.MemoryStream
        $errCopy = $proc.StandardError.BaseStream.CopyToAsync((New-Object IO.MemoryStream))
        $outCopy = $proc.StandardOutput.BaseStream.CopyToAsync($outMs)
        if (-not $proc.WaitForExit(20000)) {
            try { $proc.Kill() } catch {}
            return $null
        }
        $outCopy.Wait()
        $errCopy.Wait()
        if ($proc.ExitCode -ne 0) { return $null }
        foreach ($line in ([Text.Encoding]::UTF8.GetString($outMs.ToArray()) -split "`n")) {
            if ($line.StartsWith('password=')) { $token = $line.Substring(9).Trim() }
        }
    }
    catch { return $null }
    finally {
        [Console]::InputEncoding = $previousInput
        if ($null -eq $savedPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $savedPrompt }
        if ($null -eq $savedGcm) { Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue } else { $env:GCM_INTERACTIVE = $savedGcm }
    }
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    return $token
}

function Get-GitHubReleaseVersions([string]$Owner, [string]$Repo) {
    $versions = New-Object System.Collections.Generic.List[version]
    $raw = $null
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $raw = & gh api "repos/$Owner/$Repo/releases?per_page=100" 2>$null
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($code -ne 0) { $raw = $null }
    }
    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        $token = Get-GitHubCredentialToken
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw '未找到 gh CLI，且 Git 没有可用的 GitHub 凭据，无法读取 GitHub Release。'
        }
        try {
            $response = Invoke-WebRequest -Uri "https://api.github.com/repos/$Owner/$Repo/releases?per_page=100" -Headers @{
                Authorization = "Bearer $token"
                'User-Agent'  = 'stream-distribution-make-release'
                Accept        = 'application/vnd.github+json'
            } -UseBasicParsing -TimeoutSec 20
            $raw = $response.Content
        }
        catch { throw '无法读取 GitHub Release。' }
        finally { $token = $null }
    }
    $releases = @($raw | ConvertFrom-Json)
    foreach ($release in $releases) {
        $parsed = Normalize-SemVer ([string]$release.tag_name)
        if ($null -ne $parsed) { [void]$versions.Add($parsed) }
    }
    return $versions
}

function Get-LocalTagVersions([string]$RepoRoot) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = @(& git -C $RepoRoot tag --list 'v*' --list '[0-9]*.[0-9]*.[0-9]*' 2>$null)
    $ErrorActionPreference = $prev
    $versions = New-Object System.Collections.Generic.List[version]
    foreach ($line in $lines) {
        $parsed = Normalize-SemVer ([string]$line)
        if ($null -ne $parsed) { [void]$versions.Add($parsed) }
    }
    return $versions
}

function Get-LocalReleaseDirectoryVersions([string]$ReleaseRoot) {
    $versions = New-Object System.Collections.Generic.List[version]
    if ([string]::IsNullOrWhiteSpace($ReleaseRoot) -or -not (Test-Path -LiteralPath $ReleaseRoot)) { return $versions }
    foreach ($dir in @(Get-ChildItem -LiteralPath $ReleaseRoot -Directory -ErrorAction SilentlyContinue)) {
        $parsed = Normalize-SemVer $dir.Name
        if ($null -ne $parsed) { [void]$versions.Add($parsed) }
    }
    return $versions
}

function Get-ProdInstalledVersion([string]$ProdRoot) {
    $versions = New-Object System.Collections.Generic.List[version]
    if ([string]::IsNullOrWhiteSpace($ProdRoot)) { return $versions }
    $path = Join-Path $ProdRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $path)) { return $versions }
    $parsed = Normalize-SemVer (([IO.File]::ReadAllText($path)).Trim())
    if ($null -ne $parsed) { [void]$versions.Add($parsed) }
    return $versions
}

function Resolve-NextReleaseVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [string]$ReleaseRoot = 'E:\01_Work\03_Release\01_Personal\stream-distribution',
        [string]$ProdRoot = 'E:\01_Work\04_Prod\01_Personal\019-StreamDistribution'
    )

    $origin = Get-RemoteOriginUrl $RepoRoot
    if ($null -eq $origin) { throw '没有 origin 远程仓库，无法自动识别版本。' }
    $repo = Get-GitHubRepoFromOrigin $origin
    if ($null -eq $repo) { throw 'origin 不是 GitHub 仓库，无法自动识别版本。' }

    $remoteTags = Get-RemoteTagVersions $RepoRoot
    $releaseVersions = Get-GitHubReleaseVersions $repo.Owner $repo.Repo
    $localTags = Get-LocalTagVersions $RepoRoot
    $localReleaseVersions = Get-LocalReleaseDirectoryVersions $ReleaseRoot
    $prodVersions = Get-ProdInstalledVersion $ProdRoot

    $remoteLatest = $null
    if ($remoteTags.Count -gt 0) { $remoteLatest = ($remoteTags | Sort-Object -Descending | Select-Object -First 1) }
    $releaseLatest = $null
    if ($releaseVersions.Count -gt 0) { $releaseLatest = ($releaseVersions | Sort-Object -Descending | Select-Object -First 1) }
    $localLatest = $null
    if ($localTags.Count -gt 0) { $localLatest = ($localTags | Sort-Object -Descending | Select-Object -First 1) }
    $directoryLatest = $null
    if ($localReleaseVersions.Count -gt 0) { $directoryLatest = ($localReleaseVersions | Sort-Object -Descending | Select-Object -First 1) }
    $prodLatest = $null
    if ($prodVersions.Count -gt 0) { $prodLatest = ($prodVersions | Sort-Object -Descending | Select-Object -First 1) }

    if ($null -ne $remoteLatest -and $null -ne $releaseLatest -and $remoteLatest.ToString() -ne $releaseLatest.ToString()) {
        throw "远程 Tag 最新版本 v$remoteLatest 与 GitHub Release 最新版本 v$releaseLatest 不一致。"
    }
    if ($null -ne $localLatest -and $null -ne $remoteLatest -and $localLatest.ToString() -ne $remoteLatest.ToString()) {
        throw "本地 Tag 最新版本 v$localLatest 落后于远程 Tag v$remoteLatest。请先同步后再制作 Release。"
    }

    $latest = $directoryLatest
    $sourceNames = New-Object System.Collections.Generic.List[string]
    if ($null -ne $directoryLatest) { [void]$sourceNames.Add('本地 Release 目录') }
    if ($null -ne $remoteLatest -and ($null -eq $latest -or $remoteLatest -gt $latest)) { $latest = $remoteLatest }
    if ($null -ne $releaseLatest -and ($null -eq $latest -or $releaseLatest -gt $latest)) { $latest = $releaseLatest }
    if ($null -ne $localLatest -and ($null -eq $latest -or $localLatest -gt $latest)) { $latest = $localLatest }
    if ($null -ne $prodLatest -and ($null -eq $latest -or $prodLatest -gt $latest)) { $latest = $prodLatest }
    if ($null -ne $remoteLatest -or $null -ne $localLatest) { [void]$sourceNames.Add('Git Tag') }
    if ($null -ne $releaseLatest) { [void]$sourceNames.Add('GitHub Release') }
    if ($null -ne $prodLatest) { [void]$sourceNames.Add('正式 Prod') }
    if ($null -eq $latest) {
        $latest = [version]'0.0.0'
        [void]$sourceNames.Add('无历史版本')
    }

    $next = [version]::new($latest.Major, $latest.Minor, $latest.Build + 1)
    return [pscustomobject]@{
        LatestVersion = $latest.ToString()
        NextVersion = $next.ToString()
        VersionSource = ($sourceNames -join ' / ')
    }
}

function Test-ReleaseVersionAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$ReleaseRoot = 'E:\01_Work\03_Release\01_Personal\stream-distribution'
    )
    $normalized = Normalize-SemVer $Version
    if ($null -eq $normalized) { throw "版本号无效：$Version" }
    $label = $normalized.ToString()
    if (Get-LocalTagVersions $RepoRoot | Where-Object { $_.ToString() -eq $label }) { throw "本地已存在版本 v$label。" }
    if (Get-RemoteTagVersions $RepoRoot | Where-Object { $_.ToString() -eq $label }) { throw "远程已存在版本 v$label。" }
    $origin = Get-RemoteOriginUrl $RepoRoot
    $repo = Get-GitHubRepoFromOrigin $origin
    if ($null -ne $repo) {
        if (Get-GitHubReleaseVersions $repo.Owner $repo.Repo | Where-Object { $_.ToString() -eq $label }) {
            throw "GitHub Release 已存在版本 v$label。"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $ReleaseRoot $label)) { throw "Release 目录已存在：$(Join-Path $ReleaseRoot $label)" }
}
