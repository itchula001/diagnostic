# ============================================================
# IT FIELD DIAGNOSTIC AGENT V5.3.1
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

$AgentUrl =
    "http://127.0.0.1:8765/"

$AgentTempDir =
    Join-Path `
        $env:TEMP `
        "ITDiagV5"

$AgentDataDir =
    Join-Path `
        $env:LOCALAPPDATA `
        "ITDiagV5"

$HistoryFile =
    Join-Path `
        $AgentDataDir `
        "history.json"

$ReportDir =
    Join-Path `
        ([Environment]::GetFolderPath("Desktop")) `
        "ITDiag-Reports"

$AgentLogFile =
    Join-Path `
        $AgentDataDir `
        "agent.log"


New-Item `
    -ItemType Directory `
    -Force `
    -Path $AgentTempDir |
    Out-Null

New-Item `
    -ItemType Directory `
    -Force `
    -Path $AgentDataDir |
    Out-Null

New-Item `
    -ItemType Directory `
    -Force `
    -Path $ReportDir |
    Out-Null


# ============================================================
# LOGGING
# ============================================================

function Write-AgentError {

    param(
        [string]$Message
    )

    try {

        $line =
            "$(Get-Date -Format s) [ERROR] $Message"

        Add-Content `
            -LiteralPath $AgentLogFile `
            -Value $line `
            -Encoding UTF8

    }
    catch {
    }

}


function Write-AgentInfo {

    param(
        [string]$Message
    )

    try {

        $line =
            "$(Get-Date -Format s) [INFO] $Message"

        Add-Content `
            -LiteralPath $AgentLogFile `
            -Value $line `
            -Encoding UTF8

    }
    catch {
    }

}


# ============================================================
# GLOBAL STATE
# ============================================================

$global:CurrentJob =
    $null

$global:History =
    @()


# ============================================================
# LOAD HISTORY
# ============================================================

if (Test-Path $HistoryFile) {

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

            if ($null -ne $parsed) {

                $global:History =
                    @(
                        $parsed
                    )
            }
        }

    }
    catch {

        $global:History =
            @()
    }

}


# ============================================================
# SAVE HISTORY
# ============================================================

function Save-History {

    try {

        $global:History |
            ConvertTo-Json `
                -Depth 20 |
            Set-Content `
                -Path $HistoryFile `
                -Encoding UTF8

    }
    catch {

        Write-AgentError `
            $_.Exception.Message
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
            ConvertTo-Json `
                -Depth 30 `
                -Compress

        $bytes =
            [System.Text.Encoding]::UTF8.GetBytes(
                $json
            )

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

        Write-AgentError `
            $_.Exception.Message
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

        if (
            [string]::IsNullOrWhiteSpace(
                $body
            )
        ) {

            return $null
        }

        return (
            $body |
            ConvertFrom-Json
        )

    }
    catch {

        return $null
    }

}


# ============================================================
# ADD JOB EVENT
# ============================================================

function Add-JobEvent {

    param(
        [string]$Action,
        [string]$Result
    )

    if (
        $null -eq
        $global:CurrentJob
    ) {

        return
    }

    if (
        $null -eq
        $global:CurrentJob.events
    ) {

        $global:CurrentJob |
            Add-Member `
                -MemberType NoteProperty `
                -Name events `
                -Value @() `
                -Force
    }

    $event =
        [PSCustomObject]@{

            time =
                (Get-Date).ToString("s")

            action =
                $Action

            result =
                $Result
        }

    $global:CurrentJob.events =
        @(
            $global:CurrentJob.events
        ) +
        $event

}


# ============================================================
# SYSTEM INFO
# ============================================================

