# ============================================================
# IT FIELD DIAGNOSTIC AGENT V5.1
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

$AgentUrl = "http://127.0.0.1:8765/"
$AgentTempDir = Join-Path $env:TEMP "ITDiagV5"
$AgentDataDir = Join-Path $env:LOCALAPPDATA "ITDiagV5"
$HistoryFile = Join-Path $AgentDataDir "history.json"
$ReportDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "ITDiag-Reports"

New-Item -ItemType Directory -Force -Path $AgentTempDir | Out-Null
New-Item -ItemType Directory -Force -Path $AgentDataDir | Out-Null
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

# ============================================================
# GLOBAL STATE
# ============================================================

$global:CurrentJob = $null
$global:History = @()

if (Test-Path $HistoryFile) {
    try {
        $raw = Get-Content $HistoryFile -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $parsed = $raw | ConvertFrom-Json
            if ($null -ne $parsed) {
                $global:History = @($parsed)
            }
        }
    }
    catch {
        $global:History = @()
    }
}

# ============================================================
# SAVE HISTORY
# ============================================================

function Save-History {

    try {

        $global:History |
            ConvertTo-Json -Depth 10 |
            Set-Content `
                -Path $HistoryFile `
                -Encoding UTF8

    }
    catch {
    }
}

# ============================================================
# JSON RESPONSE
# ============================================================

function Send-JsonResponse {

    param(
        $Context,
        $Data,
        [int]$StatusCode = 200
    )

    try {

        $json =
            $Data |
            ConvertTo-Json -Depth 20 -Compress

        $bytes =
            [System.Text.Encoding]::UTF8.GetBytes($json)

        $response =
            $Context.Response

        $response.StatusCode =
            $StatusCode

        $response.ContentType =
            "application/json; charset=utf-8"

        $response.ContentEncoding =
            [System.Text.Encoding]::UTF8

        $response.ContentLength64 =
            $bytes.Length

        $response.OutputStream.Write(
            $bytes,
            0,
            $bytes.Length
        )

        $response.OutputStream.Close()

    }
    catch {
    }
}

# ============================================================
# READ REQUEST BODY
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

        return (
            $body | ConvertFrom-Json
        )

    }
    catch {

        return $null
    }
}

# ============================================================
# SYSTEM INFO
# ============================================================

function Get-SystemInfo {

    try {

        $os =
            Get-CimInstance Win32_OperatingSystem

        $computer =
            Get-CimInstance Win32_ComputerSystem

        $bios =
            Get-CimInstance Win32_BIOS

        return [PSCustomObject]@{

            computer =
                $env:COMPUTERNAME

            user =
                $env:USERNAME

            manufacturer =
                $computer.Manufacturer

            model =
                $computer.Model

            windows =
                $os.Caption

            build =
                $os.BuildNumber

            architecture =
                $os.OSArchitecture

            memoryGB =
                [math]::Round(
                    $computer.TotalPhysicalMemory / 1GB,
                    2
                )

            serial =
                $bios.SerialNumber
        }

    }
    catch {

        return [PSCustomObject]@{

            computer = $env:COMPUTERNAME
            user = $env:USERNAME
            manufacturer = ""
            model = ""
            windows = ""
            build = ""
            architecture = ""
            memoryGB = 0
            serial = ""
        }
    }
}

# ============================================================
# METRICS
# ============================================================

