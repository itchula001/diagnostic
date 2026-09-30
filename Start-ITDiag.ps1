# ============================================================
# IT DIAG LAUNCHER V5.3.3
# ============================================================
# Purpose:
#   - Start IT Diagnostic Agent
#   - Automatically request Administrator privilege
#   - Keep Agent elevated for Fix Engine actions
#   - Do not require manual "Run as Administrator"
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

# ------------------------------------------------------------
# BASE DIRECTORY
# ------------------------------------------------------------

$BaseDir =
    Split-Path `
        -Parent `
        $MyInvocation.MyCommand.Path

$AgentScript =
    Join-Path `
        $BaseDir `
        "Start-Agent.ps1"


# ------------------------------------------------------------
# CHECK AGENT SCRIPT
# ------------------------------------------------------------

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
# CHECK CURRENT PRIVILEGE
# ------------------------------------------------------------

try {

    $identity =
        [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal =
        New-Object `
            Security.Principal.WindowsPrincipal(
                $identity
            )

    $isAdmin =
        $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )

}
catch {

    $isAdmin = $false
}


# ------------------------------------------------------------
# SELF-ELEVATE
# ------------------------------------------------------------
# If Launcher is not Administrator:
#   restart this same Launcher using UAC
#   then exit the non-elevated process
#
# This means the Agent launched afterwards will inherit
# Administrator privileges.
# ------------------------------------------------------------

if (-not $isAdmin) {

    try {

        $launcherPath =
            (Resolve-Path $MyInvocation.MyCommand.Path).Path

        Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -ArgumentList @(
                "-NoLogo"
                "-NoProfile"
                "-ExecutionPolicy"
                "Bypass"
                "-File"
                "`"$launcherPath`""
            ) |
            Out-Null

    }
    catch {

        Add-Type -AssemblyName PresentationFramework

        [System.Windows.MessageBox]::Show(
            "Administrator permission is required to start IT Diagnostic Agent.",
            "IT Diagnostic Agent",
            "OK",
            "Warning"
        ) | Out-Null
    }

    exit 0
}


# ------------------------------------------------------------
# AGENT ALREADY ONLINE CHECK
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
# TEMP WORK DIRECTORY
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


# ------------------------------------------------------------
# TEMP RUNNER
# ------------------------------------------------------------

$runner =
    Join-Path `
        $tempRoot `
        "run-agent.cmd"

$agentFull =
    (Resolve-Path $AgentScript).Path


# ------------------------------------------------------------
# CREATE AGENT RUNNER
# ------------------------------------------------------------

$cmd = @"
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$agentFull"
"@

Set-Content `
    -Path $runner `
    -Value $cmd `
    -Encoding ASCII


# ------------------------------------------------------------
# START ELEVATED AGENT
# ------------------------------------------------------------
# Launcher itself is already elevated at this point.
# Therefore Agent inherits Administrator privilege.
# ------------------------------------------------------------

Start-Process `
    -FilePath $runner `
    -WindowStyle Hidden


# ------------------------------------------------------------
# EXIT LAUNCHER
# ------------------------------------------------------------

exit 0