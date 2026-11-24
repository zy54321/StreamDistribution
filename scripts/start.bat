@echo off
setlocal
cd /d "%~dp0.."
if exist "SHA256SUMS" (
  echo [start] FAIL: this directory is a frozen release. Install to a separate target.
  exit /b 1
)
if exist "RELEASE-MANIFEST.json" (
  echo [start] FAIL: this directory is a frozen release. Install to a separate target.
  exit /b 1
)
if not exist ".env" (
  echo [start] FAIL: .env is missing.
  exit /b 1
)
if not exist "docker-compose.yml" (
  echo [start] FAIL: docker-compose.yml is missing.
  exit /b 1
)
docker compose up -d --no-build
if errorlevel 1 (
  echo [start] FAIL: compose up failed.
  exit /b 1
)
powershell -NoProfile -Command "$ok = $false; foreach ($i in 1..15) { try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8092/api/health' -TimeoutSec 5; if ($r.status -eq 'ok') { $ok = $true; break } } catch {} ; Start-Sleep -Seconds 1 }; if (-not $ok) { exit 1 }"
if errorlevel 1 (
  echo [start] FAIL: health check http://127.0.0.1:8092/api/health
  exit /b 1
)
echo [start] PASS stream-distribution-prod http://127.0.0.1:8092/api/health
docker compose ps
exit /b 0