function Get-Metrics {

    try {

        $cpuData =
            Get-CimInstance Win32_Processor

        $cpu =
            [math]::Round(
                (
                    $cpuData |
                    Measure-Object LoadPercentage -Average
                ).Average,
                0
            )

        $os =
            Get-CimInstance Win32_OperatingSystem

        $totalRam =
            [double]$os.TotalVisibleMemorySize

        $freeRam =
            [double]$os.FreePhysicalMemory

        $ram =
            if ($totalRam -gt 0) {
                [math]::Round(
                    (($totalRam - $freeRam) / $totalRam) * 100,
                    0
                )
            }
            else {
                0
            }

        $ramFreeGB =
            [math]::Round(
                $freeRam / 1MB,
                2
            )

        $disk =
            Get-CimInstance Win32_LogicalDisk `
                -Filter "DeviceID='C:'"

        $diskUsage =
            if ($disk.Size -gt 0) {
                [math]::Round(
                    (
                        ($disk.Size - $disk.FreeSpace) /
                        $disk.Size
                    ) * 100,
                    0
                )
            }
            else {
                0
            }

        $diskFreeGB =
            [math]::Round(
                $disk.FreeSpace / 1GB,
                2
            )

        return [PSCustomObject]@{

            cpu =
                $cpu

            ram =
                $ram

            ramFreeGB =
                $ramFreeGB

            disk =
                $diskUsage

            diskFreeGB =
                $diskFreeGB
        }

    }
    catch {

        return [PSCustomObject]@{
            cpu = 0
            ram = 0
            ramFreeGB = 0
            disk = 0
            diskFreeGB = 0
        }
    }
}

# ============================================================
# NETWORK
# ============================================================

function Get-NetworkInfo {

    $adapters = @()

    try {

        $configs =
            Get-CimInstance Win32_NetworkAdapterConfiguration `
                -Filter "IPEnabled=True"

        foreach ($item in $configs) {

            $ipv4 = ""

            if ($item.IPAddress) {

                $ipv4 =
                    @(
                        $item.IPAddress |
                        Where-Object {
                            $_ -match "^\d+\.\d+\.\d+\.\d+$"
                        }
                    ) -join ", "
            }

            $gateway =
                if ($item.DefaultIPGateway) {
                    $item.DefaultIPGateway -join ", "
                }
                else {
                    ""
                }

            $dns =
                if ($item.DNSServerSearchOrder) {
                    $item.DNSServerSearchOrder -join ", "
                }
                else {
                    ""
                }

            $adapters +=
                [PSCustomObject]@{

                    interface =
                        $item.Description

                    ipv4 =
                        $ipv4

                    gateway =
                        $gateway

                    dns =
                        $dns
                }
        }
    }
    catch {
    }

    $internet = $false

    try {

        $test =
            Test-Connection `
                -ComputerName "1.1.1.1" `
                -Count 1 `
                -Quiet `
                -ErrorAction SilentlyContinue

        $internet =
            [bool]$test
    }
    catch {
        $internet = $false
    }

    return [PSCustomObject]@{

        internet =
            $internet

        adapters =
            @($adapters)
    }
}

# ============================================================
# SERVICES
# ============================================================

