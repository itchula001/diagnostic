# ============================================================
# Windows IT Diagnostic Local Agent V2
# ============================================================

$ErrorActionPreference = "Continue"

$Port = 8765
$Prefix = "http://127.0.0.1:$Port/"

$AgentDir = Join-Path $env:LOCALAPPDATA "IT_Diagnostic_Agent"
$HistoryFilePath = Join-Path $AgentDir "history.json"

# ------------------------------------------------------------
# Agent Directory
# ------------------------------------------------------------

if (-not (Test-Path $AgentDir)) {
    New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null
}

# ------------------------------------------------------------
# HTTP Listener
# ------------------------------------------------------------

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)

try {
    $listener.Start()
}
catch {
    Write-Host ""
    Write-Host "❌ Cannot start Local Agent." -ForegroundColor Red
    Write-Host "Port $Port may already be in use." -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Windows IT Diagnostic Local Agent V2" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "✅ Agent Started" -ForegroundColor Green
Write-Host "Listening: $Prefix" -ForegroundColor Yellow
Write-Host "Computer : $env:COMPUTERNAME" -ForegroundColor Yellow
Write-Host "User     : $env:USERNAME" -ForegroundColor Yellow
Write-Host ""

# ------------------------------------------------------------
# History
# ------------------------------------------------------------

[array]$global:HistoryLog = @()

if (Test-Path $HistoryFilePath) {

    try {

        $raw = Get-Content `
            -Path $HistoryFilePath `
            -Raw `
            -ErrorAction Stop

        if (-not [string]::IsNullOrWhiteSpace($raw)) {

            $parsed = $raw | ConvertFrom-Json

            if ($null -ne $parsed) {
                $global:HistoryLog = @($parsed)
            }
        }

    }
    catch {

        $global:HistoryLog = @()
    }
}

function Save-HistoryToFile {

    try {

        $global:HistoryLog |
            ConvertTo-Json -Depth 5 |
            Set-Content `
                -Path $HistoryFilePath `
                -Encoding UTF8

    }
    catch {
        Write-Host "History save failed: $($_.Exception.Message)" `
            -ForegroundColor Yellow
    }
}

function Add-History {

    param(
        [string]$Problem,
        [string]$Action,
        [string]$Result
    )

    $entry = [ordered]@{
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        computer  = $env:COMPUTERNAME
        problem   = $Problem
        action    = $Action
        result    = $Result
    }

    $global:HistoryLog = @(
        $global:HistoryLog
        $entry
    )

    # จำกัด History สูงสุด 500 รายการ
    if ($global:HistoryLog.Count -gt 500) {

        $global:HistoryLog =
            @(
                $global:HistoryLog |
                Select-Object -Last 500
            )
    }

    Save-HistoryToFile
}

# ------------------------------------------------------------
# Protected Processes
# ------------------------------------------------------------

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
    "svchost",
    "dwm",
    "sihost",
    "taskhostw",
    "fontdrvhost",
    "conhost",
    "explorer"
)

function Test-ProtectedProcess {

    param(
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }

    return (
        $ProtectedList -contains $Name
    )
}

# ------------------------------------------------------------
# JSON Response
# ------------------------------------------------------------

function Send-Json {

    param(
        $Response,
        $Data,
        [int]$StatusCode = 200
    )

    try {

        $json = $Data | ConvertTo-Json -Depth 8

        $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)

        $Response.StatusCode = $StatusCode
        $Response.ContentType = "application/json; charset=utf-8"
        $Response.ContentEncoding = [System.Text.Encoding]::UTF8
        $Response.ContentLength64 = $buffer.Length

        $Response.OutputStream.Write(
            $buffer,
            0,
            $buffer.Length
        )

    }
    finally {

        $Response.Close()
    }
}

function Read-JsonBody {

    param(
        $Request
    )

    $reader = New-Object System.IO.StreamReader(
        $Request.InputStream,
        $Request.ContentEncoding
    )

    try {

        $body = $reader.ReadToEnd()

        if ([string]::IsNullOrWhiteSpace($body)) {
            return $null
        }

        return ($body | ConvertFrom-Json)

    }
    finally {

        $reader.Dispose()
    }
}

# ------------------------------------------------------------
# CPU
# ------------------------------------------------------------

