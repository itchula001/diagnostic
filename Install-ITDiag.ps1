# ============================================================
# IT DIAG PROTOCOL INSTALLER V5.1
# ============================================================

$ErrorActionPreference = "Stop"

$BaseDir =
    Split-Path `
        -Parent `
        $MyInvocation.MyCommand.Path

$Launcher =
    Join-Path `
        $BaseDir `
        "Start-ITDiag.ps1"

if (-not (Test-Path $Launcher)) {

    Write-Host ""
    Write-Host "Start-ITDiag.ps1 not found." `
        -ForegroundColor Red
    Write-Host $Launcher
    Write-Host ""

    exit 1
}

# ------------------------------------------------------------
# PowerShell launcher command
# ------------------------------------------------------------

$command =
    "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$Launcher`""

# ------------------------------------------------------------
# Registry
# ------------------------------------------------------------

$protocolRoot =
    "HKCU:\Software\Classes\itdiag"

$commandRoot =
    "$protocolRoot\shell\open\command"

New-Item `
    -Path $protocolRoot `
    -Force |
    Out-Null

New-Item `
    -Path "$protocolRoot\shell" `
    -Force |
    Out-Null

New-Item `
    -Path "$protocolRoot\shell\open" `
    -Force |
    Out-Null

New-Item `
    -Path $commandRoot `
    -Force |
    Out-Null

Set-ItemProperty `
    -Path $protocolRoot `
    -Name "(Default)" `
    -Value "URL:IT Diagnostic Protocol"

New-ItemProperty `
    -Path $protocolRoot `
    -Name "URL Protocol" `
    -Value "" `
    -PropertyType String `
    -Force |
    Out-Null

Set-ItemProperty `
    -Path $commandRoot `
    -Name "(Default)" `
    -Value $command

Write-Host ""
Write-Host "============================================" `
    -ForegroundColor Green
Write-Host " IT DIAG PROTOCOL INSTALLED" `
    -ForegroundColor Green
Write-Host "============================================" `
    -ForegroundColor Green
Write-Host ""
Write-Host "Protocol: itdiag://start"
Write-Host ""
Write-Host "Launcher:"
Write-Host $Launcher
Write-Host ""

# ------------------------------------------------------------
# Test registry
# ------------------------------------------------------------

$value =
    Get-ItemProperty `
        -Path $commandRoot `
        -Name "(Default)"

if ($value."(Default)") {

    Write-Host "Registry registration: OK" `
        -ForegroundColor Green

}
else {

    Write-Host "Registry registration: FAILED" `
        -ForegroundColor Red

    exit 1
}

Write-Host ""
Write-Host "Installation complete."
Write-Host ""