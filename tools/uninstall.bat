@echo off
setlocal
REM One-click uninstall: delete files added by install, restore replaced ones.
REM Usage: uninstall.bat [game dir]
REM NOTE: this file is intentionally pure ASCII (no non-ASCII chars).

set "EXTRA="
if not "%~1"=="" set "EXTRA=-GamePath %*"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0opti-capture-install.ps1" uninstall %EXTRA%
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo [FAILED] uninstall exit code %RC%
    pause
) else (
    echo.
    if "%~1"=="" pause
)
exit /b %RC%
