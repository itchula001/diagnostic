# ==========================================
# Windows Diagnostic Local Agent V1.5.3
# ==========================================

$port = 8765
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()

Write-Host "" -ForegroundColor Cyan
Write-Host "✅ Local Diagnostic Agent V1.5.3 Started!" -ForegroundColor Green
Write-Host "Listening on http://127.0.0.1:$port" -ForegroundColor Yellow
Write-Host "" -ForegroundColor Cyan

# สร้างโฟลเดอร์สำหรับเก็บ History ใน LocalAppData
$AgentDir = Join-Path $env:LOCALAPPDATA "IT_Diagnostic_Agent"
if (-not (Test-Path $AgentDir)) {
    New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null
}
$historyFilePath = Join-Path $AgentDir "history.json"

[array]$global:HistoryLog = @()
if (Test-Path $historyFilePath) {
    try {
        $rawJson = Get-Content $historyFilePath -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($rawJson)) {
            $parsed = $rawJson | ConvertFrom-Json
            if ($null -ne $parsed) { $global:HistoryLog = @($parsed) }
        }
    } catch {
        $global:HistoryLog = @()
    }
}

function Save-HistoryToFile {
    try {
        $global:HistoryLog | ConvertTo-Json -Depth 3 | Set-Content $historyFilePath -Encoding UTF8
    } catch {}
}

