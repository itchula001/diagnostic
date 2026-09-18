# ============================================================
# IT FIELD DIAGNOSTIC - TEMPORARY LOCAL AGENT V5
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

$Port = 8765

$AgentDir = Join-Path `
    $env:TEMP `
    "IT_Field_Diagnostic_Agent"

$PidFile = Join-Path `
    $AgentDir `
    "agent.pid"

$HistoryFile = Join-Path `
    $AgentDir `
    "history.json"


# ============================================================
# PREPARE
# ============================================================

if (-not (Test-Path $AgentDir)) {

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $AgentDir |
        Out-Null
}


$PID |
    Set-Content `
        $PidFile `
        -Encoding ASCII


# ============================================================
# LISTENER
# ============================================================

$listener =
    New-Object System.Net.HttpListener

$listener.Prefixes.Add(
    "http://127.0.0.1:$Port/"
)


try {

    $listener.Start()

}
catch {

    exit 1

}


# ============================================================
# HISTORY
# ============================================================

[array]$global:HistoryLog = @()


if (
    Test-Path $HistoryFile
) {

    try {

        $raw =
            Get-Content `
                $HistoryFile `
                -Raw

        if (
            -not [string]::IsNullOrWhiteSpace(
                $raw
            )
        ) {

            $parsed =
                $raw |
                ConvertFrom-Json

            if (
                $null -ne $parsed
            ) {

                $global:HistoryLog =
                    @($parsed)

            }

        }

    }
    catch {

        $global:HistoryLog =
            @()

    }

}


