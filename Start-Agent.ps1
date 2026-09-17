# ============================================================
# IT FIELD DIAGNOSTIC - PORTABLE JOB AGENT V4
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

$Port = 8765
$BindAddress = "127.0.0.1"

$AgentVersion = "4.0.0-Portable"

$BaseDir = Join-Path $env:TEMP "ITDiagnosticAgent"

$DataDir = Join-Path $BaseDir "data"
$LogDir  = Join-Path $BaseDir "logs"

$HistoryFile = Join-Path $DataDir "history.json"
$LogFile     = Join-Path $LogDir "agent.log"

$JobFile = Join-Path $DataDir "current-job.json"

$ProtectedProcesses = @(
    "System"
    "Registry"
    "smss"
    "csrss"
    "wininit"
    "services"
    "lsass"
    "winlogon"
    "dwm"
    "svchost"
)

# ============================================================
# PREPARE
# ============================================================

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-AgentLog {

    param(
        [string]$Message
    )

    try {

        $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        Add-Content `
            -Path $LogFile `
            -Value "[$time] $Message"

    }
    catch {}
}

Write-AgentLog "======================================"
Write-AgentLog "IT Diagnostic Portable Agent starting"
Write-AgentLog "Version: $AgentVersion"
Write-AgentLog "======================================"

# ============================================================
# ADMIN
# ============================================================

function Test-IsAdmin {

    try {

        $identity =
            [Security.Principal.WindowsIdentity]::GetCurrent()

        $principal =
            New-Object Security.Principal.WindowsPrincipal($identity)

        return $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )

    }
    catch {

        return $false
    }
}

# ============================================================
# JSON
# ============================================================

function Send-Json {

    param(
        $Context,
        $Data,
        [int]$StatusCode = 200
    )

    try {

        $json =
            $Data | ConvertTo-Json -Depth 15

        $bytes =
            [System.Text.Encoding]::UTF8.GetBytes($json)

        $Context.Response.StatusCode = $StatusCode

        $Context.Response.ContentType =
            "application/json; charset=utf-8"

        $Context.Response.ContentLength64 =
            $bytes.Length

        $Context.Response.OutputStream.Write(
            $bytes,
            0,
            $bytes.Length
        )

        $Context.Response.OutputStream.Close()

    }
    catch {

        try {
            $Context.Response.Close()
        }
        catch {}
    }
}

# ============================================================
# CORS
# ============================================================

function Set-Cors {

    param(
        $Context
    )

    $origin =
        $Context.Request.Headers["Origin"]

    $allowed = @(
        "https://itchula001.github.io"
        "http://localhost"
        "http://127.0.0.1"
        "null"
    )

    if ($allowed -contains $origin) {

        $Context.Response.Headers.Add(
            "Access-Control-Allow-Origin",
            $origin
        )

        $Context.Response.Headers.Add(
            "Vary",
            "Origin"
        )
    }

    $Context.Response.Headers.Add(
        "Access-Control-Allow-Methods",
        "GET, POST, OPTIONS"
    )

    $Context.Response.Headers.Add(
        "Access-Control-Allow-Headers",
        "Content-Type"
    )
}

# ============================================================
# BODY
# ============================================================

function Read-RequestBody {

    param(
        $Request
    )

    try {

        $reader =
            New-Object System.IO.StreamReader(
                $Request.InputStream,
                $Request.ContentEncoding
            )

        $body =
            $reader.ReadToEnd()

        $reader.Close()

        if ([string]::IsNullOrWhiteSpace($body)) {
            return $null
        }

        return $body | ConvertFrom-Json

    }
    catch {

        return $null
    }
}

# ============================================================
# HISTORY
# ============================================================

function Load-History {

    if (-not (Test-Path $HistoryFile)) {
        return @()
    }

    try {

        $raw =
            Get-Content `
                -Path $HistoryFile `
                -Raw

        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @()
        }

        $data =
            $raw | ConvertFrom-Json

        return @($data)

    }
    catch {

        return @()
    }
}