# รายชื่อ Process ระบบที่ป้องกันไม่ให้เผลอกด Kill
$ProtectedList = @("System", "Idle", "Memory Compression", "explorer", "svchost", "csrss", "smss", "wininit", "services", "lsass", "winlogon", "dwm", "sihost", "taskhostw")

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        # CORS ให้รับคำสั่งจาก Cloud Website ได้
        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")

        if ($request.HttpMethod -eq "OPTIONS") {
            $response.StatusCode = 200
            $response.Close()
            continue
        }

        $localPath = $request.Url.LocalPath
        $responseData = ""

        switch ($localPath) {
            "/metrics" {
                $cpu = Get-WmiObject Win32_Processor | Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average
                $os = Get-CimInstance Win32_OperatingSystem
                $ram = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100)
                $ramFreeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
                $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
                $diskUsage = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100)
                $diskFreeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
                if ($null -eq $cpu) { $cpu = 0 }
                
                $responseData = @{ cpu = $cpu; ram = $ram; disk = $diskUsage; ramFreeGB = $ramFreeGB; diskFreeGB = $diskFreeGB } | ConvertTo-Json -Depth 3
            }
            "/processes" {
                $topCpu = Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object {
                    @{ Id = $_.Id; Name = $_.Name; CPU_Time = if ($_.CPU) { [math]::Round($_.CPU, 1) } else { 0 }; RAM_MB = [math]::Round($_.WorkingSet / 1MB, 1); IsSystem = ($ProtectedList -contains $_.Name) }
                }
                $topRam = Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 5 | ForEach-Object {
                    @{ Id = $_.Id; Name = $_.Name; CPU_Time = if ($_.CPU) { [math]::Round($_.CPU, 1) } else { 0 }; RAM_MB = [math]::Round($_.WorkingSet / 1MB, 1); IsSystem = ($ProtectedList -contains $_.Name) }
                }
                $responseData = @{ cpu = @($topCpu); ram = @($topRam) } | ConvertTo-Json -Depth 3
            }
            "/diagnose" {
                $problems = @()

                # 1. Disk Space Check
                $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
                $diskFreeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
                $diskPercent = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100)
                if ($diskPercent -gt 85) {
                    $problems += @{
                        id = "DISK_C_FULL"; title = "Disk (C:) Low Space ($diskPercent%)"; severity = "critical"
                        description = "Drive C has only $diskFreeGB GB free space left."
                        evidence = @("Usage at $diskPercent%", "Free space: $diskFreeGB GB")
                        possibleCauses = @("Temporary files accumulated", "Large logs directory")
                        recommendedFix = "Clean-Temp"
                    }
                }

                # 2. Print Spooler Check
                $spooler = Get-Service -Name "Spooler" -ErrorAction SilentlyContinue
                if ($spooler -and $spooler.Status -ne "Running") {
                    $problems += @{
                        id = "SPOOLER_STOP"; title = "Print Spooler Service Stopped"; severity = "warning"
                        description = "Printer service is not running."
                        evidence = @("Spooler Status: $($spooler.Status)")
                        possibleCauses = @("Service crashed or manually disabled")
                        recommendedFix = "restart-spooler"
                    }
                }

                # 3. Windows Update Service Check
                $wuauserv = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
                if ($wuauserv -and $wuauserv.Status -ne "Running" -and $wuauserv.StartType -eq "Automatic") {
                    $problems += @{
                        id = "WUAUSERV_STOPPED"; title = "Windows Update Service Stopped"; severity = "warning"
                        description = "Windows Update service is not running despite Automatic startup."
                        evidence = @("Status: $($wuauserv.Status)", "StartType: Automatic")
                        possibleCauses = @("Service crashed or blocked by background process")
                        recommendedFix = "restart-service-wuauserv"
                    }
                }

                # 4. Network & Connectivity Check
                $activeAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Virtual|Loopback" }
                $gateway = (Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true -and $_.DefaultIPGateway } | Select-Object -ExpandProperty DefaultIPGateway | Select-Object -First 1)

                if (-not $activeAdapters -or -not $gateway) {
                    $problems += @{
                        id = "NETWORK_DISCONNECTED"; title = "Network / Wi-Fi Disconnected"; severity = "critical"
                        description = "No active network adapter or IP gateway found."
                        evidence = @("Adapter Status: Disconnected", "Gateway: None")
                        possibleCauses = @("Wi-Fi turned off", "Ethernet cable unplugged")
                        recommendedFix = "renew-ip"
                    }
                } else {
                    $ping = New-Object System.Net.NetworkInformation.Ping
                    $gwPingOk = $false
                    try { if (($ping.Send($gateway, 800)).Status -eq "Success") { $gwPingOk = $true } } catch {}

                    if (-not $gwPingOk) {
                        $problems += @{
                            id = "GATEWAY_UNREACHABLE"; title = "Gateway Unreachable ($gateway)"; severity = "critical"
                            description = "Cannot reach local router or network gateway."
                            evidence = @("Gateway IP: $gateway", "Ping: FAILED")
                            possibleCauses = @("Local router down", "IP address conflict")
                            recommendedFix = "renew-ip"
                        }
                    } else {
                        $dnsOk = $false
                        try { if ([System.Net.Dns]::GetHostAddresses("www.google.com")) { $dnsOk = $true } } catch {}

                        if (-not $dnsOk) {
                            $problems += @{
                                id = "DNS_FAILURE"; title = "DNS Resolution Failed"; severity = "warning"
                                description = "Internet IP is reachable, but domain names cannot be resolved."
                                evidence = @("Domain Google: FAILED")
                                possibleCauses = @("Corrupted DNS cache", "DNS server unreachable")
                                recommendedFix = "flush-dns"
                            }
                        }
                    }
                }

                # 5. Security & Firewall Check
                try {
                    $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
                    if ($defender) {
                        if (-not $defender.RealTimeProtectionEnabled) {
                            $problems += @{
                                id = "SECURITY_DEFENDER_DISABLED"; title = "Antivirus Protection Off"; severity = "critical"
                                description = "Windows Defender Real-Time Protection is disabled."
                                evidence = @("RealTimeProtectionEnabled: False")
                                possibleCauses = @("Turned off by user", "Malware interference")
                                recommendedFix = "enable-defender"
                            }
                        }
                    }
                } catch {}

                # 6. High RAM Usage Check
                $os = Get-CimInstance Win32_OperatingSystem
                $ramPercent = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100)
                if ($ramPercent -gt 85) {
                    $problems += @{
                        id = "RAM_HIGH"; title = "High Memory (RAM) Usage ($ramPercent%)"; severity = "warning"
                        description = "System memory is running critically low."
                        evidence = @("Usage at $ramPercent%")
                        possibleCauses = @("Too many heavy applications running", "Memory leak")
                        recommendedFix = "Clear-Memory"
                    }
                }

                # 7. High CPU Usage Check
                $cpu = Get-WmiObject Win32_Processor | Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average
                if ($cpu -gt 90) {
                    $problems += @{
                        id = "CPU_HIGH"; title = "High CPU Usage ($cpu%)"; severity = "critical"
                        description = "Processor is under heavy load."
                        evidence = @("Usage at $cpu%")
                        possibleCauses = @("Background processing", "Runaway process")
                        recommendedFix = ""
                    }
                }

                $responseData = @{ problems = $problems } | ConvertTo-Json -Depth 3
            }
            "/fix" {
                $reader = New-Object System.IO.StreamReader($request.InputStream)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $action = $body.action
                $verificationStatus = $body.verificationStatus
                $success = $true
                $msg = "Action executed."

                try {
                    switch ($action) {
                        "Clean-Temp" { Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue; $msg = "Temp files cleaned." }
                        "restart-spooler" { Restart-Service -Name "Spooler" -Force -ErrorAction Stop; $msg = "Print Spooler restarted." }
                        "restart-service-wuauserv" { Restart-Service -Name "wuauserv" -Force -ErrorAction Stop; $msg = "Windows Update Service restarted." }
                        "Clear-Memory" { [System.GC]::Collect(); $msg = "RAM Memory cleared." }
                        "flush-dns" { Clear-DnsClientCache -ErrorAction SilentlyContinue; $msg = "DNS cache flushed." }
                        "renew-ip" { Start-Process "ipconfig" -ArgumentList "/renew" -NoNewWindow -Wait; $msg = "IP renewed successfully." }
                        "gpupdate" { Start-Process "gpupdate" -ArgumentList "/force" -NoNewWindow -Wait; $msg = "Group Policy updated." }
                        "enable-defender" { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop; $msg = "Windows Defender enabled." }
                        default { $success = $false; $msg = "Action not in Whitelist." }
                    }
                } catch { 
                    $success = $false
                    $msg = $_.Exception.Message 
                }

                $resultLabel = if ($success) { if ($verificationStatus) { $verificationStatus } else { "EXECUTED" } } else { "FAILED" }

                $responseData = @{ success = $success; message = $msg } | ConvertTo-Json
                $global:HistoryLog = @($global:HistoryLog) + @{ 
                    timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    computer = $env:COMPUTERNAME
                    problem = $body.title
                    action = $action
                    result = $resultLabel 
                }
                Save-HistoryToFile
            }
            "/history" {
                $responseData = $global:HistoryLog | ConvertTo-Json -Depth 3
                if ($null -eq $responseData -or $responseData -eq "null") { $responseData = "[]" }
            }
            "/kill" {
                $reader = New-Object System.IO.StreamReader($request.InputStream)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                try {
                    Stop-Process -Id $body.id -Force -ErrorAction Stop
                    $responseData = @{ success = $true; message = "Terminated $($body.name)" } | ConvertTo-Json
                    $global:HistoryLog = @($global:HistoryLog) + @{ timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); computer = $env:COMPUTERNAME; problem = "Kill Process $($body.name)"; action = "Kill PID $($body.id)"; result = "SUCCESS" }
                } catch {
                    $responseData = @{ success = $false; message = $_.Exception.Message } | ConvertTo-Json
                    $global:HistoryLog = @($global:HistoryLog) + @{ timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); computer = $env:COMPUTERNAME; problem = "Kill Process $($body.name)"; action = "Kill PID $($body.id)"; result = "FAILED" }
                }
                Save-HistoryToFile
            }
            "/stop" {
                $responseData = '{"success":true, "message":"Agent stopped"}'
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseData)
                $response.ContentType = "application/json"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
                $response.Close()
                
                Write-Host "🛑 Agent stopped." -ForegroundColor Red
                $listener.Stop()
                Exit
            }
            default {
                $response.StatusCode = 404
                $responseData = '{"error": "Not Found"}'
            }
        }

        if ($localPath -ne "/stop") {
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseData)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.Close()
        }
    }
} catch {
    Write-Host "Error: $_" -ForegroundColor Red
} finally {
    if ($listener.IsListening) { $listener.Stop() }
}