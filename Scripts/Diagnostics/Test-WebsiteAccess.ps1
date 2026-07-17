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

    Write-Host ('{0,-24}: ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Add-Issue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$List,
        [Parameter(Mandatory)][string]$Text
    )

    [void]$List.Add($Text)
}

function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor
            [Net.SecurityProtocolType]::Tls12
    }
    catch {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor 3072
    }
}

function Get-NormalizedUriText {
    param(
        [AllowNull()][object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    try {
        $normalized = New-Object `
            -TypeName System.Uri `
            -ArgumentList ([string]$Value)

        return $normalized.AbsoluteUri.TrimEnd('/')
    }
    catch {
        return ([string]$Value).TrimEnd('/')
    }
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

function Invoke-WebProbe {
    param(
        [Parameter(Mandatory)][Uri]$Uri,
        [int]$TimeoutMilliseconds = 12000
    )

    $request = $null
    $response = $null
    $watch = New-Object -TypeName System.Diagnostics.Stopwatch

    try {
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'HEAD'
        $request.AllowAutoRedirect = $true
        $request.MaximumAutomaticRedirections = 10
        $request.Timeout = $TimeoutMilliseconds
        $request.ReadWriteTimeout = $TimeoutMilliseconds
        $request.UserAgent = 'Mozilla/5.0 Raccoon-Admin-Toolkit/1.0'
        $request.Proxy = [System.Net.WebRequest]::DefaultWebProxy

        $watch.Start()

        try {
            $response = $request.GetResponse()
        }
        catch [System.Net.WebException] {
            if ($null -ne $_.Exception.Response -and
                [int]$_.Exception.Response.StatusCode -eq 405) {
                $request = [System.Net.HttpWebRequest]::Create($Uri)
                $request.Method = 'GET'
                $request.AllowAutoRedirect = $true
                $request.MaximumAutomaticRedirections = 10
                $request.Timeout = $TimeoutMilliseconds
                $request.ReadWriteTimeout = $TimeoutMilliseconds
                $request.UserAgent = 'Mozilla/5.0 Raccoon-Admin-Toolkit/1.0'
                $request.Proxy = [System.Net.WebRequest]::DefaultWebProxy
                $response = $request.GetResponse()
            }
            else {
                throw
            }
        }

        $watch.Stop()

        $certificate = $null

        try {
            if ($null -ne $request.ServicePoint.Certificate) {
                $certificate = New-Object `
                    -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 `
                    -ArgumentList $request.ServicePoint.Certificate
            }
        }
        catch {
        }

        return [pscustomobject]@{
            Success      = $true
            StatusCode   = [int]$response.StatusCode
            StatusText   = [string]$response.StatusDescription
            TimeMs       = [int]$watch.ElapsedMilliseconds
            FinalUri     = [string]$response.ResponseUri.AbsoluteUri
            Server       = [string]$response.Server
            Certificate  = $certificate
            Error        = ''
        }
    }
    catch {
        $watch.Stop()

        $statusCode = $null
        $statusText = ''
        $finalUri = ''
        $server = ''
        $httpResponseReceived = $false

        if ($_.Exception -is [System.Net.WebException] -and
            $null -ne $_.Exception.Response) {
            try {
                $response = $_.Exception.Response
                $statusCode = [int]$response.StatusCode
                $statusText = [string]$response.StatusDescription
                $finalUri = [string]$response.ResponseUri.AbsoluteUri
                $server = [string]$response.Server
                $httpResponseReceived = $true
            }
            catch {
            }
        }

        $certificate = $null

        try {
            if ($null -ne $request -and
                $null -ne $request.ServicePoint.Certificate) {
                $certificate = New-Object `
                    -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 `
                    -ArgumentList $request.ServicePoint.Certificate
            }
        }
        catch {
        }

        return [pscustomobject]@{
            Success      = $httpResponseReceived
            StatusCode   = $statusCode
            StatusText   = $statusText
            TimeMs       = [int]$watch.ElapsedMilliseconds
            FinalUri     = $finalUri
            Server       = $server
            Certificate  = $certificate
            Error        = if ($httpResponseReceived) {
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

function Get-HostsEntries {
    param([Parameter(Mandatory)][string]$HostName)

    $hostsPath = Join-Path `
        -Path $env:SystemRoot `
        -ChildPath 'System32\drivers\etc\hosts'

    if (-not (Test-Path -LiteralPath $hostsPath -PathType Leaf)) {
        return @()
    }

    $escaped = [Regex]::Escape($HostName)

    return @(
        Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue |
        Where-Object {
            $_ -notmatch '^\s*#' -and
            $_ -match "(?i)(^|\s)$escaped(\s|$)"
        }
    )
}

Write-Host ''
Write-Host 'Діагностика доступу до сайту' -ForegroundColor Cyan
Write-Host 'Перевіряю URL, DNS, hosts, порт, проксі, HTTP і сертифікат...' `
    -ForegroundColor DarkGray
Write-Host ''

$inputUrl = (Read-Host 'Введіть адресу сайту').Trim()

if ([string]::IsNullOrWhiteSpace($inputUrl)) {
    throw 'Адреса сайту не може бути порожньою.'
}

if ($inputUrl -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
    $inputUrl = 'https://' + $inputUrl
}

$uri = $null

try {
    $uri = New-Object -TypeName System.Uri -ArgumentList $inputUrl
}
catch {
    throw "Некоректна адреса: $inputUrl"
}

if ([string]::IsNullOrWhiteSpace($uri.Host)) {
    throw "В адресі не знайдено ім’я вузла: $inputUrl"
}

if ($uri.Scheme -notin @('http', 'https')) {
    throw 'Підтримуються лише адреси HTTP і HTTPS.'
}

Enable-Tls12

$issues = New-Object -TypeName System.Collections.ArrayList
$warnings = New-Object -TypeName System.Collections.ArrayList

Write-Section -Title 'АДРЕС'

Write-Value -Label 'Початковий URL' -Value $inputUrl -Color Cyan
Write-Value -Label 'Протокол' -Value $uri.Scheme
Write-Value -Label 'Вузол' -Value $uri.Host
Write-Value -Label 'Порт' -Value ([string]$uri.Port)

Write-Section -Title 'DNS И HOSTS'

$dnsWatch = New-Object -TypeName System.Diagnostics.Stopwatch
$addresses = @()
$dnsError = ''

try {
    $dnsWatch.Start()
    $addresses = @(
        [System.Net.Dns]::GetHostAddresses($uri.Host) |
        ForEach-Object { $_.IPAddressToString }
    )
    $dnsWatch.Stop()
}
catch {
    $dnsWatch.Stop()
    $dnsError = $_.Exception.Message
}

if ($addresses.Count -gt 0) {
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
        -Label 'DNS-адреса' `
        -Value ($addresses -join ', ') `
        -Color $dnsColor

    Write-Value `
        -Label 'Время DNS' `
        -Value "$($dnsWatch.ElapsedMilliseconds) мс" `
        -Color $dnsColor

    if ($dnsWatch.ElapsedMilliseconds -ge 2000) {
        Add-Issue -List $issues -Text 'DNS розпізнає ім’я дуже повільно.'
    }
    elseif ($dnsWatch.ElapsedMilliseconds -ge 700) {
        [void]$warnings.Add('DNS розпізнає ім’я повільніше, ніж зазвичай.')
    }
}
else {
    Write-Value -Label 'DNS' -Value "помилка: $dnsError" -Color Red
    Add-Issue -List $issues -Text 'DNS не може розпізнати ім’я сайту.'
}

$hostsEntries = @(Get-HostsEntries -HostName $uri.Host)

if ($hostsEntries.Count -gt 0) {
    Write-Value `
        -Label 'Файл hosts' `
        -Value ($hostsEntries -join ' | ') `
        -Color Yellow

    [void]$warnings.Add('Для сайту є запис у локальному файлі hosts.')
}
else {
    Write-Value -Label 'Файл hosts' -Value 'записів немає' -Color Green
}

$proxyUri = $null
$usesProxy = $false

try {
    $proxy = [System.Net.WebRequest]::DefaultWebProxy

    if ($null -ne $proxy) {
        $isBypassed = $proxy.IsBypassed($uri)
        $proxyUri = $proxy.GetProxy($uri)

        $usesProxy = (
            -not $isBypassed -and
            $null -ne $proxyUri -and
            $proxyUri.Host -ne $uri.Host
        )
    }
}
catch {
    $proxyUri = $null
    $usesProxy = $false
}

if ($usesProxy -and $addresses.Count -eq 0) {
    [void]$issues.Remove('DNS не може розпізнати ім’я сайту.')
    [void]$warnings.Add(
        'Локальний DNS не розпізнав ім’я сайту, але проксі може виконати розпізнавання самостійно.'
    )
}

Write-Section -Title 'СЕТЕВАЯ ДОСТУПНОСТЬ'

$pingResult = Test-PingHost -HostName $uri.Host

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

    [void]$warnings.Add('Сайт не відповідає на ping. Це не завжди помилка: ICMP може бути заборонено.')
}

$tcpHost = $uri.Host
$tcpPort = $uri.Port
$tcpLabel = "TCP $($uri.Port)"

if ($usesProxy) {
    $tcpHost = $proxyUri.Host
    $tcpPort = $proxyUri.Port
    $tcpLabel = "TCP до прокси $tcpPort"
}

$tcpResult = Test-TcpPort `
    -HostName $tcpHost `
    -Port $tcpPort

if ($tcpResult.Success) {
    Write-Value `
        -Label $tcpLabel `
        -Value "доступний, $($tcpResult.TimeMs) мс" `
        -Color Green
}
else {
    Write-Value `
        -Label $tcpLabel `
        -Value "недоступний: $($tcpResult.Error)" `
        -Color Red

    if ($usesProxy) {
        Add-Issue `
            -List $issues `
            -Text "Не вдається підключитися до проксі $tcpHost`:$tcpPort."
    }
    else {
        Add-Issue `
            -List $issues `
            -Text "Не вдається підключитися до $($uri.Host):$($uri.Port)."
    }
}

Write-Section -Title 'ПРОКСИ'

if ($usesProxy) {
    Write-Value `
        -Label 'Використовуваний проксі' `
        -Value $proxyUri.AbsoluteUri `
        -Color Yellow

    [void]$warnings.Add('Запит до сайту спрямовується через проксі-сервер.')
}
else {
    Write-Value `
        -Label 'Використовуваний проксі' `
        -Value 'пряме підключення' `
        -Color Green
}

Write-Section -Title 'HTTP / HTTPS'

$webResult = Invoke-WebProbe -Uri $uri

if ($webResult.Success) {
    $responseColor = if ($webResult.StatusCode -ge 200 -and
        $webResult.StatusCode -lt 400) {
        [ConsoleColor]::Green
    }
    elseif ($webResult.StatusCode -ge 400 -and
        $webResult.StatusCode -lt 500) {
        [ConsoleColor]::Yellow
    }
    else {
        [ConsoleColor]::Red
    }

    Write-Value `
        -Label 'Відповідь сервера' `
        -Value "$($webResult.StatusCode) $($webResult.StatusText)" `
        -Color $responseColor

    Write-Value `
        -Label 'Время відповіді' `
        -Value "$($webResult.TimeMs) мс" `
        -Color $(if ($webResult.TimeMs -ge 5000) {
            [ConsoleColor]::Red
        }
        elseif ($webResult.TimeMs -ge 2000) {
            [ConsoleColor]::Yellow
        }
        else {
            [ConsoleColor]::Green
        })

    Write-Value -Label 'Кінцева URL-адреса' -Value $webResult.FinalUri
    Write-Value -Label 'Сервер' -Value $webResult.Server

    if ($webResult.StatusCode -ge 500) {
        Add-Issue -List $issues -Text "Сайт відповідає серверною помилкою HTTP $($webResult.StatusCode)."
    }
    elseif ($webResult.StatusCode -ge 400) {
        [void]$warnings.Add("Сайт відповідає кодом HTTP $($webResult.StatusCode).")
    }

    if ($webResult.TimeMs -ge 5000) {
        Add-Issue -List $issues -Text 'Сайт відповідає дуже повільно.'
    }
    elseif ($webResult.TimeMs -ge 2000) {
        [void]$warnings.Add('Сайт відповідає повільно.')
    }

    $initialUriText = Get-NormalizedUriText -Value $uri
    $finalUriText = Get-NormalizedUriText -Value $webResult.FinalUri

    if (-not [string]::IsNullOrWhiteSpace($finalUriText) -and
        $finalUriText -ne $initialUriText) {
        [void]$warnings.Add("Сайт перенаправляє запит на $($webResult.FinalUri).")
    }
}
else {
    $responseText = $webResult.Error

    if ($null -ne $webResult.StatusCode) {
        $responseText = "$($webResult.StatusCode) $($webResult.StatusText): $responseText"
    }

    Write-Value -Label 'HTTP-запит' -Value $responseText -Color Red
    Add-Issue -List $issues -Text 'HTTP-запит до сайту не виконується.'
}

if ($uri.Scheme -eq 'https') {
    Write-Section -Title 'СЕРТИФИКАТ TLS'

    if ($null -eq $webResult.Certificate) {
        Write-Host '[WARN] Не вдалося отримати сертифікат сайту.' `
            -ForegroundColor Yellow
        [void]$warnings.Add('Не вдалося прочитати сертифікат TLS.')
    }
    else {
        $certificate = $webResult.Certificate
        $daysLeft = [Math]::Floor(
            ($certificate.NotAfter - (Get-Date)).TotalDays
        )

        Write-Value -Label 'Кому видано' -Value ([string]$certificate.Subject)
        Write-Value -Label 'Ким видано' -Value ([string]$certificate.Issuer)
        Write-Value -Label 'Чинний від' -Value $certificate.NotBefore.ToString('dd.MM.yyyy HH:mm')
        Write-Value -Label 'Чинний до' -Value $certificate.NotAfter.ToString('dd.MM.yyyy HH:mm')
        Write-Value `
            -Label 'Залишилося днів' `
            -Value ([string]$daysLeft) `
            -Color $(if ($daysLeft -lt 0) {
                [ConsoleColor]::Red
            }
            elseif ($daysLeft -lt 30) {
                [ConsoleColor]::Yellow
            }
            else {
                [ConsoleColor]::Green
            })

        if ($daysLeft -lt 0) {
            Add-Issue -List $issues -Text 'Строк дії TLS-сертифіката минув.'
        }
        elseif ($daysLeft -lt 14) {
            [void]$warnings.Add('Строк дії TLS-сертифіката завершиться менш ніж за 14 днів.')
        }
        elseif ($daysLeft -lt 30) {
            [void]$warnings.Add('Строк дії TLS-сертифіката незабаром завершиться.')
        }
    }
}

Write-Section -Title 'ПІДСУМОК'

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host '[OK] DNS, порт і HTTP-доступ до сайту працюють.' `
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