function Save-History {

    param(
        [array]$Items
    )

    try {

        if ($Items.Count -gt 500) {

            $Items =
                $Items |
                Select-Object -Last 500
        }

        $Items |
            ConvertTo-Json -Depth 15 |
            Set-Content `
                -Path $HistoryFile `
                -Encoding UTF8

    }
    catch {}
}

function Add-History {

    param(
        [string]$Action,
        [string]$Target,
        [string]$Result,
        $Details = $null
    )

    $history =
        @(Load-History)

    $history += [PSCustomObject]@{

        Timestamp =
            (Get-Date).ToString("o")

        JobId =
            Get-CurrentJobId

        Action =
            $Action

        Target =
            $Target

        Result =
            $Result

        Details =
            $Details
    }

    Save-History $history
}

# ============================================================
# JOB
# ============================================================

function Get-CurrentJob {

    if (-not (Test-Path $JobFile)) {
        return $null
    }

    try {

        return (
            Get-Content `
                $JobFile `
                -Raw
        ) | ConvertFrom-Json

    }
    catch {

        return $null
    }
}

function Get-CurrentJobId {

    $job =
        Get-CurrentJob

    if ($job) {
        return $job.JobId
    }

    return $null
}

function Start-JobSession {

    param(
        [string]$JobId,
        [string]$Technician = ""
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {

        $JobId =
            "IT-" +
            (Get-Date -Format "yyyyMMdd-HHmmss")
    }

    $existing =
        Get-CurrentJob

    if ($existing) {

        return $existing
    }

    $computer =
        $env:COMPUTERNAME

    $job = [PSCustomObject]@{

        JobId =
            $JobId

        Technician =
            $Technician

        ComputerName =
            $computer

        StartedAt =
            (Get-Date).ToString("o")

        EndedAt =
            $null

        Status =
            "ACTIVE"

        AgentVersion =
            $AgentVersion
    }

    $job |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -Path $JobFile `
            -Encoding UTF8

    Add-History `
        -Action "JOB_START" `
        -Target $JobId `
        -Result "SUCCESS" `
        -Details $job

    Write-AgentLog "Job started: $JobId"

    return $job
}

function End-JobSession {

    $job =
        Get-CurrentJob

    if (-not $job) {

        return [PSCustomObject]@{
            Success = $false
            Message = "No active job"
        }
    }

    $job.EndedAt =
        (Get-Date).ToString("o")

    $job.Status =
        "COMPLETED"

    $job |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -Path $JobFile `
            -Encoding UTF8

    Add-History `
        -Action "JOB_END" `
        -Target $job.JobId `
        -Result "SUCCESS" `
        -Details $job

    Write-AgentLog "Job completed: $($job.JobId)"

    return $job
}

# ============================================================
# SYSTEM
# ============================================================

function Get-SystemInfo {

    $os =
        Get-CimInstance Win32_OperatingSystem

    $cs =
        Get-CimInstance Win32_ComputerSystem

    $ip = @(
        Get-NetIPAddress `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
        Where-Object {

            $_.IPAddress -notlike "127.*" -and
            $_.IPAddress -notlike "169.254.*"

        } |
        Select-Object -ExpandProperty IPAddress
    )

    $uptime =
        (Get-Date) - $os.LastBootUpTime

    [PSCustomObject]@{

        AgentVersion =
            $AgentVersion

        Mode =
            "PORTABLE_JOB"

        ComputerName =
            $env:COMPUTERNAME

        User =
            $env:USERNAME

        IsAdmin =
            Test-IsAdmin

        Windows = [PSCustomObject]@{

            Caption =
                $os.Caption

            Version =
                $os.Version

            Build =
                $os.BuildNumber

            Architecture =
                $os.OSArchitecture
        }

        IP =
            $ip

        UptimeMinutes =
            [math]::Round(
                $uptime.TotalMinutes,
                0
            )

        Job =
            Get-CurrentJob

        Timestamp =
            (Get-Date).ToString("o")
    }
}

# ============================================================
# METRICS
# ============================================================

function Get-Metrics {

    $cpu =
        Get-CimInstance Win32_Processor |
        Measure-Object LoadPercentage -Average

    $cpuValue = 0

    if ($cpu) {

        $cpuValue =
            [math]::Round(
                [double]$cpu.Average,
                1
            )
    }

    $os =
        Get-CimInstance Win32_OperatingSystem

    $total =
        [double]$os.TotalVisibleMemorySize

    $free =
        [double]$os.FreePhysicalMemory

    $ramValue = 0

    if ($total -gt 0) {

        $ramValue =
            [math]::Round(
                (($total - $free) / $total) * 100,
                1
            )
    }

    $disk =
        Get-CimInstance Win32_LogicalDisk `
            -Filter "DeviceID='C:'"

    $diskValue = 0

    if ($disk.Size -gt 0) {

        $diskValue =
            [math]::Round(
                (
                    (
                        $disk.Size -
                        $disk.FreeSpace
                    ) /
                    $disk.Size
                ) * 100,
                1
            )
    }

    [PSCustomObject]@{

        CPU =
            $cpuValue

        RAM =
            $ramValue

        DiskC =
            $diskValue

        Timestamp =
            (Get-Date).ToString("o")
    }
}

# ============================================================
# NETWORK
# ============================================================

function Get-NetworkInfo {

    $config =
        Get-NetIPConfiguration |
        Where-Object {
            $_.IPv4DefaultGateway
        } |
        Select-Object -First 1

    $gateway = $null
    $adapter = $null
    $dns = @()

    if ($config) {

        $gateway =
            $config.IPv4DefaultGateway.NextHop

        $adapter =
            $config.InterfaceAlias

        $dns =
            @(
                $config.DNSServer.ServerAddresses
            )
    }

    $gatewayPing = $false

    if ($gateway) {

        $gatewayPing =
            Test-Connection `
                -ComputerName $gateway `
                -Count 1 `
                -Quiet `
                -ErrorAction SilentlyContinue
    }

    $internet =
        Test-Connection `
            -ComputerName "1.1.1.1" `
            -Count 1 `
            -Quiet `
            -ErrorAction SilentlyContinue

    $dnsTest = $false

    try {

        Resolve-DnsName `
            "www.microsoft.com" `
            -ErrorAction Stop |
            Out-Null

        $dnsTest = $true
    }
    catch {}

    [PSCustomObject]@{

        Adapter =
            $adapter

        Gateway =
            $gateway

        GatewayPing =
            $gatewayPing

        DNS =
            $dns

        DNSTest =
            $dnsTest

        Internet =
            $internet
    }
}

# ============================================================
# SERVICES
# ============================================================

function Get-ServiceStatus {

    $names = @(
        "Spooler"
        "wuauserv"
        "BITS"
        "WinDefend"
        "WSearch"
        "Dhcp"
        "Dnscache"
    )

    $result = @()

    foreach ($name in $names) {

        $svc =
            Get-Service `
                -Name $name `
                -ErrorAction SilentlyContinue

        if ($svc) {

            $result += [PSCustomObject]@{

                Name =
                    $svc.Name

                DisplayName =
                    $svc.DisplayName

                Status =
                    $svc.Status.ToString()

                StartType =
                    $svc.StartType.ToString()
            }
        }
    }

    return $result
}

# ============================================================
# PROCESSES
# ============================================================

function Get-ProcessList {

    $result = @()

    foreach ($p in Get-Process) {

        try {

            $cpu = 0
            $ram = 0
            $path = $null

            try {
                $cpu =
                    [math]::Round(
                        $p.CPU,
                        1
                    )
            }
            catch {}

            try {
                $ram =
                    [math]::Round(
                        $p.WorkingSet64 / 1MB,
                        1
                    )
            }
            catch {}

            try {
                $path =
                    $p.Path
            }
            catch {}

            $result += [PSCustomObject]@{

                PID =
                    $p.Id

                Name =
                    $p.ProcessName

                CPU =
                    $cpu

                RAMMB =
                    $ram

                Path =
                    $path

                Protected =
                    (
                        $ProtectedProcesses `
                        -contains $p.ProcessName
                    )
            }

        }
        catch {}
    }

    return $result
}

# ============================================================
# EVENTS
# ============================================================

function Get-EventData {

    param(
        [int]$Limit = 100
    )

    $events = @()

    foreach ($log in @(
        "System",
        "Application"
    )) {

        try {

            $items =
                Get-WinEvent `
                    -LogName $log `
                    -MaxEvents $Limit `
                    -ErrorAction Stop

            foreach ($item in $items) {

                $events += [PSCustomObject]@{

                    Log =
                        $log

                    Time =
                        $item.TimeCreated

                    Id =
                        $item.Id

                    Level =
                        $item.LevelDisplayName

                    Provider =
                        $item.ProviderName

                    Message =
                        $item.Message
                }
            }
        }
        catch {}
    }

    return @(
        $events |
        Sort-Object Time -Descending |
        Select-Object -First $Limit
    )
}

# ============================================================
# DIAGNOSTIC
# ============================================================

function Run-Diagnostics {

    $results = @()

    $metrics =
        Get-Metrics

    # CPU
    $cpuStatus =
        if ($metrics.CPU -ge 90) {
            "FAIL"
        }
        elseif ($metrics.CPU -ge 75) {
            "WARN"
        }
        else {
            "PASS"
        }

    $results += [PSCustomObject]@{

        Id =
            "cpu"

        Name =
            "CPU Usage"

        Status =
            $cpuStatus

        Value =
            "$($metrics.CPU)%"

        Evidence =
            "Current CPU usage"

        FixAvailable =
            $false
    }

    # RAM
    $ramStatus =
        if ($metrics.RAM -ge 90) {
            "FAIL"
        }
        elseif ($metrics.RAM -ge 80) {
            "WARN"
        }
        else {
            "PASS"
        }

    $results += [PSCustomObject]@{

        Id =
            "ram"

        Name =
            "Memory Usage"

        Status =
            $ramStatus

        Value =
            "$($metrics.RAM)%"

        Evidence =
            "Physical memory utilization"

        FixAvailable =
            $false
    }

    # DISK
    $diskStatus =
        if ($metrics.DiskC -ge 95) {
            "FAIL"
        }
        elseif ($metrics.DiskC -ge 85) {
            "WARN"
        }
        else {
            "PASS"
        }

    $results += [PSCustomObject]@{

        Id =
            "disk"

        Name =
            "Disk C:"

        Status =
            $diskStatus

        Value =
            "$($metrics.DiskC)%"

        Evidence =
            "Disk used"

        FixAvailable =
            $false
    }

    # NETWORK
    $network =
        Get-NetworkInfo

    $networkStatus =
        if (
            -not $network.GatewayPing -or
            -not $network.DNSTest -or
            -not $network.Internet
        ) {
            "FAIL"
        }
        else {
            "PASS"
        }

    $results += [PSCustomObject]@{

        Id =
            "network"

        Name =
            "Network Connectivity"

        Status =
            $networkStatus

        Value =
            if ($network.Internet) {
                "Online"
            }
            else {
                "Offline"
            }

        Evidence =
            "Gateway / DNS / Internet"

        FixAvailable =
            $true
    }

    # SPOOLER
    $spooler =
        Get-Service `
            -Name "Spooler" `
            -ErrorAction SilentlyContinue

    $spoolerStatus =
        if (
            $spooler -and
            $spooler.Status -eq "Running"
        ) {
            "PASS"
        }
        else {
            "FAIL"
        }

    $results += [PSCustomObject]@{

        Id =
            "spooler"

        Name =
            "Print Spooler"

        Status =
            $spoolerStatus

        Value =
            if ($spooler) {
                $spooler.Status
            }
            else {
                "Missing"
            }

        Evidence =
            "Windows Print Spooler"

        FixAvailable =
            $true
    }

    # WINDOWS UPDATE
    $wu =
        Get-Service `
            -Name "wuauserv" `
            -ErrorAction SilentlyContinue

    $wuStatus =
        if (
            $wu -and
            $wu.Status -eq "Running"
        ) {
            "PASS"
        }
        else {
            "WARN"
        }

    $results += [PSCustomObject]@{

        Id =
            "windows-update"

        Name =
            "Windows Update"

        Status =
            $wuStatus

        Value =
            if ($wu) {
                $wu.Status
            }
            else {
                "Missing"
            }

        Evidence =
            "Windows Update service"

        FixAvailable =
            $true
    }

    # DEFENDER
    $defender =
        Get-Service `
            -Name "WinDefend" `
            -ErrorAction SilentlyContinue

    $defenderStatus =
        if (
            $defender -and
            $defender.Status -eq "Running"
        ) {
            "PASS"
        }
        else {
            "WARN"
        }

    $results += [PSCustomObject]@{

        Id =
            "defender"

        Name =
            "Microsoft Defender"

        Status =
            $defenderStatus

        Value =
            if ($defender) {
                $defender.Status
            }
            else {
                "Unavailable"
            }

        Evidence =
            "Microsoft Defender service"

        FixAvailable =
            $true
    }

    # EVENTS
    $critical =
        @(
            Get-WinEvent `
                -FilterHashtable @{
                    LogName = "System"
                    Level = 1,2
                    StartTime =
                        (Get-Date).AddHours(-24)
                } `
                -ErrorAction SilentlyContinue
        )

    $eventStatus =
        if ($critical.Count -gt 20) {
            "WARN"
        }
        else {
            "PASS"
        }

    $results += [PSCustomObject]@{

        Id =
            "events"

        Name =
            "System Errors"

        Status =
            $eventStatus

        Value =
            $critical.Count

        Evidence =
            "Critical/Error events in last 24 hours"

        FixAvailable =
            $false
    }

    # SCORE
    $score = 100

    foreach ($r in $results) {

        if ($r.Status -eq "FAIL") {
            $score -= 20
        }

        if ($r.Status -eq "WARN") {
            $score -= 8
        }
    }

    if ($score -lt 0) {
        $score = 0
    }

    $diagnostic = [PSCustomObject]@{

        JobId =
            Get-CurrentJobId

        Timestamp =
            (Get-Date).ToString("o")

        Score =
            $score

        Results =
            $results
    }

    Add-History `
        -Action "DIAGNOSE" `
        -Target "FULL" `
        -Result "SUCCESS" `
        -Details $diagnostic

    return $diagnostic
}

# ============================================================
# FIX
# ============================================================

function Invoke-Fix {

    param(
        [string]$FixId
    )

    Write-AgentLog "Fix: $FixId"

    $message = ""

    switch ($FixId) {

        "restart-spooler" {

            Restart-Service `
                -Name "Spooler" `
                -Force

            $message =
                "Print Spooler restarted"
        }

        "restart-service-wuauserv" {

            Restart-Service `
                -Name "wuauserv" `
                -Force

            $message =
                "Windows Update service restarted"
        }

        "restart-bits" {

            Restart-Service `
                -Name "BITS" `
                -Force

            $message =
                "BITS restarted"
        }

        "flush-dns" {

            ipconfig /flushdns |
                Out-Null

            $message =
                "DNS cache flushed"
        }

        "renew-ip" {

            ipconfig /renew |
                Out-Null

            $message =
                "IP address renewed"
        }

        "gpupdate" {

            gpupdate.exe /force |
                Out-Null

            $message =
                "Group Policy updated"
        }

        "enable-defender" {

            Start-Service `
                -Name "WinDefend"

            $message =
                "Microsoft Defender started"
        }

        "restart-windows-search" {

            Restart-Service `
                -Name "WSearch" `
                -Force

            $message =
                "Windows Search restarted"
        }

        default {

            throw "Fix not allowed"
        }
    }

    Add-History `
        -Action "FIX" `
        -Target $FixId `
        -Result "SUCCESS" `
        -Details $message

    return [PSCustomObject]@{

        Success =
            $true

        Fix =
            $FixId

        Message =
            $message
    }
}

# ============================================================
# KILL PROCESS
# ============================================================

function Stop-SafeProcess {

    param(
        [int]$PID
    )

    $p =
        Get-Process `
            -Id $PID `
            -ErrorAction SilentlyContinue

    if (-not $p) {

        throw "Process not found"
    }

    if (
        $ProtectedProcesses `
        -contains $p.ProcessName
    ) {

        throw "Protected process"
    }

    $name =
        $p.ProcessName

    Stop-Process `
        -Id $PID `
        -Force

    Add-History `
        -Action "KILL_PROCESS" `
        -Target "$name ($PID)" `
        -Result "SUCCESS"

    return [PSCustomObject]@{

        Success =
            $true

        PID =
            $PID

        Name =
            $name
    }
}

# ============================================================
# EXPORT JOB
# ============================================================

function Export-JobData {

    $job =
        Get-CurrentJob

    if (-not $job) {

        throw "No active job"
    }

    $history =
        @(Load-History) |
        Where-Object {
            $_.JobId -eq $job.JobId
        }

    [PSCustomObject]@{

        Job =
            $job

        History =
            $history

        ExportedAt =
            (Get-Date).ToString("o")

        AgentVersion =
            $AgentVersion
    }
}

# ============================================================
# CLEANUP
# ============================================================

function Cleanup-Agent {

    Write-AgentLog "Cleanup requested"

    try {

        if (Test-Path $JobFile) {

            Remove-Item `
                $JobFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

    }
    catch {}

    try {

        $listener.Stop()
        $listener.Close()

    }
    catch {}

    Write-AgentLog "Agent stopped"

    exit
}

# ============================================================
# ROUTER
# ============================================================

function Handle-Request {

    param(
        $Context
    )

    Set-Cors $Context

    $request =
        $Context.Request

    if (
        $request.HttpMethod -eq "OPTIONS"
    ) {

        $Context.Response.StatusCode = 204
        $Context.Response.Close()

        return
    }

    $path =
        $request.Url.AbsolutePath

    try {

        switch ($path) {

            "/system" {

                Send-Json `
                    $Context `
                    (Get-SystemInfo)

                return
            }

            "/metrics" {

                Send-Json `
                    $Context `
                    (Get-Metrics)

                return
            }

            "/network" {

                Send-Json `
                    $Context `
                    (Get-NetworkInfo)

                return
            }

            "/services" {

                Send-Json `
                    $Context `
                    (Get-ServiceStatus)

                return
            }

            "/processes" {

                Send-Json `
                    $Context `
                    (Get-ProcessList)

                return
            }

            "/events" {

                Send-Json `
                    $Context `
                    (Get-EventData 100)

                return
            }

            "/history" {

                Send-Json `
                    $Context `
                    (Load-History)

                return
            }

            "/job/status" {

                Send-Json `
                    $Context `
                    @{
                        Active =
                            [bool](Get-CurrentJob)

                        Job =
                            Get-CurrentJob
                    }

                return
            }

            "/job/start" {

                if (
                    $request.HttpMethod -ne "POST"
                ) {

                    Send-Json `
                        $Context `
                        @{
                            Error = "POST required"
                        } `
                        405

                    return
                }

                $body =
                    Read-RequestBody $request

                $job =
                    Start-JobSession `
                        -JobId (
                            if ($body) {
                                [string]$body.JobId
                            }
                            else {
                                ""
                            }
                        ) `
                        -Technician (
                            if ($body) {
                                [string]$body.Technician
                            }
                            else {
                                ""
                            }
                        )

                Send-Json `
                    $Context `
                    $job

                return
            }

            "/job/end" {

                if (
                    $request.HttpMethod -ne "POST"
                ) {

                    Send-Json `
                        $Context `
                        @{
                            Error = "POST required"
                        } `
                        405

                    return
                }

                $job =
                    End-JobSession

                Send-Json `
                    $Context `
                    $job

                return
            }

            "/job/export" {

                Send-Json `
                    $Context `
                    (Export-JobData)

                return
            }

            "/diagnose" {

                if (-not (Get-CurrentJob)) {

                    Send-Json `
                        $Context `
                        @{
                            Error =
                                "No active job"
                        } `
                        409

                    return
                }

                Send-Json `
                    $Context `
                    (Run-Diagnostics)

                return
            }

            "/fix" {

                if (
                    $request.HttpMethod -ne "POST"
                ) {

                    Send-Json `
                        $Context `
                        @{
                            Error = "POST required"
                        } `
                        405

                    return
                }

                if (-not (Get-CurrentJob)) {

                    Send-Json `
                        $Context `
                        @{
                            Error =
                                "No active job"
                        } `
                        409

                    return
                }

                $body =
                    Read-RequestBody $request

                if (
                    -not $body -or
                    -not $body.fix
                ) {

                    Send-Json `
                        $Context `
                        @{
                            Error =
                                "Fix ID required"
                        } `
                        400

                    return
                }

                Send-Json `
                    $Context `
                    (
                        Invoke-Fix `
                            -FixId (
                                [string]$body.fix
                            )
                    )

                return
            }

            "/kill" {

                if (
                    $request.HttpMethod -ne "POST"
                ) {

                    Send-Json `
                        $Context `
                        @{
                            Error = "POST required"
                        } `
                        405

                    return
                }

                if (-not (Get-CurrentJob)) {

                    Send-Json `
                        $Context `
                        @{
                            Error =
                                "No active job"
                        } `
                        409

                    return
                }

                $body =
                    Read-RequestBody $request

                if (
                    -not $body -or
                    -not $body.pid
                ) {

                    Send-Json `
                        $Context `
                        @{
                            Error = "PID required"
                        } `
                        400

                    return
                }

                Send-Json `
                    $Context `
                    (
                        Stop-SafeProcess `
                            -PID (
                                [int]$body.pid
                            )
                    )

                return
            }

            "/agent/stop" {

                Send-Json `
                    $Context `
                    @{
                        Success = $true
                        Message =
                            "Agent stopping"
                    }

                Start-Job {

                    Start-Sleep `
                        -Milliseconds 300

                    Stop-Process `
                        -Id $PID `
                        -Force

                } | Out-Null

                return
            }

            default {

                Send-Json `
                    $Context `
                    @{
                        Error = "Not Found"
                    } `
                    404

                return
            }
        }

    }
    catch {

        Write-AgentLog `
            "ERROR [$path] $($_.Exception.Message)"

        Send-Json `
            $Context `
            @{
                Success = $false
                Error =
                    $_.Exception.Message
            } `
            500
    }
}

# ============================================================
# HTTP SERVER
# ============================================================

$listener =
    New-Object System.Net.HttpListener

$listener.Prefixes.Add(
    "http://$BindAddress`:$Port/"
)

try {

    $listener.Start()

}
catch {

    Write-AgentLog `
        "Cannot start HTTP listener"

    exit 1
}

Write-AgentLog `
    "Listening on http://$BindAddress`:$Port/"

# ============================================================
# OPEN PORTAL
# ============================================================

try {

    Start-Process `
        "https://itchula001.github.io/diagnostic/"

}
catch {}

# ============================================================
# MAIN LOOP
# ============================================================

while ($listener.IsListening) {

    try {

        $context =
            $listener.GetContext()

        Handle-Request $context

    }
    catch {

        Write-AgentLog `
            "Listener error: $($_.Exception.Message)"

        Start-Sleep `
            -Milliseconds 300
    }
}