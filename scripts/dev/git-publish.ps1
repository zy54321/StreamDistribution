# Commit reviewed files and push the current branch with a normal git push.
# Double-click entry: 01_提交GitHub.bat. Refuses force push, pull, rebase, and empty commits.
# Adapted from myLedger: same confirmations, plus this project's secret paths.

param(
    [string]$RepoRoot = '',
    [string]$CommitMessage = '',
    [string]$ConfirmCommit = '',
    [string]$ConfirmPush = '',
    [string]$ConfirmPublic = '',
    [string]$VisibilityOverride = '',
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'confirm-yn.ps1')

function Fail([string]$Message) {
    Write-Host "[GitHub] 失败：$Message"
    exit 1
}

function Say([string]$Message) {
    Write-Host "[GitHub] $Message"
}

function ConvertTo-GitArgumentLine([string[]]$Items) {
    return (($Items | ForEach-Object {
                if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
            }) -join ' ')
}

function Invoke-GitRaw([string[]]$ArgumentList) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ConvertTo-GitArgumentLine (@('-c', 'core.quotepath=false', '-c', 'i18n.logOutputEncoding=utf-8', '-C', $RepoRoot) + $ArgumentList)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outMs = New-Object IO.MemoryStream
    $errMs = New-Object IO.MemoryStream
    $outCopy = $proc.StandardOutput.BaseStream.CopyToAsync($outMs)
    $errCopy = $proc.StandardError.BaseStream.CopyToAsync($errMs)
    [void]$proc.WaitForExit()
    try { [void]$outCopy.Wait(5000) } catch {}
    try { [void]$errCopy.Wait(5000) } catch {}
    $bytes = $outMs.ToArray()
    $code = 1
    try { if ($proc.HasExited) { $code = $proc.ExitCode } } catch { $code = 1 }
    return @{ Code = $code; Text = [Text.Encoding]::UTF8.GetString($bytes); Bytes = $bytes }
}

function Split-GitNul([string]$Text) {
    $list = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($Text)) {
        foreach ($part in $Text.Split([char]0)) {
            if (-not [string]::IsNullOrEmpty($part)) { [void]$list.Add($part) }
        }
    }
    Write-Output -NoEnumerate $list
}

function Test-SensitivePath([string]$Relative) {
    $normalized = ($Relative -replace '\\', '/').TrimStart('./')
    $name = Split-Path -Leaf ($normalized -replace '/', '\')
    if ($name -eq '.env' -or $name -eq '.env.compose') { return $true }
    if ($name -like '.env.*' -and $name -notlike '*.example') { return $true }
    if ($normalized -eq 'config/channels.yaml') { return $true }
    if ($normalized -match '(^|/)(\.venv|venv|__pycache__|\.git|secrets|backups)(/|$)') { return $true }
    if ($name -match '(?i)\.(pem|p12|pfx|key|pyc)$') { return $true }
    if ($name -match '(?i)^(id_rsa|id_ed25519)$') { return $true }
    return $false
}

function Test-SensitiveBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes) { return $false }
    if ($Bytes.Length -gt 5MB) { return $true }
    $sample = [Text.Encoding]::GetEncoding(28591).GetString($Bytes)
    if ($sample -match 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY') { return $true }
    if ($sample -match 'AKIA[0-9A-Z]{16}') { return $true }
    return $false
}

function Assert-GitIgnore {
    $path = Join-Path $RepoRoot '.gitignore'
    if (-not (Test-Path -LiteralPath $path)) { Fail '.gitignore 不存在。没有创建提交。' }
    $rules = New-Object System.Collections.Generic.HashSet[string]
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -gt 0 -and -not $trimmed.StartsWith('#')) { [void]$rules.Add($trimmed) }
    }
    foreach ($required in @('.env', '.venv/', 'venv/', '__pycache__/', 'config/channels.yaml')) {
        if (-not $rules.Contains($required)) {
            Fail ".gitignore 没有忽略 $required。没有创建提交。"
        }
    }
    Say '.gitignore 已覆盖 .env、config/channels.yaml、.venv 与 __pycache__。'
}

function Test-Ignored([string]$Relative) {
    $result = Invoke-GitRaw @('check-ignore', '-q', '--', $Relative)
    return $result.Code -eq 0
}