function Save-History {

    try {

        $global:HistoryLog |
            ConvertTo-Json `
                -Depth 12 |
            Set-Content `
                $HistoryFile `
                -Encoding UTF8

    }
    catch {}

}


# ============================================================
# JOB
# ============================================================

$global:CurrentJob = $null


# ============================================================
# PROTECTED PROCESSES
# ============================================================

$ProtectedList = @(

    "System",
    "Idle",
    "Memory Compression",
    "Registry",
    "smss",
    "csrss",
    "wininit",
    "services",
    "lsass",
    "winlogon",
    "dwm",
    "svchost",
    "sihost",
    "taskhostw"

)


# ============================================================
# JSON
# ============================================================

function Send-Json {

    param(

        $Response,

        $Data,

        [int]
        $StatusCode = 200

    )


    $json =
        $Data |
        ConvertTo-Json `
            -Depth 12


    $bytes =
        [System.Text.Encoding]::UTF8.GetBytes(
            $json
        )


    $Response.StatusCode =
        $StatusCode

    $Response.ContentType =
        "application/json; charset=utf-8"

    $Response.ContentEncoding =
        [System.Text.Encoding]::UTF8

    $Response.ContentLength64 =
        $bytes.Length


    $Response.OutputStream.Write(
        $bytes,
        0,
        $bytes.Length
    )


    $Response.Close()

}


# ============================================================
# REQUEST BODY
# ============================================================

function Read-Body {

    param(
        $Request
    )


    try {

        $reader =
            New-Object `
                System.IO.StreamReader(
                    $Request.InputStream
                )

        return $reader.ReadToEnd()

    }
    catch {

        return ""

    }

}


# ============================================================
# MAIN LOOP
# ============================================================

try {

    while (
        $listener.IsListening
    ) {

        $context =
            $listener.GetContext()


        $request =
            $context.Request

        $response =
            $context.Response


        # ----------------------------------------------------
        # CORS
        # ----------------------------------------------------

        $origin =
            $request.Headers["Origin"]


        $allowedOrigins = @(

            "https://itchula001.github.io",
            "http://localhost",
            "http://127.0.0.1",
            "null"

        )


        if (
            $allowedOrigins -contains
            $origin
        ) {

            $response.Headers.Add(
                "Access-Control-Allow-Origin",
                $origin
            )

        }


        $response.Headers.Add(
            "Access-Control-Allow-Methods",
            "GET, POST, OPTIONS"
        )


        $response.Headers.Add(
            "Access-Control-Allow-Headers",
            "Content-Type"
        )


        if (
            $request.HttpMethod -eq
            "OPTIONS"
        ) {

            $response.StatusCode = 200

            $response.Close()

            continue

        }


        $path =
            $request.Url.LocalPath


        # ====================================================
        # AGENT STATUS
        # ====================================================

        if (
            $path -eq
            "/agent/status"
        ) {

            Send-Json `
                $response `
                @{
                    online = $true
                    pid = $PID
                    port = $Port
                    computer =
                        $env:COMPUTERNAME
                    user =
                        $env:USERNAME
                    jobActive =
                        ($null -ne
                         $global:CurrentJob)
                }

            continue

        }


        # ====================================================
        # AGENT STOP
        # ====================================================

        if (
            $path -eq
            "/agent/stop"
        ) {

            $agentPid =
                $PID


            Send-Json `
                $response `
                @{
                    success = $true
                    message =
                        "Agent stopping"
                }


            Start-Job `
                -ArgumentList $agentPid `
                -ScriptBlock {

                    param(
                        $targetPid
                    )

                    Start-Sleep `
                        -Milliseconds 700

                    try {

                        Stop-Process `
                            -Id $targetPid `
                            -Force

                    }
                    catch {}

                } |
                Out-Null


            continue

        }


        # ====================================================
        # SYSTEM
        # ====================================================

        if (
            $path -eq
            "/system"
        ) {

            $os =
                Get-CimInstance `
                    Win32_OperatingSystem


            Send-Json `
                $response `
                @{
                    computer =
                        $env:COMPUTERNAME

                    user =
                        $env:USERNAME

                    os =
                        $os.Caption

                    version =
                        $os.Version

                    architecture =
                        $os.OSArchitecture

                    boot =
                        $os.LastBootUpTime
                }


            continue

        }


        # ====================================================
        # METRICS
        # ====================================================

        if (
            $path -eq
            "/metrics"
        ) {

            $cpu =
                Get-CimInstance `
                    Win32_Processor |
                Measure-Object `
                    -Property LoadPercentage `
                    -Average |
                Select-Object `
                    -ExpandProperty Average


            $os =
                Get-CimInstance `
                    Win32_OperatingSystem


            $ram =
                (
                    (
                        $os.TotalVisibleMemorySize -
                        $os.FreePhysicalMemory
                    )
                    /
                    $os.TotalVisibleMemorySize
                ) * 100


            $disk =
                Get-CimInstance `
                    Win32_LogicalDisk `
                    -Filter "DeviceID='C:'"


            $diskUsage =
                (
                    (
                        $disk.Size -
                        $disk.FreeSpace
                    )
                    /
                    $disk.Size
                ) * 100


            Send-Json `
                $response `
                @{
                    cpu =
                        [math]::Round(
                            $cpu,
                            1
                        )

                    ram =
                        [math]::Round(
                            $ram,
                            1
                        )

                    disk =
                        [math]::Round(
                            $diskUsage,
                            1
                        )

                    ramFreeGB =
                        [math]::Round(
                            $os.FreePhysicalMemory /
                            1MB,
                            2
                        )

                    diskFreeGB =
                        [math]::Round(
                            $disk.FreeSpace /
                            1GB,
                            2
                        )
                }


            continue

        }


        # ====================================================
        # PROCESSES
        # ====================================================

        if (
            $path -eq
            "/processes"
        ) {

            $processes =
                Get-Process |
                Sort-Object `
                    WorkingSet `
                    -Descending |
                Select-Object `
                    -First 25 |
                ForEach-Object {

                    @{
                        Id =
                            $_.Id

                        Name =
                            $_.Name

                        RAM_MB =
                            [math]::Round(
                                $_.WorkingSet /
                                1MB,
                                1
                            )

                        CPU_Time =
                            if ($_.CPU) {
                                [math]::Round(
                                    $_.CPU,
                                    1
                                )
                            }
                            else {
                                0
                            }

                        IsSystem =
                            (
                                $ProtectedList -contains
                                $_.Name
                            )
                    }

                }


            Send-Json `
                $response `
                @{
                    processes =
                        @($processes)
                }


            continue

        }


        # ====================================================
        # EVENTS
        # ====================================================

        if (
            $path -eq
            "/events"
        ) {

            $events = @()


            foreach (
                $logName in @(
                    "System",
                    "Application"
                )
            ) {

                try {

                    $items =
                        Get-WinEvent `
                            -FilterHashtable @{
                                LogName =
                                    $logName

                                Level =
                                    2
                            } `
                            -MaxEvents 15


                    foreach (
                        $event in $items
                    ) {

                        $events += @{

                            Log =
                                $logName

                            Time =
                                $event.TimeCreated

                            Id =
                                $event.Id

                            Provider =
                                $event.ProviderName

                            Message =
                                $event.Message
                        }

                    }

                }
                catch {}

            }


            Send-Json `
                $response `
                @{
                    events =
                        @($events)
                }


            continue

        }


        # ====================================================
        # DIAGNOSTIC
        # ====================================================

        if (
            $path -eq
            "/diagnose"
        ) {

            $problems = @()

            $score = 100


            # ------------------------------------------------
            # DISK
            # ------------------------------------------------

            $disk =
                Get-CimInstance `
                    Win32_LogicalDisk `
                    -Filter "DeviceID='C:'"


            $diskPercent =
                (
                    (
                        $disk.Size -
                        $disk.FreeSpace
                    )
                    /
                    $disk.Size
                ) * 100


            $diskFreeGB =
                $disk.FreeSpace /
                1GB


            if (
                $diskPercent -gt 90
            ) {

                $score -= 25


                $problems += @{

                    id =
                        "DISK_CRITICAL"

                    title =
                        "Disk C: critically full"

                    severity =
                        "critical"

                    description =
                        "Disk usage is $([math]::Round($diskPercent))%."

                    evidence = @(
                        "Usage: $([math]::Round($diskPercent))%",
                        "Free: $([math]::Round($diskFreeGB,2)) GB"
                    )

                    recommendedFix =
                        $null
                }

            }
            elseif (
                $diskPercent -gt 85
            ) {

                $score -= 15


                $problems += @{

                    id =
                        "DISK_WARNING"

                    title =
                        "Disk C: low free space"

                    severity =
                        "warning"

                    description =
                        "Disk usage is $([math]::Round($diskPercent))%."

                    evidence = @(
                        "Usage: $([math]::Round($diskPercent))%",
                        "Free: $([math]::Round($diskFreeGB,2)) GB"
                    )

                    recommendedFix =
                        $null
                }

            }


            # ------------------------------------------------
            # SPOOLER
            # ------------------------------------------------

            $spooler =
                Get-Service `
                    -Name Spooler `
                    -ErrorAction SilentlyContinue


            if (
                $spooler -and
                $spooler.Status -ne
                "Running"
            ) {

                $score -= 15


                $problems += @{

                    id =
                        "SPOOLER_STOP"

                    title =
                        "Print Spooler is stopped"

                    severity =
                        "warning"

                    description =
                        "Print Spooler is not running."

                    evidence = @(
                        "Status: $($spooler.Status)"
                    )

                    recommendedFix =
                        "restart-spooler"
                }

            }


            # ------------------------------------------------
            # WINDOWS UPDATE
            # ------------------------------------------------

            $wu =
                Get-Service `
                    -Name wuauserv `
                    -ErrorAction SilentlyContinue


            if (
                $wu -and
                $wu.Status -ne
                "Running"
            ) {

                $score -= 5


                $problems += @{

                    id =
                        "WU_STOP"

                    title =
                        "Windows Update service is stopped"

                    severity =
                        "warning"

                    description =
                        "Windows Update service is not running."

                    evidence = @(
                        "Status: $($wu.Status)"
                    )

                    recommendedFix =
                        "restart-service-wuauserv"
                }

            }


            # ------------------------------------------------
            # BITS
            # ------------------------------------------------

            $bits =
                Get-Service `
                    -Name BITS `
                    -ErrorAction SilentlyContinue


            if (
                $bits -and
                $bits.Status -ne
                "Running"
            ) {

                $score -= 5


                $problems += @{

                    id =
                        "BITS_STOP"

                    title =
                        "BITS service is stopped"

                    severity =
                        "warning"

                    description =
                        "Background Intelligent Transfer Service is not running."

                    evidence = @(
                        "Status: $($bits.Status)"
                    )

                    recommendedFix =
                        "restart-bits"
                }

            }


            # ------------------------------------------------
            # NETWORK
            # ------------------------------------------------

            $internet =
                Test-Connection `
                    -ComputerName "8.8.8.8" `
                    -Count 1 `
                    -Quiet


            if (
                -not $internet
            ) {

                $score -= 20


                $problems += @{

                    id =
                        "NETWORK_OFFLINE"

                    title =
                        "Internet connectivity test failed"

                    severity =
                        "critical"

                    description =
                        "Connectivity test to 8.8.8.8 failed."

                    evidence = @(
                        "Ping failed"
                    )

                    recommendedFix =
                        "flush-dns"
                }

            }


            # ------------------------------------------------
            # DEFENDER
            # ------------------------------------------------

            try {

                $defender =
                    Get-MpComputerStatus


                if (
                    -not
                    $defender.RealTimeProtectionEnabled
                ) {

                    $score -= 10


                    $problems += @{

                        id =
                            "DEFENDER_OFF"

                        title =
                            "Microsoft Defender real-time protection is OFF"

                        severity =
                            "warning"

                        description =
                            "Real-time protection is disabled."

                        evidence = @(
                            "RealTimeProtectionEnabled: False"
                        )

                        recommendedFix =
                            "enable-defender"
                    }

                }

            }
            catch {}


            if (
                $score -lt 0
            ) {

                $score = 0

            }


            Send-Json `
                $response `
                @{
                    healthScore =
                        $score

                    problems =
                        @($problems)

                    checkedAt =
                        Get-Date
                }


            continue

        }


        # ====================================================
        # START JOB
        # ====================================================

        if (
            $path -eq
            "/job/start"
        ) {

            $body =
                Read-Body $request


            try {

                $job =
                    $body |
                    ConvertFrom-Json

            }
            catch {

                Send-Json `
                    $response `
                    @{
                        success = $false
                        message =
                            "Invalid job JSON"
                    } `
                    400

                continue

            }


            $global:CurrentJob =
                $job


            $global:HistoryLog +=
                $job


            Save-History


            Send-Json `
                $response `
                @{
                    success = $true
                    job =
                        $job
                }


            continue

        }


        # ====================================================
        # JOB STATUS
        # ====================================================

        if (
            $path -eq
            "/job/status"
        ) {

            Send-Json `
                $response `
                @{
                    active =
                        (
                            $null -ne
                            $global:CurrentJob
                        )

                    job =
                        $global:CurrentJob
                }


            continue

        }


        # ====================================================
        # JOB ACTION
        # ====================================================

        if (
            $path -eq
            "/job/action"
        ) {

            $body =
                Read-Body $request


            try {

                $action =
                    $body |
                    ConvertFrom-Json

            }
            catch {

                Send-Json `
                    $response `
                    @{
                        success = $false
                    } `
                    400

                continue

            }


            if (
                $null -ne
                $global:CurrentJob
            ) {

                if (
                    $null -eq
                    $global:CurrentJob.actions
                ) {

                    $global:CurrentJob |
                        Add-Member `
                            -MemberType NoteProperty `
                            -Name actions `
                            -Value @()

                }


                $global:CurrentJob.actions +=
                    $action


                Save-History

            }


            Send-Json `
                $response `
                @{
                    success = $true
                }


            continue

        }


        # ====================================================
        # JOB END
        # ====================================================

        if (
            $path -eq
            "/job/end"
        ) {

            $body =
                Read-Body $request


            try {

                $job =
                    $body |
                    ConvertFrom-Json

                $global:CurrentJob =
                    $job

            }
            catch {}


            if (
                $null -ne
                $global:CurrentJob
            ) {

                $global:CurrentJob.status =
                    "Completed"

                $global:CurrentJob.endedAt =
                    Get-Date

                Save-History

            }


            Send-Json `
                $response `
                @{
                    success = $true
                    job =
                        $global:CurrentJob
                }


            continue

        }


        # ====================================================
        # HISTORY
        # ====================================================

        if (
            $path -eq
            "/history"
        ) {

            Send-Json `
                $response `
                @{
                    history =
                        @(
                            $global:HistoryLog
                        )
                }


            continue

        }


        # ====================================================
        # KILL PROCESS
        # ====================================================

        if (
            $path -eq
            "/kill"
        ) {

            $body =
                Read-Body $request


            try {

                $data =
                    $body |
                    ConvertFrom-Json

                $processId =
                    [int]$data.pid

            }
            catch {

                Send-Json `
                    $response `
                    @{
                        success = $false
                        message =
                            "Invalid PID"
                    } `
                    400

                continue

            }


            try {

                $process =
                    Get-Process `
                        -Id $processId `
                        -ErrorAction Stop


                if (
                    $ProtectedList -contains
                    $process.Name
                ) {

                    Send-Json `
                        $response `
                        @{
                            success = $false
                            message =
                                "Protected system process"
                        } `
                        403

                    continue

                }


                Stop-Process `
                    -Id $processId `
                    -Force


                Send-Json `
                    $response `
                    @{
                        success = $true
                        message =
                            "Process terminated"
                    }

            }
            catch {

                Send-Json `
                    $response `
                    @{
                        success = $false
                        message =
                            $_.Exception.Message
                    } `
                    500

            }


            continue

        }


        # ====================================================
        # FIX
        # ====================================================

        if (
            $path -eq
            "/fix"
        ) {

            $body =
                Read-Body $request


            try {

                $data =
                    $body |
                    ConvertFrom-Json

                $action =
                    $data.action

            }
            catch {

                Send-Json `
                    $response `
                    @{
                        success = $false
                        message =
                            "Invalid request"
                    } `
                    400

                continue

            }


            try {

                $message = ""


                switch (
                    $action
                ) {

                    "restart-spooler" {

                        Restart-Service `
                            Spooler `
                            -Force

                        $message =
                            "Print Spooler restarted."

                    }


                    "restart-service-wuauserv" {

                        Restart-Service `
                            wuauserv `
                            -Force

                        $message =
                            "Windows Update restarted."

                    }


                    "restart-bits" {

                        Restart-Service `
                            BITS `
                            -Force

                        $message =
                            "BITS restarted."

                    }


                    "flush-dns" {

                        ipconfig `
                            /flushdns |
                            Out-Null

                        $message =
                            "DNS cache flushed."

                    }


                    "renew-ip" {

                        ipconfig `
                            /renew |
                            Out-Null

                        $message =
                            "IP address renewed."

                    }


                    "gpupdate" {

                        gpupdate `
                            /force |
                            Out-Null

                        $message =
                            "Group Policy updated."

                    }


                    "enable-defender" {

                        Set-MpPreference `
                            -DisableRealtimeMonitoring `
                            $false

                        $message =
                            "Defender real-time protection enabled."

                    }


                    "restart-windows-search" {

                        Restart-Service `
                            WSearch `
                            -Force

                        $message =
                            "Windows Search restarted."

                    }


                    default {

                        throw `
                            "Action is not whitelisted."

                    }

                }


                Send-Json `
                    $response `
                    @{
                        success = $true
                        action =
                            $action
                        message =
                            $message
                        time =
                            Get-Date
                    }

            }
            catch {

                Send-Json `
                    $response `
                    @{
                        success = $false
                        action =
                            $action
                        message =
                            $_.Exception.Message
                    } `
                    500

            }


            continue

        }


        # ====================================================
        # 404
        # ====================================================

        Send-Json `
            $response `
            @{
                success = $false
                error =
                    "Endpoint not found"
                path =
                    $path
            } `
            404

    }

}
finally {

    try {

        $listener.Stop()

        $listener.Close()

    }
    catch {}


    try {

        if (
            Test-Path $PidFile
        ) {

            Remove-Item `
                $PidFile `
                -Force

        }

    }
    catch {}

}