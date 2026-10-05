@echo off
setlocal
REM Show install status: installed or not, proxy dll, entry counts.
REM Usage: status.bat [game dir]
REM NOTE: this file is intentionally pure ASCII (no non-ASCII chars).

set "EXTRA="
if not "%~1"=="" set "EXTRA=-GamePath %*"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0opti-capture-install.ps1" status %EXTRA%
set "RC=%errorlevel%"
if "%~1"=="" pause
exit /b %RC%
