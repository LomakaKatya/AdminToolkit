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
        $Value = 'не определено'
        $Color = [ConsoleColor]::DarkGray
    }

    Write-Host ('{0,-26}: ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Add-Issue {
    param(
        [Parameter(Mandatory)][System.Collections.ArrayList]$List,
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

    Write-Value -Label 'Узел' -Value $HostName -Color Cyan
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
        Write-Value -Label 'DNS' -Value "ошибка: $dnsError" -Color Red
        Add-Issue -List $issues -Text 'Не удалось разрешить имя удалённого компьютера.'
    }

    Write-Section -Title 'СЕТЕВАЯ ДОСТУПНОСТЬ'

    $pingResult = Test-PingHost -HostName $HostName

    if ($pingResult.Success) {
        Write-Value `
            -Label 'Ping' `
            -Value "ответ $($pingResult.TimeMs) мс" `
            -Color Green
    }
    else {
        Write-Value `
            -Label 'Ping' `
            -Value "нет ответа ($($pingResult.Status))" `
            -Color Yellow

        [void]$warnings.Add('Удалённый узел не отвечает на ping. ICMP может быть запрещён.')
    }

    $tcpResult = Test-TcpPort -HostName $HostName -Port $Port

    if ($tcpResult.Success) {
        Write-Value `
            -Label "TCP $Port" `
            -Value "порт открыт, $($tcpResult.TimeMs) мс" `
            -Color Green
    }
    else {
        Write-Value `
            -Label "TCP $Port" `
            -Value "порт недоступен: $($tcpResult.Error)" `
            -Color Red

        Add-Issue `
            -List $issues `
            -Text "TCP-порт $Port на удалённом компьютере недоступен."
    }

    Write-Section -Title 'ИТОГ'

    if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
        Write-Host '[OK] Удалённый узел и выбранный порт доступны.' `
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
            Write-Host '[OK] Несмотря на отсутствие ping, нужный сервис доступен по TCP.' `
                -ForegroundColor Green
        }
    }
}

