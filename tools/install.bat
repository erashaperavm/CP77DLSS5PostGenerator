@echo off
setlocal
REM One-click install: copy an ALREADY-EXTRACTED OptiScaler folder + CET folder into the game.
REM This script does NOT unzip anything.
REM Usage:   install.bat [OptiScaler dir] [CET dir] [game dir]
REM Example: install.bat "D:\testdlss5\OptiScaler-Capture-Release" "D:\testdlss5\CET-optiscaler_capture" "D:\steam\steamapps\common\Cyberpunk 2077"
REM NOTE: this file is intentionally pure ASCII (no non-ASCII chars).

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0opti-capture-install.ps1" install %*
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo [FAILED] install exit code %RC%
    pause
) else (
    echo.
    if "%~1"=="" pause
)
exit /b %RC%
