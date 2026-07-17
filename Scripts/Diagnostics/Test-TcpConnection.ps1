Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

    Write-Host ('{0,-22}: ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
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

function Test-TcpPortCompatible {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 5000
    )

    $client = $null
    $asyncResult = $null
    $waitHandle = $null
    $watch = New-Object -TypeName System.Diagnostics.Stopwatch

    try {
        $client = New-Object -TypeName System.Net.Sockets.TcpClient
        $watch.Start()

        $asyncResult = $client.BeginConnect(
            $HostName,
            $Port,
            $null,
            $null
        )

        $waitHandle = $asyncResult.AsyncWaitHandle

        if (-not $waitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return [pscustomobject]@{
                Success = $false
                TimeMs  = [int]$watch.ElapsedMilliseconds
                Error   = "тайм-аут $TimeoutMilliseconds мс"
            }
        }

        $client.EndConnect($asyncResult)

        return [pscustomobject]@{
            Success = [bool]$client.Connected
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

Write-Host ''
Write-Host 'Перевірка TCP-підключення' -ForegroundColor Cyan
Write-Host ('=' * 48) -ForegroundColor DarkGray
Write-Host ''

$target = ''

while ([string]::IsNullOrWhiteSpace($target)) {
    $target = (Read-Host 'Введіть IP-адрес или имя узла').Trim()

    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host 'Адреса не може бути порожньою.' -ForegroundColor Yellow
    }
}

$port = 0

while ($true) {
    $portText = (Read-Host 'Введіть TCP-порт (1-65535)').Trim()

    if ([int]::TryParse($portText, [ref]$port) -and
        $port -ge 1 -and
        $port -le 65535) {
        break
    }

    Write-Host 'Порт має бути числом от 1 до 65535.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "Перевіряємо $target`:$port..." -ForegroundColor Cyan
Write-Host ''

$resolvedAddresses = @()
$dnsError = ''

try {
    $resolvedAddresses = @(
        [System.Net.Dns]::GetHostAddresses($target) |
        ForEach-Object { $_.IPAddressToString }
    )
}
catch {
    $dnsError = $_.Exception.Message
}

if ($resolvedAddresses.Count -gt 0) {
    Write-Value -Label 'Разрешённые адреса' -Value ($resolvedAddresses -join ', ')
}
else {
    Write-Value -Label 'DNS' -Value "помилка: $dnsError" -Color Red
    Write-Host ''
    Write-Host '[FAIL] Ім’я узла не втаклося разрешить.' -ForegroundColor Red
    return
}

$testNetConnection = Get-Command `
    -Name 'Test-NetConnection' `
    -ErrorAction SilentlyContinue

if ($null -ne $testNetConnection) {
    try {
        $result = Test-NetConnection `
            -ComputerName $target `
            -Port $port `
            -InformationLevel Detailed `
            -WarningAction SilentlyContinue `
            -ErrorAction Stop

        $succeeded = [bool](
            Get-SafePropertyValue `
                -InputObject $result `
                -Name 'TcpTestSucceeded' `
                -DefaultValue $false
        )

        $remoteAddress = [string](
            Get-SafePropertyValue `
                -InputObject $result `
                -Name 'RemoteAddress' `
                -DefaultValue ''
        )

        $sourceAddress = [string](
            Get-SafePropertyValue `
                -InputObject $result `
                -Name 'SourceAddress' `
                -DefaultValue ''
        )

        $interfaceAlias = [string](
            Get-SafePropertyValue `
                -InputObject $result `
                -Name 'InterfaceAlias' `
                -DefaultValue ''
        )

        Write-Value -Label 'Відтаклений адрес' -Value $remoteAddress
        Write-Value -Label 'Локальний адрес' -Value $sourceAddress
        Write-Value -Label 'Інтерфейс' -Value $interfaceAlias
        Write-Host ''

        if ($succeeded) {
            Write-Host "[OK] TCP-порт $port доступний на $target." `
                -ForegroundColor Green
        }
        else {
            Write-Host "[FAIL] TCP-порт $port недоступний на $target." `
                -ForegroundColor Red
        }

        return
    }
    catch {
        Write-Host 'Test-NetConnection завершился ошибкой. Используется совместимая проверка.' `
            -ForegroundColor DarkYellow
        Write-Host $_.Exception.Message -ForegroundColor DarkGray
        Write-Host ''
    }
}
else {
    Write-Host 'Test-NetConnection відсутній. Використовується сумісна TCP-перевірка.' `
        -ForegroundColor DarkYellow
    Write-Host ''
}

$tcpResult = Test-TcpPortCompatible `
    -HostName $target `
    -Port $port

Write-Value -Label 'Час перевірки' -Value "$($tcpResult.TimeMs) мс"
Write-Host ''

if ($tcpResult.Success) {
    Write-Host "[OK] TCP-порт $port доступний на $target." -ForegroundColor Green
}
else {
    Write-Host "[FAIL] TCP-порт $port недоступний на $target." -ForegroundColor Red

    if (-not [string]::IsNullOrWhiteSpace($tcpResult.Error)) {
        Write-Host "Причина: $($tcpResult.Error)" -ForegroundColor Yellow
    }
}
