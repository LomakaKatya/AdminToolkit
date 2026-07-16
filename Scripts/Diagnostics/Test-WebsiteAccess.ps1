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

    Write-Host ('{0,-24}: ' -f $Label) -NoNewline
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
Write-Host 'Диагностика доступа к сайту' -ForegroundColor Cyan
Write-Host 'Проверяю URL, DNS, hosts, порт, прокси, HTTP и сертификат...' `
    -ForegroundColor DarkGray
Write-Host ''

$inputUrl = (Read-Host 'Введите адрес сайта').Trim()

if ([string]::IsNullOrWhiteSpace($inputUrl)) {
    throw 'Адрес сайта не может быть пустым.'
}

if ($inputUrl -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
    $inputUrl = 'https://' + $inputUrl
}

$uri = $null

try {
    $uri = New-Object -TypeName System.Uri -ArgumentList $inputUrl
}
catch {
    throw "Некорректный адрес: $inputUrl"
}

if ([string]::IsNullOrWhiteSpace($uri.Host)) {
    throw "В адресе не найдено имя узла: $inputUrl"
}

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor
    [Net.SecurityProtocolType]::Tls12

$issues = New-Object -TypeName System.Collections.ArrayList
$warnings = New-Object -TypeName System.Collections.ArrayList

Write-Section -Title 'АДРЕС'

Write-Value -Label 'Исходный URL' -Value $inputUrl -Color Cyan
Write-Value -Label 'Протокол' -Value $uri.Scheme
Write-Value -Label 'Узел' -Value $uri.Host
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
        Add-Issue -List $issues -Text 'DNS разрешает имя очень медленно.'
    }
    elseif ($dnsWatch.ElapsedMilliseconds -ge 700) {
        [void]$warnings.Add('DNS разрешает имя медленнее обычного.')
    }
}
else {
    Write-Value -Label 'DNS' -Value "ошибка: $dnsError" -Color Red
    Add-Issue -List $issues -Text 'DNS не может разрешить имя сайта.'
}

$hostsEntries = @(Get-HostsEntries -HostName $uri.Host)

if ($hostsEntries.Count -gt 0) {
    Write-Value `
        -Label 'Файл hosts' `
        -Value ($hostsEntries -join ' | ') `
        -Color Yellow

    [void]$warnings.Add('Для сайта есть запись в локальном файле hosts.')
}
else {
    Write-Value -Label 'Файл hosts' -Value 'записей нет' -Color Green
}

Write-Section -Title 'СЕТЕВАЯ ДОСТУПНОСТЬ'

$pingResult = Test-PingHost -HostName $uri.Host

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

    [void]$warnings.Add('Сайт не отвечает на ping. Это не всегда ошибка: ICMP может быть запрещён.')
}

$tcpResult = Test-TcpPort `
    -HostName $uri.Host `
    -Port $uri.Port

if ($tcpResult.Success) {
    Write-Value `
        -Label "TCP $($uri.Port)" `
        -Value "доступен, $($tcpResult.TimeMs) мс" `
        -Color Green
}
else {
    Write-Value `
        -Label "TCP $($uri.Port)" `
        -Value "недоступен: $($tcpResult.Error)" `
        -Color Red

    Add-Issue `
        -List $issues `
        -Text "Не удаётся подключиться к $($uri.Host):$($uri.Port)."
}

Write-Section -Title 'ПРОКСИ'

$proxyUri = $null

try {
    $proxy = [System.Net.WebRequest]::DefaultWebProxy

    if ($null -ne $proxy) {
        $proxyUri = $proxy.GetProxy($uri)
    }
}
catch {
}

if ($null -ne $proxyUri -and
    $proxyUri.AbsoluteUri -ne $uri.AbsoluteUri) {
    Write-Value -Label 'Используемый прокси' -Value $proxyUri.AbsoluteUri -Color Yellow
    [void]$warnings.Add('Запрос к сайту направляется через прокси-сервер.')
}
else {
    Write-Value -Label 'Используемый прокси' -Value 'прямое подключение' -Color Green
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
        -Label 'Ответ сервера' `
        -Value "$($webResult.StatusCode) $($webResult.StatusText)" `
        -Color $responseColor

    Write-Value `
        -Label 'Время ответа' `
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

    Write-Value -Label 'Конечный URL' -Value $webResult.FinalUri
    Write-Value -Label 'Сервер' -Value $webResult.Server

    if ($webResult.StatusCode -ge 500) {
        Add-Issue -List $issues -Text "Сайт отвечает серверной ошибкой HTTP $($webResult.StatusCode)."
    }
    elseif ($webResult.StatusCode -ge 400) {
        [void]$warnings.Add("Сайт отвечает кодом HTTP $($webResult.StatusCode).")
    }

    if ($webResult.TimeMs -ge 5000) {
        Add-Issue -List $issues -Text 'Сайт отвечает очень медленно.'
    }
    elseif ($webResult.TimeMs -ge 2000) {
        [void]$warnings.Add('Сайт отвечает медленно.')
    }

    if ($webResult.FinalUri -ne $uri.AbsoluteUri) {
        [void]$warnings.Add("Сайт перенаправляет запрос на $($webResult.FinalUri).")
    }
}
else {
    $responseText = $webResult.Error

    if ($null -ne $webResult.StatusCode) {
        $responseText = "$($webResult.StatusCode) $($webResult.StatusText): $responseText"
    }

    Write-Value -Label 'HTTP-запрос' -Value $responseText -Color Red
    Add-Issue -List $issues -Text 'HTTP-запрос к сайту не выполняется.'
}

if ($uri.Scheme -eq 'https') {
    Write-Section -Title 'СЕРТИФИКАТ TLS'

    if ($null -eq $webResult.Certificate) {
        Write-Host '[WARN] Не удалось получить сертификат сайта.' `
            -ForegroundColor Yellow
        [void]$warnings.Add('Сертификат TLS не удалось прочитать.')
    }
    else {
        $certificate = $webResult.Certificate
        $daysLeft = [Math]::Floor(
            ($certificate.NotAfter - (Get-Date)).TotalDays
        )

        Write-Value -Label 'Кому выдан' -Value ([string]$certificate.Subject)
        Write-Value -Label 'Кем выдан' -Value ([string]$certificate.Issuer)
        Write-Value -Label 'Действителен с' -Value $certificate.NotBefore.ToString('dd.MM.yyyy HH:mm')
        Write-Value -Label 'Действителен до' -Value $certificate.NotAfter.ToString('dd.MM.yyyy HH:mm')
        Write-Value `
            -Label 'Осталось дней' `
            -Value ([string]$daysLeft) `
            -Color $(if ($daysLeft -lt 0) {
                [ConsoleColor]::Red
            }
            elseif ($daysLeft -lt 14) {
                [ConsoleColor]::Red
            }
            elseif ($daysLeft -lt 30) {
                [ConsoleColor]::Yellow
            }
            else {
                [ConsoleColor]::Green
            })

        if ($daysLeft -lt 0) {
            Add-Issue -List $issues -Text 'Срок действия TLS-сертификата истёк.'
        }
        elseif ($daysLeft -lt 14) {
            Add-Issue -List $issues -Text 'TLS-сертификат истекает менее чем через 14 дней.'
        }
        elseif ($daysLeft -lt 30) {
            [void]$warnings.Add('TLS-сертификат скоро истекает.')
        }
    }
}

Write-Section -Title 'ИТОГ'

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host '[OK] DNS, порт и HTTP-доступ к сайту работают.' `
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
