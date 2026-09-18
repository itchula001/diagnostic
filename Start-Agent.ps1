# ============================================================
# IT FIELD DIAGNOSTIC PORTAL V5
# START-AGENT.PS1
# Version: 5.1
# ============================================================

$ErrorActionPreference = "Continue"

$AgentVersion = "5.1"
$AgentName    = "IT Diagnostic Agent V5.1"
$AgentPort    = 8765
$AgentPrefix  = "http://127.0.0.1:8765/"

$BaseDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir      = Join-Path $BaseDir "data"
$TempDir      = Join-Path $env:TEMP "ITDiagV5"
$ReportDir    = Join-Path $env:USERPROFILE "Desktop\ITDiag-Reports"

$CurrentJobFile = Join-Path $DataDir "current-job.json"
$HistoryFile    = Join-Path $DataDir "job-history.json"

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null


# ============================================================
# GLOBAL STATE
# ============================================================

$global:CurrentJob = $null
$global:StopRequested = $false


# ============================================================
# BASIC FUNCTIONS
# ============================================================

function Get-TimeStamp {
    return (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

function New-JobId {
    return "JOB-" + (Get-Date).ToString("yyyyMMdd-HHmmss")
}

function Convert-ToJsonSafe {
    param(
        [Parameter(Mandatory = $false)]
        $Object
    )

    if ($null -eq $Object) {
        return "null"
    }

    return ($Object | ConvertTo-Json -Depth 20 -Compress)
}

function HtmlEncode {
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) {
        return ""
    }

    return [System.Net.WebUtility]::HtmlEncode(
        [string]$Value
    )
}


# ============================================================
# JSON FILE HELPERS
# ============================================================

function Save-JsonFile {
    param(
        [string]$Path,
        $Object
    )

    try {
        $json = $Object | ConvertTo-Json -Depth 30
        [System.IO.File]::WriteAllText(
            $Path,
            $json,
            [System.Text.Encoding]::UTF8
        )
        return $true
    }
    catch {
        return $false
    }
}

function Read-JsonFile {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        return ($raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}


# ============================================================
# CURRENT JOB
# ============================================================

function Save-CurrentJob {
    if ($null -eq $global:CurrentJob) {
        return
    }

    Save-JsonFile -Path $CurrentJobFile -Object $global:CurrentJob | Out-Null
}

function Load-CurrentJob {

    if (-not (Test-Path $CurrentJobFile)) {
        $global:CurrentJob = $null
        return
    }

    $job = Read-JsonFile -Path $CurrentJobFile

    if ($null -eq $job) {
        $global:CurrentJob = $null
        return
    }

    if ($job.status -eq "ACTIVE") {
        $global:CurrentJob = $job
    }
    else {
        $global:CurrentJob = $null
    }
}

function Get-History {

    if (-not (Test-Path $HistoryFile)) {
        return @()
    }

    $history = Read-JsonFile -Path $HistoryFile

    if ($null -eq $history) {
        return @()
    }

    if ($history -is [System.Array]) {
        return @($history)
    }

    return @($history)
}

function Save-History {
    param(
        [array]$History
    )

    Save-JsonFile -Path $HistoryFile -Object $History | Out-Null
}


# ============================================================
# JOB EVENTS
# ============================================================

function Add-JobEvent {
    param(
        [string]$Type,
        [string]$Message
    )

    if ($null -eq $global:CurrentJob) {
        return
    }

    $event = [ordered]@{
        time    = Get-TimeStamp
        type    = $Type
        message = $Message
    }

    $events = @()

    if ($null -ne $global:CurrentJob.events) {
        $events = @($global:CurrentJob.events)
    }

    $events += [pscustomobject]$event

    $global:CurrentJob.events = $events

    Save-CurrentJob
}


# ============================================================
# JOB START
# ============================================================

function Start-NewJob {

    if ($null -ne $global:CurrentJob) {

        if ($global:CurrentJob.status -eq "ACTIVE") {

            return [ordered]@{
                success = $true
                message = "A job is already active."
                job     = $global:CurrentJob
            }
        }
    }

    $jobId = New-JobId

    $job = [ordered]@{
        id         = $jobId
        status     = "ACTIVE"
        startedAt  = Get-TimeStamp
        endedAt    = $null
        computer   = $env:COMPUTERNAME
        user       = $env:USERNAME
        technician = $env:USERNAME
        events     = @()
        notes      = @()
    }

    $global:CurrentJob = [pscustomobject]$job

    Add-JobEvent `
        -Type "job-start" `
        -Message "Diagnostic job started."

    Save-CurrentJob

    return [ordered]@{
        success = $true
        message = "Job started."
        job     = $global:CurrentJob
    }
}


# ============================================================
# SYSTEM INFORMATION
# ============================================================

function Get-SystemInformation {

    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $os       = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $bios     = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue

    return [ordered]@{
        computerName = $env:COMPUTERNAME
        userName     = $env:USERNAME
        domain       = $env:USERDOMAIN
        manufacturer = $computer.Manufacturer
        model        = $computer.Model
        serialNumber = $bios.SerialNumber
        os           = $os.Caption
        osVersion    = $os.Version
        build        = $os.BuildNumber
        architecture = $os.OSArchitecture
        memoryGB     = if ($computer.TotalPhysicalMemory) {
            [math]::Round(
                $computer.TotalPhysicalMemory / 1GB,
                2
            )
        }
        else {
            $null
        }
        lastBoot     = if ($os.LastBootUpTime) {
            [Management.ManagementDateTimeConverter]::ToDateTime(
                $os.LastBootUpTime
            )
        }
        else {
            $null
        }
    }
}


# ============================================================
# METRICS
# ============================================================

function Get-SystemMetrics {

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

    $cpu = $null

    try {
        $cpu = (Get-CimInstance Win32_Processor |
            Measure-Object -Property LoadPercentage -Average).Average
    }
    catch {
        $cpu = $null
    }

    $totalMemory = $null
    $freeMemory  = $null
    $usedMemory  = $null

    if ($os) {

        $totalMemory = [double]$os.TotalVisibleMemorySize * 1KB
        $freeMemory  = [double]$os.FreePhysicalMemory * 1KB

        if ($totalMemory -gt 0) {
            $usedMemory = $totalMemory - $freeMemory
        }
    }

    $disks = @()

    try {

        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        ForEach-Object {

            $freeGB = 0
            $sizeGB = 0

            if ($_.Size) {
                $sizeGB = [math]::Round($_.Size / 1GB, 2)
            }

            if ($_.FreeSpace) {
                $freeGB = [math]::Round($_.FreeSpace / 1GB, 2)
            }

            $usedPercent = 0

            if ($_.Size -gt 0) {
                $usedPercent = [math]::Round(
                    (($_.Size - $_.FreeSpace) / $_.Size) * 100,
                    1
                )
            }

            $disks += [ordered]@{
                drive       = $_.DeviceID
                sizeGB      = $sizeGB
                freeGB      = $freeGB
                usedPercent = $usedPercent
            }
        }
    }
    catch {
    }

    return [ordered]@{
        cpuPercent         = if ($null -ne $cpu) {
            [math]::Round($cpu, 1)
        } else {
            $null
        }

        totalMemoryGB      = if ($totalMemory) {
            [math]::Round($totalMemory / 1GB, 2)
        } else {
            $null
        }

        usedMemoryGB       = if ($usedMemory) {
            [math]::Round($usedMemory / 1GB, 2)
        } else {
            $null
        }

        freeMemoryGB       = if ($freeMemory) {
            [math]::Round($freeMemory / 1GB, 2)
        } else {
            $null
        }

        disks = $disks
    }
}


# ============================================================
# NETWORK
# ============================================================

function Get-NetworkInformation {

    $adapters = @()

    try {

        Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        ForEach-Object {

            $ipv4 = @()

            if ($_.IPv4Address) {
                $ipv4 = @(
                    $_.IPv4Address |
                    ForEach-Object {
                        $_.IPv4Address
                    }
                )
            }

            $dns = @()

            if ($_.DNSServer.ServerAddresses) {
                $dns = @(
                    $_.DNSServer.ServerAddresses
                )
            }

            $adapters += [ordered]@{
                interface       = $_.InterfaceAlias
                description     = $_.InterfaceDescription
                status          = [string]$_.NetAdapter.Status
                mac             = $_.NetAdapter.MacAddress
                ipv4            = $ipv4
                gateway         = $_.IPv4DefaultGateway.NextHop
                dns             = $dns
            }
        }
    }
    catch {

        try {

            Get-NetAdapter -ErrorAction SilentlyContinue |
            ForEach-Object {

                $adapters += [ordered]@{
                    interface   = $_.Name
                    description = $_.InterfaceDescription
                    status      = [string]$_.Status
                    mac         = $_.MacAddress
                    ipv4        = @()
                    gateway     = $null
                    dns         = @()
                }
            }
        }
        catch {
        }
    }

    return $adapters
}


# ============================================================
# SERVICES
# ============================================================

function Get-ServiceInformation {

    $services = @()

    try {

        Get-Service |
        Sort-Object Status,DisplayName |
        ForEach-Object {

            $services += [ordered]@{
                name        = $_.Name
                displayName = $_.DisplayName
                status      = [string]$_.Status
                startType   = try {
                    (Get-CimInstance Win32_Service `
                        -Filter "Name='$($_.Name)'" `
                        -ErrorAction Stop).StartMode
                }
                catch {
                    $null
                }
            }
        }
    }
    catch {
    }

    return $services
}


# ============================================================
# PROCESSES
# ============================================================

function Get-ProcessInformation {

    $processes = @()

    try {

        Get-Process |
        Sort-Object CPU -Descending -ErrorAction SilentlyContinue |
        Select-Object -First 150 |
        ForEach-Object {

            $cpu = $null

            try {
                $cpu = $_.CPU
            }
            catch {
            }

            $memory = $null

            try {
                $memory = $_.WorkingSet64
            }
            catch {
            }

            $processes += [ordered]@{
                id        = $_.Id
                name      = $_.ProcessName
                cpu       = $cpu
                memoryMB  = if ($memory) {
                    [math]::Round($memory / 1MB, 1)
                }
                else {
                    0
                }
            }
        }
    }
    catch {
    }

    return $processes
}


# ============================================================
# WINDOWS EVENTS
# ============================================================

function Get-WindowsEvents {

    $events = @()

    try {

        Get-WinEvent -FilterHashtable @{
            LogName   = "System"
            StartTime = (Get-Date).AddHours(-24)
        } -MaxEvents 100 -ErrorAction Stop |
        ForEach-Object {

            $events += [ordered]@{
                time    = $_.TimeCreated
                level   = [string]$_.LevelDisplayName
                source  = $_.ProviderName
                id      = $_.Id
                message = $_.Message
            }
        }
    }
    catch {
    }

    return $events
}


# ============================================================
# DIAGNOSTICS
# ============================================================

function Invoke-Diagnostics {

    $results = @()

    # DNS
    try {

        $dns = Resolve-DnsName `
            -Name "www.microsoft.com" `
            -ErrorAction Stop

        $results += [ordered]@{
            test    = "DNS"
            status  = "PASS"
            message = "DNS resolution successful."
        }
    }
    catch {

        $results += [ordered]@{
            test    = "DNS"
            status  = "FAIL"
            message = $_.Exception.Message
        }
    }

    # Internet
    try {

        $ping = Test-Connection `
            -ComputerName "8.8.8.8" `
            -Count 1 `
            -Quiet `
            -ErrorAction Stop

        if ($ping) {

            $results += [ordered]@{
                test    = "Internet"
                status  = "PASS"
                message = "8.8.8.8 is reachable."
            }
        }
        else {

            $results += [ordered]@{
                test    = "Internet"
                status  = "FAIL"
                message = "8.8.8.8 is not reachable."
            }
        }
    }
    catch {

        $results += [ordered]@{
            test    = "Internet"
            status  = "FAIL"
            message = $_.Exception.Message
        }
    }

    # Local Agent
    try {

        $results += [ordered]@{
            test    = "Local Agent"
            status  = "PASS"
            message = "IT Diagnostic Agent is running."
        }
    }
    catch {
    }

    return $results
}


# ============================================================
# KILL PROCESS
# ============================================================

function Kill-ProcessById {

    param(
        [int]$ProcessId
    )

    if ($ProcessId -le 0) {

        return [ordered]@{
            success = $false
            message = "Invalid process ID."
        }
    }

    if ($ProcessId -eq 4) {

        return [ordered]@{
            success = $false
            message = "PID 4 is protected. HTTP.sys/System will not be terminated."
        }
    }

    try {

        $process = Get-Process -Id $ProcessId -ErrorAction Stop

        $name = $process.ProcessName

        Stop-Process `
            -Id $ProcessId `
            -Force `
            -ErrorAction Stop

        if ($global:CurrentJob) {

            Add-JobEvent `
                -Type "process-kill" `
                -Message "Process $ProcessId ($name) terminated."
        }

        return [ordered]@{
            success = $true
            message = "Process terminated."
            pid     = $ProcessId
            name    = $name
        }
    }
    catch {

        return [ordered]@{
            success = $false
            message = $_.Exception.Message
        }
    }
}


# ============================================================
# REPORT
# ============================================================

function Get-ReportFile {
    param(
        [string]$JobId
    )

    return (Join-Path $ReportDir ($JobId + ".html"))
}

function New-JobReport {

    param(
        $Job
    )

    $jobId = [string]$Job.id
    $reportFile = Get-ReportFile -JobId $jobId

    $system      = Get-SystemInformation
    $metrics     = Get-SystemMetrics
    $network     = Get-NetworkInformation
    $services    = Get-ServiceInformation
    $processes   = Get-ProcessInformation
    $events      = Get-WindowsEvents
    $diagnostics = Invoke-Diagnostics

    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine("<!DOCTYPE html>")
    [void]$sb.AppendLine("<html>")
    [void]$sb.AppendLine("<head>")
    [void]$sb.AppendLine("<meta charset='utf-8'>")
    [void]$sb.AppendLine("<title>IT Diagnostic Report - $(HtmlEncode $jobId)</title>")

    [void]$sb.AppendLine(@"
<style>
body {
    font-family: Segoe UI, Arial, sans-serif;
    background:#111827;
    color:#e5e7eb;
    margin:0;
    padding:30px;
}
.container {
    max-width:1400px;
    margin:auto;
}
h1,h2 {
    color:#fff;
}
.card {
    background:#1f2937;
    border:1px solid #374151;
    border-radius:12px;
    padding:20px;
    margin-bottom:20px;
}
table {
    width:100%;
    border-collapse:collapse;
}
th,td {
    padding:9px;
    border-bottom:1px solid #374151;
    text-align:left;
    vertical-align:top;
}
th {
    background:#111827;
}
pre {
    white-space:pre-wrap;
    word-break:break-word;
}
.pass {
    font-weight:bold;
}
.fail {
    font-weight:bold;
}
.small {
    color:#9ca3af;
}
</style>
"@)

    [void]$sb.AppendLine("</head>")
    [void]$sb.AppendLine("<body>")
    [void]$sb.AppendLine("<div class='container'>")

    [void]$sb.AppendLine(
        "<h1>IT FIELD DIAGNOSTIC REPORT</h1>"
    )

    [void]$sb.AppendLine(
        "<div class='card'><h2>Job</h2>"
    )

    [void]$sb.AppendLine(
        "<p><b>Job ID:</b> $(HtmlEncode $job.id)</p>"
    )

    [void]$sb.AppendLine(
        "<p><b>Status:</b> $(HtmlEncode $job.status)</p>"
    )

    [void]$sb.AppendLine(
        "<p><b>Computer:</b> $(HtmlEncode $job.computer)</p>"
    )

    [void]$sb.AppendLine(
        "<p><b>User:</b> $(HtmlEncode $job.user)</p>"
    )

    [void]$sb.AppendLine(
        "<p><b>Started:</b> $(HtmlEncode $job.startedAt)</p>"
    )

    [void]$sb.AppendLine(
        "<p><b>Ended:</b> $(HtmlEncode $job.endedAt)</p>"
    )

    [void]$sb.AppendLine("</div>")


    # SYSTEM
    [void]$sb.AppendLine("<div class='card'>")
    [void]$sb.AppendLine("<h2>System Information</h2>")
    [void]$sb.AppendLine("<table>")

    foreach ($property in $system.Keys) {

        $value = $system[$property]

        if ($value -is [System.Array] -or
            $value -is [System.Collections.IEnumerable]) {

            $value = ($value | Out-String)
        }

        [void]$sb.AppendLine(
            "<tr><th>$(HtmlEncode $property)</th><td><pre>$(HtmlEncode $value)</pre></td></tr>"
        )
    }

    [void]$sb.AppendLine("</table>")
    [void]$sb.AppendLine("</div>")


    # METRICS
    [void]$sb.AppendLine("<div class='card'>")
    [void]$sb.AppendLine("<h2>System Metrics</h2>")

    [void]$sb.AppendLine(
        "<p><b>CPU:</b> $(HtmlEncode $metrics.cpuPercent)%</p>"
    )

    [void]$sb.AppendLine(
        "<p><b>Total Memory:</b> $(HtmlEncode $metrics.totalMemoryGB) GB</p>"
    )

    [void]$sb.AppendLine(
        "<p><b>Used Memory:</b> $(HtmlEncode $metrics.usedMemoryGB) GB</p>"
    )

    [void]$sb.AppendLine(
        "<p><b>Free Memory:</b> $(HtmlEncode $metrics.freeMemoryGB) GB</p>"
    )

    [void]$sb.AppendLine("</div>")


    # NETWORK
    [void]$sb.AppendLine("<div class='card'>")
    [void]$sb.AppendLine("<h2>Network</h2>")
    [void]$sb.AppendLine("<table>")
    [void]$sb.AppendLine("<tr><th>Interface</th><th>Status</th><th>MAC</th><th>IPv4</th><th>Gateway</th><th>DNS</th></tr>")

    foreach ($adapter in $network) {

        $ipv4 = ($adapter.ipv4 -join ", ")
        $dns  = ($adapter.dns -join ", ")

        [void]$sb.AppendLine(
            "<tr>" +
            "<td>$(HtmlEncode $adapter.interface)</td>" +
            "<td>$(HtmlEncode $adapter.status)</td>" +
            "<td>$(HtmlEncode $adapter.mac)</td>" +
            "<td>$(HtmlEncode $ipv4)</td>" +
            "<td>$(HtmlEncode $adapter.gateway)</td>" +
            "<td>$(HtmlEncode $dns)</td>" +
            "</tr>"
        )
    }

    [void]$sb.AppendLine("</table>")
    [void]$sb.AppendLine("</div>")


    # DIAGNOSTICS
    [void]$sb.AppendLine("<div class='card'>")
    [void]$sb.AppendLine("<h2>Diagnostics</h2>")
    [void]$sb.AppendLine("<table>")
    [void]$sb.AppendLine("<tr><th>Test</th><th>Status</th><th>Message</th></tr>")

    foreach ($result in $diagnostics) {

        [void]$sb.AppendLine(
            "<tr>" +
            "<td>$(HtmlEncode $result.test)</td>" +
            "<td>$(HtmlEncode $result.status)</td>" +
            "<td>$(HtmlEncode $result.message)</td>" +
            "</tr>"
        )
    }

    [void]$sb.AppendLine("</table>")
    [void]$sb.AppendLine("</div>")


    # SERVICES
    [void]$sb.AppendLine("<div class='card'>")
    [void]$sb.AppendLine("<h2>Services</h2>")
    [void]$sb.AppendLine("<table>")
    [void]$sb.AppendLine("<tr><th>Name</th><th>Display Name</th><th>Status</th><th>Start Type</th></tr>")

    foreach ($service in $services) {

        [void]$sb.AppendLine(
            "<tr>" +
            "<td>$(HtmlEncode $service.name)</td>" +
            "<td>$(HtmlEncode $service.displayName)</td>" +
            "<td>$(HtmlEncode $service.status)</td>" +
            "<td>$(HtmlEncode $service.startType)</td>" +
            "</tr>"
        )
    }

    [void]$sb.AppendLine("</table>")
    [void]$sb.AppendLine("</div>")


    # PROCESSES
    [void]$sb.AppendLine("<div class='card'>")
    [void]$sb.AppendLine("<h2>Processes</h2>")
    [void]$sb.AppendLine("<table>")
    [void]$sb.AppendLine("<tr><th>PID</th><th>Name</th><th>CPU</th><th>Memory MB</th></tr>")

    foreach ($process in $processes) {

        [void]$sb.AppendLine(
            "<tr>" +
            "<td>$(HtmlEncode $process.id)</td>" +
            "<td>$(HtmlEncode $process.name)</td>" +
            "<td>$(HtmlEncode $process.cpu)</td>" +
            "<td>$(HtmlEncode $process.memoryMB)</td>" +
            "</tr>"
        )
    }

    [void]$sb.AppendLine("</table>")
    [void]$sb.AppendLine("</div>")


    # EVENTS
    [void]$sb.AppendLine("<div class='card'>")
    [void]$sb.AppendLine("<h2>Windows Events - Last 24 Hours</h2>")
    [void]$sb.AppendLine("<table>")
    [void]$sb.AppendLine("<tr><th>Time</th><th>Level</th><th>Source</th><th>ID</th><th>Message</th></tr>")

    foreach ($event in $events) {

        [void]$sb.AppendLine(
            "<tr>" +
            "<td>$(HtmlEncode $event.time)</td>" +
            "<td>$(HtmlEncode $event.level)</td>" +
            "<td>$(HtmlEncode $event.source)</td>" +
            "<td>$(HtmlEncode $event.id)</td>" +
            "<td><pre>$(HtmlEncode $event.message)</pre></td>" +
            "</tr>"
        )
    }

    [void]$sb.AppendLine("</table>")
    [void]$sb.AppendLine("</div>")


    # JOB EVENTS
    [void]$sb.AppendLine("<div class='card'>")
    [void]$sb.AppendLine("<h2>Job Events</h2>")
    [void]$sb.AppendLine("<table>")
    [void]$sb.AppendLine("<tr><th>Time</th><th>Type</th><th>Message</th></tr>")

    foreach ($event in @($job.events)) {

        [void]$sb.AppendLine(
            "<tr>" +
            "<td>$(HtmlEncode $event.time)</td>" +
            "<td>$(HtmlEncode $event.type)</td>" +
            "<td>$(HtmlEncode $event.message)</td>" +
            "</tr>"
        )
    }

    [void]$sb.AppendLine("</table>")
    [void]$sb.AppendLine("</div>")

    [void]$sb.AppendLine(
        "<p class='small'>Generated by IT Diagnostic Agent V5.1</p>"
    )

    [void]$sb.AppendLine("</div>")
    [void]$sb.AppendLine("</body>")
    [void]$sb.AppendLine("</html>")

    [System.IO.File]::WriteAllText(
        $reportFile,
        $sb.ToString(),
        [System.Text.Encoding]::UTF8
    )

    return $reportFile
}


# ============================================================
# END JOB
# ============================================================

function End-CurrentJob {

    if ($null -eq $global:CurrentJob) {

        return [ordered]@{
            success = $false
            message = "No active job."
        }
    }

    if ($global:CurrentJob.status -ne "ACTIVE") {

        return [ordered]@{
            success = $false
            message = "No active job."
        }
    }

    $job = $global:CurrentJob

    $job.endedAt = Get-TimeStamp
    $job.status  = "COMPLETED"

    $newEvent = [ordered]@{
        time    = Get-TimeStamp
        type    = "job-end"
        message = "Diagnostic job ended."
    }

    $existingEvents = @()

    if ($null -ne $job.events) {
        $existingEvents = @($job.events)
    }

    $existingEvents += [pscustomobject]$newEvent
    $job.events = $existingEvents

    # Save completed job before clearing current job
    $completedJobFile = Join-Path $TempDir ($job.id + "-completed.json")

    Save-JsonFile `
        -Path $completedJobFile `
        -Object $job |
        Out-Null

    # History
    $history = Get-History

    $history = @(
        $job
    ) + @(
        $history
    )

    if ($history.Count -gt 100) {
        $history = @(
            $history |
            Select-Object -First 100
        )
    }

    Save-History -History $history

    # Clear active job immediately
    $global:CurrentJob = $null

    if (Test-Path $CurrentJobFile) {
        Remove-Item $CurrentJobFile -Force -ErrorAction SilentlyContinue
    }

    # Create report synchronously
    # This avoids spawning another Agent process.
    $reportFile = $null

    try {
        $reportFile = New-JobReport -Job $job
    }
    catch {
        $reportFile = $null
    }

    return [ordered]@{
        success = $true
        message = if ($reportFile) {
            "Job ended and report generated."
        }
        else {
            "Job ended but report generation failed."
        }
        job    = $job
        report = $reportFile
        ready  = [bool]$reportFile
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

        return [ordered]@{
            success = $false
            ready   = $false
            message = "Job ID is required."
        }
    }

    $file = Get-ReportFile -JobId $JobId

    if (Test-Path $file) {

        return [ordered]@{
            success = $true
            ready   = $true
            report  = $file
            message = "Report is ready."
        }
    }

    return [ordered]@{
        success = $true
        ready   = $false
        report  = $file
        message = "Report is not ready."
    }
}


# ============================================================
# OPEN REPORT
# ============================================================

function Open-Report {

    param(
        [string]$JobId
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {

        return [ordered]@{
            success = $false
            message = "Job ID is required."
        }
    }

    $file = Get-ReportFile -JobId $JobId

    if (-not (Test-Path $file)) {

        return [ordered]@{
            success = $false
            message = "Report file does not exist."
            report  = $file
        }
    }

    try {

        Start-Process $file | Out-Null

        return [ordered]@{
            success = $true
            message = "Report opened."
            report  = $file
        }
    }
    catch {

        return [ordered]@{
            success = $false
            message = $_.Exception.Message
            report  = $file
        }
    }
}


# ============================================================
# AGENT STOP
# ============================================================

function Start-AgentStopWorker {

    $targetPid = [int]$PID

    $stopScript = Join-Path $TempDir "Stop-Agent-$targetPid.cmd"

    $cmd = @"
@echo off
timeout /t 2 /nobreak >nul
taskkill /PID $targetPid /F >nul 2>&1
del "%~f0" >nul 2>&1
"@

    try {

        [System.IO.File]::WriteAllText(
            $stopScript,
            $cmd,
            [System.Text.Encoding]::ASCII
        )

        Start-Process `
            -FilePath "cmd.exe" `
            -ArgumentList "/c `"$stopScript`"" `
            -WindowStyle Hidden

        return $true
    }
    catch {

        return $false
    }
}


# ============================================================
# HTTP RESPONSE
# ============================================================

function Send-JsonResponse {

    param(
        [System.Net.HttpListenerContext]$Context,
        $Data,
        [int]$StatusCode = 200
    )

    try {

        $json = $Data | ConvertTo-Json -Depth 30

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

        $response = $Context.Response

        $response.StatusCode = $StatusCode
        $response.ContentType = "application/json; charset=utf-8"
        $response.ContentEncoding = [System.Text.Encoding]::UTF8
        $response.ContentLength64 = $bytes.Length

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
# REQUEST BODY
# ============================================================

function Get-RequestBody {

    param(
        [System.Net.HttpListenerRequest]$Request
    )

    try {

        if (-not $Request.HasEntityBody) {
            return $null
        }

        $reader = New-Object System.IO.StreamReader(
            $Request.InputStream,
            $Request.ContentEncoding
        )

        $body = $reader.ReadToEnd()

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
# URL QUERY
# ============================================================

function Get-QueryValue {

    param(
        [System.Net.HttpListenerRequest]$Request,
        [string]$Name
    )

    try {
        return $Request.QueryString[$Name]
    }
    catch {
        return $null
    }
}


# ============================================================
# REQUEST HANDLER
# ============================================================

function Handle-Request {

    param(
        [System.Net.HttpListenerContext]$Context
    )

    $request = $Context.Request
    $path    = $request.Url.AbsolutePath
    $method  = $request.HttpMethod.ToUpper()

    # CORS preflight
    if ($method -eq "OPTIONS") {

        Send-JsonResponse `
            -Context $Context `
            -Data @{
                success = $true
            }

        return
    }


    # --------------------------------------------------------
    # AGENT STATUS
    # --------------------------------------------------------

    if ($path -eq "/agent/status") {

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success  = $true
                online   = $true
                version  = $AgentVersion
                agent    = $AgentName
                pid      = $PID
                computer = $env:COMPUTERNAME
                user     = $env:USERNAME
            })

        return
    }


    # --------------------------------------------------------
    # AGENT STOP
    # --------------------------------------------------------

    if ($path -eq "/agent/stop") {

        $started = Start-AgentStopWorker

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success = $started
                message = if ($started) {
                    "Agent is shutting down."
                }
                else {
                    "Unable to start shutdown worker."
                }
            })

        $global:StopRequested = $true

        return
    }


    # --------------------------------------------------------
    # JOB START
    # --------------------------------------------------------

    if ($path -eq "/job/start" -and $method -eq "POST") {

        $result = Start-NewJob

        Send-JsonResponse `
            -Context $Context `
            -Data $result

        return
    }


    # --------------------------------------------------------
    # JOB STATUS
    # --------------------------------------------------------

    if ($path -eq "/job/status") {

        if ($null -ne $global:CurrentJob) {

            Send-JsonResponse `
                -Context $Context `
                -Data ([ordered]@{
                    success = $true
                    active  = $true
                    job     = $global:CurrentJob
                })
        }
        else {

            Send-JsonResponse `
                -Context $Context `
                -Data ([ordered]@{
                    success = $true
                    active  = $false
                    job     = $null
                })
        }

        return
    }


    # --------------------------------------------------------
    # JOB END
    # --------------------------------------------------------

    if ($path -eq "/job/end" -and $method -eq "POST") {

        $result = End-CurrentJob

        Send-JsonResponse `
            -Context $Context `
            -Data $result

        return
    }


    # --------------------------------------------------------
    # REPORT STATUS
    # --------------------------------------------------------

    if ($path -eq "/report/status") {

        $jobId = Get-QueryValue `
            -Request $request `
            -Name "jobId"

        $result = Get-ReportStatus -JobId $jobId

        Send-JsonResponse `
            -Context $Context `
            -Data $result

        return
    }


    # --------------------------------------------------------
    # REPORT OPEN
    # --------------------------------------------------------

    if ($path -eq "/report/open") {

        $jobId = Get-QueryValue `
            -Request $request `
            -Name "jobId"

        $result = Open-Report -JobId $jobId

        Send-JsonResponse `
            -Context $Context `
            -Data $result

        return
    }


    # --------------------------------------------------------
    # HISTORY
    # --------------------------------------------------------

    if ($path -eq "/history") {

        $history = Get-History

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success = $true
                history = $history
            })

        return
    }


    # --------------------------------------------------------
    # SYSTEM
    # --------------------------------------------------------

    if ($path -eq "/system") {

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success = $true
                system  = Get-SystemInformation
            })

        return
    }


    # --------------------------------------------------------
    # METRICS
    # --------------------------------------------------------

    if ($path -eq "/metrics") {

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success = $true
                metrics = Get-SystemMetrics
            })

        return
    }


    # --------------------------------------------------------
    # NETWORK
    # --------------------------------------------------------

    if ($path -eq "/network") {

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success = $true
                network = Get-NetworkInformation
            })

        return
    }


    # --------------------------------------------------------
    # SERVICES
    # --------------------------------------------------------

    if ($path -eq "/services") {

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success  = $true
                services = Get-ServiceInformation
            })

        return
    }


    # --------------------------------------------------------
    # PROCESSES
    # --------------------------------------------------------

    if ($path -eq "/processes") {

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success   = $true
                processes = Get-ProcessInformation
            })

        return
    }


    # --------------------------------------------------------
    # PROCESS KILL
    # --------------------------------------------------------

    if (($path -eq "/process/kill") -or
        ($path -eq "/kill")) {

        $body = Get-RequestBody -Request $request

        $processId = 0

        if ($body) {

            if ($body.pid) {
                $processId = [int]$body.pid
            }
            elseif ($body.id) {
                $processId = [int]$body.id
            }
        }

        if ($processId -eq 0) {

            $queryPid = Get-QueryValue `
                -Request $request `
                -Name "pid"

            if ($queryPid) {
                $processId = [int]$queryPid
            }
        }

        $result = Kill-ProcessById -ProcessId $processId

        Send-JsonResponse `
            -Context $Context `
            -Data $result

        return
    }


    # --------------------------------------------------------
    # EVENTS
    # --------------------------------------------------------

    if ($path -eq "/events") {

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success = $true
                events  = Get-WindowsEvents
            })

        return
    }


    # --------------------------------------------------------
    # DIAGNOSE
    # --------------------------------------------------------

    if ($path -eq "/diagnose") {

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success     = $true
                diagnostics = Invoke-Diagnostics
            })

        return
    }


    # --------------------------------------------------------
    # FIX
    # --------------------------------------------------------

    if ($path -eq "/fix") {

        $body = Get-RequestBody -Request $request

        Send-JsonResponse `
            -Context $Context `
            -Data ([ordered]@{
                success = $false
                message = "No automatic fix action was specified."
                request = $body
            })

        return
    }


    # --------------------------------------------------------
    # NOT FOUND
    # --------------------------------------------------------

    Send-JsonResponse `
        -Context $Context `
        -StatusCode 404 `
        -Data ([ordered]@{
            success = $false
            message = "Endpoint not found."
            path    = $path
        })
}


# ============================================================
# START HTTP LISTENER
# ============================================================

Load-CurrentJob

$listener = New-Object System.Net.HttpListener

$listener.Prefixes.Add($AgentPrefix)

try {

    $listener.Start()

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " IT FIELD DIAGNOSTIC AGENT V5.1" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Version : $AgentVersion"
    Write-Host "PID     : $PID"
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "User    : $env:USERNAME"
    Write-Host ""
    Write-Host "Listening:"
    Write-Host "http://127.0.0.1:$AgentPort/"
    Write-Host ""
    Write-Host "Endpoints:"
    Write-Host "  /agent/status"
    Write-Host "  /agent/stop"
    Write-Host "  /job/start"
    Write-Host "  /job/status"
    Write-Host "  /job/end"
    Write-Host "  /report/status"
    Write-Host "  /report/open"
    Write-Host "  /history"
    Write-Host "  /system"
    Write-Host "  /metrics"
    Write-Host "  /network"
    Write-Host "  /services"
    Write-Host "  /processes"
    Write-Host "  /process/kill"
    Write-Host "  /events"
    Write-Host "  /diagnose"
    Write-Host ""
    Write-Host "Agent is READY." -ForegroundColor Green
    Write-Host ""

}
catch {

    Write-Host ""
    Write-Host "Unable to start HTTP listener." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""

    exit 1
}


# ============================================================
# MAIN LOOP
# ============================================================

while ($listener.IsListening) {

    if ($global:StopRequested) {
        break
    }

    try {

        $context = $listener.GetContext()

        Handle-Request -Context $context
    }
    catch {

        if (-not $global:StopRequested) {

            Write-Host (
                "Request error: " + $_.Exception.Message
            ) -ForegroundColor Yellow
        }
    }
}


# ============================================================
# CLEAN SHUTDOWN
# ============================================================

try {
    $listener.Stop()
}
catch {
}

try {
    $listener.Close()
}
catch {
}

Write-Host ""
Write-Host "IT Diagnostic Agent V5.1 stopped." -ForegroundColor Yellow
Write-Host ""