function Get-CpuUsage {

    try {

        $cpu = Get-CimInstance Win32_Processor |
            Measure-Object `
                -Property LoadPercentage `
                -Average |
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

# ------------------------------------------------------------
# RAM
# ------------------------------------------------------------

function Get-RamInfo {

    try {

        $os = Get-CimInstance Win32_OperatingSystem

        $total = [double]$os.TotalVisibleMemorySize
        $free = [double]$os.FreePhysicalMemory

        if ($total -le 0) {
            return @{
                percent = 0
                freeGB  = 0
            }
        }

        $percent = [math]::Round(
            (($total - $free) / $total) * 100
        )

        $freeGB = [math]::Round(
            $free / 1MB,
            2
        )

        return @{
            percent = $percent
            freeGB  = $freeGB
        }
    }
    catch {

        return @{
            percent = 0
            freeGB  = 0
        }
    }
}

# ------------------------------------------------------------
# Disk
# ------------------------------------------------------------

function Get-SystemDiskInfo {

    try {

        $disk = Get-CimInstance Win32_LogicalDisk `
            -Filter "DeviceID='C:'"

        if ($null -eq $disk -or $disk.Size -le 0) {

            return @{
                percent = 0
                freeGB  = 0
            }
        }

        $percent = [math]::Round(
            (($disk.Size - $disk.FreeSpace) / $disk.Size) * 100
        )

        $freeGB = [math]::Round(
            $disk.FreeSpace / 1GB,
            2
        )

        return @{
            percent = $percent
            freeGB  = $freeGB
        }
    }
    catch {

        return @{
            percent = 0
            freeGB  = 0
        }
    }
}

# ------------------------------------------------------------
# Metrics
# ------------------------------------------------------------

function Get-Metrics {

    $cpu = Get-CpuUsage
    $ram = Get-RamInfo
    $disk = Get-SystemDiskInfo

    return @{
        cpu       = $cpu
        ram       = $ram.percent
        ramFreeGB = $ram.freeGB
        disk      = $disk.percent
        diskFreeGB = $disk.freeGB
        computer  = $env:COMPUTERNAME
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}

# ------------------------------------------------------------
# Processes
# ------------------------------------------------------------

function Get-ProcessData {

    $processes = @()

    try {

        $processes = Get-Process |
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
                        $_.WorkingSet64 / 1MB,
                        1
                    )
                }
                catch {}

                [PSCustomObject]@{
                    Id       = $_.Id
                    Name     = $_.Name
                    CPU_Time = $cpuTime
                    RAM_MB   = $ramMB
                    IsSystem = Test-ProtectedProcess $_.Name
                }
            }
    }
    catch {}

    $topCpu = @(
        $processes |
        Sort-Object CPU_Time -Descending |
        Select-Object -First 10
    )

    $topRam = @(
        $processes |
        Sort-Object RAM_MB -Descending |
        Select-Object -First 10
    )

    return @{
        cpu = $topCpu
        ram = $topRam
    }
}

# ------------------------------------------------------------
# Diagnostic
# ------------------------------------------------------------

function Invoke-Diagnostic {

    $problems = @()

    # ========================================================
    # 1. Disk
    # ========================================================

    $disk = Get-SystemDiskInfo

    if ($disk.percent -gt 90) {

        $problems += @{
            id = "DISK_C_FULL"
            title = "Disk (C:) Critically Low ($($disk.percent)%)"
            severity = "critical"
            description = "Drive C has very limited free space."
            evidence = @(
                "Usage: $($disk.percent)%",
                "Free space: $($disk.freeGB) GB"
            )
            possibleCauses = @(
                "Temporary files",
                "Large application data",
                "Large logs"
            )
            recommendedFix = "Clean-Temp"
        }

    }
    elseif ($disk.percent -gt 85) {

        $problems += @{
            id = "DISK_C_LOW"
            title = "Disk (C:) Low Space ($($disk.percent)%)"
            severity = "warning"
            description = "Drive C is running low on free space."
            evidence = @(
                "Usage: $($disk.percent)%",
                "Free space: $($disk.freeGB) GB"
            )
            possibleCauses = @(
                "Temporary files",
                "Large logs",
                "Downloads"
            )
            recommendedFix = "Clean-Temp"
        }
    }

    # ========================================================
    # 2. Print Spooler
    # ========================================================

    $spooler = Get-Service `
        -Name "Spooler" `
        -ErrorAction SilentlyContinue

    if ($spooler) {

        if ($spooler.Status -ne "Running") {

            $problems += @{
                id = "SPOOLER_STOP"
                title = "Print Spooler Service Stopped"
                severity = "warning"
                description = "Windows Print Spooler is not running."
                evidence = @(
                    "Status: $($spooler.Status)",
                    "StartType: $($spooler.StartType)"
                )
                possibleCauses = @(
                    "Service stopped",
                    "Service crash"
                )
                recommendedFix = "restart-spooler"
            }
        }
    }

    # ========================================================
    # 3. Windows Update
    # ========================================================

    $wuauserv = Get-Service `
        -Name "wuauserv" `
        -ErrorAction SilentlyContinue

    if ($wuauserv) {

        if (
            $wuauserv.Status -ne "Running" -and
            $wuauserv.StartType -eq "Automatic"
        ) {

            $problems += @{
                id = "WUAUSERV_STOPPED"
                title = "Windows Update Service Stopped"
                severity = "warning"
                description = "Windows Update is configured for automatic startup but is not running."
                evidence = @(
                    "Status: $($wuauserv.Status)",
                    "StartType: $($wuauserv.StartType)"
                )
                possibleCauses = @(
                    "Service stopped",
                    "Temporary service failure"
                )
                recommendedFix = "restart-service-wuauserv"
            }
        }
    }

    # ========================================================
    # 4. Network
    # ========================================================

    $activeAdapters = @(
        Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq "Up" -and
            $_.InterfaceDescription -notmatch "Virtual|Loopback"
        }
    )

    $gateway = $null

    try {

        $gateway = Get-CimInstance `
            Win32_NetworkAdapterConfiguration |
            Where-Object {
                $_.IPEnabled -eq $true -and
                $_.DefaultIPGateway
            } |
            ForEach-Object {
                $_.DefaultIPGateway
            } |
            Select-Object -First 1

    }
    catch {}

    if (
        $activeAdapters.Count -eq 0 -or
        [string]::IsNullOrWhiteSpace([string]$gateway)
    ) {

        $problems += @{
            id = "NETWORK_DISCONNECTED"
            title = "Network / Wi-Fi Disconnected"
            severity = "critical"
            description = "No active physical network adapter or default gateway was detected."
            evidence = @(
                "Active adapter: None",
                "Gateway: None"
            )
            possibleCauses = @(
                "Wi-Fi disabled",
                "Ethernet disconnected",
                "DHCP failure"
            )
            recommendedFix = "renew-ip"
        }

    }
    else {

        # ----------------------------------------------------
        # Gateway ping
        # ----------------------------------------------------

        $gatewayPing = $false

        try {

            $ping = New-Object System.Net.NetworkInformation.Ping

            $reply = $ping.Send(
                [string]$gateway,
                1000
            )

            if ($reply.Status -eq "Success") {
                $gatewayPing = $true
            }

        }
        catch {}

        if (-not $gatewayPing) {

            $problems += @{
                id = "GATEWAY_UNREACHABLE"
                title = "Gateway Unreachable ($gateway)"
                severity = "critical"
                description = "The local default gateway did not respond to ping."
                evidence = @(
                    "Gateway: $gateway",
                    "Ping: FAILED"
                )
                possibleCauses = @(
                    "Router unavailable",
                    "Network isolation",
                    "IP conflict"
                )
                recommendedFix = "renew-ip"
            }

        }
        else {

            # ------------------------------------------------
            # DNS
            # ------------------------------------------------

            $dnsOk = $false

            try {

                $addresses =
                    [System.Net.Dns]::GetHostAddresses(
                        "www.google.com"
                    )

                if ($addresses.Count -gt 0) {
                    $dnsOk = $true
                }

            }
            catch {}

            if (-not $dnsOk) {

                $problems += @{
                    id = "DNS_FAILURE"
                    title = "DNS Resolution Failed"
                    severity = "warning"
                    description = "Gateway is reachable but DNS resolution failed."
                    evidence = @(
                        "Gateway Ping: OK",
                        "DNS lookup: FAILED"
                    )
                    possibleCauses = @(
                        "DNS server unavailable",
                        "DNS cache problem"
                    )
                    recommendedFix = "flush-dns"
                }
            }
        }
    }

    # ========================================================
    # 5. Defender
    # ========================================================

    try {

        $defender =
            Get-MpComputerStatus `
                -ErrorAction Stop

        if (
            $defender.RealTimeProtectionEnabled -eq $false
        ) {

            $problems += @{
                id = "SECURITY_DEFENDER_DISABLED"
                title = "Antivirus Protection Off"
                severity = "critical"
                description = "Microsoft Defender Real-Time Protection is disabled."
                evidence = @(
                    "RealTimeProtectionEnabled: False"
                )
                possibleCauses = @(
                    "Protection disabled",
                    "Security configuration issue"
                )
                recommendedFix = "enable-defender"
            }
        }

    }
    catch {}

    # ========================================================
    # 6. RAM
    # ========================================================

    $ram = Get-RamInfo

    if ($ram.percent -gt 90) {

        $problems += @{
            id = "RAM_HIGH"
            title = "High Memory Usage ($($ram.percent)%)"
            severity = "critical"
            description = "Available physical memory is very low."
            evidence = @(
                "RAM usage: $($ram.percent)%",
                "Free RAM: $($ram.freeGB) GB"
            )
            possibleCauses = @(
                "Heavy applications",
                "Large background processes"
            )
            recommendedFix = "Clear-Memory"
        }

    }
    elseif ($ram.percent -gt 85) {

        $problems += @{
            id = "RAM_HIGH"
            title = "High Memory Usage ($($ram.percent)%)"
            severity = "warning"
            description = "System memory usage is high."
            evidence = @(
                "RAM usage: $($ram.percent)%",
                "Free RAM: $($ram.freeGB) GB"
            )
            possibleCauses = @(
                "Heavy applications",
                "Multiple applications"
            )
            recommendedFix = "Clear-Memory"
        }
    }

    # ========================================================
    # 7. CPU
    # ========================================================

    $cpu = Get-CpuUsage

    if ($cpu -gt 90) {

        $problems += @{
            id = "CPU_HIGH"
            title = "High CPU Usage ($cpu%)"
            severity = "critical"
            description = "Processor load is currently very high."
            evidence = @(
                "CPU usage: $cpu%"
            )
            possibleCauses = @(
                "Heavy application",
                "Background process",
                "Runaway process"
            )
            recommendedFix = ""
        }
    }

    return @{
        problems = @($problems)
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        computer = $env:COMPUTERNAME
    }
}

# ------------------------------------------------------------
# Whitelisted Fix
# ------------------------------------------------------------

$AllowedFixes = @(
    "Clean-Temp",
    "restart-spooler",
    "restart-service-wuauserv",
    "Clear-Memory",
    "flush-dns",
    "renew-ip",
    "gpupdate",
    "enable-defender"
)

function Invoke-WhitelistedFix {

    param(
        [string]$Action
    )

    if (
        [string]::IsNullOrWhiteSpace($Action) -or
        $AllowedFixes -notcontains $Action
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
                    "$env:WINDIR\Temp"
                )

                foreach ($path in $paths) {

                    if (Test-Path $path) {

                        Get-ChildItem `
                            -Path $path `
                            -Force `
                            -ErrorAction SilentlyContinue |
                            Remove-Item `
                                -Recurse `
                                -Force `
                                -ErrorAction SilentlyContinue
                    }
                }

                return @{
                    success = $true
                    message = "Temporary files cleanup completed."
                }
            }

            "restart-spooler" {

                Restart-Service `
                    -Name "Spooler" `
                    -Force `
                    -ErrorAction Stop

                return @{
                    success = $true
                    message = "Print Spooler restarted."
                }
            }

            "restart-service-wuauserv" {

                Restart-Service `
                    -Name "wuauserv" `
                    -Force `
                    -ErrorAction Stop

                return @{
                    success = $true
                    message = "Windows Update Service restarted."
                }
            }

            "Clear-Memory" {

                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()

                return @{
                    success = $true
                    message = "PowerShell/.NET memory cleanup executed."
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
                    -PassThru

                if ($process.ExitCode -ne 0) {

                    return @{
                        success = $false
                        message = "ipconfig /renew failed with exit code $($process.ExitCode)."
                    }
                }

                return @{
                    success = $true
                    message = "IP address renewal completed."
                }
            }

            "gpupdate" {

                $process = Start-Process `
                    -FilePath "gpupdate.exe" `
                    -ArgumentList "/force" `
                    -NoNewWindow `
                    -Wait `
                    -PassThru

                return @{
                    success = ($process.ExitCode -eq 0)
                    message = "Group Policy update completed with exit code $($process.ExitCode)."
                }
            }

            "enable-defender" {

                Set-MpPreference `
                    -DisableRealtimeMonitoring $false `
                    -ErrorAction Stop

                return @{
                    success = $true
                    message = "Microsoft Defender Real-Time Protection enable command executed."
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
}

# ------------------------------------------------------------
# Main HTTP Loop
# ------------------------------------------------------------

try {

    while ($listener.IsListening) {

        $context = $listener.GetContext()

        $request = $context.Request
        $response = $context.Response

        # ----------------------------------------------------
        # CORS
        # ----------------------------------------------------

        $response.Headers.Add(
            "Access-Control-Allow-Origin",
            "*"
        )

        $response.Headers.Add(
            "Access-Control-Allow-Methods",
            "GET, POST, OPTIONS"
        )

        $response.Headers.Add(
            "Access-Control-Allow-Headers",
            "Content-Type"
        )

        if ($request.HttpMethod -eq "OPTIONS") {

            $response.StatusCode = 204
            $response.Close()

            continue
        }

        $path = $request.Url.LocalPath

        Write-Host `
            "[$(Get-Date -Format 'HH:mm:ss')] $($request.HttpMethod) $path" `
            -ForegroundColor DarkGray

        # ====================================================
        # METRICS
        # ====================================================

        if ($path -eq "/metrics") {

            Send-Json `
                -Response $response `
                -Data (Get-Metrics)

            continue
        }

        # ====================================================
        # PROCESSES
        # ====================================================

        if ($path -eq "/processes") {

            Send-Json `
                -Response $response `
                -Data (Get-ProcessData)

            continue
        }

        # ====================================================
        # DIAGNOSTIC
        # ====================================================

        if ($path -eq "/diagnose") {

            Send-Json `
                -Response $response `
                -Data (Invoke-Diagnostic)

            continue
        }

        # ====================================================
        # HISTORY
        # ====================================================

        if ($path -eq "/history") {

            Send-Json `
                -Response $response `
                -Data @($global:HistoryLog)

            continue
        }

        # ====================================================
        # FIX
        # ====================================================

        if ($path -eq "/fix") {

            if ($request.HttpMethod -ne "POST") {

                Send-Json `
                    -Response $response `
                    -StatusCode 405 `
                    -Data @{
                        success = $false
                        message = "POST required."
                    }

                continue
            }

            try {

                $body = Read-JsonBody $request

                if ($null -eq $body) {

                    Send-Json `
                        -Response $response `
                        -StatusCode 400 `
                        -Data @{
                            success = $false
                            message = "Invalid request body."
                        }

                    continue
                }

                $action =
                    [string]$body.action

                $title =
                    [string]$body.title

                $verificationStatus =
                    [string]$body.verificationStatus

                $result =
                    Invoke-WhitelistedFix `
                        -Action $action

                if ($result.success) {

                    $historyResult =
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

                    Add-History `
                        -Problem $title `
                        -Action $action `
                        -Result $historyResult
                }
                else {

                    Add-History `
                        -Problem $title `
                        -Action $action `
                        -Result "FAILED"
                }

                Send-Json `
                    -Response $response `
                    -Data $result

            }
            catch {

                Send-Json `
                    -Response $response `
                    -StatusCode 400 `
                    -Data @{
                        success = $false
                        message = $_.Exception.Message
                    }
            }

            continue
        }

        # ====================================================
        # KILL PROCESS
        # ====================================================

        if ($path -eq "/kill") {

            if ($request.HttpMethod -ne "POST") {

                Send-Json `
                    -Response $response `
                    -StatusCode 405 `
                    -Data @{
                        success = $false
                        message = "POST required."
                    }

                continue
            }

            try {

                $body = Read-JsonBody $request

                if ($null -eq $body) {

                    Send-Json `
                        -Response $response `
                        -StatusCode 400 `
                        -Data @{
                            success = $false
                            message = "Invalid request body."
                        }

                    continue
                }

                $pidValue = 0

                if (
                    -not [int]::TryParse(
                        [string]$body.id,
                        [ref]$pidValue
                    )
                ) {

                    Send-Json `
                        -Response $response `
                        -StatusCode 400 `
                        -Data @{
                            success = $false
                            message = "Invalid process ID."
                        }

                    continue
                }

                if ($pidValue -le 0) {

                    Send-Json `
                        -Response $response `
                        -StatusCode 400 `
                        -Data @{
                            success = $false
                            message = "Invalid process ID."
                        }

                    continue
                }

                $requestedName =
                    [string]$body.name

                # ------------------------------------------------
                # อ่าน Process จริงจาก PID
                # ------------------------------------------------

                try {

                    $process =
                        Get-Process `
                            -Id $pidValue `
                            -ErrorAction Stop

                }
                catch {

                    Send-Json `
                        -Response $response `
                        -StatusCode 404 `
                        -Data @{
                            success = $false
                            message = "Process PID $pidValue was not found."
                        }

                    continue
                }

                $actualName =
                    [string]$process.Name

                # ------------------------------------------------
                # ตรวจ Protected Process ฝั่ง Agent
                # ------------------------------------------------

                if (Test-ProtectedProcess $actualName) {

                    Add-History `
                        -Problem "Kill Process $actualName" `
                        -Action "Kill PID $pidValue" `
                        -Result "BLOCKED_PROTECTED"

                    Send-Json `
                        -Response $response `
                        -StatusCode 403 `
                        -Data @{
                            success = $false
                            message = "Protected process cannot be terminated: $actualName"
                        }

                    continue
                }

                # ------------------------------------------------
                # ป้องกัน mismatch ระหว่างชื่อที่ส่งมากับ Process จริง
                # ------------------------------------------------

                if (
                    -not [string]::IsNullOrWhiteSpace(
                        $requestedName
                    ) -and
                    $requestedName -ne $actualName
                ) {

                    Add-History `
                        -Problem "Kill Process $requestedName" `
                        -Action "Kill PID $pidValue" `
                        -Result "BLOCKED_NAME_MISMATCH"

                    Send-Json `
                        -Response $response `
                        -StatusCode 409 `
                        -Data @{
                            success = $false
                            message = "Process name mismatch. Actual process is '$actualName'."
                        }

                    continue
                }

                # ------------------------------------------------
                # Kill
                # ------------------------------------------------

                try {

                    Stop-Process `
                        -Id $pidValue `
                        -Force `
                        -ErrorAction Stop

                    Add-History `
                        -Problem "Kill Process $actualName" `
                        -Action "Kill PID $pidValue" `
                        -Result "SUCCESS"

                    Send-Json `
                        -Response $response `
                        -Data @{
                            success = $true
                            message = "Terminated $actualName (PID $pidValue)."
                        }

                }
                catch {

                    Add-History `
                        -Problem "Kill Process $actualName" `
                        -Action "Kill PID $pidValue" `
                        -Result "FAILED"

                    Send-Json `
                        -Response $response `
                        -Data @{
                            success = $false
                            message = $_.Exception.Message
                        }
                }

            }
            catch {

                Send-Json `
                    -Response $response `
                    -StatusCode 400 `
                    -Data @{
                        success = $false
                        message = $_.Exception.Message
                    }
            }

            continue
        }

        # ====================================================
        # STOP
        # ====================================================

        if ($path -eq "/stop") {

            Send-Json `
                -Response $response `
                -Data @{
                    success = $true
                    message = "Agent stopped."
                }

            Write-Host ""
            Write-Host "🛑 Agent stopped." -ForegroundColor Red

            $listener.Stop()

            break
        }

        # ====================================================
        # 404
        # ====================================================

        Send-Json `
            -Response $response `
            -StatusCode 404 `
            -Data @{
                error = "Not Found"
                path = $path
            }
    }
}
catch {

    Write-Host ""
    Write-Host "❌ Agent error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {

    if ($listener.IsListening) {
        $listener.Stop()
    }

    $listener.Close()
}

Write-Host ""
Write-Host "Agent process exited." -ForegroundColor Yellow