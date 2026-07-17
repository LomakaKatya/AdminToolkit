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

    Write-Host ('{0,-25}: ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Add-Issue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$List,
        [Parameter(Mandatory)][string]$Text
    )

    [void]$List.Add($Text)
}

function Get-SafePropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor
            [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # 3072 is TLS 1.2 for older .NET versions where the enum name is absent.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor 3072
    }
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
        $text = "немає відповіді, втрати 100%"
    }
    else {
        $text = "середнє $($Result.AverageMs) мс, min $($Result.MinimumMs), max $($Result.MaximumMs), втрати $($Result.LossPercent)%"

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
            Success    = $true
            StatusCode = [int]$response.StatusCode
            Status     = "{0} {1}" -f `
                [int]$response.StatusCode,
                [string]$response.StatusDescription
            TimeMs     = [int]$watch.ElapsedMilliseconds
            FinalUrl  = [string]$response.ResponseUri.AbsoluteUri
            Error     = ''
        }
    }
    catch {
        $watch.Stop()

        $status = ''
        $finalUrl = ''
        $httpResponseReceived = $false

        if ($_.Exception -is [System.Net.WebException] -and
            $null -ne $_.Exception.Response) {
            try {
                $response = $_.Exception.Response
                $status = "{0} {1}" -f `
                    [int]$response.StatusCode,
                    [string]$response.StatusDescription
                $finalUrl = [string]$response.ResponseUri.AbsoluteUri
                $httpResponseReceived = $true
            }
            catch {
            }
        }

        return [pscustomobject]@{
            Success    = $httpResponseReceived
            StatusCode = if ($httpResponseReceived) {
                [int]$response.StatusCode
            }
            else {
                $null
            }
            Status     = $status
            TimeMs     = [int]$watch.ElapsedMilliseconds
            FinalUrl  = $finalUrl
            Error     = if ($httpResponseReceived) {
                ''
            }
            else {
                $_.Exception.Message
            }
        }
    }
    finally {
        if ($null -ne $response) {
            $response.Close()
        }
    }
}

Write-Host ''
Write-Host 'Комплексна діагностика інтернет-з’єднання' `
    -ForegroundColor Cyan
Write-Host 'Перевіряю локальний адаптер, шлюз, зовнішній IP, DNS і HTTPS...' `
    -ForegroundColor DarkGray

Enable-Tls12

$issues = New-Object -TypeName System.Collections.ArrayList
$warnings = New-Object -TypeName System.Collections.ArrayList

$defaultRoutes = @(
    Get-WmiObject `
        -Class Win32_IP4RouteTable `
        -Filter "Destination='0.0.0.0' AND Mask='0.0.0.0'" `
        -ErrorAction SilentlyContinue |
    Sort-Object -Property Metric1
)

$primaryInterfaceIndex = $null

if ($defaultRoutes.Count -gt 0) {
    $primaryInterfaceIndex = Get-SafePropertyValue `
        -InputObject $defaultRoutes[0] `
        -Name 'InterfaceIndex' `
        -DefaultValue $null
}

