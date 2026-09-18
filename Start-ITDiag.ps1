# ============================================================
# IT DIAG LAUNCHER V5.1
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

$BaseDir =
    Split-Path `
        -Parent `
        $MyInvocation.MyCommand.Path

$AgentScript =
    Join-Path `
        $BaseDir `
        "Start-Agent.ps1"

if (-not (Test-Path $AgentScript)) {

    Add-Type -AssemblyName PresentationFramework

    [System.Windows.MessageBox]::Show(
        "Start-Agent.ps1 was not found.`n`n$AgentScript",
        "IT Diagnostic Agent",
        "OK",
        "Error"
    ) | Out-Null

    exit 1
}

# ------------------------------------------------------------
# Check whether Agent is already online
# ------------------------------------------------------------

try {

    $status =
        Invoke-RestMethod `
            -Uri "http://127.0.0.1:8765/agent/status" `
            -TimeoutSec 2 `
            -ErrorAction Stop

    if (
        $status.success -and
        $status.online
    ) {

        exit 0
    }

}
catch {
}

# ------------------------------------------------------------
# Create temporary startup command
# ------------------------------------------------------------

$tempRoot =
    Join-Path `
        $env:TEMP `
        "ITDiagV5"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $tempRoot |
    Out-Null

$runner =
    Join-Path `
        $tempRoot `
        "run-agent.cmd"

$agentFull =
    (Resolve-Path $AgentScript).Path

$cmd = @"
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$agentFull"
"@

Set-Content `
    -Path $runner `
    -Value $cmd `
    -Encoding ASCII

# ------------------------------------------------------------
# Start Agent
# ------------------------------------------------------------

Start-Process `
    -FilePath $runner `
    -WindowStyle Hidden

exit 0