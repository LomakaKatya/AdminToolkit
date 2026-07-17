Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Value {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Value,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = 'не визначено'
        $Color = [ConsoleColor]::DarkGray
    }

    Write-Host ('{0,-26}: ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Add-Issue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$List,
        [Parameter(Mandatory)][string]$Text
    )

    [void]$List.Add($Text)
}

function Test-PingHost {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$TimeoutMilliseconds = 1500
    )

    $ping = New-Object -TypeName System.Net.NetworkInformation.Ping

    try {
        $reply = $ping.Send($HostName, $TimeoutMilliseconds)

        return [pscustomobject]@{
            Success = ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
            TimeMs  = if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                [int]$reply.RoundtripTime
            }
            else {
                $null
            }
            Status  = [string]$reply.Status
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            TimeMs  = $null
            Status  = $_.Exception.Message
        }
    }
    finally {
        $ping.Dispose()
    }
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 3500
    )

    $client = $null
    $async = $null
    $waitHandle = $null
    $watch = New-Object -TypeName System.Diagnostics.Stopwatch

    try {
        $client = New-Object -TypeName System.Net.Sockets.TcpClient
        $watch.Start()

        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        $waitHandle = $async.AsyncWaitHandle

        if (-not $waitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return [pscustomobject]@{
                Success = $false
                TimeMs  = [int]$watch.ElapsedMilliseconds
                Error   = 'тайм-аут'
            }
        }

        $client.EndConnect($async)

        return [pscustomobject]@{
            Success = $client.Connected
            TimeMs  = [int]$watch.ElapsedMilliseconds
            Error   = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            TimeMs  = [int]$watch.ElapsedMilliseconds
            Error   = $_.Exception.Message
        }
    }
    finally {
        $watch.Stop()

        if ($null -ne $waitHandle) {
            $waitHandle.Close()
        }

        if ($null -ne $client) {
            $client.Close()
        }
    }
}

function Get-ListeningPorts {
    try {
        $properties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()

        return @(
            $properties.GetActiveTcpListeners() |
            ForEach-Object { [int]$_.Port } |
            Sort-Object -Unique
        )
    }
    catch {
        return @()
    }
}

function Show-OutboundCheck {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port
    )

    $issues = New-Object -TypeName System.Collections.ArrayList
    $warnings = New-Object -TypeName System.Collections.ArrayList

    Write-Section -Title 'АДРЕС'

    Write-Value -Label 'Вузол' -Value $HostName -Color Cyan
    Write-Value -Label 'Порт' -Value ([string]$Port)

    $addresses = @()
    $dnsError = ''

    try {
        $addresses = @(
            [System.Net.Dns]::GetHostAddresses($HostName) |
            ForEach-Object { $_.IPAddressToString }
        )
    }
    catch {
        $dnsError = $_.Exception.Message
    }

    if ($addresses.Count -gt 0) {
        Write-Value -Label 'DNS-адреса' -Value ($addresses -join ', ') -Color Green
    }
    else {
        Write-Value -Label 'DNS' -Value "помилка: $dnsError" -Color Red
        Add-Issue -List $issues -Text 'Не вдалося розпізнати ім''я віддаленого комп''ютера.'
    }

    Write-Section -Title 'СЕТЕВАЯ ДОСТУПНОСТЬ'

    $pingResult = Test-PingHost -HostName $HostName

    if ($pingResult.Success) {
        Write-Value `
            -Label 'Ping' `
            -Value "відповідь $($pingResult.TimeMs) мс" `
            -Color Green
    }
    else {
        Write-Value `
            -Label 'Ping' `
            -Value "немає відповіді ($($pingResult.Status))" `
            -Color Yellow

        [void]$warnings.Add('Віддалений вузол не відповідає на ping. ICMP може бути заборонено.')
    }

    $tcpResult = Test-TcpPort -HostName $HostName -Port $Port

    if ($tcpResult.Success) {
        Write-Value `
            -Label "TCP $Port" `
            -Value "порт відкритий, $($tcpResult.TimeMs) мс" `
            -Color Green
    }
    else {
        Write-Value `
            -Label "TCP $Port" `
            -Value "порт недоступний: $($tcpResult.Error)" `
            -Color Red

        Add-Issue `
            -List $issues `
            -Text "TCP-порт $Port на віддаленому комп'ютері недоступний."
    }

    Write-Section -Title 'ПІДСУМОК'

    if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
        Write-Host '[OK] Віддалений вузол і вибраний порт доступні.' `
            -ForegroundColor Green
    }
    else {
        foreach ($issue in $issues) {
            Write-Host "[FAIL] $issue" -ForegroundColor Red
        }

        foreach ($warning in $warnings) {
            Write-Host "[WARN] $warning" -ForegroundColor Yellow
        }

        if ($tcpResult.Success -and -not $pingResult.Success) {
            Write-Host '[OK] Попри відсутність ping, потрібна служба доступна через TCP.' `
                -ForegroundColor Green
        }
    }
}

