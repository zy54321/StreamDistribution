# Source release package for Stream Distribution.
# Output: E:\01_Work\03_Release\01_Personal\stream-distribution\<X.Y.Z>
# Excludes .venv, __pycache__, .git, .env, and config/channels.yaml.
# Does not build or save a Docker image. Prod keeps its own compose file and builds there.

param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$OutputRoot = 'E:\01_Work\03_Release\01_Personal\stream-distribution'

function Fail([string]$Message) {
    Write-Host "[package-release] FAIL: $Message"
    exit 1
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "Version must be X.Y.Z. Current: $Version" }

$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$head = @(& git -C $RepoRoot rev-parse HEAD 2>$null)
$gitCode = $LASTEXITCODE
$dirty = @(& git -C $RepoRoot status --porcelain)
$dirtyCode = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($gitCode -ne 0 -or $head.Count -eq 0) { Fail 'OFFICIAL_RELEASE_BLOCKED_NO_GIT_HEAD. No package directory was created.' }
$gitRevision = ([string]$head[0]).Trim()
if ($gitRevision -notmatch '^[0-9a-f]{40}$') { Fail "OFFICIAL_RELEASE_BLOCKED_INVALID_GIT_HEAD: $gitRevision" }
if ($dirtyCode -ne 0 -or $dirty.Count -gt 0) { Fail 'OFFICIAL_RELEASE_BLOCKED_DIRTY_TREE. No package directory was created.' }

$releaseRoot = Join-Path $OutputRoot $Version
if (Test-Path -LiteralPath $releaseRoot) { Fail "Release directory already exists and will not be overwritten: $releaseRoot" }

function Copy-Tree([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "missing source: $Source" }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & robocopy $Source $Destination /E /NFL /NDL /NJH /NJS /nc /ns /np /XD .git .venv venv __pycache__ /XF .env channels.yaml *.pyc
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $Source" }
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ('stream-distribution-release-' + [Guid]::NewGuid().ToString('N'))
$parentExisted = Test-Path -LiteralPath $OutputRoot
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'config') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'scripts') | Out-Null
    Copy-Tree (Join-Path $RepoRoot 'app') (Join-Path $stage 'app')
    Copy-Tree (Join-Path $RepoRoot 'static') (Join-Path $stage 'static')
    foreach ($name in @('Dockerfile', 'requirements.txt', 'README.md', '.env.example', '.gitignore', 'docker-compose.yml')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $name) -Destination (Join-Path $stage $name)
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'config\channels.example.yaml') -Destination (Join-Path $stage 'config\channels.example.yaml')
    foreach ($name in @('start.bat', 'stop.bat', 'status.bat')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\$name") -Destination (Join-Path $stage "scripts\$name")
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\release\runtime\*') -Destination (Join-Path $stage 'scripts')
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\dev\confirm-yn.ps1') -Destination (Join-Path $stage 'scripts\confirm-yn.ps1')

    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $stage 'VERSION'), ($Version + [Environment]::NewLine), [Text.Encoding]::ASCII)
    $manifest = [ordered]@{
        product = 'stream-distribution'
        version = $Version
        gitRevision = $gitRevision
        releaseStatus = 'official'
        builtAt = [DateTime]::UtcNow.ToString('o')
        packageKind = 'source'
        excluded = @('.venv', '__pycache__', '.git', '.env', 'config/channels.yaml')
        preservedOnProd = @('.env', 'config/channels.yaml', 'docker-compose.yml')
    }
    [IO.File]::WriteAllText((Join-Path $stage 'RELEASE-MANIFEST.json'), (($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine), $utf8)

    $forbidden = @(Get-ChildItem -LiteralPath $stage -Recurse -Force | Where-Object {
            $_.Name -eq '.env' -or
            $_.Name -eq 'channels.yaml' -or
            $_.Name -eq '.venv' -or
            $_.Name -eq 'venv' -or
            $_.Name -eq '__pycache__' -or
            $_.Name -eq '.git' -or
            $_.Extension -eq '.pyc' -or
            ($_.Name -like '.env.*' -and $_.Name -ne '.env.example')
        })
    if ($forbidden.Count -gt 0) { throw 'Package contains a forbidden secret, virtualenv, or cache path' }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'scripts\03_发布Prod.bat'))) { throw 'deploy entry was not packed' }
    if (-not (Test-Path -LiteralPath (Join-Path $stage '.env.example'))) { throw '.env.example is missing' }

    . (Join-Path $PSScriptRoot 'checksum-manifest.ps1')
    Write-ReleaseChecksumManifest -StageRoot $stage

    if (-not $parentExisted) { New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null }
    Move-Item -LiteralPath $stage -Destination $releaseRoot
    Write-Host "[package-release] PASS $releaseRoot"
}
catch {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not $parentExisted -and (Test-Path -LiteralPath $OutputRoot)) {
        $left = @(Get-ChildItem -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) { Remove-Item -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "[package-release] FAIL: $($_.Exception.Message)"
    exit 1
}
exit 0
