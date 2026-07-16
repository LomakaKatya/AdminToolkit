Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host 'Проверка TCP-подключения' -ForegroundColor Cyan
Write-Host ('=' * 48) -ForegroundColor DarkGray
Write-Host ''

$target = ''

while ([string]::IsNullOrWhiteSpace($target)) {
    $target = (Read-Host 'Введите IP-адрес или имя узла').Trim()

    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host 'Адрес не может быть пустым.' -ForegroundColor Yellow
    }
}

$port = 0

while ($true) {
    $portText = (Read-Host 'Введите TCP-порт (1-65535)').Trim()

    if ([int]::TryParse($portText, [ref]$port) -and
        $port -ge 1 -and
        $port -le 65535) {
        break
    }

    Write-Host 'Порт должен быть числом от 1 до 65535.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "Проверяем $target`:$port..." -ForegroundColor Cyan
Write-Host ''

$testNetConnectionCommand = Get-Command `
    -Name 'Test-NetConnection' `
    -ErrorAction SilentlyContinue

if ($null -ne $testNetConnectionCommand) {
    $result = Test-NetConnection `
        -ComputerName $target `
        -Port $port `
        -InformationLevel Detailed

    Write-Host ''

    if ($result.TcpTestSucceeded) {
        Write-Host "[OK] TCP-порт $port доступен на $target." -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] TCP-порт $port недоступен на $target." -ForegroundColor Red
    }

    return
}

Write-Host 'Test-NetConnection отсутствует. Используется совместимая TCP-проверка.' `
    -ForegroundColor DarkYellow
Write-Host ''

$resolvedAddresses = @()

try {
    $resolvedAddresses = @(
        [System.Net.Dns]::GetHostAddresses($target) |
        ForEach-Object {
            $_.IPAddressToString
        }
    )
}
catch {
    throw "Не удалось определить адрес узла '$target': $($_.Exception.Message)"
}

$tcpClient = $null
$asyncResult = $null
$waitHandle = $null
$stopwatch = New-Object -TypeName System.Diagnostics.Stopwatch
$tcpSucceeded = $false
$errorMessage = $null
$timeoutMilliseconds = 5000

try {
    $tcpClient = New-Object -TypeName System.Net.Sockets.TcpClient

    $stopwatch.Start()

    $asyncResult = $tcpClient.BeginConnect(
        $target,
        $port,
        $null,
        $null
    )

    $waitHandle = $asyncResult.AsyncWaitHandle

    if (-not $waitHandle.WaitOne($timeoutMilliseconds, $false)) {
        $errorMessage = "Истекло время ожидания ($timeoutMilliseconds мс)."
    }
    else {
        try {
            $tcpClient.EndConnect($asyncResult)
            $tcpSucceeded = $tcpClient.Connected
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
    }
}
finally {
    $stopwatch.Stop()

    if ($null -ne $waitHandle) {
        $waitHandle.Close()
    }

    if ($null -ne $tcpClient) {
        $tcpClient.Close()
    }
}

Write-Host "Узел:              $target"
Write-Host "Разрешённый адрес: $($resolvedAddresses -join ', ')"
Write-Host "TCP-порт:          $port"
Write-Host "Время проверки:    $($stopwatch.ElapsedMilliseconds) мс"
Write-Host ''

if ($tcpSucceeded) {
    Write-Host "[OK] TCP-порт $port доступен на $target." -ForegroundColor Green
}
else {
    Write-Host "[FAIL] TCP-порт $port недоступен на $target." -ForegroundColor Red

    if (-not [string]::IsNullOrWhiteSpace($errorMessage)) {
        Write-Host "Причина: $errorMessage" -ForegroundColor Yellow
    }
}