function Get-FullPath([string]$Relative) {
    return Join-Path $RepoRoot (($Relative -replace '/', '\').TrimStart('\'))
}

function Expand-WorktreeFiles([string]$Relative) {
    $list = New-Object System.Collections.Generic.List[string]
    $full = Get-FullPath $Relative
    if ((Test-Path -LiteralPath $full) -and (Get-Item -LiteralPath $full).PSIsContainer) {
        foreach ($file in @(Get-ChildItem -LiteralPath $full -Recurse -File -Force)) {
            [void]$list.Add($file.FullName.Substring($RepoRoot.Length).TrimStart('\') -replace '\\', '/')
        }
        if ($list.Count -eq 0) { Fail "未跟踪目录里没有具体文件，不能按目录添加：$Relative" }
        Write-Output -NoEnumerate $list
        return
    }
    [void]$list.Add($Relative)
    Write-Output -NoEnumerate $list
}

function Get-ObjectBytes([string]$Object) {
    $sizeResult = Invoke-GitRaw @('cat-file', '-s', $Object)
    if ($sizeResult.Code -ne 0) { return $null }
    $size = [int64]$sizeResult.Text.Trim()
    if ($size -gt 5MB) { return @{ TooBig = $true; Size = $size; Bytes = $null } }
    $result = Invoke-GitRaw @('cat-file', '-p', $Object)
    if ($result.Code -ne 0) { return $null }
    return @{ TooBig = $false; Size = $size; Bytes = $result.Bytes }
}

function Convert-GitHubVisibility($Payload) {
    if ($null -eq $Payload) { return 'unknown' }
    $visibility = ([string]$Payload.visibility).Trim().ToLower()
    if ($Payload.private -eq $true -and $visibility -eq 'private') { return 'private' }
    if ($Payload.private -eq $false -and $visibility -eq 'public') { return 'public' }
    return 'unknown'
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
        $errMs = New-Object IO.MemoryStream
        $outCopy = $proc.StandardOutput.BaseStream.CopyToAsync($outMs)
        $errCopy = $proc.StandardError.BaseStream.CopyToAsync($errMs)
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

function Get-AuthenticatedGitHubPayload([string]$Owner, [string]$Repo) {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        $raw = & gh api "repos/$Owner/$Repo" 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$raw)) {
            try { return ($raw | ConvertFrom-Json) } catch { return $null }
        }
    }
    $token = Get-GitHubCredentialToken
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    try {
        $response = Invoke-WebRequest -Uri ('https://api.github.com/repos/{0}/{1}' -f $Owner, $Repo) -Headers @{
            Authorization = "Bearer $token"
            'User-Agent'  = 'stream-distribution-git-publish'
            Accept        = 'application/vnd.github+json'
        } -UseBasicParsing -TimeoutSec 20
        return ($response.Content | ConvertFrom-Json)
    }
    catch { return $null }
    finally { $token = $null }
}

function Get-RemoteVisibility([string]$Url) {
    if ($Url -match '^(https://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/]+)/([^/]+?)(\.git)?$') {
        return Convert-GitHubVisibility (Get-AuthenticatedGitHubPayload $Matches[2] $Matches[3])
    }
    if ($Url -match '^(https?://|ssh://|git@)') { return 'unknown' }
    if (-not [string]::IsNullOrWhiteSpace($VisibilityOverride)) { return $VisibilityOverride.Trim().ToLower() }
    if ($Url -match '^[A-Za-z]:\\' -or $Url -match '^\\\\' -or $Url -match '^/' -or $Url -match '^file://') { return 'local' }
    return 'unknown'
}

function Assert-TrackedSecrets {
    $tracked = Invoke-GitRaw @('ls-files', '--', '.env', 'config/channels.yaml', '.venv', 'venv')
    if ($tracked.Code -ne 0) { Fail '无法核对已跟踪文件。没有创建提交。' }
    foreach ($line in ($tracked.Text -split "`n")) {
        $path = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($path)) { Fail "敏感路径已被 Git 跟踪：$path。没有创建提交。" }
    }
}

Say '从当前开发目录检查、提交并推送。'
Say '不会强推，不会自动 pull 或 rebase。'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Assert-GitIgnore

$inside = Invoke-GitRaw @('rev-parse', '--is-inside-work-tree')
if ($inside.Code -ne 0) { Fail '这里不是可用的 Git 仓库。没有写入。' }
$headResult = Invoke-GitRaw @('rev-parse', 'HEAD')
$hasHead = $headResult.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($headResult.Text.Trim())
if ($hasHead) {
    $head = $headResult.Text.Trim()
    $branch = (Invoke-GitRaw @('rev-parse', '--abbrev-ref', 'HEAD')).Text.Trim()
}
else {
    $head = ''
    $branch = (Invoke-GitRaw @('symbolic-ref', '--short', 'HEAD')).Text.Trim()
}
if ($branch -eq 'HEAD' -or [string]::IsNullOrWhiteSpace($branch)) { Fail '当前处于游离 HEAD，已停止。' }

Say "仓库：$RepoRoot"
Say "分支：$branch"
if ($hasHead) { Say "本地修订：$head" } else { Say '本地还没有提交。这次会创建首次提交。' }
Assert-TrackedSecrets

$remoteNames = Split-GitNul ((Invoke-GitRaw @('remote')).Text.Replace("`n", [char]0).Replace("`r", ''))
if (-not $remoteNames.Contains('origin')) { Fail '没有名为 origin 的 GitHub 远程仓库。已停止，没有创建提交。' }
$remoteUrl = (Invoke-GitRaw @('remote', 'get-url', 'origin')).Text.Trim()
$displayUrl = $remoteUrl -replace '://[^/\s@]+@', '://***@'
Say "远程 origin：$displayUrl"
$visibility = Get-RemoteVisibility $remoteUrl
$visibilityLabel = switch ($visibility) {
    'private' { '私有' }
    'public' { '公开' }
    'local' { '本地' }
    default { '无法确认' }
}
Say "仓库可见性：$visibilityLabel"
if ($visibility -eq 'unknown') { Fail '无法确认远程仓库是否公开。已停止，没有创建提交。' }

Say '正在读取远程分支状态。'
$remoteLines = Invoke-GitRaw @('ls-remote', '--heads', 'origin', "refs/heads/$branch")
if ($remoteLines.Code -ne 0) { Fail '无法读取 GitHub 远程状态。已停止，没有创建提交。' }
$remoteSha = ''
foreach ($line in ($remoteLines.Text -split "`n")) {
    if ($line -match '^([0-9a-f]{40})\s+') { $remoteSha = $Matches[1] }
}
if ([string]::IsNullOrWhiteSpace($remoteSha)) {
    Say "远程还没有 $branch 分支。这不是分叉，推送时不会使用 --force。"
}
elseif (-not $hasHead) {
    Fail '远程分支已有提交，本地还没有。不会自动 pull。请先由 Owner 处理后再运行。'
}
else {
    $fetch = Invoke-GitRaw @('fetch', 'origin', $branch, '--quiet')
    if ($fetch.Code -ne 0) { Fail '无法获取远程修订。已停止，没有合并，也没有创建提交。' }
    $remoteIsAncestor = (Invoke-GitRaw @('merge-base', '--is-ancestor', $remoteSha, 'HEAD')).Code -eq 0
    $localIsAncestor = (Invoke-GitRaw @('merge-base', '--is-ancestor', 'HEAD', $remoteSha)).Code -eq 0
    if (-not $remoteIsAncestor -and -not $localIsAncestor) {
        Fail '本地和远程历史已经分叉。不会自动合并、pull 或 rebase。'
    }
    if ($localIsAncestor -and $remoteSha -ne $head) {
        Fail '远程分支比本地更新。不会自动 pull。请先由 Owner 处理后再运行。'
    }
    Say "远程修订：$remoteSha"
}

$status = Invoke-GitRaw @('status', '--porcelain=v1', '-z', '--untracked-files=all')
if ($status.Code -ne 0) { Fail '无法读取工作区文件清单。没有创建提交。' }
$records = Split-GitNul $status.Text
$candidates = New-Object System.Collections.Generic.List[string]
$renameFrom = @{}
for ($i = 0; $i -lt $records.Count; $i++) {
    $entry = [string]$records[$i]
    if ($entry.Length -lt 4) { continue }
    $xy = $entry.Substring(0, 2)
    if ($xy -match 'U' -or $xy -eq 'AA' -or $xy -eq 'DD') { Fail '存在未合并冲突。不会自动处理。没有创建提交。' }
    $isRename = $xy[0] -eq [char]'R' -or $xy[0] -eq [char]'C' -or $xy[1] -eq [char]'R' -or $xy[1] -eq [char]'C'
    $newPath = $entry.Substring(3)
    if ($isRename) {
        $i++
        if ($i -ge $records.Count -or [string]::IsNullOrWhiteSpace([string]$records[$i])) {
            Fail '无法识别重命名来源。没有创建提交。'
        }
        $renameFrom[$newPath] = [string]$records[$i]
    }
    foreach ($file in (Expand-WorktreeFiles $newPath)) {
        if (-not $candidates.Contains($file)) { [void]$candidates.Add($file) }
    }
}

$ahead = 0
if (-not $hasHead) {
    $ahead = 0
}
elseif (-not [string]::IsNullOrWhiteSpace($remoteSha)) {
    $ahead = [int]((Invoke-GitRaw @('rev-list', '--count', "$remoteSha..HEAD")).Text.Trim())
}
elseif ($remoteLines.Code -eq 0) {
    $ahead = [int]((Invoke-GitRaw @('rev-list', '--count', 'HEAD')).Text.Trim())
}
if ($candidates.Count -eq 0 -and $ahead -eq 0) {
    Say '没有需要提交或推送的内容。没有创建空提交。'
    exit 0
}

$toAdd = New-Object System.Collections.Generic.List[string]
if ($candidates.Count -gt 0) {
    Say '计划纳入提交的文件：'
    foreach ($path in $candidates) {
        if (Test-Ignored $path) {
            Say " - $path （已忽略，不会添加）"
            continue
        }
        if ($renameFrom.ContainsKey($path)) { Say " - $path （重命名自 $($renameFrom[$path])）" } else { Say " - $path" }
        [void]$toAdd.Add($path)
        if (Test-SensitivePath $path) { Fail "敏感文件不能提交：$path" }
        $full = Get-FullPath $path
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full
            if ($item.PSIsContainer) { Fail "仍然是目录，不能整目录添加：$path" }
            if ($item.Length -gt 5MB) { Fail "文件超过 5MB，已停止：$path" }
            if (Test-SensitiveBytes ([IO.File]::ReadAllBytes($full))) { Fail "文件内容含有密钥特征，已停止：$path" }
        }
    }
}
else {
    Say '工作区没有新的文件变更。'
}
if ($toAdd.Count -eq 0 -and $ahead -eq 0) {
    Say '没有需要提交或推送的内容。没有创建空提交。'
    exit 0
}
Say "尚未推送的本地提交数：$ahead"

