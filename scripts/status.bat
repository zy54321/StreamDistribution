@echo off
setlocal
cd /d "%~dp0.."
if exist "SHA256SUMS" (
  echo [status] FAIL: this directory is a frozen release. Install to a separate target.
  exit /b 1
)
if exist "RELEASE-MANIFEST.json" (
  echo [status] FAIL: this directory is a frozen release. Install to a separate target.
  exit /b 1
)
if not exist ".env" (
  echo [status] FAIL: .env is missing.
  exit /b 1
)
docker compose ps
if errorlevel 1 exit /b 1
docker inspect -f "{{.Name}} {{.State.Status}}" stream-distribution-prod
if errorlevel 1 (
  echo [status] FAIL: container stream-distribution-prod is missing.
  exit /b 1
)
powershell -NoProfile -Command "try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8092/api/health' -TimeoutSec 5; if ($r.status -ne 'ok') { exit 1 } } catch { exit 1 }"
if errorlevel 1 (
  echo [status] FAIL: health check http://127.0.0.1:8092/api/health
  exit /b 1
)
echo [status] PASS http://127.0.0.1:8092/api/health
exit /b 0
