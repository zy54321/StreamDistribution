@echo off
setlocal
cd /d "%~dp0.."
if exist "SHA256SUMS" (
  echo [stop] FAIL: this directory is a frozen release. Install to a separate target.
  exit /b 1
)
if exist "RELEASE-MANIFEST.json" (
  echo [stop] FAIL: this directory is a frozen release. Install to a separate target.
  exit /b 1
)
if not exist ".env" (
  echo [stop] FAIL: .env is missing.
  exit /b 1
)
echo [stop] Stopping containers. Volumes are preserved.
docker compose stop
if errorlevel 1 exit /b 1
echo [stop] PASS
exit /b 0
