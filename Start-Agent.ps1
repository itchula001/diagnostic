# ============================================================
# IT Diagnostic Agent V3
# Windows PowerShell 5.1 compatible
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

$Port = 8765
$Prefix = "http://127.0.0.1:$Port/"

$BaseDir = Join-Path $env:LOCALAPPDATA "IT_Diagnostic_Agent"
$HistoryFile = Join-Path $BaseDir "history.json"

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

# ------------------------------------------------------------
# ADMIN CHECK
# ------------------------------------------------------------

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$WindowsPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)

$IsAdmin = $WindowsPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

# ------------------------------------------------------------
# PROTECTED PROCESSES
# ------------------------------------------------------------

$ProtectedProcesses = @(
    "System",
    "Registry",
    "smss",
    "csrss",
    "wininit",
    "services",
    "lsass",
    "winlogon",
    "svchost",
    "fontdrvhost",
    "dwm",
    "Memory Compression",
    "Secure System",
    "Idle"
)

# ------------------------------------------------------------
# HISTORY
# ------------------------------------------------------------

function Load-History {

    if (!(Test-Path $HistoryFile)) {
        return @()
    }

    try {
        $raw = Get-Content $HistoryFile -Raw

        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @()
        }

        $data = $raw | ConvertFrom-Json

        if ($data -is [System.Array]) {
            return @($data)
        }

        return @($data)

    } catch {

        return @()
    }
}

function Save-History {

    param(
        [array]$History
    )

    try {

        if ($History.Count -gt 500) {
            $History = $History | Select-Object -Last 500
        }

        $History |
            ConvertTo-Json -Depth 8 |
            Set-Content -Path $HistoryFile -Encoding UTF8

    } catch {}
}

function Add-History {

    param(
        [string]$Problem,
        [string]$Action,
        [string]$Before,
        [string]$After,
        [string]$Result,
        [string]$Event = ""
    )

    $history = Load-History

    $entry = [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        ComputerName = $env:COMPUTERNAME
        Problem      = $Problem
        Action       = $Action
        Before       = $Before
        After        = $After
        Result       = $Result
        Event        = $Event
    }

    $history += $entry

    Save-History $history
}

# ------------------------------------------------------------
# HTTP HELPERS
# ------------------------------------------------------------

function Set-Cors {

    param(
        $Context
    )

    $origin = $Context.Request.Headers["Origin"]

    $allowed = @(
        "https://itchula001.github.io",
        "http://localhost",
        "http://127.0.0.1",
        "null"
    )

    if (
        [string]::IsNullOrWhiteSpace($origin) -or
        $allowed -contains $origin -or
        $origin.StartsWith("http://localhost:") -or
        $origin.StartsWith("http://127.0.0.1:")
    ) {

        if ($origin) {
            $Context.Response.Headers.Add(
                "Access-Control-Allow-Origin",
                $origin
            )
        } else {
            $Context.Response.Headers.Add(
                "Access-Control-Allow-Origin",
                "*"
            )
        }
    }

    $Context.Response.Headers.Add(
        "Access-Control-Allow-Headers",
        "Content-Type"
    )

    $Context.Response.Headers.Add(
        "Access-Control-Allow-Methods",
        "GET,POST,OPTIONS"
    )
}

function Send-Json {

    param(
        $Context,
        $Object,
        [int]$StatusCode = 200
    )

    Set-Cors $Context

    $json = $Object | ConvertTo-Json -Depth 10

    $bytes = [Text.Encoding]::UTF8.GetBytes($json)

    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = "application/json; charset=utf-8"
    $Context.Response.ContentLength64 = $bytes.Length

    $Context.Response.OutputStream.Write(
        $bytes,
        0,
        $bytes.Length
    )

    $Context.Response.OutputStream.Close()
}

function Send-Text {

    param(
        $Context,
        [string]$Text,
        [string]$ContentType = "text/plain; charset=utf-8",
        [int]$StatusCode = 200
    )

    Set-Cors $Context

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)

    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length

    $Context.Response.OutputStream.Write(
        $bytes,
        0,
        $bytes.Length
    )

    $Context.Response.OutputStream.Close()
}

function Get-RequestBody {

    param(
        $Context
    )

    try {

        $reader = New-Object IO.StreamReader(
            $Context.Request.InputStream
        )

        $body = $reader.ReadToEnd()

        $reader.Close()

        if ([string]::IsNullOrWhiteSpace($body)) {
            return $null
        }

        return ($body | ConvertFrom-Json)

    } catch {

        return $null
    }
}

# ------------------------------------------------------------
# SYSTEM
# ------------------------------------------------------------

