# ============================================================
# IT Field Diagnostic Local Agent
# Version 2.0.0
# Windows PowerShell 5.1+ / PowerShell 7+
# ============================================================

$ErrorActionPreference = "Continue"

$AgentVersion = "2.0.0"
$Port = 8765
$Prefix = "http://127.0.0.1:$Port/"

# ------------------------------------------------------------
# Agent storage
# ------------------------------------------------------------

$AgentDir = Join-Path $env:LOCALAPPDATA "IT_Diagnostic_Agent"

if (-not (Test-Path -LiteralPath $AgentDir)) {
    New-Item -ItemType Directory -Path $AgentDir -Force | Out-Null
}

$HistoryFilePath = Join-Path $AgentDir "history.json"
$LogFilePath = Join-Path $AgentDir "agent.log"

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

function Write-AgentLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    try {
        $line = "{0} [{1}] {2}" -f `
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `
            $Level,
            $Message

        Add-Content -LiteralPath $LogFilePath -Value $line -Encoding UTF8
    }
    catch {}
}

# ------------------------------------------------------------
# History
# ------------------------------------------------------------

[array]$global:HistoryLog = @()

function Load-History {
    try {
        if (-not (Test-Path -LiteralPath $HistoryFilePath)) {
            $global:HistoryLog = @()
            return
        }

        $raw = Get-Content `
            -LiteralPath $HistoryFilePath `
            -Raw `
            -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($raw)) {
            $global:HistoryLog = @()
            return
        }

        $parsed = $raw | ConvertFrom-Json

        if ($null -eq $parsed) {
            $global:HistoryLog = @()
        }
        else {
            $global:HistoryLog = @($parsed)
        }
    }
    catch {
        Write-AgentLog "History load failed: $($_.Exception.Message)" "WARN"
        $global:HistoryLog = @()
    }
}

function Save-History {
    try {
        $json = @($global:HistoryLog) |
            ConvertTo-Json -Depth 6

        Set-Content `
            -LiteralPath $HistoryFilePath `
            -Value $json `
            -Encoding UTF8
    }
    catch {
        Write-AgentLog "History save failed: $($_.Exception.Message)" "WARN"
    }
}

function Add-History {
    param(
        [string]$Problem,
        [string]$Action,
        [string]$Result,
        [string]$Message = ""
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        computer  = $env:COMPUTERNAME
        problem   = $Problem
        action    = $Action
        result    = $Result
        message   = $Message
    }

    $global:HistoryLog = @($global:HistoryLog) + $entry

    # Keep the history file from growing forever.
    if ($global:HistoryLog.Count -gt 500) {
        $global:HistoryLog =
            @($global:HistoryLog | Select-Object -Last 500)
    }

    Save-History
}

Load-History

# ------------------------------------------------------------
# Protected processes
# ------------------------------------------------------------

$ProtectedList = @(
    "System",
    "Idle",
    "Registry",
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
    "taskhostw",
    "fontdrvhost",
    "Secure System",
    "WmiPrvSE"
)

# ------------------------------------------------------------
# Allowed remediation actions
# ------------------------------------------------------------

$AllowedActions = @(
    "Clean-Temp",
    "restart-spooler",
    "restart-service-wuauserv",
    "Clear-Memory",
    "flush-dns",
    "renew-ip",
    "enable-defender",
    "gpupdate"
)

# ------------------------------------------------------------
# HTTP helper
# ------------------------------------------------------------

