# Build an official source release only from a clean revision that matches GitHub.
# Double-click entry: 02_制作Release.bat. Does not deploy Prod.

param(
    [string]$Version = '',
    [string]$ConfirmRelease = '',
    [switch]$NonInteractive,
    [switch]$PreconditionsOnly,
    [string]$RepoRoot = '',
    [string]$ReleaseRoot = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = 'E:\01_Work\03_Release\01_Personal\stream-distribution'
}

function Fail([string]$Message) {
    Write-Host "[Release] 失败：$Message"
    exit 1
}

function Say([string]$Message) {
    Write-Host "[Release] $Message"
}

Say '从当前开发目录制作正式 Release。'
Say '不会安装或升级 Prod。'

. (Join-Path $PSScriptRoot 'confirm-yn.ps1')
. (Join-Path $RepoRoot 'scripts\release\resolve-release-version.ps1')

$ignorePath = Join-Path $RepoRoot '.gitignore'
if (-not (Test-Path -LiteralPath $ignorePath)) { Fail '.gitignore 不存在。没有创建版本目录。' }
$rules = New-Object System.Collections.Generic.HashSet[string]
foreach ($line in [IO.File]::ReadAllLines($ignorePath)) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -gt 0 -and -not $trimmed.StartsWith('#')) { [void]$rules.Add($trimmed) }
}
foreach ($required in @('.env', '.venv/', '__pycache__/', 'config/channels.yaml')) {
    if (-not $rules.Contains($required)) { Fail ".gitignore 没有忽略 $required。没有创建版本目录。" }
}

$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$headText = @(& git -C $RepoRoot rev-parse HEAD 2>$null)
$headCode = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($headCode -ne 0 -or $headText.Count -eq 0) { Fail '没有 Git 修订，不能制作正式 Release。没有创建版本目录。' }
$head = ([string]$headText[0]).Trim()
$branch = ((& git -C $RepoRoot rev-parse --abbrev-ref HEAD) | Out-String).Trim()
$dirty = @(& git -C $RepoRoot status --porcelain)
if ($dirty.Count -gt 0) { Fail '工作区有未提交的修改。不能从未提交的内容制作正式 Release。' }

$remotes = @(& git -C $RepoRoot remote)
if ($remotes -notcontains 'origin') { Fail '没有 GitHub 远程仓库，修订尚未被远程确认。没有创建版本目录。' }
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$remoteLines = @(& git -C $RepoRoot ls-remote --heads origin "refs/heads/$branch" 2>&1)
$remoteCode = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($remoteCode -ne 0) { Fail '无法确认 GitHub 上的修订。没有创建版本目录。' }
$remoteSha = ''
foreach ($line in $remoteLines) {
    if ([string]$line -match '^([0-9a-f]{40})\s+') { $remoteSha = $Matches[1] }
}
if ($remoteSha -ne $head) { Fail "本地修订 $head 与 GitHub 分支 $branch 的修订不一致。没有创建版本目录。" }

$versionInfo = $null
if ([string]::IsNullOrWhiteSpace($Version)) {
    try {
        $versionInfo = Resolve-NextReleaseVersion -RepoRoot $RepoRoot -ReleaseRoot $ReleaseRoot
        $Version = $versionInfo.NextVersion
    }
    catch { Fail $_.Exception.Message }
}
elseif ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "版本号必须是 X.Y.Z。当前：$Version" }

try { Test-ReleaseVersionAvailable -RepoRoot $RepoRoot -Version $Version -ReleaseRoot $ReleaseRoot }
catch { Fail $_.Exception.Message }

if ($null -eq $versionInfo) {
    try { $versionInfo = Resolve-NextReleaseVersion -RepoRoot $RepoRoot -ReleaseRoot $ReleaseRoot }
    catch {
        $versionInfo = [pscustomobject]@{ LatestVersion = '未知'; NextVersion = $Version; VersionSource = '参数指定' }
    }
}

Write-Host '================================'
Write-Host 'Stream Distribution Release'
Write-Host '================================'
Write-Host ''
Write-Host ("当前最新发布版本：v{0}" -f $versionInfo.LatestVersion)
Write-Host ("本次计划发布版本：v{0}" -f $Version)
Write-Host ("版本来源：{0}" -f $versionInfo.VersionSource)
Write-Host '版本检查：通过'
Write-Host '重复版本检查：通过'
Write-Host ''
Write-Host '即将开始制作 Release。'
Write-Host ''

$target = Join-Path $ReleaseRoot $Version
Say "版本：$Version"
Say "分支：$branch"
Say "Git 修订：$head"
Say "目标目录：$target"
Say '影响范围：只打包正式 Release，不会安装或升级 Prod。'
Say '打包会排除 .venv、__pycache__、.git、.env、config/channels.yaml。'

if (-not $NonInteractive) {
    if (-not (Confirm-YesNo -Prompt 'YES-RELEASE (Y/N):')) {
        Say '已取消。没有创建版本目录。'
        exit 0
    }
}
elseif (-not (Test-YesAnswer -Answer $ConfirmRelease -LegacyAccepted @("YES-RELEASE $Version"))) {
    Say '已取消。没有创建版本目录。'
    exit 0
}

if ($PreconditionsOnly) {
    Say '预检查通过。按测试模式停止，没有创建版本目录。'
    exit 0
}

try { Test-ReleaseVersionAvailable -RepoRoot $RepoRoot -Version $Version -ReleaseRoot $ReleaseRoot }
catch { Fail $_.Exception.Message }

Say '正在检查 Python 语法。'
$python = Join-Path $RepoRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { $python = 'python' }
$savedBytecode = $env:PYTHONDONTWRITEBYTECODE
$env:PYTHONDONTWRITEBYTECODE = '1'
& $python -m compileall -q -f (Join-Path $RepoRoot 'app')
$compileCode = $LASTEXITCODE
if ($null -eq $savedBytecode) { Remove-Item Env:PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue } else { $env:PYTHONDONTWRITEBYTECODE = $savedBytecode }
if ($compileCode -ne 0) { Fail 'Python 语法检查失败。没有创建版本目录。' }

Say '正在打包正式 Release。'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\release\package-release.ps1') -Version $Version
if ($LASTEXITCODE -ne 0) { Fail '打包失败。失败目录不会被记成成功发布。' }
if (-not (Test-Path -LiteralPath $target)) { Fail '打包程序没有留下版本目录。' }

$manifest = Get-Content -LiteralPath (Join-Path $target 'RELEASE-MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$manifest.version -ne $Version -or [string]$manifest.gitRevision -ne $head -or [string]$manifest.releaseStatus -ne 'official') {
    Fail 'Manifest 与当前版本或 Git 修订不一致。'
}
$packedSecrets = @(Get-ChildItem -LiteralPath $target -Recurse -Force | Where-Object {
        $_.Name -eq '.env' -or $_.Name -eq 'channels.yaml' -or $_.Name -eq '.venv' -or $_.Name -eq '__pycache__' -or $_.Name -eq '.git'
    })
if ($packedSecrets.Count -gt 0) { Fail '版本目录里出现了被排除的敏感或本地路径。' }
Say "正式 Release 已完成：$target"
Say "版本 $Version ，修订 $head 。没有部署 Prod。"
exit 0