function Get-SystemInfo {

    try {

        $os =
            Get-CimInstance `
                Win32_OperatingSystem

        $computer =
            Get-CimInstance `
                Win32_ComputerSystem

        $bios =
            Get-CimInstance `
                Win32_BIOS

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

            computer =
                $env:COMPUTERNAME

            user =
                $env:USERNAME

            manufacturer =
                ""

            model =
                ""

            windows =
                ""

            build =
                ""

            architecture =
                ""

            memoryGB =
                0

            serial =
                ""
        }
    }

}


# ============================================================
# METRICS V5.3.2
# ============================================================

function Get-Metrics {

    try {

        # ----------------------------------------------------
        # CPU
        # ----------------------------------------------------

        $cpuData =
            @(Get-CimInstance Win32_Processor -ErrorAction Stop)

        $cpuAverage =
            (
                $cpuData |
                Measure-Object `
                    -Property LoadPercentage `
                    -Average
            ).Average

        if ($null -eq $cpuAverage) {
            $cpu = 0
        }
        else {
            $cpu =
                [math]::Round(
                    [double]$cpuAverage,
                    0
                )
        }


        # ----------------------------------------------------
        # MEMORY
        # ----------------------------------------------------

        $os =
            Get-CimInstance `
                Win32_OperatingSystem `
                -ErrorAction Stop

        $totalRamKB =
            [double]$os.TotalVisibleMemorySize

        $freeRamKB =
            [double]$os.FreePhysicalMemory

        if ($totalRamKB -gt 0) {

            $ram =
                [math]::Round(
                    (
                        (
                            $totalRamKB -
                            $freeRamKB
                        ) /
                        $totalRamKB
                    ) * 100,
                    0
                )

        }
        else {

            $ram = 0

        }

        $ramFreeGB =
            [math]::Round(
                $freeRamKB / 1MB,
                2
            )


        # ----------------------------------------------------
        # DISK C:
        # ----------------------------------------------------

        $disk =
            Get-CimInstance `
                Win32_LogicalDisk `
                -Filter "DeviceID='C:'" `
                -ErrorAction Stop

        if (
            $null -ne $disk -and
            [double]$disk.Size -gt 0
        ) {

            $diskUsage =
                [math]::Round(
                    (
                        (
                            [double]$disk.Size -
                            [double]$disk.FreeSpace
                        ) /
                        [double]$disk.Size
                    ) * 100,
                    0
                )

            $diskFreeGB =
                [math]::Round(
                    [double]$disk.FreeSpace / 1GB,
                    2
                )

        }
        else {

            $diskUsage = 0
            $diskFreeGB = 0

        }


        # ----------------------------------------------------
        # IMPORTANT
        # Return ONE object only
        # ----------------------------------------------------

        $result =
            [PSCustomObject]@{

                cpu =
                    [int]$cpu

                ram =
                    [int]$ram

                ramFreeGB =
                    [double]$ramFreeGB

                disk =
                    [int]$diskUsage

                diskFreeGB =
                    [double]$diskFreeGB
            }


        return ,$result

    }
    catch {

        # ----------------------------------------------------
        # SAFE FALLBACK
        # ----------------------------------------------------

        $result =
            [PSCustomObject]@{

                cpu = 0
                ram = 0
                ramFreeGB = 0
                disk = 0
                diskFreeGB = 0
            }

        return ,$result
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

            $gateway = ""

            if ($item.DefaultIPGateway) {

                $gateway =
                    ($item.DefaultIPGateway -join ", ")
            }

            $dns = ""

            if ($item.DNSServerSearchOrder) {

                $dns =
                    ($item.DNSServerSearchOrder -join ", ")
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

    $result =
        @()

    foreach (
        $name
        in $important
    ) {

        try {

            $service =
                Get-CimInstance `
                    Win32_Service `
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

    return @(
        $result
    )

}


# ============================================================
# PROCESSES
# ============================================================

function Get-ProcessStatus {

    $result =
        @()

    try {

        $items =
            Get-Process |
            Sort-Object `
                WorkingSet64 `
                -Descending |
            Select-Object `
                -First 60

        foreach (
            $item
            in $items
        ) {

            $cpu =
                0

            try {

                if (
                    $item.CPU
                ) {

                    $cpu =
                        [math]::Round(
                            $item.CPU,
                            1
                        )
                }

            }
            catch {
            }

            $result +=
                [PSCustomObject]@{

                    id =
                        $item.Id

                    name =
                        $item.ProcessName

                    cpu =
                        $cpu

                    memoryMB =
                        [math]::Round(
                            $item.WorkingSet64 /
                            1MB,
                            1
                        )
                }
        }

    }
    catch {
    }

    return @(
        $result
    )

}


# ============================================================
# EVENTS
# ============================================================

function Get-Events {

    $result =
        @()

    try {

        $logs =
            Get-WinEvent `
                -LogName System `
                -MaxEvents 40 `
                -ErrorAction Stop

        foreach (
            $item
            in $logs
        ) {

            $result +=
                [PSCustomObject]@{

                    time =
                        $item.TimeCreated

                    id =
                        $item.Id

                    provider =
                        $item.ProviderName

                    level =
                        $item.LevelDisplayName

                    message =
                        $item.Message
                }
        }

    }
    catch {
    }

    return @(
        $result
    )

}


# ============================================================
# DIAGNOSTICS
# ============================================================

function Run-Diagnostics {

    $problems =
        @()

    $health =
        100

    try {

        $metrics =
            Get-Metrics

        if (
            $metrics.cpu -ge 90
        ) {

            $health -=
                20

            $problems +=
                [PSCustomObject]@{

                    title =
                        "High CPU Usage"

                    severity =
                        "HIGH"

                    description =
                        "CPU usage is above 90%."

                    recommendedFix =
                        "Review running processes."
                }
        }

        if (
            $metrics.ram -ge 90
        ) {

            $health -=
                20

            $problems +=
                [PSCustomObject]@{

                    title =
                        "High Memory Usage"

                    severity =
                        "HIGH"

                    description =
                        "RAM usage is above 90%."

                    recommendedFix =
                        "Review applications and memory usage."
                }
        }

        if (
            $metrics.disk -ge 90
        ) {

            $health -=
                20

            $problems +=
                [PSCustomObject]@{

                    title =
                        "Low Disk Space"

                    severity =
                        "HIGH"

                    description =
                        "C: disk usage is above 90%."

                    recommendedFix =
                        "Clean temporary files and unnecessary data."
                }
        }

        $network =
            Get-NetworkInfo

        if (
            -not $network.internet
        ) {

            $health -=
                25

            $problems +=
                [PSCustomObject]@{

                    title =
                        "Internet Connectivity"

                    severity =
                        "HIGH"

                    description =
                        "Internet connectivity test failed."

                    recommendedFix =
                        "Test DNS, renew IP, and check network adapter."
                }
        }

    }
    catch {
    }

    if (
        $health -lt 0
    ) {

        $health =
            0
    }

    return [PSCustomObject]@{

        health =
            $health

        problems =
            @(
                $problems
            )
    }

}


# ============================================================
# START JOB
# ============================================================

function Start-NewJob {

    if (
        $null -ne
        $global:CurrentJob
    ) {

        return @{
            success =
                $false

            message =
                "A job is already active."

            job =
                $global:CurrentJob
        }
    }

    $jobId =
        "JOB-" +
        (
            Get-Date `
                -Format "yyyyMMdd-HHmmss"
        )

    $global:CurrentJob =
        [PSCustomObject]@{

            id =
                $jobId

            computer =
                $env:COMPUTERNAME

            user =
                $env:USERNAME

            startedAt =
                (
                    Get-Date
                ).ToString("s")

            endedAt =
                $null

            status =
                "ACTIVE"

            events =
                @()

            actions =
                @()
        }

    Add-JobEvent `
        "job-start" `
        "Diagnostic job started."

    Write-AgentInfo `
        "Job started: $jobId"

    return @{
        success =
            $true

        job =
            $global:CurrentJob

        message =
            "Job started successfully."
    }

}


# ============================================================
# V5.3 SAFE FIX ENGINE
# ============================================================

$global:FixCatalog =
    @{

        FLUSH_DNS =
            @{
                category =
                    "NETWORK"

                title =
                    "Flush DNS"

                admin =
                    $false
            }

        RENEW_IP =
            @{
                category =
                    "NETWORK"

                title =
                    "Renew IP"

                admin =
                    $true
            }

        RESET_WINSOCK =
            @{
                category =
                    "NETWORK"

                title =
                    "Reset Winsock"

                admin =
                    $true
            }

        RESET_TCPIP =
            @{
                category =
                    "NETWORK"

                title =
                    "Reset TCP/IP"

                admin =
                    $true
            }

        RESTART_ADAPTER =
            @{
                category =
                    "NETWORK"

                title =
                    "Restart Network Adapter"

                admin =
                    $true
            }

        TEST_INTERNET =
            @{
                category =
                    "NETWORK"

                title =
                    "Test Internet"

                admin =
                    $false
            }

        TEST_DNS =
            @{
                category =
                    "NETWORK"

                title =
                    "Test DNS"

                admin =
                    $false
            }

        RESTART_EXPLORER =
            @{
                category =
                    "WINDOWS"

                title =
                    "Restart Explorer"

                admin =
                    $false
            }

        CLEAR_USER_TEMP =
            @{
                category =
                    "WINDOWS"

                title =
                    "Clear User Temp"

                admin =
                    $false
            }

        CLEAR_WINDOWS_TEMP =
            @{
                category =
                    "WINDOWS"

                title =
                    "Clear Windows Temp"

                admin =
                    $true
            }

        RESTART_SPOOLER =
            @{
                category =
                    "PRINTER"

                title =
                    "Restart Print Spooler"

                admin =
                    $true
            }

        CLEAR_PRINT_QUEUE =
            @{
                category =
                    "PRINTER"

                title =
                    "Clear Print Queue"

                admin =
                    $true
            }

        RESTART_WUAUSERV =
            @{
                category =
                    "WINDOWS UPDATE"

                title =
                    "Restart Windows Update"

                admin =
                    $true
            }

        RESET_WINDOWS_UPDATE =
            @{
                category =
                    "WINDOWS UPDATE"

                title =
                    "Reset Windows Update Components"

                admin =
                    $true
            }

        CHECK_FIREWALL =
            @{
                category =
                    "SECURITY"

                title =
                    "Check Windows Firewall"

                admin =
                    $false
            }

        SFC_SCAN =
            @{
                category =
                    "WINDOWS"

                title =
                    "SFC Scan"

                admin =
                    $true
            }

        DISM_RESTOREHEALTH =
            @{
                category =
                    "WINDOWS"

                title =
                    "DISM RestoreHealth"

                admin =
                    $true
            }

    }


function Test-IsAdministrator {

    try {

        $identity =
            [Security.Principal.WindowsIdentity]::GetCurrent()

        $principal =
            New-Object `
                Security.Principal.WindowsPrincipal(
                    $identity
                )

        return (
            $principal.IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )
        )

    }
    catch {

        return $false
    }

}


function Add-FixActionLog {

    param(
        [string]$Action,
        [string]$Category,
        [string]$Result,
        [string]$Message
    )

    if (
        $null -eq
        $global:CurrentJob
    ) {

        return
    }

    if (
        $null -eq
        $global:CurrentJob.actions
    ) {

        $global:CurrentJob |
            Add-Member `
                -MemberType NoteProperty `
                -Name actions `
                -Value @() `
                -Force
    }

    $item =
        [PSCustomObject]@{

            time =
                (
                    Get-Date
                ).ToString("s")

            action =
                $Action

            category =
                $Category

            result =
                $Result

            message =
                $Message
        }

    $global:CurrentJob.actions =
        @(
            $global:CurrentJob.actions
        ) +
        $item

    Add-JobEvent `
        "fix:$Action" `
        "$Result - $Message"

}


function Invoke-FixAction {

    param(
        [string]$ActionId
    )

    if (
        [string]::IsNullOrWhiteSpace(
            $ActionId
        )
    ) {

        return @{
            success =
                $false

            message =
                "Fix action is required."
        }
    }

    $key =
        $ActionId.ToUpperInvariant()

    if (
        -not $global:FixCatalog.ContainsKey(
            $key
        )
    ) {

        return @{
            success =
                $false

            message =
                "Fix action is not allowed."
        }
    }

    if (
        $null -eq
        $global:CurrentJob
    ) {

        return @{
            success =
                $false

            message =
                "No active job."
        }
    }

    $meta =
        $global:FixCatalog[$key]

    if (
        $meta.admin -and
        -not (
            Test-IsAdministrator
        )
    ) {

        $message =
            "Administrator privileges are required for this action."

        Add-FixActionLog `
            $meta.title `
            $meta.category `
            "FAILED" `
            $message

        return @{
            success =
                $false

            action =
                $key

            message =
                $message
        }
    }

    try {

        $message =
            ""

        switch ($key) {

            "FLUSH_DNS" {

                Clear-DnsClientCache `
                    -ErrorAction Stop

                $message =
                    "DNS cache flushed successfully."
            }


            "RENEW_IP" {

                ipconfig /release |
                    Out-Null

                ipconfig /renew |
                    Out-Null

                $message =
                    "IP lease released and renewed."
            }


            "RESET_WINSOCK" {

                netsh winsock reset |
                    Out-Null

                $message =
                    "Winsock reset completed. Restart may be required."
            }


            "RESET_TCPIP" {

                netsh int ip reset |
                    Out-Null

                $message =
                    "TCP/IP reset completed. Restart may be required."
            }


            "RESTART_ADAPTER" {

                $adapter =
                    Get-NetAdapter |
                    Where-Object {
                        $_.Status -eq "Up"
                    } |
                    Select-Object -First 1

                if (
                    -not $adapter
                ) {

                    throw `
                        "No active network adapter was found."
                }

                Restart-NetAdapter `
                    -Name $adapter.Name `
                    -Confirm:$false `
                    -ErrorAction Stop

                $message =
                    "Network adapter '$($adapter.Name)' restarted."
            }


            "TEST_INTERNET" {

                $ok =
                    Test-Connection `
                        -ComputerName "1.1.1.1" `
                        -Count 2 `
                        -Quiet `
                        -ErrorAction SilentlyContinue

                if ($ok) {

                    $message =
                        "Internet connectivity test succeeded."

                }
                else {

                    throw `
                        "Internet connectivity test failed."
                }
            }


            "TEST_DNS" {

                Resolve-DnsName `
                    -Name "example.com" `
                    -ErrorAction Stop |
                    Out-Null

                $message =
                    "DNS resolution succeeded for example.com."
            }


            "RESTART_EXPLORER" {

                Get-Process `
                    explorer `
                    -ErrorAction SilentlyContinue |
                    Stop-Process `
                        -Force `
                        -ErrorAction SilentlyContinue

                Start-Process `
                    explorer.exe

                $message =
                    "Windows Explorer restarted."
            }


            "CLEAR_USER_TEMP" {

                $temp =
                    [IO.Path]::GetTempPath()

                Get-ChildItem `
                    -LiteralPath $temp `
                    -Force `
                    -ErrorAction SilentlyContinue |
                    Remove-Item `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue

                $message =
                    "User Temp cleanup completed where files were removable."
            }


            "CLEAR_WINDOWS_TEMP" {

                $temp =
                    Join-Path `
                        $env:WINDIR `
                        "Temp"

                Get-ChildItem `
                    -LiteralPath $temp `
                    -Force `
                    -ErrorAction SilentlyContinue |
                    Remove-Item `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue

                $message =
                    "Windows Temp cleanup completed where files were removable."
            }


            "RESTART_SPOOLER" {

                Restart-Service `
                    -Name Spooler `
                    -Force `
                    -ErrorAction Stop

                $message =
                    "Print Spooler restarted."
            }


            "CLEAR_PRINT_QUEUE" {

                Stop-Service `
                    -Name Spooler `
                    -Force `
                    -ErrorAction Stop

                $spool =
                    Join-Path `
                        $env:WINDIR `
                        "System32\spool\PRINTERS"

                Get-ChildItem `
                    -LiteralPath $spool `
                    -Force `
                    -ErrorAction SilentlyContinue |
                    Remove-Item `
                        -Force `
                        -ErrorAction SilentlyContinue

                Start-Service `
                    -Name Spooler `
                    -ErrorAction Stop

                $message =
                    "Print queue cleared and Print Spooler restarted."
            }


            "RESTART_WUAUSERV" {

                Restart-Service `
                    -Name wuauserv `
                    -Force `
                    -ErrorAction Stop

                $message =
                    "Windows Update service restarted."
            }


            "RESET_WINDOWS_UPDATE" {

                Stop-Service `
                    -Name wuauserv `
                    -Force `
                    -ErrorAction SilentlyContinue

                Stop-Service `
                    -Name bits `
                    -Force `
                    -ErrorAction SilentlyContinue

                Stop-Service `
                    -Name cryptsvc `
                    -Force `
                    -ErrorAction SilentlyContinue

                $sd =
                    Join-Path `
                        $env:WINDIR `
                        "SoftwareDistribution"

                $sdOld =
                    Join-Path `
                        $env:WINDIR `
                        "SoftwareDistribution.V5Backup"

                if (
                    Test-Path $sdOld
                ) {

                    Remove-Item `
                        $sdOld `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue
                }

                if (
                    Test-Path $sd
                ) {

                    Rename-Item `
                        $sd `
                        "SoftwareDistribution.V5Backup" `
                        -ErrorAction SilentlyContinue
                }

                Start-Service `
                    -Name cryptsvc `
                    -ErrorAction SilentlyContinue

                Start-Service `
                    -Name bits `
                    -ErrorAction SilentlyContinue

                Start-Service `
                    -Name wuauserv `
                    -ErrorAction SilentlyContinue

                $message =
                    "Windows Update components were reset where possible."
            }


            "CHECK_FIREWALL" {

                $profiles =
                    Get-NetFirewallProfile |
                    Select-Object `
                        Name,
                        Enabled

                $message =
                    (
                        $profiles |
                        ForEach-Object {

                            "$($_.Name)=$($_.Enabled)"

                        }
                    ) -join ", "
            }


            "SFC_SCAN" {

                $p =
                    Start-Process `
                        -FilePath `
                            "$env:WINDIR\System32\sfc.exe" `
                        -ArgumentList `
                            "/scannow" `
                        -Wait `
                        -PassThru `
                        -WindowStyle Hidden

                if (
                    $p.ExitCode -eq 0
                ) {

                    $message =
                        "SFC scan completed successfully."

                }
                else {

                    throw `
                        "SFC completed with exit code $($p.ExitCode)."
                }
            }


            "DISM_RESTOREHEALTH" {

                $p =
                    Start-Process `
                        -FilePath `
                            "$env:WINDIR\System32\DISM.exe" `
                        -ArgumentList `
                            "/Online",
                            "/Cleanup-Image",
                            "/RestoreHealth" `
                        -Wait `
                        -PassThru `
                        -WindowStyle Hidden

                if (
                    $p.ExitCode -eq 0
                ) {

                    $message =
                        "DISM RestoreHealth completed successfully."

                }
                else {

                    throw `
                        "DISM completed with exit code $($p.ExitCode)."
                }
            }

        }

        Add-FixActionLog `
            $meta.title `
            $meta.category `
            "SUCCESS" `
            $message

        Write-AgentInfo `
            "FIX SUCCESS: $($meta.title)"

        return @{
            success =
                $true

            action =
                $key

            category =
                $meta.category

            message =
                $message
        }

    }
    catch {

        $message =
            $_.Exception.Message

        Add-FixActionLog `
            $meta.title `
            $meta.category `
            "FAILED" `
            $message

        Write-AgentError `
            "FIX FAILED: $($meta.title) - $message"

        return @{
            success =
                $false

            action =
                $key

            category =
                $meta.category

            message =
                $message
        }
    }

}


# ============================================================
# HTML ESCAPE
# ============================================================

function ConvertTo-HtmlSafe {

    param(
        [object]$Value
    )

    if (
        $null -eq $Value
    ) {

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
            $Job.id `
                -replace `
                '[^a-zA-Z0-9\-_]', '_'

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


        $problemRows =
            ""

        foreach (
            $problem
            in $diagnostics.problems
        ) {

            $problemRows +=
                "<tr>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $problem.title
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $problem.severity
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $problem.description
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $problem.recommendedFix
                )</td>" +
                "</tr>"
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $problemRows
            )
        ) {

            $problemRows =
                "<tr><td colspan='4'>No detected problems.</td></tr>"
        }


        # ----------------------------------------------------
        # FIX ACTION ROWS
        # ----------------------------------------------------

        $actionRows =
            ""

        foreach (
            $action
            in @(
                $Job.actions
            )
        ) {

            $actionRows +=
                "<tr>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $action.time
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $action.category
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $action.action
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $action.result
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $action.message
                )</td>" +
                "</tr>"
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $actionRows
            )
        ) {

            $actionRows =
                "<tr><td colspan='5'>No Fix Engine actions executed.</td></tr>"
        }


        $serviceRows =
            ""

        foreach (
            $service
            in $services
        ) {

            $serviceRows +=
                "<tr>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $service.name
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $service.displayName
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $service.status
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $service.startType
                )</td>" +
                "</tr>"
        }


        $eventRows =
            ""

        foreach (
            $event
            in $events
        ) {

            $eventRows +=
                "<tr>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $event.time
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $event.id
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $event.provider
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $event.level
                )</td>" +
                "<td>$(
                    ConvertTo-HtmlSafe `
                        $event.message
                )</td>" +
                "</tr>"
        }


        $html = @"
<!DOCTYPE html>
<html>

<head>

<meta charset="UTF-8">

<title>
IT Diagnostic Report - $($Job.id)
</title>

<style>

body {
    font-family:
        Segoe UI,
        Arial,
        sans-serif;

    margin: 30px;

    background: #f4f6f8;

    color: #17202a;
}

h1 {
    margin-bottom: 5px;
}

.card {

    background: white;

    border:
        1px solid
        #d8dee4;

    border-radius: 10px;

    padding: 20px;

    margin-bottom: 20px;
}

.grid {

    display: grid;

    grid-template-columns:
        repeat(
            4,
            1fr
        );

    gap: 12px;
}

.metric {

    background:
        #eef2f5;

    padding: 14px;

    border-radius: 8px;
}

.label {

    color:
        #68737d;

    font-size: 12px;
}

.value {

    font-size: 20px;

    font-weight:
        bold;

    margin-top: 5px;
}

table {

    width: 100%;

    border-collapse:
        collapse;
}

th,
td {

    border:
        1px solid
        #d8dee4;

    padding: 8px;

    text-align: left;

    vertical-align:
        top;
}

th {

    background:
        #eef2f5;
}

.ok {

    color:
        green;

    font-weight:
        bold;
}

</style>

</head>

<body>


<h1>
IT FIELD DIAGNOSTIC PORTAL V5.3.1
</h1>


<p>

Generated:

$(Get-Date)

</p>


<div class="card">

<h2>
Job Information
</h2>

<div class="grid">


<div class="metric">

<div class="label">
Job ID
</div>

<div class="value">
$($Job.id)
</div>

</div>


<div class="metric">

<div class="label">
Computer
</div>

<div class="value">
$($Job.computer)
</div>

</div>


<div class="metric">

<div class="label">
User
</div>

<div class="value">
$($Job.user)
</div>

</div>


<div class="metric">

<div class="label">
Started
</div>

<div class="value">
$($Job.startedAt)
</div>

</div>


<div class="metric">

<div class="label">
Ended
</div>

<div class="value">
$($Job.endedAt)
</div>

</div>


</div>

</div>


<div class="card">

<h2>
System Information
</h2>

<div class="grid">


<div class="metric">

<div class="label">
Computer
</div>

<div class="value">
$($system.computer)
</div>

</div>


<div class="metric">

<div class="label">
User
</div>

<div class="value">
$($system.user)
</div>

</div>


<div class="metric">

<div class="label">
Manufacturer
</div>

<div class="value">
$($system.manufacturer)
</div>

</div>


<div class="metric">

<div class="label">
Model
</div>

<div class="value">
$($system.model)
</div>

</div>


<div class="metric">

<div class="label">
Windows
</div>

<div class="value">
$($system.windows)
</div>

</div>


<div class="metric">

<div class="label">
Build
</div>

<div class="value">
$($system.build)
</div>

</div>


<div class="metric">

<div class="label">
Architecture
</div>

<div class="value">
$($system.architecture)
</div>

</div>


<div class="metric">

<div class="label">
Memory
</div>

<div class="value">
$($system.memoryGB) GB
</div>

</div>


</div>

</div>


<div class="card">

<h2>
System Health
</h2>

<div class="grid">


<div class="metric">

<div class="label">
Health
</div>

<div class="value">
$($diagnostics.health) / 100
</div>

</div>


<div class="metric">

<div class="label">
CPU
</div>

<div class="value">
$($metrics.cpu)%
</div>

</div>


<div class="metric">

<div class="label">
RAM
</div>

<div class="value">
$($metrics.ram)%
</div>

</div>


<div class="metric">

<div class="label">
Disk C:
</div>

<div class="value">
$($metrics.disk)%
</div>

</div>


<div class="metric">

<div class="label">
Free RAM
</div>

<div class="value">
$($metrics.ramFreeGB) GB
</div>

</div>


<div class="metric">

<div class="label">
Free Disk
</div>

<div class="value">
$($metrics.diskFreeGB) GB
</div>

</div>


</div>

</div>


<div class="card">

<h2>
Diagnostics
</h2>

<table>

<thead>

<tr>

<th>
Problem
</th>

<th>
Severity
</th>

<th>
Description
</th>

<th>
Recommended Fix
</th>

</tr>

</thead>

<tbody>

$problemRows

</tbody>

</table>

</div>


<div class="card">

<h2>
Network
</h2>

<p>

Internet:

<strong>

$(
    if (
        $network.internet
    ) {

        "ONLINE"

    }
    else {

        "OFFLINE"
    }
)

</strong>

</p>


<table>

<thead>

<tr>

<th>
Interface
</th>

<th>
IPv4
</th>

<th>
Gateway
</th>

<th>
DNS
</th>

</tr>

</thead>

<tbody>

$(
    (
        $network.adapters |
        ForEach-Object {

            "<tr>" +
            "<td>$(
                ConvertTo-HtmlSafe `
                    $_.interface
            )</td>" +

            "<td>$(
                ConvertTo-HtmlSafe `
                    $_.ipv4
            )</td>" +

            "<td>$(
                ConvertTo-HtmlSafe `
                    $_.gateway
            )</td>" +

            "<td>$(
                ConvertTo-HtmlSafe `
                    $_.dns
            )</td>" +

            "</tr>"

        }
    ) -join ""
)

</tbody>

</table>

</div>


<div class="card">

<h2>
Fix Action Log
</h2>

<table>

<thead>

<tr>

<th>
Time
</th>

<th>
Category
</th>

<th>
Action
</th>

<th>
Result
</th>

<th>
Message
</th>

</tr>

</thead>

<tbody>

$actionRows

</tbody>

</table>

</div>


<div class="card">

<h2>
Services
</h2>

<table>

<thead>

<tr>

<th>
Name
</th>

<th>
Display Name
</th>

<th>
Status
</th>

<th>
Start Type
</th>

</tr>

</thead>

<tbody>

$serviceRows

</tbody>

</table>

</div>


<div class="card">

<h2>
Windows Events
</h2>

<table>

<thead>

<tr>

<th>
Time
</th>

<th>
ID
</th>

<th>
Provider
</th>

<th>
Level
</th>

<th>
Message
</th>

</tr>

</thead>

<tbody>

$eventRows

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

        Write-AgentError `
            $_.Exception.Message

        return $null
    }

}


# ============================================================
# END JOB
# ============================================================

function End-CurrentJob {

    if (
        $null -eq
        $global:CurrentJob
    ) {

        return @{
            success =
                $false

            message =
                "No active job."

            report =
                $null
        }
    }

    $global:CurrentJob.endedAt =
        (
            Get-Date
        ).ToString("s")

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

    Write-AgentInfo `
        "Job ended: $($finished.id)"

    return @{
        success =
            $true

        job =
            $finished

        report =
            $reportFile

        message =
            "Job ended successfully."
    }

}


# ============================================================
# KILL PROCESS
# ============================================================

function Stop-TargetProcess {

    param(
        [int]$ProcessId
    )

    if (
        $ProcessId -eq 4
    ) {

        return @{
            success =
                $false

            message =
                "PID 4 is protected."
        }
    }

    if (
        $ProcessId -le 0
    ) {

        return @{
            success =
                $false

            message =
                "Invalid process ID."
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
                success =
                    $false

                message =
                    "Protected process cannot be terminated."
            }
        }

        Stop-Process `
            -Id $ProcessId `
            -Force `
            -ErrorAction Stop

        return @{
            success =
                $true

            message =
                "Process terminated."

            pid =
                $ProcessId
        }

    }
    catch {

        return @{
            success =
                $false

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

    if (
        [string]::IsNullOrWhiteSpace(
            $JobId
        )
    ) {

        return @{
            success =
                $false

            ready =
                $false

            message =
                "Job ID is required."
        }
    }

    $safeId =
        $JobId `
            -replace `
            '[^a-zA-Z0-9\-_]', '_'

    $file =
        Join-Path `
            $ReportDir `
            "$safeId.html"

    if (
        Test-Path $file
    ) {

        return @{
            success =
                $true

            ready =
                $true

            status =
                "ready"

            path =
                $file
        }
    }

    return @{
        success =
            $true

        ready =
            $false

        status =
            "pending"

        path =
            $file
    }

}


# ============================================================
# HTTP LISTENER
# ============================================================

$listener =
    New-Object `
        System.Net.HttpListener

try {

    $listener.Prefixes.Add(
        $AgentUrl
    )

    $listener.Start()

}
catch {

    Write-Host ""
    Write-Host `
        "Unable to start IT Diagnostic Agent." `
        -ForegroundColor Red

    Write-Host `
        $_.Exception.Message `
        -ForegroundColor Red

    Write-AgentError `
        $_.Exception.Message

    exit 1
}


Write-Host ""

Write-Host `
    "IT Diagnostic Agent V5.3.1" `
    -ForegroundColor Green

Write-Host `
    "Listening on $AgentUrl" `
    -ForegroundColor Cyan

Write-Host ""

Write-AgentInfo `
    "Agent started. PID=$PID URL=$AgentUrl"


# ============================================================
# REQUEST LOOP
# ============================================================

try {

    while (
        $listener.IsListening
    ) {

        $context =
            $null

        try {

            $context =
                $listener.GetContext()

        }
        catch {

            if (
                -not $listener.IsListening
            ) {

                break
            }

            continue
        }

        if (
            $null -eq $context
        ) {

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


        try {


            # ------------------------------------------------
            # CORS
            # ------------------------------------------------

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


            # ------------------------------------------------
            # OPTIONS
            # ------------------------------------------------

            if (
                $method -eq
                "OPTIONS"
            ) {

                $response.StatusCode =
                    204

                $response.Close()

                continue
            }


            # ------------------------------------------------
            # ROOT
            # ------------------------------------------------

            if (
                $path -eq
                "/"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        agent =
                            "IT Diagnostic Agent V5.3.1"

                        version =
                            "5.3.1"

                        status =
                            "online"
                    }

                continue
            }


            # ------------------------------------------------
            # AGENT STATUS
            # ------------------------------------------------

            if (
                $path -eq
                "/agent/status"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        online =
                            $true

                        version =
                            "5.3.1"

                        agent =
                            "IT Diagnostic Agent V5.3.1"

                        pid =
                            $PID

                        computer =
                            $env:COMPUTERNAME

                        user =
                            $env:USERNAME
                    }

                continue
            }


            # ------------------------------------------------
            # SYSTEM
            # ------------------------------------------------

            if (
                $path -eq
                "/system"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        data =
                            Get-SystemInfo
                    }

                continue
            }


            # ------------------------------------------------
            # METRICS
            # ------------------------------------------------

            if (
                $path -eq
                "/metrics"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        data =
                            Get-Metrics
                    }

                continue
            }


            # ------------------------------------------------
            # NETWORK
            # ------------------------------------------------

            if (
                $path -eq
                "/network"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        data =
                            Get-NetworkInfo
                    }

                continue
            }


            # ------------------------------------------------
            # SERVICES
            # ------------------------------------------------

            if (
                $path -eq
                "/services"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        data =
                            Get-ServiceStatus
                    }

                continue
            }


            # ------------------------------------------------
            # PROCESSES
            # ------------------------------------------------

            if (
                $path -eq
                "/processes"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        data =
                            Get-ProcessStatus
                    }

                continue
            }


            # ------------------------------------------------
            # EVENTS
            # ------------------------------------------------

            if (
                $path -eq
                "/events"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        data =
                            Get-Events
                    }

                continue
            }


            # ------------------------------------------------
            # DIAGNOSE
            # ------------------------------------------------

            if (
                $path -eq
                "/diagnose"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        data =
                            Run-Diagnostics
                    }

                continue
            }


            # ------------------------------------------------
            # FIX ENGINE
            # ------------------------------------------------

            if (
                $path -eq
                "/fix" -and
                $method -eq
                "POST"
            ) {

                try {

                    $data =
                        Read-RequestBody `
                            $request

                    $actionId =
                        [string]
                        $data.action

                    Send-JsonResponse `
                        $context `
                        (
                            Invoke-FixAction `
                                -ActionId $actionId
                        )

                }
                catch {

                    Write-AgentError `
                        $_.Exception.Message

                    Send-JsonResponse `
                        $context `
                        @{
                            success =
                                $false

                            message =
                                $_.Exception.Message
                        } `
                        500
                }

                continue
            }


            # ------------------------------------------------
            # START JOB
            # ------------------------------------------------

            if (
                $path -eq
                "/job/start" -and
                $method -eq
                "POST"
            ) {

                Send-JsonResponse `
                    $context `
                    (
                        Start-NewJob
                    )

                continue
            }


            # ------------------------------------------------
            # JOB STATUS
            # ------------------------------------------------

            if (
                $path -eq
                "/job/status"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

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


            # ------------------------------------------------
            # END JOB
            # ------------------------------------------------

            if (
                $path -eq
                "/job/end" -and
                $method -eq
                "POST"
            ) {

                Send-JsonResponse `
                    $context `
                    (
                        End-CurrentJob
                    )

                continue
            }


            # ------------------------------------------------
            # HISTORY
            # ------------------------------------------------

            if (
                $path -eq
                "/history"
            ) {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        data =
                            @(
                                $global:History
                            )
                    }

                continue
            }


            # ------------------------------------------------
            # KILL
            # ------------------------------------------------

            if (
                $path -eq
                "/kill" -and
                $method -eq
                "POST"
            ) {

                try {

                    $data =
                        Read-RequestBody `
                            $request

                    $pidValue =
                        [int]
                        $data.pid

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
                            success =
                                $false

                            message =
                                $_.Exception.Message
                        }
                }

                continue
            }


            # ------------------------------------------------
            # REPORT STATUS
            # ------------------------------------------------

            if (
                $path -eq
                "/report/status"
            ) {

                $jobId =
                    $request.QueryString[
                        "jobId"
                    ]

                Send-JsonResponse `
                    $context `
                    (
                        Get-ReportStatus `
                            -JobId $jobId
                    )

                continue
            }


            # ------------------------------------------------
            # REPORT OPEN
            # ------------------------------------------------

            if (
                $path -eq
                "/report/open"
            ) {

                $jobId =
                    $request.QueryString[
                        "jobId"
                    ]

                $status =
                    Get-ReportStatus `
                        -JobId $jobId

                if (
                    $status.ready
                ) {

                    try {

                        Start-Process `
                            -FilePath `
                                $status.path

                        Send-JsonResponse `
                            $context `
                            @{
                                success =
                                    $true

                                path =
                                    $status.path
                            }

                    }
                    catch {

                        Send-JsonResponse `
                            $context `
                            @{
                                success =
                                    $false

                                message =
                                    $_.Exception.Message
                            }
                    }

                }
                else {

                    Send-JsonResponse `
                        $context `
                        @{
                            success =
                                $false

                            ready =
                                $false

                            message =
                                "Report is not ready."
                        }
                }

                continue
            }


            # ------------------------------------------------
            # AGENT STOP
            # ------------------------------------------------
            #
            # V5.3.1 FIX:
            #
            # Do NOT launch another PowerShell process
            # to kill this Agent PID.
            #
            # Instead:
            #
            #   1. Send response to browser
            #   2. Stop HttpListener
            #   3. GetContext() exits
            #   4. Request loop exits
            #   5. finally block closes listener
            #   6. PowerShell process exits normally
            #
            # ------------------------------------------------

            if (
                $path -eq
                "/agent/stop" -and
                $method -eq
                "POST"
            ) {

                Write-AgentInfo `
                    "STOP AGENT requested. Stopping listener. PID=$PID"

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $true

                        message =
                            "Agent stopping."
                    }

                try {

                    $listener.Stop()

                }
                catch {

                    Write-AgentError `
                        $_.Exception.Message
                }

                continue
            }


            # ------------------------------------------------
            # 404
            # ------------------------------------------------

            Send-JsonResponse `
                $context `
                @{
                    success =
                        $false

                    message =
                        "Endpoint not found."

                    path =
                        $path
                } `
                404

        }
        catch {

            Write-AgentError `
                $_.Exception.Message

            try {

                Send-JsonResponse `
                    $context `
                    @{
                        success =
                            $false

                        message =
                            "Internal Agent error."
                    } `
                    500

            }
            catch {
            }
        }

    }

}
finally {

    try {

        if (
            $listener.IsListening
        ) {

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

    Write-AgentInfo `
        "Agent stopped."

}