$configurations = @(
    Get-WmiObject `
        -Class Win32_NetworkAdapterConfiguration `
        -Filter 'IPEnabled=True' `
        -ErrorAction Stop |
    Where-Object {
        $null -ne $_.DefaultIPGateway -and
        @($_.DefaultIPGateway).Count -gt 0
    } |
    Sort-Object -Property @{
        Expression = {
            $interfaceIndex = Get-SafePropertyValue `
                -InputObject $_ `
                -Name 'InterfaceIndex' `
                -DefaultValue -1

            if ($null -ne $primaryInterfaceIndex -and
                [int]$interfaceIndex -eq [int]$primaryInterfaceIndex) {
                0
            }
            else {
                1
            }
        }
    }, @{
        Expression = {
            [int](
                Get-SafePropertyValue `
                    -InputObject $_ `
                    -Name 'IPConnectionMetric' `
                    -DefaultValue 9999
            )
        }
    }
)

Write-Section -Title 'АКТИВНЕ ПІДКЛЮЧЕННЯ'

if ($configurations.Count -eq 0) {
    Write-Host '[FAIL] Не знайдено активного мережевого інтерфейсу зі шлюзом за замовчуванням.' `
        -ForegroundColor Red
    Add-Issue -List $issues -Text 'Немає активного підключення зі шлюзом за замовчуванням.'

    Write-Section -Title 'ПІДСУМОК'

    foreach ($issue in $issues) {
        Write-Host "[FAIL] $issue" -ForegroundColor Red
    }

    return
}

foreach ($configuration in $configurations) {
    $adapter = Get-WmiObject `
        -Class Win32_NetworkAdapter `
        -Filter ("Index={0}" -f [int](
            Get-SafePropertyValue `
                -InputObject $configuration `
                -Name 'Index' `
                -DefaultValue -1
        )) `
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

    $adapterSpeed = [double](
        Get-SafePropertyValue `
            -InputObject $adapter `
            -Name 'Speed' `
            -DefaultValue 0
    )

    if ($adapterSpeed -gt 0) {
        $speedMbps = [Math]::Round(($adapterSpeed / 1000000), 0)
        Write-Value -Label 'Швидкість лінка' -Value "$speedMbps Мбіт/с"
    }

    $interfaceIndex = Get-SafePropertyValue `
        -InputObject $configuration `
        -Name 'InterfaceIndex' `
        -DefaultValue $null

    if ($null -ne $primaryInterfaceIndex -and
        $null -ne $interfaceIndex -and
        [int]$interfaceIndex -eq [int]$primaryInterfaceIndex) {
        Write-Value -Label 'Основний маршрут' -Value 'так' -Color Green
    }

    Write-Host ''
}

$primaryConfiguration = $configurations[0]
$gateway = [string]@($primaryConfiguration.DefaultIPGateway)[0]

Write-Section -Title 'ЗАТРИМКА ТА ВТРАТИ'

$gatewayResult = Invoke-PingSummary -Target $gateway -Count 4
$cloudflareResult = Invoke-PingSummary -Target '1.1.1.1' -Count 4
$googleResult = Invoke-PingSummary -Target '8.8.8.8' -Count 4

Show-PingResult `
    -Label 'Шлюз' `
    -Result $gatewayResult `
    -WarningLatency 10 `
    -CriticalLatency 50

Show-PingResult `
    -Label 'Інтернет 1.1.1.1' `
    -Result $cloudflareResult `
    -WarningLatency 100 `
    -CriticalLatency 200

Show-PingResult `
    -Label 'Інтернет 8.8.8.8' `
    -Result $googleResult `
    -WarningLatency 100 `
    -CriticalLatency 200

$gatewayPingFailed = ($gatewayResult.Received -eq 0)

if (-not $gatewayPingFailed -and
    ($gatewayResult.LossPercent -gt 0 -or
        [double]$gatewayResult.AverageMs -ge 20)) {
    [void]$warnings.Add('До локального шлюзу є втрати або висока затримка.')
}

$successfulExternalPings = @(
    @(
        $cloudflareResult,
        $googleResult
    ) |
    Where-Object { $_.Received -gt 0 }
)

$externalPingAllFailed = ($successfulExternalPings.Count -eq 0)

if (-not $externalPingAllFailed) {
    $bestLoss = (
        $successfulExternalPings |
        Measure-Object -Property LossPercent -Minimum
    ).Minimum

    $bestLatency = (
        $successfulExternalPings |
        Where-Object { $null -ne $_.AverageMs } |
        Measure-Object -Property AverageMs -Minimum
    ).Minimum

    if ([double]$bestLoss -ge 25) {
        Add-Issue -List $issues -Text 'На зовнішньому з’єднанні високі втрати пакетів.'
    }
    elseif ([double]$bestLoss -gt 0) {
        [void]$warnings.Add('На зовнішньому з’єднанні виявлено втрати пакетів.')
    }

    if ($null -ne $bestLatency -and [double]$bestLatency -ge 200) {
        Add-Issue -List $issues -Text 'Затримка до зовнішніх вузлів дуже висока.'
    }
    elseif ($null -ne $bestLatency -and [double]$bestLatency -ge 100) {
        [void]$warnings.Add('Затримка до зовнішніх вузлів підвищена.')
    }
}

Write-Section -Title 'DNS'

$dnsHosts = @(
    'www.microsoft.com',
    'www.cloudflare.com'
)

$dnsHost = ''
$dnsWatch = $null
$dnsAddresses = @()
$dnsErrors = @()

foreach ($candidateHost in $dnsHosts) {
    $candidateWatch = New-Object -TypeName System.Diagnostics.Stopwatch
    $candidateAddresses = @()

    try {
        $candidateWatch.Start()
        $candidateAddresses = @(
            [System.Net.Dns]::GetHostAddresses($candidateHost) |
            ForEach-Object { $_.IPAddressToString }
        )
        $candidateWatch.Stop()
    }
    catch {
        $candidateWatch.Stop()
        $dnsErrors += "$candidateHost`: $($_.Exception.Message)"
    }

    if ($candidateAddresses.Count -gt 0) {
        $dnsHost = $candidateHost
        $dnsWatch = $candidateWatch
        $dnsAddresses = $candidateAddresses
        break
    }
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
        -Label 'Розпізнавання імені' `
        -Value "$dnsHost -> $($dnsAddresses -join ', ') за $($dnsWatch.ElapsedMilliseconds) мс" `
        -Color $dnsColor

    if ($dnsWatch.ElapsedMilliseconds -ge 2000) {
        Add-Issue -List $issues -Text 'DNS відповідає дуже повільно.'
    }
    elseif ($dnsWatch.ElapsedMilliseconds -ge 700) {
        [void]$warnings.Add('DNS відповідає повільніше, ніж зазвичай.')
    }
}
else {
    Write-Value `
        -Label 'Розпізнавання імені' `
        -Value "помилка: $($dnsErrors -join ' | ')" `
        -Color Red

    if ($cloudflareResult.Received -gt 0 -or $googleResult.Received -gt 0) {
        Add-Issue -List $issues -Text 'Зовнішні IP доступні, але DNS не розпізнає перевірочні імена.'
    }
    else {
        Add-Issue -List $issues -Text 'Не працює розпізнавання DNS-імен.'
    }
}

Write-Section -Title 'HTTPS'

$tcpTargets = @(
    'www.microsoft.com',
    'www.cloudflare.com'
)

$tcpResult = $null
$tcpTargetUsed = ''

foreach ($tcpTarget in $tcpTargets) {
    $candidateResult = Test-TcpPort `
        -HostName $tcpTarget `
        -Port 443

    if ($null -eq $tcpResult) {
        $tcpResult = $candidateResult
        $tcpTargetUsed = $tcpTarget
    }

    if ($candidateResult.Success) {
        $tcpResult = $candidateResult
        $tcpTargetUsed = $tcpTarget
        break
    }
}

if ($tcpResult.Success) {
    Write-Value `
        -Label 'TCP 443' `
        -Value "$tcpTargetUsed доступний, $($tcpResult.TimeMs) мс" `
        -Color Green
}
else {
    Write-Value `
        -Label 'TCP 443' `
        -Value "обидва перевірочні вузли недоступні; остання помилка: $($tcpResult.Error)" `
        -Color Red

    Add-Issue `
        -List $issues `
        -Text 'Не вдається встановити TCP-з’єднання з портом 443 жодного перевірочного вузла.'
}

$httpsTargets = @(
    'https://www.microsoft.com/',
    'https://www.cloudflare.com/'
)

$httpsResult = $null
$httpsTargetUsed = ''

foreach ($httpsTarget in $httpsTargets) {
    $candidateResult = Test-HttpsRequest -Url $httpsTarget

    if ($null -eq $httpsResult) {
        $httpsResult = $candidateResult
        $httpsTargetUsed = $httpsTarget
    }

    if ($candidateResult.Success) {
        $httpsResult = $candidateResult
        $httpsTargetUsed = $httpsTarget
        break
    }
}

if ($httpsResult.Success) {
    $httpsColor = if ($httpsResult.TimeMs -ge 5000) {
        [ConsoleColor]::Red
    }
    elseif ($httpsResult.TimeMs -ge 2000 -or
        ($null -ne $httpsResult.StatusCode -and
            [int]$httpsResult.StatusCode -ge 400)) {
        [ConsoleColor]::Yellow
    }
    else {
        [ConsoleColor]::Green
    }

    Write-Value `
        -Label 'HTTP-відповідь' `
        -Value "$($httpsResult.Status), $($httpsResult.TimeMs) мс" `
        -Color $httpsColor

    Write-Value -Label 'Перевірочна адреса' -Value $httpsTargetUsed
    Write-Value -Label 'Кінцева адреса' -Value $httpsResult.FinalUrl

    if ($httpsResult.TimeMs -ge 5000) {
        Add-Issue -List $issues -Text 'HTTPS-сторінка відповідає дуже повільно.'
    }
    elseif ($httpsResult.TimeMs -ge 2000) {
        [void]$warnings.Add('HTTPS-сторінка відповідає повільно.')
    }

    if ($null -ne $httpsResult.StatusCode -and
        [int]$httpsResult.StatusCode -ge 400) {
        [void]$warnings.Add(
            "Перевірочний HTTPS-вузол відповідає кодом $($httpsResult.StatusCode), но соединение встановлено."
        )
    }
}
else {
    $failure = $httpsResult.Error

    if (-not [string]::IsNullOrWhiteSpace($httpsResult.Status)) {
        $failure = "$($httpsResult.Status): $failure"
    }

    Write-Value -Label 'HTTP-відповідь' -Value $failure -Color Red
    Add-Issue -List $issues -Text 'HTTPS-запит не виконується до жодного перевірочного вузла.'
}

if ($externalPingAllFailed) {
    if ($tcpResult.Success -or $httpsResult.Success) {
        [void]$warnings.Add(
            'Зовнішні вузли не відповідають на ICMP, але TCP/HTTPS працюють. Імовірно, ping фільтрується.'
        )
    }
    else {
        Add-Issue `
            -List $issues `
            -Text 'Не подтверждена связь с интерніом ни по ICMP, ни по TCP/HTTPS.'
    }
}

if ($gatewayPingFailed) {
    if ($tcpResult.Success -or $httpsResult.Success) {
        [void]$warnings.Add(
            'Шлюз не відповідає на ping, але доступ до інтернету працює. Можливо, ICMP на маршрутизаторі заборонено.'
        )
    }
    else {
        Add-Issue `
            -List $issues `
            -Text 'Шлюз не відповідає, а зовнішній TCP/HTTPS також недоступний. Перевір локальну мережу, Wi-Fi, кабель і маршрутизатор.'
    }
}

Write-Section -Title 'ПРОКСИ'

$proxyEnable = 0
$proxyServer = ''
$autoConfigUrl = ''
$internetSettingsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

try {
    $internetSettings = Get-ItemProperty `
        -LiteralPath $internetSettingsPath `
        -ErrorAction Stop

    $proxyEnable = [int](
        Get-SafePropertyValue `
            -InputObject $internetSettings `
            -Name 'ProxyEnable' `
            -DefaultValue 0
    )

    $proxyServer = [string](
        Get-SafePropertyValue `
            -InputObject $internetSettings `
            -Name 'ProxyServer' `
            -DefaultValue ''
    )

    $autoConfigUrl = [string](
        Get-SafePropertyValue `
            -InputObject $internetSettings `
            -Name 'AutoConfigURL' `
            -DefaultValue ''
    )
}
catch {
}

if ($proxyEnable -eq 1) {
    Write-Value -Label 'Проксі користувача' -Value $proxyServer -Color Yellow
    [void]$warnings.Add('У профілі користувача ввімкнено проксі-сервер.')
}
else {
    Write-Value -Label 'Проксі користувача' -Value 'не ввімкнено' -Color Green
}

if (-not [string]::IsNullOrWhiteSpace($autoConfigUrl)) {
    Write-Value -Label 'PAC-сценарій' -Value $autoConfigUrl -Color Yellow
    [void]$warnings.Add('Для користувача налаштовано автоматичний сценарій проксі (PAC).')
}
else {
    Write-Value -Label 'PAC-сценарій' -Value 'не налаштовано' -Color Green
}

$winHttpProxyLines = @(
    & netsh winhttp show proxy 2>&1 |
    ForEach-Object { ([string]$_).Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$winHttpSummary = $winHttpProxyLines -join ' | '

if ($winHttpSummary.Length -gt 180) {
    $winHttpSummary = $winHttpSummary.Substring(0, 177) + '...'
}

Write-Value -Label 'WinHTTP proxy' -Value $winHttpSummary

Write-Section -Title 'ПІДСУМОК'

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host '[OK] Локальна мережа, DNS і HTTPS працюють без явних проблем.' `
        -ForegroundColor Green
    Write-Host 'Цей тест оцінює затримку, втрати та час відповіді, але не замінює повноцінного вимірювання пропускної здатності.' `
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
