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

    Write-Host ('{0,-25}: ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Add-Issue {
    param(
        [Parameter(Mandatory)][System.Collections.ArrayList]$List,
        [Parameter(Mandatory)][string]$Text
    )

    [void]$List.Add($Text)
}

function Invoke-PingSummary {
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Count = 4,
        [int]$TimeoutMilliseconds = 1500
    )

    $times = @()
    $statuses = @()
    $ping = New-Object -TypeName System.Net.NetworkInformation.Ping

    try {
        for ($i = 0; $i -lt $Count; $i++) {
            try {
                $reply = $ping.Send($Target, $TimeoutMilliseconds)
                $statuses += [string]$reply.Status

                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $times += [int]$reply.RoundtripTime
                }
            }
            catch {
                $statuses += $_.Exception.Message
            }

            if ($i -lt ($Count - 1)) {
                Start-Sleep -Milliseconds 200
            }
        }
    }
    finally {
        $ping.Dispose()
    }

    $received = $times.Count
    $lossPercent = [Math]::Round(
        (($Count - $received) / [double][Math]::Max($Count, 1)) * 100,
        0
    )

    $average = $null
    $minimum = $null
    $maximum = $null

    if ($received -gt 0) {
        $average = [Math]::Round(
            ($times | Measure-Object -Average).Average,
            1
        )
        $minimum = ($times | Measure-Object -Minimum).Minimum
        $maximum = ($times | Measure-Object -Maximum).Maximum
    }

    return [pscustomobject]@{
        Target      = $Target
        Sent        = $Count
        Received    = $received
        LossPercent = $lossPercent
        AverageMs   = $average
        MinimumMs   = $minimum
        MaximumMs   = $maximum
        Statuses    = ($statuses -join ', ')
    }
}

function Show-PingResult {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)]$Result,
        [int]$WarningLatency = 100,
        [int]$CriticalLatency = 200
    )

    $color = [ConsoleColor]::Green
    $text = ''

    if ($Result.Received -eq 0) {
        $color = [ConsoleColor]::Red
        $text = "нет ответа, потери 100%"
    }
    else {
        $text = "среднее $($Result.AverageMs) мс, min $($Result.MinimumMs), max $($Result.MaximumMs), потери $($Result.LossPercent)%"

        if ($Result.LossPercent -ge 25 -or
            [double]$Result.AverageMs -ge $CriticalLatency) {
            $color = [ConsoleColor]::Red
        }
        elseif ($Result.LossPercent -gt 0 -or
            [double]$Result.AverageMs -ge $WarningLatency) {
            $color = [ConsoleColor]::Yellow
        }
    }

    Write-Value -Label $Label -Value $text -Color $color
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 3000
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

function Test-HttpsRequest {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutMilliseconds = 10000
    )

    $request = $null
    $response = $null
    $watch = New-Object -TypeName System.Diagnostics.Stopwatch

    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.AllowAutoRedirect = $true
        $request.MaximumAutomaticRedirections = 8
        $request.Timeout = $TimeoutMilliseconds
        $request.ReadWriteTimeout = $TimeoutMilliseconds
        $request.UserAgent = 'Raccoon-Admin-Toolkit/1.0'
        $request.Proxy = [System.Net.WebRequest]::DefaultWebProxy

        $watch.Start()

        try {
            $response = $request.GetResponse()
        }
        catch [System.Net.WebException] {
            if ($null -ne $_.Exception.Response -and
                [int]$_.Exception.Response.StatusCode -eq 405) {
                $request = [System.Net.HttpWebRequest]::Create($Url)
                $request.Method = 'GET'
                $request.AllowAutoRedirect = $true
                $request.MaximumAutomaticRedirections = 8
                $request.Timeout = $TimeoutMilliseconds
                $request.ReadWriteTimeout = $TimeoutMilliseconds
                $request.UserAgent = 'Raccoon-Admin-Toolkit/1.0'
                $request.Proxy = [System.Net.WebRequest]::DefaultWebProxy
                $response = $request.GetResponse()
            }
            else {
                throw
            }
        }

        $watch.Stop()

        return [pscustomobject]@{
            Success   = $true
            Status    = "{0} {1}" -f `
                [int]$response.StatusCode,
                [string]$response.StatusDescription
            TimeMs    = [int]$watch.ElapsedMilliseconds
            FinalUrl  = [string]$response.ResponseUri.AbsoluteUri
            Error     = ''
        }
    }
    catch {
        $watch.Stop()

        $status = ''

        if ($_.Exception -is [System.Net.WebException] -and
            $null -ne $_.Exception.Response) {
            try {
                $status = "{0} {1}" -f `
                    [int]$_.Exception.Response.StatusCode,
                    [string]$_.Exception.Response.StatusDescription
            }
            catch {
            }
        }

        return [pscustomobject]@{
            Success   = $false
            Status    = $status
            TimeMs    = [int]$watch.ElapsedMilliseconds
            FinalUrl  = ''
            Error     = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $response) {
            $response.Close()
        }
    }
}

