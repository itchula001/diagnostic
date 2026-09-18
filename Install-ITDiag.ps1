# ============================================================
# IT FIELD DIAGNOSTIC PORTAL V5
# Install Custom URL Protocol
# ============================================================

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

$BaseDir =
    Split-Path -Parent $MyInvocation.MyCommand.Path

$Launcher =
    Join-Path $BaseDir "Start-ITDiag.ps1"

# ------------------------------------------------------------
# Verify Launcher
# ------------------------------------------------------------

if (-not (Test-Path $Launcher)) {

    Write-Host ""
    Write-Host "ERROR: Start-ITDiag.ps1 not found." `
        -ForegroundColor Red

    Write-Host ""
    Write-Host "Expected:"
    Write-Host $Launcher

    Write-Host ""

    exit 1
}

# ------------------------------------------------------------
# Registry path
# ------------------------------------------------------------

$ProtocolKey =
    "HKCU:\Software\Classes\itdiag"

$CommandKey =
    "HKCU:\Software\Classes\itdiag\shell\open\command"

# ------------------------------------------------------------
# Create protocol
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================" `
    -ForegroundColor Cyan

Write-Host " IT FIELD DIAGNOSTIC PORTAL V5" `
    -ForegroundColor Cyan

Write-Host " Installing itdiag:// protocol" `
    -ForegroundColor Cyan

Write-Host "============================================" `
    -ForegroundColor Cyan

Write-Host ""

# ------------------------------------------------------------
# Root key
# ------------------------------------------------------------

New-Item `
    -Path $ProtocolKey `
    -Force |
    Out-Null

# ------------------------------------------------------------
# Protocol description
# ------------------------------------------------------------

Set-ItemProperty `
    -Path $ProtocolKey `
    -Name "(Default)" `
    -Value "URL:IT Diagnostic Protocol"

Set-ItemProperty `
    -Path $ProtocolKey `
    -Name "URL Protocol" `
    -Value ""

# ------------------------------------------------------------
# shell\open\command
# ------------------------------------------------------------

New-Item `
    -Path $CommandKey `
    -Force |
    Out-Null

# ------------------------------------------------------------
# Command
# ------------------------------------------------------------

$PowerShellPath =
    Join-Path $env:SystemRoot `
        "System32\WindowsPowerShell\v1.0\powershell.exe"

$Command =
    "`"$PowerShellPath`" -NoProfile -ExecutionPolicy Bypass -File `"$Launcher`""

Set-ItemProperty `
    -Path $CommandKey `
    -Name "(Default)" `
    -Value $Command

# ------------------------------------------------------------
# Success
# ------------------------------------------------------------

Write-Host ""
Write-Host "SUCCESS" `
    -ForegroundColor Green

Write-Host ""
Write-Host "Protocol:"
Write-Host "itdiag://start"

Write-Host ""

Write-Host "Launcher:"
Write-Host $Launcher

Write-Host ""

Write-Host "Registry:"
Write-Host $ProtocolKey

Write-Host ""

Write-Host "============================================" `
    -ForegroundColor Green

Write-Host " Installation completed." `
    -ForegroundColor Green

Write-Host "============================================" `
    -ForegroundColor Green

Write-Host ""

# ------------------------------------------------------------
# Test URL
# ------------------------------------------------------------

Write-Host "Testing protocol..." `
    -ForegroundColor Yellow

try {

    Start-Process "itdiag://start"

    Write-Host ""
    Write-Host "Protocol launch requested." `
        -ForegroundColor Green

}
catch {

    Write-Host ""
    Write-Host "Protocol test failed:" `
        -ForegroundColor Red

    Write-Host $_.Exception.Message `
        -ForegroundColor Red
}

Write-Host ""