function Show-LocalRemoteAccessCheck {
    $issues = New-Object -TypeName System.Collections.ArrayList
    $warnings = New-Object -TypeName System.Collections.ArrayList

    Write-Section -Title 'АДРЕСА ЭТОГО КОМПЬЮТЕРА'

    $configs = @(
        Get-WmiObject `
            -Class Win32_NetworkAdapterConfiguration `
            -Filter 'IPEnabled=True' `
            -ErrorAction SilentlyContinue
    )

    $ipv4 = @(
        $configs |
        ForEach-Object { @($_.IPAddress) } |
        Where-Object { $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$' } |
        Sort-Object -Unique
    )

    Write-Value -Label 'Имя компьютера' -Value $env:COMPUTERNAME -Color Cyan
    Write-Value -Label 'IPv4' -Value ($ipv4 -join ', ')

    Write-Section -Title 'RDP НА ЭТОМ КОМПЬЮТЕРЕ'

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
        Write-Value -Label 'RDP разрешён' -Value 'не удалось определить' -Color Yellow
        [void]$warnings.Add('Не удалось прочитать настройку fDenyTSConnections.')
    }
    elseif ($denyConnections -eq 0) {
        Write-Value -Label 'RDP разрешён' -Value 'да' -Color Green
    }
    else {
        Write-Value -Label 'RDP разрешён' -Value 'нет' -Color Red
        Add-Issue -List $issues -Text 'Подключения RDP запрещены в настройках Windows.'
    }

    $termService = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue

    if ($null -eq $termService) {
        Write-Value -Label 'TermService' -Value 'служба не найдена' -Color Red
        Add-Issue -List $issues -Text 'Служба удалённых рабочих столов не найдена.'
    }
    elseif ($termService.Status -eq 'Running') {
        Write-Value -Label 'TermService' -Value 'работает' -Color Green
    }
    else {
        Write-Value `
            -Label 'TermService' `
            -Value "не запущена ($($termService.Status))" `
            -Color Red

        Add-Issue -List $issues -Text 'Служба удалённых рабочих столов не запущена.'
    }

    Write-Value -Label 'Порт RDP' -Value ([string]$rdpPort)

    $listeningPorts = @(Get-ListeningPorts)

    if ($listeningPorts -contains $rdpPort) {
        Write-Value -Label 'Прослушивание порта' -Value "порт $rdpPort слушается" -Color Green
    }
    else {
        Write-Value -Label 'Прослушивание порта' -Value "порт $rdpPort не слушается" -Color Red
        Add-Issue -List $issues -Text "Локальный порт RDP $rdpPort не находится в состоянии LISTEN."
    }

    $firewallRules = @()

    if (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        try {
            $firewallRules = @(
                Get-NetFirewallRule -ErrorAction Stop |
                Where-Object {
                    $_.Enabled -eq 'True' -and
                    $_.Direction -eq 'Inbound' -and
                    $_.Action -eq 'Allow' -and
                    (
                        $_.Name -match '(?i)RemoteDesktop|RDP' -or
                        $_.DisplayName -match '(?i)Remote Desktop|RDP|Удаленн|Віддален'
                    )
                }
            )
        }
        catch {
        }
    }

    if ($firewallRules.Count -gt 0) {
        Write-Value `
            -Label 'Правила брандмауэра' `
            -Value "разрешающих правил найдено: $($firewallRules.Count)" `
            -Color Green
    }
    else {
        Write-Value `
            -Label 'Правила брандмауэра' `
            -Value 'разрешающие правила RDP не найдены или недоступны' `
            -Color Yellow

        [void]$warnings.Add('Не удалось подтвердить наличие разрешающего правила брандмауэра для RDP.')
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
            'служба не найдена'
        }

        $processText = if ($processes.Count -gt 0) {
            @(
                $processes |
                ForEach-Object { "$($_.ProcessName):$($_.Id)" }
            ) -join ', '
        }
        else {
            'процесс не запущен'
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
            [void]$warnings.Add("$($pattern.Name) установлен, но служба и процесс не запущены.")
        }
    }

    if ($foundTools -eq 0) {
        Write-Host '[INFO] Из распространённых средств удалённого доступа ничего не обнаружено.' `
            -ForegroundColor DarkGray
    }

    Write-Section -Title 'НЕДАВНИЕ СОБЫТИЯ RDP'

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
        Write-Host '[OK] За 24 часа явных ошибок RDP в операционных журналах не найдено.' `
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

        [void]$warnings.Add('В журналах RDP есть недавние предупреждения или ошибки.')
    }

    Write-Section -Title 'ИТОГ'

    if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
        Write-Host '[OK] Локальные компоненты удалённого доступа выглядят исправно.' `
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
Write-Host 'Диагностика удалённого доступа' -ForegroundColor Cyan
Write-Host ''
Write-Host '  1. Проверить подключение к другому компьютеру'
Write-Host '  2. Проверить удалённый доступ на этом компьютере'
Write-Host ''

$mode = Read-Host 'Выбери режим'

switch ($mode) {
    '1' {
        $hostName = (Read-Host 'Введите IP-адрес или имя компьютера').Trim()

        if ([string]::IsNullOrWhiteSpace($hostName)) {
            throw 'Адрес компьютера не может быть пустым.'
        }

        $port = 3389
        $portText = (Read-Host 'Введите TCP-порт [Enter = 3389]').Trim()

        if (-not [string]::IsNullOrWhiteSpace($portText)) {
            if (-not [int]::TryParse($portText, [ref]$port) -or
                $port -lt 1 -or
                $port -gt 65535) {
                throw 'Порт должен быть числом от 1 до 65535.'
            }
        }

        Show-OutboundCheck -HostName $hostName -Port $port
    }

    '2' {
        Show-LocalRemoteAccessCheck
    }

    default {
        throw 'Нужно выбрать 1 или 2.'
    }
}