Write-Host ''
Write-Host 'Комплексная диагностика интернет-соединения' `
    -ForegroundColor Cyan
Write-Host 'Проверяю локальный адаптер, шлюз, внешний IP, DNS и HTTPS...' `
    -ForegroundColor DarkGray

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor
    [Net.SecurityProtocolType]::Tls12

$issues = New-Object -TypeName System.Collections.ArrayList
$warnings = New-Object -TypeName System.Collections.ArrayList

$configurations = @(
    Get-WmiObject `
        -Class Win32_NetworkAdapterConfiguration `
        -Filter 'IPEnabled=True' `
        -ErrorAction Stop |
    Where-Object {
        $null -ne $_.DefaultIPGateway -and
        @($_.DefaultIPGateway).Count -gt 0
    }
)

Write-Section -Title 'АКТИВНОЕ ПОДКЛЮЧЕНИЕ'

if ($configurations.Count -eq 0) {
    Write-Host '[FAIL] Не найден активный сетевой интерфейс со шлюзом по умолчанию.' `
        -ForegroundColor Red
    Add-Issue -List $issues -Text 'Нет активного подключения со шлюзом по умолчанию.'

    Write-Section -Title 'ИТОГ'

    foreach ($issue in $issues) {
        Write-Host "[FAIL] $issue" -ForegroundColor Red
    }

    return
}

foreach ($configuration in $configurations) {
    $adapter = Get-WmiObject `
        -Class Win32_NetworkAdapter `
        -Filter ("Index={0}" -f [int]$configuration.Index) `
        -ErrorAction SilentlyContinue |
    Select-Object -First 1

    $ipv4 = @(
        @($configuration.IPAddress) |
        Where-Object { $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$' }
    )

    $gateways = @($configuration.DefaultIPGateway)
    $dnsServers = @($configuration.DNSServerSearchOrder)

    Write-Value `
        -Label 'Адаптер' `
        -Value $(if ($null -ne $adapter) {
            [string]$adapter.Name
        }
        else {
            [string]$configuration.Description
        }) `
        -Color Cyan

    Write-Value -Label 'IPv4' -Value ($ipv4 -join ', ')
    Write-Value -Label 'Шлюз' -Value ($gateways -join ', ')
    Write-Value -Label 'DNS' -Value ($dnsServers -join ', ')

    if ($null -ne $adapter -and [double]$adapter.Speed -gt 0) {
        $speedMbps = [Math]::Round(([double]$adapter.Speed / 1MB), 0)
        Write-Value -Label 'Скорость линка' -Value "$speedMbps Мбит/с"
    }

    Write-Host ''
}

$primaryConfiguration = $configurations[0]
$gateway = [string]@($primaryConfiguration.DefaultIPGateway)[0]