function Get-SystemInfo {

    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS

    $boot = $os.LastBootUpTime

    $uptime = 0

    if ($boot) {
        $uptime = ((Get-Date) - $boot).TotalSeconds
    }

    $ips = @()

    try {

        $ips = Get-NetIPAddress `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -notlike "127.*" -and
                $_.IPAddress -notlike "169.254.*"
            } |
            Select-Object -ExpandProperty IPAddress

    } catch {}

    $primaryIp = $null

    if ($ips.Count -gt 0) {
        $primaryIp = $ips[0]
    }

    return [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        OSCaption    = $os.Caption
        OSVersion    = $os.Version
        BuildNumber  = $os.BuildNumber
        Manufacturer = $computer.Manufacturer
        Model        = $computer.Model
        BIOSVersion  = $bios.SMBIOSBIOSVersion
        PrimaryIP    = $primaryIp
        IPAddresses  = @($ips)
        UptimeSeconds = [Math]::Round($uptime)
        IsAdmin      = $IsAdmin
        AgentVersion = "3.0.0"
        PowerShell   = $PSVersionTable.PSVersion.ToString()
    }
}

# ------------------------------------------------------------
# METRICS
# ------------------------------------------------------------

function Get-Metrics {

    $cpuData = Get-CimInstance Win32_Processor

    $cpu = 0

    if ($cpuData) {

        $avg = (
            $cpuData |
            Measure-Object LoadPercentage -Average
        ).Average

        if ($avg) {
            $cpu = [Math]::Round($avg, 1)
        }
    }

    $os = Get-CimInstance Win32_OperatingSystem

    $totalRam = [double]$os.TotalVisibleMemorySize * 1KB
    $freeRam = [double]$os.FreePhysicalMemory * 1KB

    $usedRam = $totalRam - $freeRam

    $ramPercent = 0

    if ($totalRam -gt 0) {
        $ramPercent =
            [Math]::Round(
                ($usedRam / $totalRam) * 100,
                1
            )
    }

    $disk = Get-CimInstance Win32_LogicalDisk `
        -Filter "DeviceID='C:'"

    $diskTotal = 0
    $diskFree = 0
    $diskUsed = 0
    $diskPercent = 0

    if ($disk) {

        $diskTotal = [double]$disk.Size
        $diskFree = [double]$disk.FreeSpace
        $diskUsed = $diskTotal - $diskFree

        if ($diskTotal -gt 0) {

            $diskPercent =
                [Math]::Round(
                    ($diskUsed / $diskTotal) * 100,
                    1
                )
        }
    }

    return [PSCustomObject]@{
        CPU        = $cpu
        CPUName    = ($cpuData | Select-Object -First 1 -ExpandProperty Name)
        RAMPercent = $ramPercent
        RAMUsed    = [Math]::Round($usedRam)
        RAMTotal   = [Math]::Round($totalRam)
        RAMFree    = [Math]::Round($freeRam)
        DiskPercent = $diskPercent
        DiskUsed   = [Math]::Round($diskUsed)
        DiskTotal  = [Math]::Round($diskTotal)
        DiskFree   = [Math]::Round($diskFree)
    }
}

# ------------------------------------------------------------
# NETWORK
# ------------------------------------------------------------

function Get-NetworkInfo {

    $adapter = $null

    try {

        $adapter = Get-NetIPConfiguration |
            Where-Object {
                $_.IPv4DefaultGateway -ne $null -and
                $_.NetAdapter.Status -eq "Up"
            } |
            Select-Object -First 1

    } catch {}

    $adapterOK = $false
    $adapterName = ""
    $gateway = ""
    $gatewayPingOK = $false
    $gatewayLatency = $null
    $dnsOK = $false
    $dnsAddress = ""
    $internetOK = $false
    $internetLatency = $null

    if ($adapter) {

        $adapterOK = $true

        $adapterName =
            $adapter.InterfaceAlias

        $gateway =
            $adapter.IPv4DefaultGateway.NextHop

        try {

            $ping = Test-Connection `
                -ComputerName $gateway `
                -Count 1 `
                -ErrorAction Stop

            $gatewayPingOK = $true
            $gatewayLatency =
                [Math]::Round($ping.ResponseTime)

        } catch {}

        if ($adapter.DNSServer.ServerAddresses) {

            $dnsAddress =
                $adapter.DNSServer.ServerAddresses[0]
        }

        try {

            $dnsResult = Resolve-DnsName `
                -Name "www.microsoft.com" `
                -Type A `
                -Server $dnsAddress `
                -ErrorAction Stop

            if ($dnsResult) {
                $dnsOK = $true
            }

        } catch {

            try {

                $dnsResult = Resolve-DnsName `
                    -Name "www.microsoft.com" `
                    -Type A `
                    -ErrorAction Stop

                if ($dnsResult) {
                    $dnsOK = $true
                }

            } catch {}
        }

        try {

            $sw = [Diagnostics.Stopwatch]::StartNew()

            $request = Invoke-WebRequest `
                -Uri "https://www.msftconnecttest.com/connecttest.txt" `
                -UseBasicParsing `
                -TimeoutSec 5 `
                -ErrorAction Stop

            $sw.Stop()

            if ($request.StatusCode -ge 200 -and
                $request.StatusCode -lt 500) {

                $internetOK = $true
                $internetLatency =
                    [Math]::Round($sw.Elapsed.TotalMilliseconds)
            }

        } catch {}
    }

    return [PSCustomObject]@{
        AdapterOK = $adapterOK
        AdapterName = $adapterName
        Gateway = $gateway
        GatewayPingOK = $gatewayPingOK
        GatewayLatencyMs = $gatewayLatency
        DNSOK = $dnsOK
        DNSAddress = $dnsAddress
        InternetOK = $internetOK
        InternetLatencyMs = $internetLatency
    }
}