function Get-ServiceStatus {

    $important =
        @(
            "Dhcp",
            "Dnscache",
            "EventLog",
            "Winmgmt",
            "Spooler",
            "wuauserv",
            "BITS"
        )

    $result = @()

    foreach ($name in $important) {

        try {

            $service =
                Get-CimInstance Win32_Service `
                    -Filter "Name='$name'"

            if ($service) {

                $result +=
                    [PSCustomObject]@{

                        name =
                            $service.Name

                        displayName =
                            $service.DisplayName

                        status =
                            $service.State

                        startType =
                            $service.StartMode
                    }
            }
        }
        catch {
        }
    }

    return @($result)
}

# ============================================================
# PROCESSES
# ============================================================

function Get-ProcessStatus {

    $result = @()

    try {

        $items =
            Get-Process |
            Sort-Object WorkingSet64 -Descending |
            Select-Object -First 60

        foreach ($item in $items) {

            $cpu = 0

            try {
                $cpu =
                    [math]::Round(
                        $item.CPU,
                        1
                    )
            }
            catch {
                $cpu = 0
            }

            $memory =
                [math]::Round(
                    $item.WorkingSet64 / 1MB,
                    1
                )

            $result +=
                [PSCustomObject]@{

                    id =
                        $item.Id

                    name =
                        $item.ProcessName

                    cpu =
                        $cpu

                    memoryMB =
                        $memory
                }
        }
    }
    catch {
    }

    return @($result)
}

# ============================================================
# WINDOWS EVENTS
# ============================================================

function Get-Events {

    $result = @()

    try {

        $events =
            Get-WinEvent `
                -FilterHashtable @{
                    LogName = "System"
                    Level = 1,2,3
                } `
                -MaxEvents 40

        foreach ($event in $events) {

            $result +=
                [PSCustomObject]@{

                    time =
                        $event.TimeCreated.ToString("s")

                    id =
                        $event.Id

                    provider =
                        $event.ProviderName

                    level =
                        $event.LevelDisplayName

                    message =
                        $event.Message
                }
        }
    }
    catch {
    }

    return @($result)
}

# ============================================================
# DIAGNOSTICS
# ============================================================

function Run-Diagnostics {

    $metrics =
        Get-Metrics

    $network =
        Get-NetworkInfo

    $services =
        Get-ServiceStatus

    $problems = @()

    if ($metrics.cpu -ge 90) {

        $problems +=
            [PSCustomObject]@{

                title =
                    "High CPU usage"

                severity =
                    "High"

                description =
                    "CPU usage is currently $($metrics.cpu)%."

                recommendedFix =
                    "Check processes using high CPU."
            }
    }

    if ($metrics.ram -ge 90) {

        $problems +=
            [PSCustomObject]@{

                title =
                    "High memory usage"

                severity =
                    "High"

                description =
                    "RAM usage is currently $($metrics.ram)%."

                recommendedFix =
                    "Review running processes and memory usage."
            }
    }

    if ($metrics.disk -ge 90) {

        $problems +=
            [PSCustomObject]@{

                title =
                    "Low disk space"

                severity =
                    "High"

                description =
                    "C: drive usage is $($metrics.disk)%."

                recommendedFix =
                    "Free disk space on drive C:."
            }
    }

    if (-not $network.internet) {

        $problems +=
            [PSCustomObject]@{

                title =
                    "Internet connectivity problem"

                severity =
                    "Medium"

                description =
                    "The Agent could not reach the Internet."

                recommendedFix =
                    "Check network adapter, gateway and DNS."
            }
    }

    foreach ($service in $services) {

        if (
            $service.Name -in
            @(
                "Dhcp",
                "Dnscache",
                "EventLog",
                "Winmgmt"
            )
        ) {

            if ($service.status -ne "Running") {

                $problems +=
                    [PSCustomObject]@{

                        title =
                            "Service not running: $($service.displayName)"

                        severity =
                            "Medium"

                        description =
                            "$($service.Name) is $($service.status)."

                        recommendedFix =
                            "Review and restart the service if appropriate."
                    }
            }
        }
    }

    $health = 100

    if ($metrics.cpu -ge 90) {
        $health -= 25
    }
    elseif ($metrics.cpu -ge 75) {
        $health -= 10
    }

    if ($metrics.ram -ge 90) {
        $health -= 25
    }
    elseif ($metrics.ram -ge 75) {
        $health -= 10
    }

    if ($metrics.disk -ge 90) {
        $health -= 25
    }
    elseif ($metrics.disk -ge 80) {
        $health -= 10
    }

    if (-not $network.internet) {
        $health -= 20
    }

    if ($health -lt 0) {
        $health = 0
    }

    return [PSCustomObject]@{

        health =
            $health

        problems =
            @($problems)
    }
}

# ============================================================
# JOB EVENT
# ============================================================

function Add-JobEvent {

    param(
        [string]$Action,
        [string]$Message
    )

    if ($null -eq $global:CurrentJob) {
        return
    }

    $event =
        [PSCustomObject]@{

            time =
                (Get-Date).ToString("s")

            action =
                $Action

            message =
                $Message
        }

    $global:CurrentJob.events +=
        $event
}

# ============================================================
# START JOB
# ============================================================

function Start-NewJob {

    if ($null -ne $global:CurrentJob) {

        return @{
            success = $false
            message = "A job is already active."
            job = $global:CurrentJob
        }
    }

    $jobId =
        "JOB-" +
        (Get-Date -Format "yyyyMMdd-HHmmss")

    $global:CurrentJob =
        [PSCustomObject]@{

            id =
                $jobId

            computer =
                $env:COMPUTERNAME

            user =
                $env:USERNAME

            startedAt =
                (Get-Date).ToString("s")

            endedAt =
                $null

            status =
                "ACTIVE"

            events =
                @()
        }

    Add-JobEvent `
        "job-start" `
        "Diagnostic job started."

    return @{
        success = $true
        job = $global:CurrentJob
        message = "Job started successfully."
    }
}

# ============================================================
# HTML ESCAPE
# ============================================================

function ConvertTo-HtmlSafe {

    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    return (
        [System.Net.WebUtility]::HtmlEncode(
            [string]$Value
        )
    )
}

# ============================================================
# REPORT
# ============================================================

function New-JobReport {

    param(
        $Job
    )

    try {

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $ReportDir |
            Out-Null

        $safeId =
            $Job.id -replace '[^a-zA-Z0-9\-_]', '_'

        $reportFile =
            Join-Path `
                $ReportDir `
                "$safeId.html"

        $system =
            Get-SystemInfo

        $metrics =
            Get-Metrics

        $network =
            Get-NetworkInfo

        $services =
            Get-ServiceStatus

        $events =
            Get-Events

        $diagnostics =
            Run-Diagnostics

        $problemRows = ""

        foreach ($problem in $diagnostics.problems) {

            $problemRows +=
                "<tr>" +
                "<td>$(ConvertTo-HtmlSafe $problem.title)</td>" +
                "<td>$(ConvertTo-HtmlSafe $problem.severity)</td>" +
                "<td>$(ConvertTo-HtmlSafe $problem.description)</td>" +
                "<td>$(ConvertTo-HtmlSafe $problem.recommendedFix)</td>" +
                "</tr>"
        }

        if ([string]::IsNullOrWhiteSpace($problemRows)) {

            $problemRows =
                "<tr><td colspan='4'>No detected problems.</td></tr>"
        }

        $serviceRows = ""

        foreach ($service in $services) {

            $serviceRows +=
                "<tr>" +
                "<td>$(ConvertTo-HtmlSafe $service.name)</td>" +
                "<td>$(ConvertTo-HtmlSafe $service.displayName)</td>" +
                "<td>$(ConvertTo-HtmlSafe $service.status)</td>" +
                "<td>$(ConvertTo-HtmlSafe $service.startType)</td>" +
                "</tr>"
        }

        $eventRows = ""

        foreach ($event in $events) {

            $eventRows +=
                "<tr>" +
                "<td>$(ConvertTo-HtmlSafe $event.time)</td>" +
                "<td>$(ConvertTo-HtmlSafe $event.id)</td>" +
                "<td>$(ConvertTo-HtmlSafe $event.provider)</td>" +
                "<td>$(ConvertTo-HtmlSafe $event.level)</td>" +
                "<td>$(ConvertTo-HtmlSafe $event.message)</td>" +
                "</tr>"
        }

        $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>IT Diagnostic Report - $($Job.id)</title>
<style>
body {
    font-family: Segoe UI, Arial, sans-serif;
    margin: 30px;
    background: #f4f6f8;
    color: #17202a;
}
h1 { margin-bottom: 5px; }
.card {
    background: white;
    border: 1px solid #d8dee4;
    border-radius: 10px;
    padding: 20px;
    margin-bottom: 20px;
}
.grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
}
.metric {
    background: #eef2f5;
    padding: 14px;
    border-radius: 8px;
}
.label {
    color: #68737d;
    font-size: 12px;
}
.value {
    font-size: 20px;
    font-weight: bold;
    margin-top: 5px;
}
table {
    width: 100%;
    border-collapse: collapse;
}
th, td {
    border: 1px solid #d8dee4;
    padding: 8px;
    text-align: left;
    vertical-align: top;
}
th {
    background: #eef2f5;
}
.ok {
    color: green;
    font-weight: bold;
}
</style>
</head>

<body>

<h1>IT FIELD DIAGNOSTIC PORTAL V5</h1>

<p>
Generated:
$(Get-Date)
</p>

<div class="card">

<h2>Job Information</h2>

<div class="grid">

<div class="metric">
<div class="label">Job ID</div>
<div class="value">$($Job.id)</div>
</div>

<div class="metric">
<div class="label">Computer</div>
<div class="value">$($Job.computer)</div>
</div>

<div class="metric">
<div class="label">User</div>
<div class="value">$($Job.user)</div>
</div>

<div class="metric">
<div class="label">Started</div>
<div class="value">$($Job.startedAt)</div>
</div>

<div class="metric">
<div class="label">Ended</div>
<div class="value">$($Job.endedAt)</div>
</div>

</div>
</div>

<div class="card">

<h2>System Information</h2>

<div class="grid">

<div class="metric">
<div class="label">Computer</div>
<div class="value">$($system.computer)</div>
</div>

<div class="metric">
<div class="label">User</div>
<div class="value">$($system.user)</div>
</div>

<div class="metric">
<div class="label">Manufacturer</div>
<div class="value">$($system.manufacturer)</div>
</div>

<div class="metric">
<div class="label">Model</div>
<div class="value">$($system.model)</div>
</div>

<div class="metric">
<div class="label">Windows</div>
<div class="value">$($system.windows)</div>
</div>

<div class="metric">
<div class="label">Build</div>
<div class="value">$($system.build)</div>
</div>

<div class="metric">
<div class="label">Architecture</div>
<div class="value">$($system.architecture)</div>
</div>

<div class="metric">
<div class="label">Memory</div>
<div class="value">$($system.memoryGB) GB</div>
</div>

</div>
</div>

<div class="card">

<h2>System Health</h2>

<div class="grid">

<div class="metric">
<div class="label">Health</div>
<div class="value">$($diagnostics.health) / 100</div>
</div>

<div class="metric">
<div class="label">CPU</div>
<div class="value">$($metrics.cpu)%</div>
</div>

<div class="metric">
<div class="label">RAM</div>
<div class="value">$($metrics.ram)%</div>
</div>

<div class="metric">
<div class="label">Disk C:</div>
<div class="value">$($metrics.disk)%</div>
</div>

<div class="metric">
<div class="label">Free RAM</div>
<div class="value">$($metrics.ramFreeGB) GB</div>
</div>

<div class="metric">
<div class="label">Free Disk</div>
<div class="value">$($metrics.diskFreeGB) GB</div>
</div>

</div>
</div>

<div class="card">

<h2>Diagnostics</h2>

<table>
<thead>
<tr>
<th>Problem</th>
<th>Severity</th>
<th>Description</th>
<th>Recommended Fix</th>
</tr>
</thead>
<tbody>
$problemRows
</tbody>
</table>

</div>

<div class="card">

<h2>Network</h2>

<p>
Internet:
<strong>
$(if ($network.internet) { "ONLINE" } else { "OFFLINE" })
</strong>
</p>

<table>
<thead>
<tr>
<th>Interface</th>
<th>IPv4</th>
<th>Gateway</th>
<th>DNS</th>
</tr>
</thead>
<tbody>
$(
    (
        $network.adapters |
        ForEach-Object {
            "<tr>" +
            "<td>$($_.interface)</td>" +
            "<td>$($_.ipv4)</td>" +
            "<td>$($_.gateway)</td>" +
            "<td>$($_.dns)</td>" +
            "</tr>"
        }
    ) -join ""
)
</tbody>
</table>

</div>

<div class="card">

<h2>Services</h2>

<table>
<thead>
<tr>
<th>Name</th>
<th>Display Name</th>
<th>Status</th>
<th>Start Type</th>
</tr>
</thead>
<tbody>
$serviceRows
</tbody>
</table>

</div>

<div class="card">

<h2>Windows Events</h2>

<table>
<thead>
<tr>
<th>Time</th>
<th>ID</th>
<th>Provider</th>
<th>Level</th>
<th>Message</th>
</tr>
</thead>
<tbody>
$eventRows
</tbody>
</table>

</div>

<div class="card">

<h2>Job Activity</h2>

<table>
<thead>
<tr>
<th>Time</th>
<th>Action</th>
<th>Message</th>
</tr>
</thead>
<tbody>
$(
    (
        $Job.events |
        ForEach-Object {
            "<tr>" +
            "<td>$($_.time)</td>" +
            "<td>$($_.action)</td>" +
            "<td>$($_.message)</td>" +
            "</tr>"
        }
    ) -join ""
)
</tbody>
</table>

</div>

</body>
</html>
"@

        Set-Content `
            -Path $reportFile `
            -Value $html `
            -Encoding UTF8

        return $reportFile

    }
    catch {

        return $null
    }
}

# ============================================================
# END JOB
# ============================================================

function End-CurrentJob {

    if ($null -eq $global:CurrentJob) {

        return @{
            success = $false
            message = "No active job."
            report = $null
        }
    }

    $global:CurrentJob.endedAt =
        (Get-Date).ToString("s")

    $global:CurrentJob.status =
        "COMPLETED"

    Add-JobEvent `
        "job-end" `
        "Diagnostic job ended."

    $finished =
        $global:CurrentJob

    $reportFile =
        New-JobReport `
            -Job $finished

    $global:History +=
        $finished

    Save-History

    $global:CurrentJob =
        $null

    return @{
        success = $true
        job = $finished
        report = $reportFile
        message = "Job ended successfully."
    }
}

# ============================================================
# KILL PROCESS
# ============================================================

function Stop-TargetProcess {

    param(
        [int]$ProcessId
    )

    if ($ProcessId -eq 4) {

        return @{
            success = $false
            message = "PID 4 is protected."
        }
    }

    if ($ProcessId -le 0) {

        return @{
            success = $false
            message = "Invalid process ID."
        }
    }

    try {

        $process =
            Get-Process `
                -Id $ProcessId `
                -ErrorAction Stop

        $protected =
            @(
                "System",
                "Idle",
                "Memory Compression",
                "explorer",
                "svchost",
                "csrss",
                "smss",
                "wininit",
                "services",
                "lsass",
                "winlogon",
                "dwm",
                "sihost",
                "taskhostw"
            )

        if (
            $protected -contains
            $process.ProcessName
        ) {

            return @{
                success = $false
                message =
                    "Protected process cannot be terminated."
            }
        }

        Stop-Process `
            -Id $ProcessId `
            -Force `
            -ErrorAction Stop

        return @{
            success = $true
            message =
                "Process terminated."
            pid =
                $ProcessId
        }

    }
    catch {

        return @{
            success = $false
            message =
                $_.Exception.Message
        }
    }
}