function Show-LocalRemoteAccessCheck {
    $issues = New-Object -TypeName System.Collections.ArrayList
    $warnings = New-Object -TypeName System.Collections.ArrayList

    Write-Section -Title 'АДРЕСИ ЦЬОГО КОМП''ЮТЕРА'

    $configs = @(
        Get-WmiObject `
            -Class Win32_NetworkAdapterConfiguration `
            -Filter 'IPEnabled=True' `
            -ErrorAction SilentlyContinue
    )

    $ipv4 = @(
        $configs |
        ForEach-Object { @($_.IPAddress) } |
        Where-Object {
            $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$' -and
            $_ -notmatch '^127\.' -and
            $_ -notmatch '^169\.254\.'
        } |
        Sort-Object -Unique
    )

    Write-Value -Label 'Ім''я комп''ютера' -Value $env:COMPUTERNAME -Color Cyan
    Write-Value -Label 'IPv4' -Value ($ipv4 -join ', ')

    Write-Section -Title 'RDP НА ЦЬОМУ КОМП''ЮТЕРІ'

    $terminalServerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $rdpTcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

    $denyConnections = $null
    $rdpPort = 3389

    try {
        $terminalServer = Get-ItemProperty `
            -LiteralPath $terminalServerPath `
            -ErrorAction Stop

        $denyConnections = [int]$terminalServer.fDenyTSConnections
    }
    catch {
    }

    try {
        $rdpTcp = Get-ItemProperty `
            -LiteralPath $rdpTcpPath `
            -ErrorAction Stop

        $rdpPort = [int]$rdpTcp.PortNumber
    }
    catch {
    }

    if ($null -eq $denyConnections) {
        Write-Value -Label 'RDP дозволений' -Value 'не вдалося визначити' -Color Yellow
        [void]$warnings.Add('Не вдалося прочитати параметр fDenyTSConnections.')
    }
    elseif ($denyConnections -eq 0) {
        Write-Value -Label 'RDP дозволений' -Value 'так' -Color Green
    }
    else {
        Write-Value -Label 'RDP дозволений' -Value 'ні' -Color Red
        Add-Issue -List $issues -Text 'RDP-підключення заборонені в налаштуваннях Windows.'
    }

    $rdpConfigured = ($denyConnections -eq 0)

    $nlaRequired = $null

    try {
        $nlaRequired = [int]$rdpTcp.UserAuthentication
    }
    catch {
    }

    if ($null -eq $nlaRequired) {
        Write-Value -Label 'Перевірка автентичності NLA' -Value 'не вдалося визначити' -Color DarkGray
    }
    elseif ($nlaRequired -eq 1) {
        Write-Value -Label 'Перевірка автентичності NLA' -Value 'потрібна' -Color Green
    }
    else {
        Write-Value -Label 'Перевірка автентичності NLA' -Value 'не потрібна' -Color Yellow

        if ($rdpConfigured) {
            [void]$warnings.Add(
                'Для дозволеного RDP не потрібна NLA. Це менш безпечна конфігурація.'
            )
        }
    }

    $termService = Get-Service `
        -Name 'TermService' `
        -ErrorAction SilentlyContinue

    $termServiceState = ''

    if ($null -ne $termService) {
        $termServiceState = [string]$termService.Status
    }
    else {
        $termServiceWmi = Get-WmiObject `
            -Class Win32_Service `
            -Filter "Name='TermService'" `
            -ErrorAction SilentlyContinue

        if ($null -ne $termServiceWmi) {
            $termServiceState = [string]$termServiceWmi.State
        }
    }

    if ([string]::IsNullOrWhiteSpace($termServiceState)) {
        Write-Value `
            -Label 'TermService' `
            -Value 'служба не знайдена' `
            -Color Red

        if ($rdpConfigured) {
            Add-Issue `
                -List $issues `
                -Text 'Служба відтаклених робочих столів не знайдена.'
        }
        else {
            [void]$warnings.Add(
                'TermService не знайдено, але вхідні RDP-підключення також заборонені.'
            )
        }
    }
    elseif ($termServiceState -ieq 'Running') {
        Write-Value `
            -Label 'TermService' `
            -Value 'працює' `
            -Color Green
    }
    else {
        Write-Value `
            -Label 'TermService' `
            -Value "не запущена ($termServiceState)" `
            -Color Red

        if ($rdpConfigured) {
            Add-Issue `
                -List $issues `
                -Text 'Служба відтаклених робочих столів не запущена.'
        }
        else {
            [void]$warnings.Add(
                'TermService не запущено. Якщо RDP заборонено, це може бути нормальним станом.'
            )
        }
    }

    Write-Value -Label 'Порт RDP' -Value ([string]$rdpPort)

    $listeningPorts = @(Get-ListeningPorts)

    if ($listeningPorts -contains $rdpPort) {
        Write-Value -Label 'Прослуховування порту' -Value "порт $rdpPort прослуховується" -Color Green
    }
    elseif ($rdpConfigured) {
        Write-Value -Label 'Прослуховування порту' -Value "порт $rdpPort не прослуховується" -Color Red
        Add-Issue -List $issues -Text "Локальний порт RDP $rdpPort не перебуває в стані LISTEN."
    }
    else {
        Write-Value `
            -Label 'Прослуховування порту' `
            -Value "порт $rdpPort не прослуховується, RDP заборонений" `
            -Color DarkGray
    }

    $firewallRules = @()

    if (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        try {
            $firewallRules = @(
                Get-NetFirewallRule -ErrorAction Stop |
                Where-Object {
                    [string]$_.Enabled -match '^(?i:true|1)$' -and
                    [string]$_.Direction -match '^(?i:inbound)$' -and
                    [string]$_.Action -match '^(?i:allow)$' -and
                    (
                        $_.Name -match '(?i)RemoteDesktop|RDP' -or
                        $_.DisplayName -match '(?i)Remote Desktop|RDP|Утакленн|Відтаклен'
                    )
                }
            )
        }
        catch {
        }
    }

    if ($firewallRules.Count -gt 0) {
        Write-Value `
            -Label 'Правила брандмауера' `
            -Value "дозвільних правил знайдено: $($firewallRules.Count)" `
            -Color Green
    }
    else {
        Write-Value `
            -Label 'Правила брандмауера' `
            -Value 'дозвільні правила RDP не знайдено або вони недоступні' `
            -Color Yellow

        if ($rdpConfigured) {
            [void]$warnings.Add(
                'Не вдалося підтвердити наявність дозвільного правила брандмауера для RDP.'
            )
        }
    }

    Write-Section -Title 'ПРОГРАММЫ УДАЛЁННОГО ДОСТУПА'

    $patterns = @(
        [pscustomobject]@{
            Name    = 'TeamViewer'
            Service = '(?i)^TeamViewer'
            Process = '(?i)^TeamViewer'
        },
        [pscustomobject]@{
            Name    = 'AnyDesk'
            Service = '(?i)AnyDesk'
            Process = '(?i)AnyDesk'
        },
        [pscustomobject]@{
            Name    = 'RustDesk'
            Service = '(?i)RustDesk'
            Process = '(?i)RustDesk'
        },
        [pscustomobject]@{
            Name    = 'Radmin'
            Service = '(?i)RManService|Radmin'
            Process = '(?i)RServer|Radmin'
        },
        [pscustomobject]@{
            Name    = 'VNC'
            Service = '(?i)VNC|uvnc|tvnserver'
            Process = '(?i)VNC|uvnc|tvnserver'
        },
        [pscustomobject]@{
            Name    = 'ScreenConnect'
            Service = '(?i)ScreenConnect'
            Process = '(?i)ScreenConnect'
        }
    )

    $allServices = @(Get-Service -ErrorAction SilentlyContinue)
    $allProcesses = @(Get-Process -ErrorAction SilentlyContinue)
    $foundTools = 0

    foreach ($pattern in $patterns) {
        $services = @(
            $allServices |
            Where-Object {
                $_.Name -match $pattern.Service -or
                $_.DisplayName -match $pattern.Service
            }
        )

        $processes = @(
            $allProcesses |
            Where-Object {
                $_.ProcessName -match $pattern.Process
            }
        )

        if ($services.Count -eq 0 -and $processes.Count -eq 0) {
            continue
        }

        $foundTools++

        $serviceText = if ($services.Count -gt 0) {
            @(
                $services |
                ForEach-Object { "$($_.Name):$($_.Status)" }
            ) -join ', '
        }
        else {
            'служба не знайдена'
        }

        $processText = if ($processes.Count -gt 0) {
            @(
                $processes |
                ForEach-Object { "$($_.ProcessName):$($_.Id)" }
            ) -join ', '
        }
        else {
            'процес не запущено'
        }

        $runningService = @(
            $services |
            Where-Object { $_.Status -eq 'Running' }
        ).Count -gt 0

        $color = if ($runningService -or $processes.Count -gt 0) {
            [ConsoleColor]::Green
        }
        else {
            [ConsoleColor]::Yellow
        }

        Write-Value `
            -Label $pattern.Name `
            -Value "$serviceText; $processText" `
            -Color $color

        if (-not $runningService -and $processes.Count -eq 0) {
            [void]$warnings.Add("$($pattern.Name) встановлено, але службу та процес не запущено.")
        }
    }

    if ($foundTools -eq 0) {
        Write-Host '[INFO] Серед поширених засобів віддаленого доступу нічого не виявлено.' `
            -ForegroundColor DarkGray
    }

    Write-Section -Title 'НЕДАВНІ ПОДІЇ RDP'

    $rdpEvents = @()

    if (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue) {
        $since = (Get-Date).AddHours(-24)

        foreach ($logName in @(
            'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational',
            'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational'
        )) {
            try {
                $rdpEvents += @(
                    Get-WinEvent `
                        -FilterHashtable @{
                            LogName   = $logName
                            StartTime = $since
                            Level     = @(2, 3)
                        } `
                        -MaxEvents 8 `
                        -ErrorAction Stop
                )
            }
            catch {
            }
        }
    }

    $rdpEvents = @(
        $rdpEvents |
        Sort-Object -Property TimeCreated -Descending |
        Select-Object -First 6
    )

    if ($rdpEvents.Count -eq 0) {
        Write-Host '[OK] За 24 години явних помилок RDP в операційних журналах не знайдено.' `
            -ForegroundColor Green
    }
    else {
        foreach ($event in $rdpEvents) {
            $message = ([string]$event.Message -replace '\s+', ' ').Trim()

            if ($message.Length -gt 105) {
                $message = $message.Substring(0, 102) + '...'
            }

            Write-Host ("[{0}] ID {1}: {2}" -f `
                $event.TimeCreated.ToString('dd.MM HH:mm'),
                $event.Id,
                $message) `
                -ForegroundColor Yellow
        }

        [void]$warnings.Add('У журналах RDP є нещодавні попередження або помилки.')
    }

    Write-Section -Title 'ПІДСУМОК'

    if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
        Write-Host '[OK] Локальні компоненти віддаленого доступу виглядають справними.' `
            -ForegroundColor Green
    }
    else {
        foreach ($issue in $issues) {
            Write-Host "[FAIL] $issue" -ForegroundColor Red
        }

        foreach ($warning in $warnings) {
            Write-Host "[WARN] $warning" -ForegroundColor Yellow
        }
    }
}

Write-Host ''
Write-Host 'Діагностика віддаленого доступу' -ForegroundColor Cyan
Write-Host ''
Write-Host '  1. Перевірити підключення до іншого комп''ютера'
Write-Host '  2. Перевірити віддалений доступ на цьому комп''ютері'
Write-Host ''

$mode = Read-Host 'Оберіть режим'

switch ($mode) {
    '1' {
        $hostName = (Read-Host 'Введіть IP-адресу або ім''я комп''ютера').Trim()

        if ([string]::IsNullOrWhiteSpace($hostName)) {
            throw 'Адреса комп''ютера не може бути порожньою.'
        }

        $port = 3389
        $portText = (Read-Host 'Введіть TCP-порт [Enter = 3389]').Trim()

        if (-not [string]::IsNullOrWhiteSpace($portText)) {
            if (-not [int]::TryParse($portText, [ref]$port) -or
                $port -lt 1 -or
                $port -gt 65535) {
                throw 'Порт має бути числом від 1 до 65535.'
            }
        }

        Show-OutboundCheck -HostName $hostName -Port $port
    }

    '2' {
        Show-LocalRemoteAccessCheck
    }

    default {
        throw 'Потрібно вибрати 1 або 2.'
    }
}
