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
# CHECK AGENT FILE
# ============================================================

if (-not (Test-Path $AgentScript)) {

    Add-Type -AssemblyName PresentationFramework

    [System.Windows.MessageBox]::Show(
        "ไม่พบ Start-Agent.ps1`n`n$AgentScript",
        "IT Diagnostic Portal V5",
        "OK",
        "Error"
    ) | Out-Null

    exit 1
}


# ============================================================
# CHECK EXISTING AGENT
# ============================================================

$agentOnline = $false

try {

    $status = Invoke-RestMethod `
        -Uri $AgentUrl `
        -Method GET `
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
# START AGENT IF NEEDED
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
                "`"$AgentScript`""
            ) `
            -WindowStyle Hidden | Out-Null
    }
    catch {

        Add-Type -AssemblyName PresentationFramework

        [System.Windows.MessageBox]::Show(
            "ไม่สามารถเปิด IT Diagnostic Agent ได้`n`n$($_.Exception.Message)",
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

    Start-Sleep -Milliseconds 300

    try {

        $status = Invoke-RestMethod `
            -Uri $AgentUrl `
            -Method GET `
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
# AGENT FAILED
# ============================================================

if (-not $connected) {

    Add-Type -AssemblyName PresentationFramework

    [System.Windows.MessageBox]::Show(
        "ไม่สามารถเชื่อมต่อ IT Diagnostic Agent ได้`n`nURL:`n$AgentUrl`n`nตรวจสอบว่า Port 8765 ไม่ถูกโปรแกรมอื่นใช้งาน",
        "IT Diagnostic Portal V5",
        "OK",
        "Error"
    ) | Out-Null

    exit 1
}


# ============================================================
# OPEN PORTAL
# ============================================================

try {

    Start-Process $PortalUrl | Out-Null
}
catch {

    Add-Type -AssemblyName PresentationFramework

    [System.Windows.MessageBox]::Show(
        "Agent ทำงานแล้ว แต่เปิด Portal ไม่สำเร็จ`n`n$PortalUrl",
        "IT Diagnostic Portal V5",
        "OK",
        "Warning"
    ) | Out-Null

    exit 1
}


# ============================================================
# DONE
# ============================================================

exit 0