# ------------------------------------------------------------
# SERVICES
# ------------------------------------------------------------

$ImportantServices = @(
    "Spooler",
    "wuauserv",
    "BITS",
    "Winmgmt",
    "Dhcp",
    "Dnscache",
    "LanmanWorkstation",
    "EventLog"
)

function Get-ServiceHealth {

    $result = @()

    foreach ($name in $ImportantServices) {

        $service = Get-Service `
            -Name $name `
            -ErrorAction SilentlyContinue

        if ($service) {

            $startType = ""

            try {

                $cim = Get-CimInstance Win32_Service `
                    -Filter "Name='$name'"

                if ($cim) {
                    $startType = $cim.StartMode
                }

            } catch {}

            $result += [PSCustomObject]@{
                Name = $service.Name
                DisplayName = $service.DisplayName
                Status = $service.Status.ToString()
                StartType = $startType
            }

        }
    }

    return [PSCustomObject]@{
        Services = @($result)
    }
}

# ------------------------------------------------------------
# EVENTS
# ------------------------------------------------------------

function Get-RecentEvents {

    $events = @()

    foreach ($log in @("System", "Application")) {

        try {

            $items = Get-WinEvent `
                -FilterHashtable @{
                    LogName = $log
                    Level = 1,2
                    StartTime = (Get-Date).AddHours(-24)
                } `
                -MaxEvents 15 `
                -ErrorAction Stop

            foreach ($e in $items) {

                $message = $e.Message

                if ($message.Length -gt 1500) {
                    $message = $message.Substring(0,1500)
                }

                $events += [PSCustomObject]@{
                    Time = $e.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    LogName = $log
                    Id = $e.Id
                    Level = $e.LevelDisplayName
                    Provider = $e.ProviderName
                    Message = $message
                }
            }

        } catch {}
    }

    return [PSCustomObject]@{
        Events = @(
            $events |
            Sort-Object Time -Descending |
            Select-Object -First 30
        )
    }
}

# ------------------------------------------------------------
# PROCESS MONITOR
# ------------------------------------------------------------

function Get-ProcessSnapshot {

    $map = @{}

    $cimProcesses = Get-CimInstance Win32_Process

    foreach ($cp in $cimProcesses) {

        $map[[int]$cp.ProcessId] = $cp
    }

    $items = @()

    foreach ($p in Get-Process) {

        try {

            $cpu = $p.CPU
            $ram = $p.WorkingSet64

            $path = ""

            if ($map.ContainsKey($p.Id)) {
                $path = $map[$p.Id].ExecutablePath
            }

            $user = ""

            try {

                $owner = Invoke-CimMethod `
                    -InputObject $map[$p.Id] `
                    -MethodName GetOwner

                if ($owner.User) {
                    $user = "$($owner.Domain)\$($owner.User)"
                }

            } catch {}

            $items += [PSCustomObject]@{
                PID = $p.Id
                Name = $p.ProcessName
                CPUTime = [double]$cpu
                RAMBytes = [long]$ram
                Path = $path
                User = $user
                Protected = (
                    $ProtectedProcesses -contains $p.ProcessName
                )
            }

        } catch {}
    }

    return @($items)
}

function Get-Processes {

    $first = Get-ProcessSnapshot

    Start-Sleep -Milliseconds 400

    $second = Get-ProcessSnapshot

    $lookup = @{}

    foreach ($x in $first) {
        $lookup[$x.PID] = $x
    }

    $logicalProcessors = 1

    try {
        $logicalProcessors =
            (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    } catch {}

    $result = @()

    foreach ($x in $second) {

        $cpuPercent = 0

        if ($lookup.ContainsKey($x.PID)) {

            $old = $lookup[$x.PID]

            $delta =
                [double]$x.CPUTime -
                [double]$old.CPUTime

            if ($delta -ge 0) {

                $cpuPercent =
                    ($delta / 0.4) /
                    [Math]::Max(1,$logicalProcessors) *
                    100
            }
        }

        $result += [PSCustomObject]@{
            PID = $x.PID
            Name = $x.Name
            CPUPercent = [Math]::Round($cpuPercent,1)
            RAMBytes = $x.RAMBytes
            Path = $x.Path
            User = $x.User
            Protected = $x.Protected
        }
    }

    return [PSCustomObject]@{
        Processes = @(
            $result |
            Sort-Object CPUPercent -Descending |
            Select-Object -First 50
        )
    }
}

# ------------------------------------------------------------
# DIAGNOSTIC HELPERS
# ------------------------------------------------------------

function New-Check {

    param(
        [string]$Id,
        [string]$Title,
        [string]$Status,
        [string]$Message,
        [string]$Evidence,
        [string]$FixAction = "",
        [int]$DurationMs = 0
    )

    return [PSCustomObject]@{
        Id = $Id
        Title = $Title
        Status = $Status
        Message = $Message
        Evidence = $Evidence
        FixAction = $FixAction
        DurationMs = $DurationMs
    }
}

# ------------------------------------------------------------
# DISK SCAN
# ------------------------------------------------------------

function Find-LargeFiles {

    $targets = @()

    $userProfile = $env:USERPROFILE

    if ($userProfile) {
        $targets += Join-Path $userProfile "Downloads"
        $targets += Join-Path $userProfile "Desktop"
        $targets += Join-Path $userProfile "Documents"
    }

    $targets += $env:TEMP
    $targets += "C:\Windows\Temp"

    $files = @()

    foreach ($target in $targets) {

        if (!(Test-Path $target)) {
            continue
        }

        try {

            Get-ChildItem `
                -Path $target `
                -File `
                -Recurse `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Length -ge 500MB
                } |
                Select-Object -First 100 |
                ForEach-Object {

                    $files += [PSCustomObject]@{
                        Path = $_.FullName
                        SizeBytes = $_.Length
                        Size = "{0:N1} GB" -f ($_.Length / 1GB)
                        Modified = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                    }
                }

        } catch {}
    }

    return [PSCustomObject]@{
        Files = @(
            $files |
            Sort-Object SizeBytes -Descending |
            Select-Object -First 50
        )
    }
}

# ------------------------------------------------------------
# FULL DIAGNOSTIC
# ------------------------------------------------------------

function Invoke-Diagnostic {

    $overall = [Diagnostics.Stopwatch]::StartNew()

    $checks = @()

    # CPU
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $metrics = Get-Metrics

    $sw.Stop()

    if ($metrics.CPU -ge 90) {

        $proc = Get-Processes

        $top = $proc.Processes |
            Sort-Object CPUPercent -Descending |
            Select-Object -First 3

        $evidence =
            ($top | ForEach-Object {
                "$($_.Name) PID $($_.PID) $($_.CPUPercent)%"
            }) -join ", "

        $checks += New-Check `
            "CPU_HIGH" `
            "High CPU Usage" `
            "Problem" `
            "CPU usage is critically high." `
            "$([int]$metrics.CPU)% CPU. Top: $evidence" `
            "" `
            $sw.ElapsedMilliseconds

    }
    elseif ($metrics.CPU -ge 75) {

        $checks += New-Check `
            "CPU_HIGH" `
            "High CPU Usage" `
            "Warning" `
            "CPU usage is elevated." `
            "$([int]$metrics.CPU)% CPU" `
            "" `
            $sw.ElapsedMilliseconds

    }
    else {

        $checks += New-Check `
            "CPU_HIGH" `
            "CPU Usage" `
            "OK" `
            "CPU usage is within normal range." `
            "$([int]$metrics.CPU)% CPU" `
            "" `
            $sw.ElapsedMilliseconds
    }

    # RAM
    $sw.Restart()

    if ($metrics.RAMPercent -ge 90) {

        $proc = Get-Processes

        $top = $proc.Processes |
            Sort-Object RAMBytes -Descending |
            Select-Object -First 3

        $evidence =
            ($top | ForEach-Object {
                "$($_.Name) $([Math]::Round($_.RAMBytes/1MB)) MB"
            }) -join ", "

        $checks += New-Check `
            "RAM_HIGH" `
            "High Memory Usage" `
            "Problem" `
            "Physical memory usage is critically high." `
            "$([int]$metrics.RAMPercent)% RAM. Top: $evidence" `
            "restart-windows-search" `
            $sw.ElapsedMilliseconds

    }
    elseif ($metrics.RAMPercent -ge 80) {

        $checks += New-Check `
            "RAM_HIGH" `
            "High Memory Usage" `
            "Warning" `
            "Memory usage is elevated." `
            "$([int]$metrics.RAMPercent)% RAM" `
            "" `
            $sw.ElapsedMilliseconds

    }
    else {

        $checks += New-Check `
            "RAM_HIGH" `
            "Memory Usage" `
            "OK" `
            "Memory usage is within normal range." `
            "$([int]$metrics.RAMPercent)% RAM" `
            "" `
            $sw.ElapsedMilliseconds
    }

    # DISK
    $sw.Restart()

    if ($metrics.DiskPercent -ge 95) {

        $checks += New-Check `
            "DISK_FULL" `
            "Disk C: Almost Full" `
            "Problem" `
            "Disk C: has very little free space." `
            "$([int]$metrics.DiskPercent)% used. Free: $([Math]::Round($metrics.DiskFree/1GB,1)) GB" `
            "Clean-Temp" `
            $sw.ElapsedMilliseconds

    }
    elseif ($metrics.DiskPercent -ge 85) {

        $checks += New-Check `
            "DISK_FULL" `
            "Disk C: Usage High" `
            "Warning" `
            "Disk C: usage is high." `
            "$([int]$metrics.DiskPercent)% used. Free: $([Math]::Round($metrics.DiskFree/1GB,1)) GB" `
            "Clean-Temp" `
            $sw.ElapsedMilliseconds

    }
    else {

        $checks += New-Check `
            "DISK_FULL" `
            "Disk C: Usage" `
            "OK" `
            "Disk space is within normal range." `
            "$([int]$metrics.DiskPercent)% used" `
            "" `
            $sw.ElapsedMilliseconds
    }

    # NETWORK
    $sw.Restart()

    $network = Get-NetworkInfo

    if (!$network.AdapterOK) {

        $checks += New-Check `
            "NETWORK" `
            "Network Adapter" `
            "Problem" `
            "No active network adapter with a default gateway was found." `
            "No active adapter" `
            "" `
            $sw.ElapsedMilliseconds

    }
    elseif (!$network.GatewayPingOK) {

        $checks += New-Check `
            "NETWORK" `
            "Gateway Connectivity" `
            "Problem" `
            "The local gateway did not respond." `
            "Gateway: $($network.Gateway)" `
            "flush-dns" `
            $sw.ElapsedMilliseconds

    }
    elseif (!$network.DNSOK) {

        $checks += New-Check `
            "NETWORK" `
            "DNS Resolution" `
            "Problem" `
            "DNS resolution failed." `
            "DNS: $($network.DNSAddress)" `
            "flush-dns" `
            $sw.ElapsedMilliseconds

    }
    elseif (!$network.InternetOK) {

        $checks += New-Check `
            "NETWORK" `
            "Internet Connectivity" `
            "Problem" `
            "Internet connectivity failed." `
            "Gateway OK / DNS OK / Internet FAILED" `
            "flush-dns" `
            $sw.ElapsedMilliseconds

    }
    else {

        $checks += New-Check `
            "NETWORK" `
            "Network Connectivity" `
            "OK" `
            "Gateway, DNS and Internet connectivity are working." `
            "Gateway $($network.GatewayLatencyMs) ms / Internet $($network.InternetLatencyMs) ms" `
            "" `
            $sw.ElapsedMilliseconds
    }

    # SPOOLER
    $sw.Restart()

    $spooler = Get-Service Spooler -ErrorAction SilentlyContinue

    if ($spooler -and $spooler.Status -ne "Running") {

        $checks += New-Check `
            "SPOOLER" `
            "Print Spooler" `
            "Problem" `
            "Print Spooler is not running." `
            "Status: $($spooler.Status)" `
            "restart-spooler" `
            $sw.ElapsedMilliseconds

    }
    else {

        $checks += New-Check `
            "SPOOLER" `
            "Print Spooler" `
            "OK" `
            "Print Spooler is running." `
            "Status: Running" `
            "" `
            $sw.ElapsedMilliseconds
    }

    # WINDOWS UPDATE
    $sw.Restart()

    $wu = Get-Service wuauserv -ErrorAction SilentlyContinue

    if ($wu -and $wu.Status -ne "Running") {

        $checks += New-Check `
            "WINDOWS_UPDATE" `
            "Windows Update Service" `
            "Warning" `
            "Windows Update service is not running." `
            "Status: $($wu.Status)" `
            "restart-service-wuauserv" `
            $sw.ElapsedMilliseconds

    }
    else {

        $checks += New-Check `
            "WINDOWS_UPDATE" `
            "Windows Update Service" `
            "OK" `
            "Windows Update service is running." `
            "Status: Running" `
            "" `
            $sw.ElapsedMilliseconds
    }

    # DEFENDER
    $sw.Restart()

    try {

        $defender = Get-MpComputerStatus

        if ($defender.AntivirusEnabled) {

            $checks += New-Check `
                "DEFENDER" `
                "Microsoft Defender" `
                "OK" `
                "Microsoft Defender antivirus is enabled." `
                "AntivirusEnabled=True / RealTime=$($defender.RealTimeProtectionEnabled)" `
                "" `
                $sw.ElapsedMilliseconds

        }
        else {

            $checks += New-Check `
                "DEFENDER" `
                "Microsoft Defender" `
                "Problem" `
                "Microsoft Defender antivirus is disabled." `
                "AntivirusEnabled=False" `
                "enable-defender" `
                $sw.ElapsedMilliseconds
        }

    } catch {

        $checks += New-Check `
            "DEFENDER" `
            "Microsoft Defender" `
            "Warning" `
            "Defender status could not be read." `
            $_.Exception.Message `
            "" `
            $sw.ElapsedMilliseconds
    }

    # EVENT LOG
    $sw.Restart()

    $events = Get-RecentEvents

    $critical = @(
        $events.Events |
        Where-Object {
            $_.Level -eq "Critical"
        }
    ).Count

    $errors = @(
        $events.Events |
        Where-Object {
            $_.Level -eq "Error"
        }
    ).Count

    if ($critical -gt 0) {

        $checks += New-Check `
            "EVENT_ERRORS" `
            "Windows Event Errors" `
            "Warning" `
            "Recent critical events were found." `
            "$critical Critical / $errors Error events in last 24 hours" `
            "" `
            $sw.ElapsedMilliseconds

    }
    else {

        $checks += New-Check `
            "EVENT_ERRORS" `
            "Windows Event Errors" `
            "OK" `
            "No recent Critical events detected." `
            "$errors Error events in last 24 hours" `
            "" `
            $sw.ElapsedMilliseconds
    }

    $overall.Stop()

    return [PSCustomObject]@{
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        DurationMs = [int]$overall.ElapsedMilliseconds
        Checks = @($checks)
    }
}

# ------------------------------------------------------------
# FIX ACTIONS
# ------------------------------------------------------------

function Invoke-Fix {

    param(
        $Body
    )

    if (!$IsAdmin) {

        return [PSCustomObject]@{
            Success = $false
            Message = "Administrator privileges are required."
        }
    }

    $action = [string]$Body.Action
    $problem = [string]$Body.Problem
    $before = [string]$Body.Before

    $after = ""
    $success = $false
    $message = ""

    try {

        switch ($action) {

            "Clean-Temp" {

                $targets = @(
                    $env:TEMP,
                    "C:\Windows\Temp"
                )

                $deleted = 0

                foreach ($target in $targets) {

                    if (Test-Path $target) {

                        Get-ChildItem `
                            -Path $target `
                            -Force `
                            -Recurse `
                            -ErrorAction SilentlyContinue |
                            Remove-Item `
                                -Force `
                                -Recurse `
                                -ErrorAction SilentlyContinue

                        $deleted++
                    }
                }

                $success = $true
                $message = "Temporary file cleanup completed."
                $after = "Cleanup targets processed: $deleted"
            }

            "restart-spooler" {

                Restart-Service `
                    -Name Spooler `
                    -Force `
                    -ErrorAction Stop

                Start-Sleep -Milliseconds 500

                $s = Get-Service Spooler

                $success = ($s.Status -eq "Running")
                $message = "Print Spooler restart completed."
                $after = "Status: $($s.Status)"
            }

            "restart-service-wuauserv" {

                Restart-Service `
                    -Name wuauserv `
                    -Force `
                    -ErrorAction Stop

                Start-Sleep -Milliseconds 500

                $s = Get-Service wuauserv

                $success = ($s.Status -eq "Running")
                $message = "Windows Update service restart completed."
                $after = "Status: $($s.Status)"
            }

            "restart-bits" {

                Restart-Service `
                    -Name BITS `
                    -Force `
                    -ErrorAction Stop

                Start-Sleep -Milliseconds 500

                $s = Get-Service BITS

                $success = ($s.Status -eq "Running")
                $message = "BITS restart completed."
                $after = "Status: $($s.Status)"
            }

            "flush-dns" {

                $result = ipconfig /flushdns

                $success = $true
                $message = "DNS cache flush completed."
                $after = ($result -join " ")
            }

            "renew-ip" {

                ipconfig /renew | Out-Null

                $success = $true
                $message = "DHCP IP renewal requested."
                $after = "ipconfig /renew completed"
            }

            "gpupdate" {

                $result = gpupdate /force 2>&1

                $success = $true
                $message = "Group Policy refresh completed."
                $after = ($result -join " ")
            }

            "enable-defender" {

                Set-MpPreference `
                    -DisableRealtimeMonitoring $false

                $status = Get-MpComputerStatus

                $success =
                    [bool]$status.RealTimeProtectionEnabled

                $message =
                    "Microsoft Defender real-time protection was requested."

                $after =
                    "RealTimeProtectionEnabled=$($status.RealTimeProtectionEnabled)"
            }

            "restart-windows-search" {

                Restart-Service `
                    -Name WSearch `
                    -Force `
                    -ErrorAction Stop

                $s = Get-Service WSearch

                $success = ($s.Status -eq "Running")

                $message =
                    "Windows Search service restart completed."

                $after =
                    "Status: $($s.Status)"
            }

            default {

                throw "Unsupported fix action."
            }
        }

    } catch {

        $success = $false
        $message = $_.Exception.Message
        $after = "Action failed"
    }

    $resultText =
        if ($success) {
            "SUCCESS"
        } else {
            "FAILED"
        }

    Add-History `
        -Problem $problem `
        -Action $action `
        -Before $before `
        -After $after `
        -Result $resultText

    return [PSCustomObject]@{
        Success = $success
        Message = $message
        Action = $action
        Before = $before
        After = $after
        Result = $resultText
    }
}