function Write-JsonResponse {
    param(
        [Parameter(Mandatory = $true)]
        $Response,

        [Parameter(Mandatory = $true)]
        $Data,

        [int]$StatusCode = 200
    )

    try {
        $json = $Data | ConvertTo-Json -Depth 8 -Compress
    }
    catch {
        $json = '{"success":false,"message":"JSON serialization failed"}'
        $StatusCode = 500
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Response.ContentLength64 = $bytes.Length

    $Response.OutputStream.Write(
        $bytes,
        0,
        $bytes.Length
    )

    $Response.Close()
}

function Read-RequestBody {
    param(
        [Parameter(Mandatory = $true)]
        $Request
    )

    try {
        $reader = New-Object System.IO.StreamReader(
            $Request.InputStream,
            $Request.ContentEncoding
        )

        try {
            $bodyText = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        if ([string]::IsNullOrWhiteSpace($bodyText)) {
            return $null
        }

        return ($bodyText | ConvertFrom-Json)
    }
    catch {
        throw "Invalid JSON request: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# CORS / browser security
# ------------------------------------------------------------

function Set-SecurityHeaders {
    param(
        [Parameter(Mandatory = $true)]
        $Request,

        [Parameter(Mandatory = $true)]
        $Response
    )

    $origin = $Request.Headers["Origin"]

    $allowed = $false

    if ([string]::IsNullOrWhiteSpace($origin)) {
        # Non-browser/local clients do not require CORS.
        $allowed = $true
    }
    elseif (
        $origin -eq "null" -or
        $origin -match "^https://itchula001\.github\.io$" -or
        $origin -match "^https?://localhost(:\d+)?$" -or
        $origin -match "^https?://127\.0\.0\.1(:\d+)?$"
    ) {
        $allowed = $true
    }

    if ($allowed -and -not [string]::IsNullOrWhiteSpace($origin)) {
        $Response.Headers["Access-Control-Allow-Origin"] = $origin
        $Response.Headers["Vary"] = "Origin"
    }

    $Response.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    $Response.Headers["Access-Control-Allow-Headers"] = "Content-Type"
    $Response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
    $Response.Headers["Pragma"] = "no-cache"

    return $allowed
}

# ------------------------------------------------------------
# Utility functions
# ------------------------------------------------------------

function Get-CpuUsage {
    try {
        $cpu = Get-CimInstance Win32_Processor |
            Measure-Object -Property LoadPercentage -Average |
            Select-Object -ExpandProperty Average

        if ($null -eq $cpu) {
            return 0
        }

        return [math]::Round([double]$cpu)
    }
    catch {
        return 0
    }
}

function Get-MemoryInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem

        if (
            $null -eq $os -or
            [double]$os.TotalVisibleMemorySize -le 0
        ) {
            return @{
                Percent = 0
                FreeGB = 0
                TotalGB = 0
            }
        }

        $total = [double]$os.TotalVisibleMemorySize
        $free = [double]$os.FreePhysicalMemory

        $usedPercent =
            [math]::Round(
                (($total - $free) / $total) * 100
            )

        return @{
            Percent = $usedPercent
            FreeGB = [math]::Round($free / 1MB, 2)
            TotalGB = [math]::Round($total / 1MB, 2)
        }
    }
    catch {
        return @{
            Percent = 0
            FreeGB = 0
            TotalGB = 0
        }
    }
}

function Get-DiskInfo {
    param(
        [string]$Drive = "C:"
    )

    try {
        $disk = Get-CimInstance Win32_LogicalDisk `
            -Filter "DeviceID='$Drive'" `
            -ErrorAction Stop

        if (
            $null -eq $disk -or
            [double]$disk.Size -le 0
        ) {
            return @{
                Percent = 0
                FreeGB = 0
                TotalGB = 0
            }
        }

        $size = [double]$disk.Size
        $free = [double]$disk.FreeSpace

        $usedPercent =
            [math]::Round(
                (($size - $free) / $size) * 100
            )

        return @{
            Percent = $usedPercent
            FreeGB = [math]::Round($free / 1GB, 2)
            TotalGB = [math]::Round($size / 1GB, 2)
        }
    }
    catch {
        return @{
            Percent = 0
            FreeGB = 0
            TotalGB = 0
        }
    }
}

function Get-OperatingSystemName {
    try {
        $os = Get-CimInstance Win32_OperatingSystem

        if ($os) {
            return "$($os.Caption) ($($os.Version))"
        }
    }
    catch {}

    return "Windows"
}

function Get-DefaultGateway {
    try {
        $routes = Get-NetRoute `
            -AddressFamily IPv4 `
            -DestinationPrefix "0.0.0.0/0" `
            -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric

        foreach ($route in $routes) {
            if (-not [string]::IsNullOrWhiteSpace($route.NextHop)) {
                return $route.NextHop
            }
        }
    }
    catch {}

    return $null
}

function Test-Gateway {
    param(
        [string]$Gateway
    )

    if ([string]::IsNullOrWhiteSpace($Gateway)) {
        return $false
    }

    try {
        $ping = New-Object System.Net.NetworkInformation.Ping

        $reply = $ping.Send(
            $Gateway,
            1000
        )

        return ($reply.Status -eq "Success")
    }
    catch {
        return $false
    }
}

function Test-Dns {
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses(
            "www.google.com"
        )

        return ($null -ne $addresses -and $addresses.Count -gt 0)
    }
    catch {
        return $false
    }
}

function Get-ActiveNetworkAdapters {
    try {
        return @(
            Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Status -eq "Up" -and
                $_.InterfaceDescription -notmatch "Virtual|Loopback|TAP|VPN"
            }
        )
    }
    catch {
        return @()
    }
}

# ------------------------------------------------------------
# Metrics
# ------------------------------------------------------------

function Get-Metrics {
    $memory = Get-MemoryInfo
    $disk = Get-DiskInfo -Drive "C:"
    $cpu = Get-CpuUsage

    $cpuCount = 0

    try {
        $cpuCount = @(
            Get-CimInstance Win32_Processor
        ).Count
    }
    catch {}

    return [ordered]@{
        cpu = $cpu
        ram = $memory.Percent
        disk = $disk.Percent

        ramFreeGB = $memory.FreeGB
        ramTotalGB = $memory.TotalGB

        diskFreeGB = $disk.FreeGB
        diskTotalGB = $disk.TotalGB

        cpuCount = $cpuCount
        computer = $env:COMPUTERNAME
        os = Get-OperatingSystemName

        timestamp = (
            Get-Date
        ).ToString("o")
    }
}

# ------------------------------------------------------------
# Process manager
# ------------------------------------------------------------

function Get-ProcessSnapshot {
    param(
        [int]$Limit = 5
    )

    $all = @()

    try {
        $all = @(
            Get-Process -ErrorAction SilentlyContinue |
            ForEach-Object {

                $cpuTime = 0

                try {
                    if ($null -ne $_.CPU) {
                        $cpuTime = [math]::Round(
                            [double]$_.CPU,
                            1
                        )
                    }
                }
                catch {}

                $ramMB = 0

                try {
                    $ramMB = [math]::Round(
                        [double]$_.WorkingSet64 / 1MB,
                        1
                    )
                }
                catch {}

                [pscustomobject]@{
                    Id = $_.Id
                    Name = $_.ProcessName
                    CPU_Time = $cpuTime
                    RAM_MB = $ramMB
                    IsSystem = (
                        $ProtectedList -contains $_.ProcessName
                    )
                }
            }
        )
    }
    catch {}

    $topCpu = @(
        $all |
        Sort-Object CPU_Time -Descending |
        Select-Object -First $Limit
    )

    $topRam = @(
        $all |
        Sort-Object RAM_MB -Descending |
        Select-Object -First $Limit
    )

    return [ordered]@{
        cpu = $topCpu
        ram = $topRam
    }
}

# ------------------------------------------------------------
# Diagnostic engine
# ------------------------------------------------------------

function Get-Diagnostics {
    $problems = @()

    # --------------------------------------------------------
    # 1. Disk C:
    # --------------------------------------------------------

    $disk = Get-DiskInfo -Drive "C:"

    if ($disk.TotalGB -gt 0 -and $disk.Percent -ge 90) {
        $problems += @{
            id = "DISK_C_FULL"
            title = "Disk (C:) critically low space ($($disk.Percent)%)"
            severity = "critical"
            description = "Drive C: has very little free space remaining."
            evidence = @(
                "Usage: $($disk.Percent)%"
                "Free space: $($disk.FreeGB) GB"
            )
            possibleCauses = @(
                "Temporary files accumulated"
                "Large application cache"
                "Windows update files"
                "Large logs or user files"
            )
            recommendedFix = "Clean-Temp"
        }
    }
    elseif ($disk.TotalGB -gt 0 -and $disk.Percent -ge 85) {
        $problems += @{
            id = "DISK_C_LOW"
            title = "Disk (C:) Low Space ($($disk.Percent)%)"
            severity = "warning"
            description = "Drive C: is running low on available storage."
            evidence = @(
                "Usage: $($disk.Percent)%"
                "Free space: $($disk.FreeGB) GB"
            )
            possibleCauses = @(
                "Temporary files accumulated"
                "Large application cache"
                "Windows update files"
            )
            recommendedFix = "Clean-Temp"
        }
    }

    # --------------------------------------------------------
    # 2. Print Spooler
    # --------------------------------------------------------

    try {
        $spooler = Get-Service `
            -Name "Spooler" `
            -ErrorAction SilentlyContinue

        if (
            $null -ne $spooler -and
            $spooler.StartType -ne "Disabled" -and
            $spooler.Status -ne "Running"
        ) {
            $problems += @{
                id = "SPOOLER_STOP"
                title = "Print Spooler Service Stopped"
                severity = "warning"
                description = "The Windows Print Spooler service is not running."
                evidence = @(
                    "Status: $($spooler.Status)"
                    "StartType: $($spooler.StartType)"
                )
                possibleCauses = @(
                    "Service stopped unexpectedly"
                    "Print subsystem error"
                )
                recommendedFix = "restart-spooler"
            }
        }
    }
    catch {}

    # --------------------------------------------------------
    # 3. Windows Update
    # --------------------------------------------------------

    try {
        $wuauserv = Get-Service `
            -Name "wuauserv" `
            -ErrorAction SilentlyContinue

        if (
            $null -ne $wuauserv -and
            $wuauserv.StartType -eq "Automatic" -and
            $wuauserv.Status -ne "Running"
        ) {
            $problems += @{
                id = "WUAUSERV_STOPPED"
                title = "Windows Update Service Stopped"
                severity = "warning"
                description = "Windows Update is configured for automatic startup but is not currently running."
                evidence = @(
                    "Status: $($wuauserv.Status)"
                    "StartType: $($wuauserv.StartType)"
                )
                possibleCauses = @(
                    "Service stopped unexpectedly"
                    "Windows Update subsystem issue"
                )
                recommendedFix = "restart-service-wuauserv"
            }
        }
    }
    catch {}

    # --------------------------------------------------------
    # 4. Network
    # --------------------------------------------------------

    $adapters = Get-ActiveNetworkAdapters
    $gateway = Get-DefaultGateway

    if (
        $adapters.Count -eq 0 -or
        [string]::IsNullOrWhiteSpace($gateway)
    ) {
        $problems += @{
            id = "NETWORK_DISCONNECTED"
            title = "Network / Wi-Fi Disconnected"
            severity = "critical"
            description = "No active physical network adapter or default IPv4 gateway was detected."
            evidence = @(
                "Active adapter count: $($adapters.Count)"
                "Gateway: $(if ($gateway) { $gateway } else { 'None' })"
            )
            possibleCauses = @(
                "Wi-Fi turned off"
                "Ethernet cable disconnected"
                "DHCP unavailable"
                "Network adapter disabled"
            )
            recommendedFix = "renew-ip"
        }
    }
    else {
        $gatewayOK = Test-Gateway -Gateway $gateway

        if (-not $gatewayOK) {
            $problems += @{
                id = "GATEWAY_UNREACHABLE"
                title = "Gateway Unreachable ($gateway)"
                severity = "critical"
                description = "The local default gateway did not respond to an ICMP test."
                evidence = @(
                    "Gateway IP: $gateway"
                    "Ping: FAILED"
                )
                possibleCauses = @(
                    "Router or network equipment unavailable"
                    "Incorrect network configuration"
                    "IP address conflict"
                )
                recommendedFix = "renew-ip"
            }
        }
        else {
            $dnsOK = Test-Dns

            if (-not $dnsOK) {
                $problems += @{
                    id = "DNS_FAILURE"
                    title = "DNS Resolution Failed"
                    severity = "warning"
                    description = "The local gateway is reachable, but DNS resolution failed."
                    evidence = @(
                        "Gateway ping: OK"
                        "DNS lookup: FAILED"
                    )
                    possibleCauses = @(
                        "DNS server unavailable"
                        "Corrupted DNS cache"
                        "Incorrect DNS configuration"
                    )
                    recommendedFix = "flush-dns"
                }
            }
        }
    }

    # --------------------------------------------------------
    # 5. Windows Defender
    # --------------------------------------------------------

    try {
        $defender = Get-MpComputerStatus `
            -ErrorAction SilentlyContinue

        if ($null -ne $defender) {
            if (-not $defender.RealTimeProtectionEnabled) {
                $problems += @{
                    id = "SECURITY_DEFENDER_DISABLED"
                    title = "Antivirus Real-Time Protection Off"
                    severity = "critical"
                    description = "Microsoft Defender Real-Time Protection is disabled."
                    evidence = @(
                        "RealTimeProtectionEnabled: False"
                    )
                    possibleCauses = @(
                        "Protection disabled by policy or administrator"
                        "Third-party security software"
                        "User configuration"
                    )
                    recommendedFix = "enable-defender"
                }
            }
        }
    }
    catch {
        Write-AgentLog `
            "Defender status check failed: $($_.Exception.Message)" `
            "WARN"
    }

    # --------------------------------------------------------
    # 6. RAM
    # --------------------------------------------------------

    $memory = Get-MemoryInfo

    if ($memory.Percent -ge 90) {
        $problems += @{
            id = "RAM_HIGH_CRITICAL"
            title = "Very High Memory Usage ($($memory.Percent)%)"
            severity = "critical"
            description = "Available physical memory is critically low."
            evidence = @(
                "Usage: $($memory.Percent)%"
                "Free: $($memory.FreeGB) GB"
            )
            possibleCauses = @(
                "Too many applications"
                "Memory-intensive application"
                "Potential memory leak"
            )
            recommendedFix = "Clear-Memory"
        }
    }
    elseif ($memory.Percent -ge 85) {
        $problems += @{
            id = "RAM_HIGH"
            title = "High Memory Usage ($($memory.Percent)%)"
            severity = "warning"
            description = "System memory usage is high."
            evidence = @(
                "Usage: $($memory.Percent)%"
                "Free: $($memory.FreeGB) GB"
            )
            possibleCauses = @(
                "Too many applications"
                "Memory-intensive application"
                "Potential memory leak"
            )
            recommendedFix = "Clear-Memory"
        }
    }

    # --------------------------------------------------------
    # 7. CPU
    # --------------------------------------------------------

    $cpu = Get-CpuUsage

    if ($cpu -ge 95) {
        $problems += @{
            id = "CPU_HIGH_CRITICAL"
            title = "Critical CPU Usage ($cpu%)"
            severity = "critical"
            description = "The processor is currently under extremely heavy load."
            evidence = @(
                "CPU usage: $cpu%"
            )
            possibleCauses = @(
                "Runaway process"
                "Windows background operation"
                "Heavy application workload"
            )
            recommendedFix = ""
        }
    }
    elseif ($cpu -ge 90) {
        $problems += @{
            id = "CPU_HIGH"
            title = "High CPU Usage ($cpu%)"
            severity = "warning"
            description = "The processor is currently under heavy load."
            evidence = @(
                "CPU usage: $cpu%"
            )
            possibleCauses = @(
                "Heavy application workload"
                "Background processing"
                "Runaway process"
            )
            recommendedFix = ""
        }
    }

    # --------------------------------------------------------
    # 8. Windows Firewall
    # --------------------------------------------------------

    try {
        $profiles = Get-NetFirewallProfile `
            -ErrorAction SilentlyContinue

        if ($profiles) {
            $disabledProfiles = @(
                $profiles |
                Where-Object {
                    $_.Enabled -eq $false
                }
            )

            if ($disabledProfiles.Count -gt 0) {
                $profileNames =
                    ($disabledProfiles.Name -join ", ")

                $problems += @{
                    id = "FIREWALL_DISABLED"
                    title = "Windows Firewall Profile Disabled"
                    severity = "warning"
                    description = "One or more Windows Firewall profiles are disabled."
                    evidence = @(
                        "Disabled profiles: $profileNames"
                    )
                    possibleCauses = @(
                        "Security policy"
                        "Manual configuration"
                        "Third-party firewall"
                    )
                    recommendedFix = ""
                }
            }
        }
    }
    catch {}

    return @{
        problems = @($problems)
        checkedAt = (Get-Date).ToString("o")
        computer = $env:COMPUTERNAME
    }
}

# ------------------------------------------------------------
# Remediation
# ------------------------------------------------------------

function Invoke-Remediation {
    param(
        [string]$Action
    )

    if (
        [string]::IsNullOrWhiteSpace($Action) -or
        $AllowedActions -notcontains $Action
    ) {
        return @{
            success = $false
            message = "Action not in whitelist."
        }
    }

    try {
        switch ($Action) {

            "Clean-Temp" {

                $paths = @(
                    $env:TEMP,
                    (Join-Path $env:WINDIR "Temp")
                )

                $deletedFiles = 0
                $failedFiles = 0

                foreach ($path in $paths) {

                    if (-not (Test-Path -LiteralPath $path)) {
                        continue
                    }

                    try {
                        Get-ChildItem `
                            -LiteralPath $path `
                            -Force `
                            -ErrorAction SilentlyContinue |
                        ForEach-Object {

                            try {
                                Remove-Item `
                                    -LiteralPath $_.FullName `
                                    -Recurse `
                                    -Force `
                                    -ErrorAction Stop

                                $deletedFiles++
                            }
                            catch {
                                $failedFiles++
                            }
                        }
                    }
                    catch {}
                }

                return @{
                    success = $true
                    message = "Temporary files cleaned. Removed: $deletedFiles item(s). Skipped: $failedFiles item(s)."
                }
            }

            "restart-spooler" {

                $service = Get-Service `
                    -Name "Spooler" `
                    -ErrorAction Stop

                if ($service.Status -eq "Running") {
                    Restart-Service `
                        -Name "Spooler" `
                        -Force `
                        -ErrorAction Stop
                }
                else {
                    Start-Service `
                        -Name "Spooler" `
                        -ErrorAction Stop
                }

                Start-Sleep -Milliseconds 500

                $verify = Get-Service `
                    -Name "Spooler" `
                    -ErrorAction Stop

                if ($verify.Status -eq "Running") {
                    return @{
                        success = $true
                        message = "Print Spooler is running."
                    }
                }

                return @{
                    success = $false
                    message = "Print Spooler did not reach Running state."
                }
            }

            "restart-service-wuauserv" {

                $service = Get-Service `
                    -Name "wuauserv" `
                    -ErrorAction Stop

                if ($service.Status -eq "Running") {
                    Restart-Service `
                        -Name "wuauserv" `
                        -Force `
                        -ErrorAction Stop
                }
                else {
                    Start-Service `
                        -Name "wuauserv" `
                        -ErrorAction Stop
                }

                Start-Sleep -Milliseconds 500

                $verify = Get-Service `
                    -Name "wuauserv" `
                    -ErrorAction Stop

                if ($verify.Status -eq "Running") {
                    return @{
                        success = $true
                        message = "Windows Update service is running."
                    }
                }

                return @{
                    success = $false
                    message = "Windows Update service did not reach Running state."
                }
            }

            "Clear-Memory" {

                # GC does not magically free all Windows RAM.
                # This action intentionally performs only safe garbage
                # collection and working-set trimming for the agent itself.
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                [GC]::Collect()

                return @{
                    success = $true
                    message = "Memory cleanup request completed. Windows/application memory usage should be rechecked."
                }
            }

            "flush-dns" {

                Clear-DnsClientCache `
                    -ErrorAction Stop

                return @{
                    success = $true
                    message = "DNS client cache flushed."
                }
            }

            "renew-ip" {

                $process = Start-Process `
                    -FilePath "ipconfig.exe" `
                    -ArgumentList "/renew" `
                    -NoNewWindow `
                    -Wait `
                    -PassThru `
                    -ErrorAction Stop

                if ($process.ExitCode -eq 0) {
                    return @{
                        success = $true
                        message = "IP address renewal completed."
                    }
                }

                return @{
                    success = $false
                    message = "ipconfig /renew exited with code $($process.ExitCode)."
                }
            }

            "enable-defender" {

                Set-MpPreference `
                    -DisableRealtimeMonitoring $false `
                    -ErrorAction Stop

                $verify =
                    Get-MpComputerStatus `
                        -ErrorAction Stop

                if ($verify.RealTimeProtectionEnabled) {
                    return @{
                        success = $true
                        message = "Microsoft Defender Real-Time Protection is enabled."
                    }
                }

                return @{
                    success = $false
                    message = "Defender command completed but protection could not be verified as enabled."
                }
            }

            "gpupdate" {

                $process = Start-Process `
                    -FilePath "gpupdate.exe" `
                    -ArgumentList "/force" `
                    -NoNewWindow `
                    -Wait `
                    -PassThru `
                    -ErrorAction Stop

                if ($process.ExitCode -eq 0) {
                    return @{
                        success = $true
                        message = "Group Policy update completed."
                    }
                }

                return @{
                    success = $false
                    message = "gpupdate exited with code $($process.ExitCode)."
                }
            }
        }
    }
    catch {
        return @{
            success = $false
            message = $_.Exception.Message
        }
    }

    return @{
        success = $false
        message = "Unknown remediation action."
    }
}