# ============================================================
# REPORT STATUS
# ============================================================

function Get-ReportStatus {

    param(
        [string]$JobId
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {

        return @{
            success = $false
            ready = $false
            message = "Job ID is required."
        }
    }

    $safeId =
        $JobId -replace '[^a-zA-Z0-9\-_]', '_'

    $file =
        Join-Path `
            $ReportDir `
            "$safeId.html"

    if (Test-Path $file) {

        return @{
            success = $true
            ready = $true
            status = "ready"
            path = $file
        }
    }

    return @{
        success = $true
        ready = $false
        status = "pending"
        path = $file
    }
}

# ============================================================
# HTTP LISTENER
# ============================================================

$listener =
    New-Object System.Net.HttpListener

try {

    $listener.Prefixes.Add(
        $AgentUrl
    )

    $listener.Start()

}
catch {

    Write-Host ""
    Write-Host "Unable to start IT Diagnostic Agent." `
        -ForegroundColor Red
    Write-Host $_.Exception.Message `
        -ForegroundColor Red
    Write-Host ""

    exit 1
}

Write-Host ""
Write-Host "IT Diagnostic Agent V5.1" `
    -ForegroundColor Green
Write-Host "Listening on $AgentUrl" `
    -ForegroundColor Cyan
Write-Host ""

# ============================================================
# REQUEST LOOP
# ============================================================

try {

    while ($listener.IsListening) {

        $context = $null

        try {

            $context =
                $listener.GetContext()

        }
        catch {

            if (-not $listener.IsListening) {
                break
            }

            continue
        }

        if ($null -eq $context) {
            continue
        }

        $request =
            $context.Request

        $path =
            $request.Url.AbsolutePath

        $method =
            $request.HttpMethod

        $response =
            $context.Response

        # ----------------------------------------------------
        # CORS
        # ----------------------------------------------------

        $response.Headers.Add(
            "Access-Control-Allow-Origin",
            "*"
        )

        $response.Headers.Add(
            "Access-Control-Allow-Methods",
            "GET,POST,OPTIONS"
        )

        $response.Headers.Add(
            "Access-Control-Allow-Headers",
            "Content-Type"
        )

        # ----------------------------------------------------
        # OPTIONS
        # ----------------------------------------------------

        if ($method -eq "OPTIONS") {

            $response.StatusCode = 204
            $response.Close()

            continue
        }

        # ----------------------------------------------------
        # ROOT
        # ----------------------------------------------------

        if ($path -eq "/") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    agent =
                        "IT Diagnostic Agent V5.1"
                    version =
                        "5.1"
                    status =
                        "online"
                }

            continue
        }

        # ----------------------------------------------------
        # STATUS
        # ----------------------------------------------------

        if ($path -eq "/agent/status") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    online = $true
                    version = "5.1"
                    agent =
                        "IT Diagnostic Agent V5.1"
                    pid = $PID
                    computer =
                        $env:COMPUTERNAME
                    user =
                        $env:USERNAME
                }

            continue
        }

        # ----------------------------------------------------
        # SYSTEM
        # ----------------------------------------------------

        if ($path -eq "/system") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    data =
                        Get-SystemInfo
                }

            continue
        }

        # ----------------------------------------------------
        # METRICS
        # ----------------------------------------------------

        if ($path -eq "/metrics") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    data =
                        Get-Metrics
                }

            continue
        }

        # ----------------------------------------------------
        # NETWORK
        # ----------------------------------------------------

        if ($path -eq "/network") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    data =
                        Get-NetworkInfo
                }

            continue
        }

        # ----------------------------------------------------
        # SERVICES
        # ----------------------------------------------------

        if ($path -eq "/services") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    data =
                        Get-ServiceStatus
                }

            continue
        }

        # ----------------------------------------------------
        # PROCESSES
        # ----------------------------------------------------

        if ($path -eq "/processes") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    data =
                        Get-ProcessStatus
                }

            continue
        }

        # ----------------------------------------------------
        # EVENTS
        # ----------------------------------------------------

        if ($path -eq "/events") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    data =
                        Get-Events
                }

            continue
        }

        # ----------------------------------------------------
        # DIAGNOSE
        # ----------------------------------------------------

        if ($path -eq "/diagnose") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    data =
                        Run-Diagnostics
                }

            continue
        }

        # ----------------------------------------------------
        # START JOB
        # ----------------------------------------------------

        if (
            $path -eq "/job/start" -and
            $method -eq "POST"
        ) {

            Send-JsonResponse `
                $context `
                (Start-NewJob)

            continue
        }

        # ----------------------------------------------------
        # JOB STATUS
        # ----------------------------------------------------

        if ($path -eq "/job/status") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    active =
                        ($null -ne $global:CurrentJob)
                    job =
                        $global:CurrentJob
                }

            continue
        }

        # ----------------------------------------------------
        # END JOB
        # ----------------------------------------------------

        if (
            $path -eq "/job/end" -and
            $method -eq "POST"
        ) {

            Send-JsonResponse `
                $context `
                (End-CurrentJob)

            continue
        }

        # ----------------------------------------------------
        # HISTORY
        # ----------------------------------------------------

        if ($path -eq "/history") {

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    data =
                        @($global:History)
                }

            continue
        }

        # ----------------------------------------------------
        # KILL
        # ----------------------------------------------------

        if (
            $path -eq "/kill" -and
            $method -eq "POST"
        ) {

            try {

                $data =
                    Read-RequestBody `
                        $request

                $pidValue =
                    [int]$data.pid

                Send-JsonResponse `
                    $context `
                    (
                        Stop-TargetProcess `
                            -ProcessId $pidValue
                    )
            }
            catch {

                Send-JsonResponse `
                    $context `
                    @{
                        success = $false
                        message =
                            $_.Exception.Message
                    }
            }

            continue
        }

        # ----------------------------------------------------
        # REPORT STATUS
        # ----------------------------------------------------

        if ($path -eq "/report/status") {

            $jobId =
                $request.QueryString["jobId"]

            Send-JsonResponse `
                $context `
                (
                    Get-ReportStatus `
                        -JobId $jobId
                )

            continue
        }

        # ----------------------------------------------------
        # REPORT OPEN
        # ----------------------------------------------------

        if ($path -eq "/report/open") {

            $jobId =
                $request.QueryString["jobId"]

            $status =
                Get-ReportStatus `
                    -JobId $jobId

            if ($status.ready) {

                try {

                    Start-Process `
                        -FilePath $status.path

                    Send-JsonResponse `
                        $context `
                        @{
                            success = $true
                            path =
                                $status.path
                        }

                }
                catch {

                    Send-JsonResponse `
                        $context `
                        @{
                            success = $false
                            message =
                                $_.Exception.Message
                        }
                }

            }
            else {

                Send-JsonResponse `
                    $context `
                    @{
                        success = $false
                        ready = $false
                        message =
                            "Report is not ready."
                    }
            }

            continue
        }

        # ----------------------------------------------------
        # AGENT STOP
        # ----------------------------------------------------

        if (
            $path -eq "/agent/stop" -and
            $method -eq "POST"
        ) {

            $targetPid =
                $PID

            Send-JsonResponse `
                $context `
                @{
                    success = $true
                    message =
                        "Agent stopping."
                }

            Start-Job -ScriptBlock {

                param(
                    $ProcessId,
                    $TempDirectory
                )

                Start-Sleep `
                    -Milliseconds 800

                try {

                    if (
                        Test-Path
                        $TempDirectory
                    ) {

                        Remove-Item `
                            -Path $TempDirectory `
                            -Recurse `
                            -Force `
                            -ErrorAction SilentlyContinue
                    }

                }
                catch {
                }

                Start-Sleep `
                    -Milliseconds 300

                try {

                    Stop-Process `
                        -Id $ProcessId `
                        -Force `
                        -ErrorAction SilentlyContinue

                }
                catch {
                }

            } `
            -ArgumentList `
                $targetPid,
                $AgentTempDir |
            Out-Null

            continue
        }

        # ----------------------------------------------------
        # 404
        # ----------------------------------------------------

        Send-JsonResponse `
            $context `
            @{
                success = $false
                message =
                    "Endpoint not found."
                path =
                    $path
            } `
            404
    }

}
finally {

    try {

        if ($listener.IsListening) {
            $listener.Stop()
        }

    }
    catch {
    }

    try {
        $listener.Close()
    }
    catch {
    }
}