# ------------------------------------------------------------
# KILL PROCESS
# ------------------------------------------------------------

function Invoke-KillProcess {

    param(
        $Body
    )

    if (!$IsAdmin) {

        return [PSCustomObject]@{
            Success = $false
            Message = "Administrator privileges are required."
        }
    }

    $pid = 0

    try {
        $pid = [int]$Body.PID
    } catch {}

    if ($pid -le 0) {

        return [PSCustomObject]@{
            Success = $false
            Message = "Invalid PID."
        }
    }

    try {

        $process = Get-Process `
            -Id $pid `
            -ErrorAction Stop

        $actualName = $process.ProcessName

        if ($ProtectedProcesses -contains $actualName) {

            return [PSCustomObject]@{
                Success = $false
                Message = "Protected system process cannot be terminated."
            }
        }

        if (
            $Body.Name -and
            $actualName -ne [string]$Body.Name
        ) {

            return [PSCustomObject]@{
                Success = $false
                Message = "Process identity changed. Kill cancelled."
            }
        }

        $before =
            "$actualName PID $pid Running"

        Stop-Process `
            -Id $pid `
            -Force `
            -ErrorAction Stop

        Start-Sleep -Milliseconds 500

        $stillRunning = Get-Process `
            -Id $pid `
            -ErrorAction SilentlyContinue

        if ($stillRunning) {

            Add-History `
                -Problem "Process termination" `
                -Action "Kill process" `
                -Before $before `
                -After "Process still running" `
                -Result "FAILED"

            return [PSCustomObject]@{
                Success = $false
                Message = "Process is still running."
            }
        }

        Add-History `
            -Problem "Process termination" `
            -Action "Kill process" `
            -Before $before `
            -After "Process no longer exists" `
            -Result "SUCCESS"

        return [PSCustomObject]@{
            Success = $true
            Message = "$actualName (PID $pid) terminated and verified."
        }

    } catch {

        return [PSCustomObject]@{
            Success = $false
            Message = $_.Exception.Message
        }
    }
}

# ------------------------------------------------------------
# CSV EXPORT
# ------------------------------------------------------------

function Export-HistoryCsv {

    $history = Load-History

    if (!$history -or $history.Count -eq 0) {

        return "Timestamp,ComputerName,Problem,Action,Before,After,Result,Event"
    }

    return (
        $history |
        ConvertTo-Csv -NoTypeInformation
    ) -join "`r`n"
}

# ------------------------------------------------------------
# HTTP SERVER
# ------------------------------------------------------------

$listener = New-Object System.Net.HttpListener

$listener.Prefixes.Add($Prefix)

try {

    $listener.Start()

} catch {

    Write-Host ""
    Write-Host "Unable to start IT Diagnostic Agent." -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host ""
    Read-Host "Press ENTER to exit"
    exit
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " IT Diagnostic Agent V3" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "URL       : $Prefix"
Write-Host "Computer  : $env:COMPUTERNAME"
Write-Host "Admin     : $IsAdmin"
Write-Host "History   : $HistoryFile"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$running = $true

while ($running) {

    try {

        $context = $listener.GetContext()

        $request = $context.Request
        $response = $context.Response

        Set-Cors $context

        # OPTIONS
        if ($request.HttpMethod -eq "OPTIONS") {

            $response.StatusCode = 204
            $response.Close()

            continue
        }

        $path = $request.Url.AbsolutePath.ToLower()
        $method = $request.HttpMethod.ToUpper()

        Write-Host (
            "{0} {1}" -f $method,$path
        )

        # ----------------------------------------------------
        # SYSTEM
        # ----------------------------------------------------

        if ($path -eq "/system") {

            Send-Json `
                $context `
                (Get-SystemInfo)

            continue
        }

        # ----------------------------------------------------
        # METRICS
        # ----------------------------------------------------

        if ($path -eq "/metrics") {

            Send-Json `
                $context `
                (Get-Metrics)

            continue
        }

        # ----------------------------------------------------
        # NETWORK
        # ----------------------------------------------------

        if ($path -eq "/network") {

            Send-Json `
                $context `
                (Get-NetworkInfo)

            continue
        }

        # ----------------------------------------------------
        # SERVICES
        # ----------------------------------------------------

        if ($path -eq "/services") {

            Send-Json `
                $context `
                (Get-ServiceHealth)

            continue
        }

        # ----------------------------------------------------
        # EVENTS
        # ----------------------------------------------------

        if ($path -eq "/events") {

            Send-Json `
                $context `
                (Get-RecentEvents)

            continue
        }

        # ----------------------------------------------------
        # PROCESSES
        # ----------------------------------------------------

        if ($path -eq "/processes") {

            Send-Json `
                $context `
                (Get-Processes)

            continue
        }

        # ----------------------------------------------------
        # DISK SCAN
        # ----------------------------------------------------

        if ($path -eq "/disk-scan") {

            Send-Json `
                $context `
                (Find-LargeFiles)

            continue
        }

        # ----------------------------------------------------
        # DIAGNOSTIC
        # ----------------------------------------------------

        if ($path -eq "/diagnose") {

            Send-Json `
                $context `
                (Invoke-Diagnostic)

            continue
        }

        # ----------------------------------------------------
        # FIX
        # ----------------------------------------------------

        if ($path -eq "/fix") {

            if ($method -ne "POST") {

                Send-Json `
                    $context `
                    @{
                        Success = $false
                        Message = "POST required."
                    } `
                    405

                continue
            }

            $body = Get-RequestBody $context

            if (!$body) {

                Send-Json `
                    $context `
                    @{
                        Success = $false
                        Message = "Invalid request body."
                    } `
                    400

                continue
            }

            Send-Json `
                $context `
                (Invoke-Fix $body)

            continue
        }

        # ----------------------------------------------------
        # KILL
        # ----------------------------------------------------

        if ($path -eq "/kill") {

            if ($method -ne "POST") {

                Send-Json `
                    $context `
                    @{
                        Success = $false
                        Message = "POST required."
                    } `
                    405

                continue
            }

            $body = Get-RequestBody $context

            if (!$body) {

                Send-Json `
                    $context `
                    @{
                        Success = $false
                        Message = "Invalid request body."
                    } `
                    400

                continue
            }

            Send-Json `
                $context `
                (Invoke-KillProcess $body)

            continue
        }

        # ----------------------------------------------------
        # HISTORY
        # ----------------------------------------------------

        if ($path -eq "/history") {

            Send-Json `
                $context `
                @{
                    History = @(Load-History)
                }

            continue
        }

        # ----------------------------------------------------
        # EXPORT
        # ----------------------------------------------------

        if ($path -eq "/export") {

            $csv = Export-HistoryCsv

            Send-Text `
                $context `
                $csv `
                "text/csv; charset=utf-8"

            continue
        }

        # ----------------------------------------------------
        # STOP
        # ----------------------------------------------------

        if ($path -eq "/stop") {

            Send-Json `
                $context `
                @{
                    Success = $true
                    Message = "Agent stopping."
                }

            $running = $false

            continue
        }

        # ----------------------------------------------------
        # NOT FOUND
        # ----------------------------------------------------

        Send-Json `
            $context `
            @{
                Success = $false
                Message = "Endpoint not found."
                Path = $path
            } `
            404

    } catch {

        Write-Host "Request error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

try {
    $listener.Stop()
    $listener.Close()
} catch {}

Write-Host ""
Write-Host "IT Diagnostic Agent stopped." -ForegroundColor Yellow