Write-Section -Title 'ЗАДЕРЖКА И ПОТЕРИ'

$gatewayResult = Invoke-PingSummary -Target $gateway -Count 4
$cloudflareResult = Invoke-PingSummary -Target '1.1.1.1' -Count 4
$googleResult = Invoke-PingSummary -Target '8.8.8.8' -Count 4

Show-PingResult `
    -Label 'Шлюз' `
    -Result $gatewayResult `
    -WarningLatency 10 `
    -CriticalLatency 50

Show-PingResult `
    -Label 'Интернет 1.1.1.1' `
    -Result $cloudflareResult `
    -WarningLatency 100 `
    -CriticalLatency 200

Show-PingResult `
    -Label 'Интернет 8.8.8.8' `
    -Result $googleResult `
    -WarningLatency 100 `
    -CriticalLatency 200

if ($gatewayResult.Received -eq 0) {
    Add-Issue -List $issues -Text 'Нет связи со шлюзом. Проблема находится в локальной сети, Wi-Fi, кабеле или роутере.'
}
elseif ($gatewayResult.LossPercent -gt 0 -or
    [double]$gatewayResult.AverageMs -ge 20) {
    [void]$warnings.Add('До локального шлюза есть потери или высокая задержка.')
}

if ($cloudflareResult.Received -eq 0 -and $googleResult.Received -eq 0) {
    Add-Issue -List $issues -Text 'Шлюз доступен, но внешние IP-адреса не отвечают. Возможна проблема провайдера, маршрута или фильтрации.'
}
else {
    $externalLoss = [Math]::Max(
        [double]$cloudflareResult.LossPercent,
        [double]$googleResult.LossPercent
    )

    $externalLatency = 0

    if ($null -ne $cloudflareResult.AverageMs) {
        $externalLatency = [Math]::Max(
            $externalLatency,
            [double]$cloudflareResult.AverageMs
        )
    }

    if ($null -ne $googleResult.AverageMs) {
        $externalLatency = [Math]::Max(
            $externalLatency,
            [double]$googleResult.AverageMs
        )
    }

    if ($externalLoss -ge 25) {
        Add-Issue -List $issues -Text 'На внешнем соединении высокая потеря пакетов.'
    }
    elseif ($externalLoss -gt 0) {
        [void]$warnings.Add('На внешнем соединении обнаружены потери пакетов.')
    }

    if ($externalLatency -ge 200) {
        Add-Issue -List $issues -Text 'Задержка до внешних узлов очень высокая.'
    }
    elseif ($externalLatency -ge 100) {
        [void]$warnings.Add('Задержка до внешних узлов повышена.')
    }
}

Write-Section -Title 'DNS'

$dnsHost = 'www.microsoft.com'
$dnsWatch = New-Object -TypeName System.Diagnostics.Stopwatch
$dnsAddresses = @()
$dnsError = ''

try {
    $dnsWatch.Start()
    $dnsAddresses = @(
        [System.Net.Dns]::GetHostAddresses($dnsHost) |
        ForEach-Object { $_.IPAddressToString }
    )
    $dnsWatch.Stop()
}
catch {
    $dnsWatch.Stop()
    $dnsError = $_.Exception.Message
}

if ($dnsAddresses.Count -gt 0) {
    $dnsColor = if ($dnsWatch.ElapsedMilliseconds -ge 2000) {
        [ConsoleColor]::Red
    }
    elseif ($dnsWatch.ElapsedMilliseconds -ge 700) {
        [ConsoleColor]::Yellow
    }
    else {
        [ConsoleColor]::Green
    }

    Write-Value `
        -Label 'Разрешение имени' `
        -Value "$dnsHost -> $($dnsAddresses -join ', ') за $($dnsWatch.ElapsedMilliseconds) мс" `
        -Color $dnsColor

    if ($dnsWatch.ElapsedMilliseconds -ge 2000) {
        Add-Issue -List $issues -Text 'DNS отвечает очень медленно.'
    }
    elseif ($dnsWatch.ElapsedMilliseconds -ge 700) {
        [void]$warnings.Add('DNS отвечает медленнее обычного.')
    }
}
else {
    Write-Value `
        -Label 'Разрешение имени' `
        -Value "ошибка: $dnsError" `
        -Color Red

    if ($cloudflareResult.Received -gt 0 -or $googleResult.Received -gt 0) {
        Add-Issue -List $issues -Text 'Внешние IP доступны, но DNS не разрешает имена.'
    }
    else {
        Add-Issue -List $issues -Text 'Не работает разрешение DNS-имён.'
    }
}