if ($toAdd.Count -gt 0) {
    $authorName = (Invoke-GitRaw @('config', '--get', 'user.name')).Text.Trim()
    $authorEmail = (Invoke-GitRaw @('config', '--get', 'user.email')).Text.Trim()
    if ([string]::IsNullOrWhiteSpace($authorName) -or [string]::IsNullOrWhiteSpace($authorEmail)) {
        Fail "Git 还没有提交身份（user.name / user.email）。没有创建提交。请先设置后再运行。"
    }
}

$script:CommittedThisRun = $false
if ($visibility -eq 'public') {
    Say '警告：origin 是公开的 GitHub 仓库。继续会把当前分支的全部历史公开到互联网。'
    $publicOk = $false
    if (-not $NonInteractive) { $publicOk = Confirm-YesNo -Prompt 'YES-PUBLIC-PUSH (Y/N):' }
    else { $publicOk = Test-YesAnswer -Answer $ConfirmPublic -LegacyAccepted @('YES-PUBLIC-PUSH') }
    if (-not $publicOk) {
        Say '已取消。公开仓库没有得到明确确认。没有创建提交，也没有推送。'
        exit 0
    }
}

if ($toAdd.Count -gt 0) {
    $commitOk = $false
    if (-not $NonInteractive) {
        $CommitMessage = Read-Host '请输入提交说明'
        $commitOk = Confirm-YesNo -Prompt 'YES-COMMIT (Y/N):'
    }
    else { $commitOk = Test-YesAnswer -Answer $ConfirmCommit -LegacyAccepted @('YES-COMMIT') }
    if ([string]::IsNullOrWhiteSpace($CommitMessage)) { Fail '提交说明为空。没有创建提交。' }
    if (-not $commitOk) {
        Say '已取消。没有创建提交，也没有推送。'
        exit 0
    }
    Say '正在提交已列出的文件。'
    $add = Invoke-GitRaw (@('add', '--') + @($toAdd.ToArray()))
    if ($add.Code -ne 0) { Fail 'git add 失败。没有推送。' }
    $staged = Split-GitNul ((Invoke-GitRaw @('diff', '--cached', '--name-only', '-z')).Text)
    if ($staged.Count -eq 0) { Fail '暂存区没有文件。没有创建提交。' }
    foreach ($path in $staged) {
        if (Test-SensitivePath $path) { Fail "暂存区出现敏感文件，已停止提交：$path" }
        if (Test-Ignored $path) { Fail "暂存区包含已被忽略的文件，已停止提交：$path" }
        $blob = Get-ObjectBytes (':' + $path)
        if ($null -eq $blob) { continue }
        if ($blob.TooBig) { Fail "暂存内容超过 5MB，已停止：$path" }
        if (Test-SensitiveBytes $blob.Bytes) { Fail "暂存区含有密钥特征，已停止提交：$path" }
    }
    $commit = Invoke-GitRaw @('commit', '-m', $CommitMessage)
    if ($commit.Code -ne 0) { Fail 'git commit 失败。没有推送。' }
    $head = (Invoke-GitRaw @('rev-parse', 'HEAD')).Text.Trim()
    $script:CommittedThisRun = $true
    Say "本地提交已创建：$head"
}

