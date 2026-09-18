# ============================================================
# IT FIELD DIAGNOSTIC PORTAL V5
# START-ITDIAG.PS1
# ============================================================

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$AgentScript = Join-Path $BaseDir "Start-Agent.ps1"

$AgentUrl = "http://127.0.0.1:8765/agent/status"

$PortalUrl = "https://itchula001.github.io/diagnostic/"


# ============================================================
# CHECK AGENT SCRIPT
# ============================================================

if (-not (Test-Path -LiteralPath $AgentScript)) {

    Add-Type -AssemblyName PresentationFramework

    [System.Windows.MessageBox]::Show(
        "Start-Agent.ps1 was not found.`n`n$AgentScript",
        "IT Diagnostic Portal V5",
        "OK",
        "Error"
    ) | Out-Null

    exit 1
}


# ============================================================
# CHECK CURRENT AGENT
# ============================================================

$agentOnline = $false

try {

    $status = Invoke-RestMethod `
        -Uri $AgentUrl `
        -Method Get `
        -TimeoutSec 2 `
        -ErrorAction Stop

    if ($status.success -eq $true -and
        $status.online -eq $true) {

        $agentOnline = $true
    }
}
catch {

    $agentOnline = $false
}


# ============================================================
# START AGENT
# ============================================================

if (-not $agentOnline) {

    try {

        Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                $AgentScript
            ) `
            -WindowStyle Hidden `
            -ErrorAction Stop |
            Out-Null
    }
    catch {

        Add-Type -AssemblyName PresentationFramework

        [System.Windows.MessageBox]::Show(
            "Unable to start IT Diagnostic Agent.`n`n$($_.Exception.Message)",
            "IT Diagnostic Portal V5",
            "OK",
            "Error"
        ) | Out-Null

        exit 1
    }
}


# ============================================================
# WAIT FOR AGENT
# ============================================================

$connected = $false

for ($i = 0; $i -lt 30; $i++) {

    Start-Sleep -Milliseconds 500

    try {

        $status = Invoke-RestMethod `
            -Uri $AgentUrl `
            -Method Get `
            -TimeoutSec 2 `
            -ErrorAction Stop

        if ($status.success -eq $true -and
            $status.online -eq $true) {

            $connected = $true

            break
        }
    }
    catch {
    }
}


# ============================================================
# AGENT CONNECTION FAILED
# ============================================================

if (-not $connected) {

    Add-Type -AssemblyName PresentationFramework

    [System.Windows.MessageBox]::Show(
        "Unable to connect to IT Diagnostic Agent.`n`nURL: $AgentUrl",
        "IT Diagnostic Portal V5",
        "OK",
        "Error"
    ) | Out-Null

    exit 1
}


# ============================================================
# VERIFY AGENT VERSION
# ============================================================

try {

    $status = Invoke-RestMethod `
        -Uri $AgentUrl `
        -Method Get `
        -TimeoutSec 2 `
        -ErrorAction Stop

    if ([string]$status.version -ne "5.1") {

        Add-Type -AssemblyName PresentationFramework

        [System.Windows.MessageBox]::Show(
            "An older IT Diagnostic Agent is running.`n`nDetected version: $($status.version)`nDetected PID: $($status.pid)`n`nPlease close the old Agent and run this launcher again.",
            "IT Diagnostic Portal V5",
            "OK",
            "Warning"
        ) | Out-Null

        exit 1
    }
}
catch {

    Add-Type -AssemblyName PresentationFramework

    [System.Windows.MessageBox]::Show(
        "Agent version check failed.`n`n$($_.Exception.Message)",
        "IT Diagnostic Portal V5",
        "OK",
        "Error"
    ) | Out-Null

    exit 1
}


# ============================================================
# OPEN WEB PORTAL
# ============================================================

try {

    Start-Process `
        -FilePath $PortalUrl `
        -ErrorAction Stop |
        Out-Null
}
catch {

    Add-Type -AssemblyName PresentationFramework

    [System.Windows.MessageBox]::Show(
        "Agent is running, but the web portal could not be opened.`n`n$PortalUrl",
        "IT Diagnostic Portal V5",
        "OK",
        "Warning"
    ) | Out-Null

    exit 1
}


# ============================================================
# EXIT
# ============================================================

exit 0