# ------------------------------------------------------------
# Process termination
# ------------------------------------------------------------

function Invoke-KillProcess {
    param(
        [int]$Id,
        [string]$Name
    )

    if ($Id -le 0) {
        return @{
            success = $false
            message = "Invalid process ID."
        }
    }

    if ($ProtectedList -contains $Name) {
        return @{
            success = $false
            message = "Protected system process cannot be terminated."
        }
    }

    try {
        $process = Get-Process `
            -Id $Id `
            -ErrorAction Stop

        if (
            $process.ProcessName -ne $Name -and
            -not [string]::IsNullOrWhiteSpace($Name)
        ) {
            return @{
                success = $false
                message = "Process identity changed. Operation cancelled."
            }
        }

        Stop-Process `
            -Id $Id `
            -Force `
            -ErrorAction Stop

        Start-Sleep -Milliseconds 250

        $stillRunning = Get-Process `
            -Id $Id `
            -ErrorAction SilentlyContinue

        if ($null -eq $stillRunning) {
            return @{
                success = $true
                message = "Terminated $Name (PID $Id)."
            }
        }

        return @{
            success = $false
            message = "Process is still running."
        }
    }
    catch {
        return @{
            success = $false
            message = $_.Exception.Message
        }
    }
}

# ------------------------------------------------------------
# Start HTTP listener
# ------------------------------------------------------------

$listener = New-Object System.Net.HttpListener

try {
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
}
catch {
    Write-Host ""
    Write-Host "❌ Unable to start Local Diagnostic Agent." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""

    Write-AgentLog `
        "Listener start failed: $($_.Exception.Message)" `
        "ERROR"

    exit 1
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " IT Field Diagnostic Local Agent $AgentVersion" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Status   : RUNNING" -ForegroundColor Green
Write-Host "Computer : $env:COMPUTERNAME" -ForegroundColor Yellow
Write-Host "Address  : $Prefix" -ForegroundColor Yellow
Write-Host "Admin    : $([bool](([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))" -ForegroundColor Yellow
Write-Host ""
Write-Host "Press Ctrl+C to stop the agent." -ForegroundColor Gray
Write-Host ""

Write-AgentLog `
    "Agent started. Version=$AgentVersion Prefix=$Prefix" `
    "INFO"

# ------------------------------------------------------------
# Main request loop
# ------------------------------------------------------------

try {

    while ($listener.IsListening) {

        try {
            $context = $listener.GetContext()
        }
        catch {
            if (-not $listener.IsListening) {
                break
            }

            Write-AgentLog `
                "GetContext failed: $($_.Exception.Message)" `
                "WARN"

            continue
        }

        $request = $context.Request
        $response = $context.Response

        $corsAllowed = Set-SecurityHeaders `
            -Request $request `
            -Response $response

        $path = $request.Url.AbsolutePath
        $method = $request.HttpMethod.ToUpperInvariant()

        Write-AgentLog `
            "$method $path from $($request.RemoteEndPoint)" `
            "INFO"

        # ----------------------------------------------------
        # OPTIONS / CORS
        # ----------------------------------------------------

        if ($method -eq "OPTIONS") {

            if (-not $corsAllowed) {
                $response.StatusCode = 403
                $response.Close()
                continue
            }

            $response.StatusCode = 204
            $response.Close()
            continue
        }

        # ----------------------------------------------------
        # Reject disallowed browser origins
        # ----------------------------------------------------

        if (
            -not $corsAllowed -and
            -not [string]::IsNullOrWhiteSpace(
                $request.Headers["Origin"]
            )
        ) {
            Write-JsonResponse `
                -Response $response `
                -Data @{
                    success = $false
                    message = "Origin not allowed."
                } `
                -StatusCode 403

            continue
        }

        # ----------------------------------------------------
        # HEALTH
        # ----------------------------------------------------

        if ($path -eq "/health" -and $method -eq "GET") {

            Write-JsonResponse `
                -Response $response `
                -Data @{
                    success = $true
                    status = "online"
                    version = $AgentVersion
                    computer = $env:COMPUTERNAME
                    os = Get-OperatingSystemName
                    serverTime = (Get-Date).ToString("o")
                }

            continue
        }

        # ----------------------------------------------------
        # METRICS
        # ----------------------------------------------------

        if ($path -eq "/metrics" -and $method -eq "GET") {

            Write-JsonResponse `
                -Response $response `
                -Data (Get-Metrics)

            continue
        }

        # ----------------------------------------------------
        # PROCESSES
        # ----------------------------------------------------

        if ($path -eq "/processes" -and $method -eq "GET") {

            Write-JsonResponse `
                -Response $response `
                -Data (Get-ProcessSnapshot -Limit 5)

            continue
        }

        # ----------------------------------------------------
        # DIAGNOSTIC
        # ----------------------------------------------------

        if ($path -eq "/diagnose" -and $method -eq "GET") {

            $diagnosticResult = Get-Diagnostics

            Write-JsonResponse `
                -Response $response `
                -Data $diagnosticResult

            continue
        }

        # ----------------------------------------------------
        # HISTORY
        # ----------------------------------------------------

        if ($path -eq "/history" -and $method -eq "GET") {

            Write-JsonResponse `
                -Response $response `
                -Data @($global:HistoryLog)

            continue
        }

        # ----------------------------------------------------
        # FIX
        # ----------------------------------------------------

        if ($path -eq "/fix" -and $method -eq "POST") {

            try {
                $body = Read-RequestBody -Request $request

                if ($null -eq $body) {
                    Write-JsonResponse `
                        -Response $response `
                        -Data @{
                            success = $false
                            message = "Request body is required."
                        } `
                        -StatusCode 400

                    continue
                }

                $action = [string]$body.action
                $title = [string]$body.title
                $verificationStatus =
                    [string]$body.verificationStatus

                if (
                    [string]::IsNullOrWhiteSpace($action)
                ) {
                    Write-JsonResponse `
                        -Response $response `
                        -Data @{
                            success = $false
                            message = "Action is required."
                        } `
                        -StatusCode 400

                    continue
                }

                # Verification-only records should not execute
                # an action a second time.
                if (
                    $verificationStatus -eq "VERIFIED_SUCCESS" -or
                    $verificationStatus -eq "VERIFIED_FAILED"
                ) {
                    Add-History `
                        -Problem $title `
                        -Action $action `
                        -Result $verificationStatus `
                        -Message "Verification result recorded."

                    Write-JsonResponse `
                        -Response $response `
                        -Data @{
                            success = $true
                            message = "Verification result recorded."
                        }

                    continue
                }

                if (
                    $AllowedActions -notcontains $action
                ) {
                    Add-History `
                        -Problem $title `
                        -Action $action `
                        -Result "FAILED" `
                        -Message "Action not in whitelist."

                    Write-JsonResponse `
                        -Response $response `
                        -Data @{
                            success = $false
                            message = "Action not in whitelist."
                        } `
                        -StatusCode 403

                    continue
                }

                $result = Invoke-Remediation `
                    -Action $action

                $historyResult =
                    if ($result.success) {
                        if (
                            [string]::IsNullOrWhiteSpace(
                                $verificationStatus
                            )
                        ) {
                            "EXECUTED"
                        }
                        else {
                            $verificationStatus
                        }
                    }
                    else {
                        "FAILED"
                    }

                Add-History `
                    -Problem $title `
                    -Action $action `
                    -Result $historyResult `
                    -Message $result.message

                Write-JsonResponse `
                    -Response $response `
                    -Data $result
            }
            catch {
                Write-AgentLog `
                    "FIX error: $($_.Exception.Message)" `
                    "ERROR"

                Write-JsonResponse `
                    -Response $response `
                    -Data @{
                        success = $false
                        message = $_.Exception.Message
                    } `
                    -StatusCode 500
            }

            continue
        }

        # ----------------------------------------------------
        # KILL PROCESS
        # ----------------------------------------------------

        if ($path -eq "/kill" -and $method -eq "POST") {

            try {
                $body = Read-RequestBody -Request $request

                if ($null -eq $body) {
                    Write-JsonResponse `
                        -Response $response `
                        -Data @{
                            success = $false
                            message = "Request body is required."
                        } `
                        -StatusCode 400

                    continue
                }

                $id = 0

                try {
                    $id = [int]$body.id
                }
                catch {
                    $id = 0
                }

                $name = [string]$body.name

                $result = Invoke-KillProcess `
                    -Id $id `
                    -Name $name

                Add-History `
                    -Problem "Kill Process $name" `
                    -Action "Kill PID $id" `
                    -Result (
                        if ($result.success) {
                            "SUCCESS"
                        }
                        else {
                            "FAILED"
                        }
                    ) `
                    -Message $result.message

                Write-JsonResponse `
                    -Response $response `
                    -Data $result
            }
            catch {
                Write-AgentLog `
                    "KILL error: $($_.Exception.Message)" `
                    "ERROR"

                Write-JsonResponse `
                    -Response $response `
                    -Data @{
                        success = $false
                        message = $_.Exception.Message
                    } `
                    -StatusCode 500
            }

            continue
        }

        # ----------------------------------------------------
        # STOP
        # ----------------------------------------------------

        if ($path -eq "/stop" -and $method -eq "GET") {

            Write-JsonResponse `
                -Response $response `
                -Data @{
                    success = $true
                    message = "Agent stopped successfully."
                }

            Write-AgentLog `
                "Agent stop requested from portal." `
                "INFO"

            Start-Sleep -Milliseconds 100

            $listener.Stop()

            break
        }

        # ----------------------------------------------------
        # 404
        # ----------------------------------------------------

        Write-JsonResponse `
            -Response $response `
            -Data @{
                success = $false
                error = "Not Found"
                path = $path
            } `
            -StatusCode 404
    }
}
catch {
    Write-Host ""
    Write-Host "Agent error: $($_.Exception.Message)" -ForegroundColor Red

    Write-AgentLog `
        "Fatal agent error: $($_.Exception.Message)" `
        "ERROR"
}
finally {

    if ($null -ne $listener) {

        try {
            if ($listener.IsListening) {
                $listener.Stop()
            }
        }
        catch {}

        try {
            $listener.Close()
        }
        catch {}
    }

    Write-AgentLog `
        "Agent stopped." `
        "INFO"

    Write-Host ""
    Write-Host "🛑 Local Diagnostic Agent stopped." -ForegroundColor Red
}