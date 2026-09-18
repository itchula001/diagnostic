# ============================================================
# IT DIAGNOSTIC LAUNCHER
# ============================================================

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


# ============================================================
# IMPORTANT
# ============================================================

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
# DOWNLOAD LATEST AGENT
# ============================================================

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


# ============================================================
# CHECK EXISTING AGENT
# ============================================================

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


# ============================================================
# WAIT FOR AGENT
# ============================================================

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