Write-Section -Title 'HTTPS'

$tcpResult = Test-TcpPort `
    -HostName 'www.microsoft.com' `
    -Port 443

if ($tcpResult.Success) {
    Write-Value `
        -Label 'TCP 443' `
        -Value "доступен, $($tcpResult.TimeMs) мс" `
        -Color Green
}
else {
    Write-Value `
        -Label 'TCP 443' `
        -Value "недоступен: $($tcpResult.Error)" `
        -Color Red

    Add-Issue -List $issues -Text 'Не удаётся установить TCP-соединение на порт 443.'
}

$httpsResult = Test-HttpsRequest -Url 'https://www.microsoft.com/'

if ($httpsResult.Success) {
    $httpsColor = if ($httpsResult.TimeMs -ge 5000) {
        [ConsoleColor]::Red
    }
    elseif ($httpsResult.TimeMs -ge 2000) {
        [ConsoleColor]::Yellow
    }
    else {
        [ConsoleColor]::Green
    }

    Write-Value `
        -Label 'HTTP-ответ' `
        -Value "$($httpsResult.Status), $($httpsResult.TimeMs) мс" `
        -Color $httpsColor

    Write-Value -Label 'Конечный адрес' -Value $httpsResult.FinalUrl

    if ($httpsResult.TimeMs -ge 5000) {
        Add-Issue -List $issues -Text 'HTTPS-страница отвечает очень медленно.'
    }
    elseif ($httpsResult.TimeMs -ge 2000) {
        [void]$warnings.Add('HTTPS-страница отвечает медленно.')
    }
}
else {
    $failure = $httpsResult.Error

    if (-not [string]::IsNullOrWhiteSpace($httpsResult.Status)) {
        $failure = "$($httpsResult.Status): $failure"
    }

    Write-Value -Label 'HTTP-ответ' -Value $failure -Color Red
    Add-Issue -List $issues -Text 'HTTPS-запрос не выполняется.'
}

Write-Section -Title 'ПРОКСИ'

$proxyEnable = 0
$proxyServer = ''
$internetSettingsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

try {
    $internetSettings = Get-ItemProperty `
        -LiteralPath $internetSettingsPath `
        -ErrorAction Stop

    $proxyEnable = [int]$internetSettings.ProxyEnable
    $proxyServer = [string]$internetSettings.ProxyServer
}
catch {
}

if ($proxyEnable -eq 1) {
    Write-Value -Label 'Прокси пользователя' -Value $proxyServer -Color Yellow
    [void]$warnings.Add('В профиле пользователя включён прокси-сервер.')
}
else {
    Write-Value -Label 'Прокси пользователя' -Value 'не включён' -Color Green
}

Write-Section -Title 'ИТОГ'

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host '[OK] Локальная сеть, DNS и HTTPS работают без явных проблем.' `
        -ForegroundColor Green
    Write-Host 'Этот тест оценивает задержку, потери и время ответа, но не заменяет полноценный замер пропускной способности.' `
        -ForegroundColor DarkGray
}
else {
    foreach ($issue in $issues) {
        Write-Host "[FAIL] $issue" -ForegroundColor Red
    }

    foreach ($warning in $warnings) {
        Write-Host "[WARN] $warning" -ForegroundColor Yellow
    }
}
