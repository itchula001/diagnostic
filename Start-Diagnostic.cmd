@echo off
title IT Field Diagnostic Agent

set "SCRIPT=%~dp0Start-Agent.ps1"

echo.
echo ============================================================
echo       IT FIELD DIAGNOSTIC - PORTABLE AGENT V4
echo ============================================================
echo.
echo Starting temporary diagnostic agent...
echo.
echo This Agent:
echo   - Does NOT install a Windows Service
echo   - Does NOT create Scheduled Task
echo   - Does NOT start with Windows
echo   - Runs only for this diagnostic job
echo.
echo ============================================================
echo.

powershell.exe ^
    -NoProfile ^
    -ExecutionPolicy Bypass ^
    -File "%SCRIPT%"

echo.
echo Agent has stopped.
echo.
pause