if (-not [string]::IsNullOrWhiteSpace($remoteSha)) {
    $ahead = [int]((Invoke-GitRaw @('rev-list', '--count', "$remoteSha..HEAD")).Text.Trim())
    $commits = Split-GitNul (((Invoke-GitRaw @('rev-list', '--reverse', "$remoteSha..HEAD")).Text.Replace("`n", [char]0)))
}
else {
    $ahead = [int]((Invoke-GitRaw @('rev-list', '--count', 'HEAD')).Text.Trim())
    $commits = Split-GitNul (((Invoke-GitRaw @('rev-list', '--reverse', 'HEAD')).Text.Replace("`n", [char]0)))
}
if ($ahead -gt 0) {
    Say ("即将审查未推送的 " + $commits.Count + " 个提交。")
    foreach ($commitId in $commits) {
        if ($commitId -notmatch '^[0-9a-f]{40}$') { continue }
        $names = Invoke-GitRaw @('diff-tree', '-r', '--diff-filter=ACMRT', '--name-only', '--no-commit-id', '--root', $commitId)
        if ($names.Code -ne 0) { Fail '无法读取提交中的文件清单。没有推送。' }
        foreach ($path in ($names.Text -split "`n")) {
            $relative = $path.Trim()
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            if (Test-SensitivePath $relative) { Fail "即将推送的历史包含敏感文件：$relative。没有推送。" }
            $blob = Get-ObjectBytes ($commitId + ':' + $relative)
            if ($null -eq $blob) { Fail "无法读取即将推送的文件内容：$relative。没有推送。" }
            if ($blob.TooBig) { Fail "即将推送的历史包含超过 5MB 的文件：$relative。没有推送。" }
            if (Test-SensitiveBytes $blob.Bytes) { Fail "即将推送的历史包含敏感内容：$relative。没有推送。" }
        }
    }
    Say '历史审查完成。确认推送仍需要 YES-PUSH。'
}

if (-not $NonInteractive) {
    if (-not (Confirm-YesNo -Prompt 'YES-PUSH (Y/N):')) {
        if ($script:CommittedThisRun) {
            Say '本地已提交，远程未更新。'
            exit 2
        }
        Say '已取消推送。远程未更新。'
        exit 0
    }
}
elseif (-not (Test-YesAnswer -Answer $ConfirmPush -LegacyAccepted @('YES-PUSH'))) {
    if ($script:CommittedThisRun) {
        Say '本地已提交，远程未更新。'
        exit 2
    }
    Say '已取消推送。远程未更新。'
    exit 0
}

Say "正在推送 origin $branch。不会使用 --force。"
$push = Invoke-GitRaw @('push', 'origin', "HEAD:refs/heads/$branch")
$head = (Invoke-GitRaw @('rev-parse', 'HEAD')).Text.Trim()
if ($push.Code -ne 0) {
    Say "本地修订：$head"
    Fail '本地已提交或本地修订仍在，远程未更新。'
}
Say "推送完成。本地修订：$head"
Say "远程分支：origin/$branch"
exit 0
