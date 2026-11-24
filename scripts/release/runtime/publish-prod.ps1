# Deploy the release directory that contains this script to the existing Prod tree.
# Does not replace .env, config/channels.yaml, or docker-compose.yml.
# Rebuilds only the stream-distribution-prod compose project.

param(
    [string]$ReleaseRoot = '',
    [string]$ProdRoot = '',
    [string]$ConfirmUpgrade = '',
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$confirmYn = Join-Path $PSScriptRoot 'confirm-yn.ps1'
if (-not (Test-Path -LiteralPath $confirmYn)) {
    $confirmYn = Join-Path $PSScriptRoot '..\..\dev\confirm-yn.ps1'
}
. $confirmYn

$RealProd = 'E:\01_Work\04_Prod\01_Personal\019-StreamDistribution'
$ContainerName = 'stream-distribution-prod'
$script:Snapshot = $null

function Fail([string]$Message) {
    Write-Host "[Prod] 失败：$Message"
    exit 1
}

function Say([string]$Message) {
    Write-Host "[Prod] $Message"
}

function Test-DevCopy {
    $full = [IO.Path]::GetFullPath($PSScriptRoot)
    return $full -like '*\01_PersonalProjects\019-StreamDistribution\*'
}

function Get-ShaOrMissing([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'MISSING' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Get-ProtectedMap([string]$Root) {
    return @{
        '.env' = Get-ShaOrMissing (Join-Path $Root '.env')
        'config\channels.yaml' = Get-ShaOrMissing (Join-Path $Root 'config\channels.yaml')
        'docker-compose.yml' = Get-ShaOrMissing (Join-Path $Root 'docker-compose.yml')
    }
}

function Assert-Protected([hashtable]$Before, [hashtable]$After) {
    foreach ($name in @($Before.Keys)) {
        if ($Before[$name] -ne $After[$name]) { return $name }
    }
    return $null
}

function Get-ForeignContainerIds {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $rows = @(& docker ps -a --no-trunc --format '{{.ID}} {{.Names}}' 2>$null)
    $ErrorActionPreference = $prev
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($row in $rows) {
        $text = [string]$row
        if ($text -match '^([0-9a-f]+) (.+)$' -and $Matches[2] -ne $ContainerName) {
            [void]$ids.Add($Matches[1])
        }
    }
    return $ids
}

function Save-Snapshot([string]$Source) {
    $dest = Join-Path ([IO.Path]::GetTempPath()) ('stream-distribution-prod-snap-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    & robocopy $Source $dest /E /NFL /NDL /NJH /NJS /nc /ns /np /XD .git .venv venv __pycache__
    if ($LASTEXITCODE -ge 8) { throw '无法保存 Prod 回退快照。没有修改 Prod。' }
    $script:Snapshot = $dest
}

function Restore-Snapshot {
    if ([string]::IsNullOrWhiteSpace($script:Snapshot) -or -not (Test-Path -LiteralPath $script:Snapshot)) {
        Say '没有可恢复的 Prod 快照。没有删除数据卷。'
        return
    }
    & robocopy $script:Snapshot $ProdRoot /E /NFL /NDL /NJH /NJS /nc /ns /np /XD .git .venv venv __pycache__
    if ($LASTEXITCODE -ge 8) { Say '回退复制没有完成。没有删除数据卷。' }
    else { Say '已恢复升级前的 Prod 文件。密钥、渠道配置和 compose 仍是原文件。' }
}

function Clear-Snapshot {
    if (-not [string]::IsNullOrWhiteSpace($script:Snapshot) -and (Test-Path -LiteralPath $script:Snapshot)) {
        Remove-Item -LiteralPath $script:Snapshot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:Snapshot = $null
}

function Invoke-ProdCompose([string[]]$ArgumentList) {
    & docker compose -p $ContainerName --project-directory $ProdRoot -f (Join-Path $ProdRoot 'docker-compose.yml') @ArgumentList
    $script:ComposeCode = $LASTEXITCODE
}

Say '使用当前 Release 目录升级正式 Prod。'
Say "目标：$RealProd"
Say '不会覆盖 .env、config/channels.yaml、docker-compose.yml，也不会操作其他业务容器。'

if (Test-DevCopy) {
    Fail '这是开发目录中的副本，不是正式 Release 包。没有修改 Prod。'
}
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$ReleaseRoot = [IO.Path]::GetFullPath($ReleaseRoot)
if ([string]::IsNullOrWhiteSpace($ProdRoot)) { $ProdRoot = $RealProd }
$ProdRoot = [IO.Path]::GetFullPath($ProdRoot)
if ($ProdRoot.TrimEnd('\') -ne $RealProd) { Fail '正式入口只能升级既定 Prod 目录。没有写入。' }
if ($ReleaseRoot.TrimEnd('\') -eq $ProdRoot.TrimEnd('\')) { Fail 'Release 目录不能就是 Prod 目录。没有写入。' }

$versionPath = Join-Path $ReleaseRoot 'VERSION'
$manifestPath = Join-Path $ReleaseRoot 'RELEASE-MANIFEST.json'
if (-not (Test-Path -LiteralPath $versionPath) -or -not (Test-Path -LiteralPath $manifestPath)) {
    Fail '当前目录不是正式 Release 包。没有修改 Prod。'
}
$version = ([IO.File]::ReadAllText($versionPath)).Trim()
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$manifest.version -ne $version -or [string]$manifest.releaseStatus -ne 'official') {
    Fail 'Release 版本或身份不正确。没有修改 Prod。'
}
if (-not (Test-Path -LiteralPath $ProdRoot)) { Fail '正式 Prod 尚不存在。本入口只升级已有 Prod，不会新建生产目录。' }

$forbidden = @(Get-ChildItem -LiteralPath $ReleaseRoot -Recurse -Force | Where-Object {
        $_.Name -eq '.env' -or $_.Name -eq 'channels.yaml' -or $_.Name -eq '.venv' -or $_.Name -eq '.git'
    })
if ($forbidden.Count -gt 0) { Fail 'Release 包含有密钥、渠道配置或本地目录。没有修改 Prod。' }

$currentPath = Join-Path $ProdRoot 'VERSION'
$currentVersion = '0.0.0'
if (Test-Path -LiteralPath $currentPath) { $currentVersion = ([IO.File]::ReadAllText($currentPath)).Trim() }
if ($version -notmatch '^\d+\.\d+\.\d+$' -or $currentVersion -notmatch '^\d+\.\d+\.\d+$') {
    Fail '版本号无法比较。没有修改 Prod。'
}
if ([version]$version -eq [version]$currentVersion -and (Test-Path -LiteralPath $currentPath)) {
    Fail "正式环境已经是 $currentVersion，拒绝重复部署。"
}
if ((Test-Path -LiteralPath $currentPath) -and [version]$version -lt [version]$currentVersion) {
    Fail '目标版本低于当前 Prod，拒绝降级。'
}

Say "当前 Prod：$currentVersion"
Say "目标 Release：$version"
Say "Git 修订：$($manifest.gitRevision)"
Say '影响范围：把 Release 源码同步到正式目录后，只重建 stream-distribution-prod。'

if (-not $NonInteractive) {
    if (-not (Confirm-YesNo -Prompt 'YES-UPGRADE (Y/N):')) {
        Say '已取消。没有复制文件，也没有重建容器。'
        exit 0
    }
}
elseif (-not (Test-YesAnswer -Answer $ConfirmUpgrade -LegacyAccepted @("YES-UPGRADE $version"))) {
    Say '已取消。没有复制文件，也没有重建容器。'
    exit 0
}

$protectedBefore = Get-ProtectedMap $ProdRoot
foreach ($name in @('.env', 'config\channels.yaml', 'docker-compose.yml')) {
    if ($protectedBefore[$name] -eq 'MISSING') { Fail "正式 Prod 缺少 $name。没有修改。" }
}
$foreignBefore = @(Get-ForeignContainerIds)
try {
    Save-Snapshot $ProdRoot
    Say '正在同步 Release，并跳过受保护文件。'
    & robocopy $ReleaseRoot $ProdRoot /E /NFL /NDL /NJH /NJS /nc /ns /np /XD .git .venv venv __pycache__ /XF .env channels.yaml docker-compose.yml SHA256SUMS RELEASE-MANIFEST.json '03_发布Prod.bat' publish-prod.ps1 confirm-yn.ps1
    if ($LASTEXITCODE -ge 8) { throw '文件同步失败' }
    $changed = Assert-Protected $protectedBefore (Get-ProtectedMap $ProdRoot)
    if ($changed) { throw "受保护文件被改动：$changed" }

    Say '正在只重建 stream-distribution-prod。'
    Invoke-ProdCompose @('up', '-d', '--build')
    if ($script:ComposeCode -ne 0) { throw '容器重建失败' }

    $healthy = $false
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8092/api/health' -TimeoutSec 5
            if ([string]$health.status -eq 'ok') { $healthy = $true; break }
        }
        catch {}
        Start-Sleep -Seconds 1
    }
    if (-not $healthy) { throw '健康检查没有返回 {"status":"ok"}' }

    $changed = Assert-Protected $protectedBefore (Get-ProtectedMap $ProdRoot)
    if ($changed) { throw "重建后受保护文件被改动：$changed" }
    $foreignAfter = @(Get-ForeignContainerIds)
    foreach ($id in $foreignBefore) {
        if ($foreignAfter -notcontains $id) { throw "其他容器发生变化：$id。本脚本没有再操作它们。" }
    }
    Say "升级流程完成。当前版本 $version 。http://127.0.0.1:8092/api/health 返回 status=ok。"
}
catch {
    Restore-Snapshot
    $restored = Assert-Protected $protectedBefore (Get-ProtectedMap $ProdRoot)
    if ($restored) { Say "受保护文件核对失败：$restored" }
    try { Invoke-ProdCompose @('up', '-d', '--build') } catch {}
    Fail $_.Exception.Message
}
finally {
    Clear-Snapshot
}
exit 0
