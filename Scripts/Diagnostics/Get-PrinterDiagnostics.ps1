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

function Get-PrinterStatusText {
    param([int]$Code)

    $map = @{
        1 = 'другое'
        2 = 'неизвестно'
        3 = 'готов'
        4 = 'печатает'
        5 = 'прогрев'
        6 = 'остановлен'
        7 = 'офлайн'
    }

    if ($map.ContainsKey($Code)) {
        return $map[$Code]
    }

    return "код $Code"
}

function Get-ErrorStateText {
    param([int]$Code)

    $map = @{
        0  = 'неизвестно'
        1  = 'другое'
        2  = 'ошибок нет'
        3  = 'мало бумаги'
        4  = 'нет бумаги'
        5  = 'мало тонера'
        6  = 'нет тонера'
        7  = 'открыта крышка'
        8  = 'замятие бумаги'
        9  = 'офлайн'
        10 = 'требуется обслуживание'
        11 = 'выходной лоток заполнен'
    }

    if ($map.ContainsKey($Code)) {
        return $map[$Code]
    }

    return "код $Code"
}

function Test-PingHost {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$TimeoutMilliseconds = 1200
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
        [int]$TimeoutMilliseconds = 2500
    )

    $client = $null
    $async = $null
    $waitHandle = $null
    $stopwatch = New-Object -TypeName System.Diagnostics.Stopwatch

    try {
        $client = New-Object -TypeName System.Net.Sockets.TcpClient
        $stopwatch.Start()

        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        $waitHandle = $async.AsyncWaitHandle

        if (-not $waitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return [pscustomobject]@{
                Success = $false
                TimeMs  = [int]$stopwatch.ElapsedMilliseconds
                Error   = 'тайм-аут'
            }
        }

        $client.EndConnect($async)

        return [pscustomobject]@{
            Success = $client.Connected
            TimeMs  = [int]$stopwatch.ElapsedMilliseconds
            Error   = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            TimeMs  = [int]$stopwatch.ElapsedMilliseconds
            Error   = $_.Exception.Message
        }
    }
    finally {
        $stopwatch.Stop()

        if ($null -ne $waitHandle) {
            $waitHandle.Close()
        }

        if ($null -ne $client) {
            $client.Close()
        }
    }
}

function Get-ShortText {
    param(
        [string]$Text,
        [int]$MaxLength = 110
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $clean = ($Text -replace '\s+', ' ').Trim()

    if ($clean.Length -le $MaxLength) {
        return $clean
    }

    return $clean.Substring(0, $MaxLength - 3) + '...'
}

Write-Host ''
Write-Host 'Диагностика печати' -ForegroundColor Cyan
Write-Host 'Собираю состояние очереди, драйвера, порта и службы печати...' `
    -ForegroundColor DarkGray

$issues = New-Object -TypeName System.Collections.ArrayList
$warnings = New-Object -TypeName System.Collections.ArrayList

$spooler = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
$printers = @(
    Get-WmiObject -Class Win32_Printer -ErrorAction Stop |
    Sort-Object -Property @{ Expression = { -not [bool]$_.Default } }, Name
)

Write-Section -Title 'СЛУЖБА ПЕЧАТИ'

if ($null -eq $spooler) {
    Write-Value -Label 'Print Spooler' -Value 'служба не найдена' -Color Red
    Add-Issue -List $issues -Text 'Служба Print Spooler не найдена.'
}
elseif ($spooler.Status -eq 'Running') {
    Write-Value -Label 'Print Spooler' -Value 'работает' -Color Green
}
else {
    Write-Value `
        -Label 'Print Spooler' `
        -Value "не запущена ($($spooler.Status))" `
        -Color Red

    Add-Issue -List $issues -Text 'Служба Print Spooler не запущена.'
}

if ($printers.Count -eq 0) {
    Write-Section -Title 'ПРИНТЕРЫ'
    Write-Host '[FAIL] В системе не найдено ни одного принтера.' `
        -ForegroundColor Red
    Add-Issue -List $issues -Text 'В системе не установлены принтеры.'

    Write-Section -Title 'ИТОГ'

    foreach ($issue in $issues) {
        Write-Host "[FAIL] $issue" -ForegroundColor Red
    }

    return
}

Write-Section -Title 'ВЫБОР ПРИНТЕРА'

for ($index = 0; $index -lt $printers.Count; $index++) {
    $printer = $printers[$index]
    $markers = @()

    if ([bool]$printer.Default) {
        $markers += 'по умолчанию'
    }

    if ([bool]$printer.WorkOffline) {
        $markers += 'офлайн'
    }

    if ([bool]$printer.Shared) {
        $markers += 'общий'
    }

    $markerText = ''

    if ($markers.Count -gt 0) {
        $markerText = ' [' + ($markers -join ', ') + ']'
    }

    Write-Host ("  {0}. {1}{2}" -f ($index + 1), $printer.Name, $markerText)
}

Write-Host ''

$defaultIndex = 1

for ($index = 0; $index -lt $printers.Count; $index++) {
    if ([bool]$printers[$index].Default) {
        $defaultIndex = $index + 1
        break
    }
}

$selectionText = Read-Host "Выбери принтер [Enter = $defaultIndex]"
$selection = $defaultIndex

if (-not [string]::IsNullOrWhiteSpace($selectionText)) {
    if (-not [int]::TryParse($selectionText, [ref]$selection) -or
        $selection -lt 1 -or
        $selection -gt $printers.Count) {
        throw "Номер принтера должен быть от 1 до $($printers.Count)."
    }
}

$selectedPrinter = $printers[$selection - 1]

Write-Section -Title 'СОСТОЯНИЕ ПРИНТЕРА'

$statusText = Get-PrinterStatusText -Code ([int]$selectedPrinter.PrinterStatus)
$errorText = Get-ErrorStateText -Code ([int]$selectedPrinter.DetectedErrorState)

Write-Value -Label 'Имя' -Value ([string]$selectedPrinter.Name) -Color Cyan
Write-Value -Label 'Драйвер' -Value ([string]$selectedPrinter.DriverName)
Write-Value -Label 'Порт' -Value ([string]$selectedPrinter.PortName)
Write-Value -Label 'Состояние' -Value $statusText `
    -Color $(if ([int]$selectedPrinter.PrinterStatus -in @(3, 4, 5)) {
        [ConsoleColor]::Green
    }
    elseif ([int]$selectedPrinter.PrinterStatus -in @(6, 7)) {
        [ConsoleColor]::Red
    }
    else {
        [ConsoleColor]::Yellow
    })

Write-Value -Label 'Ошибка устройства' -Value $errorText `
    -Color $(if ([int]$selectedPrinter.DetectedErrorState -eq 2) {
        [ConsoleColor]::Green
    }
    elseif ([int]$selectedPrinter.DetectedErrorState -in @(3, 5)) {
        [ConsoleColor]::Yellow
    }
    elseif ([int]$selectedPrinter.DetectedErrorState -ge 4) {
        [ConsoleColor]::Red
    }
    else {
        [ConsoleColor]::DarkGray
    })

Write-Value -Label 'Работа офлайн' `
    -Value $(if ([bool]$selectedPrinter.WorkOffline) { 'да' } else { 'нет' }) `
    -Color $(if ([bool]$selectedPrinter.WorkOffline) {
        [ConsoleColor]::Red
    }
    else {
        [ConsoleColor]::Green
    })

Write-Value -Label 'Приостановлен' `
    -Value $(if ([bool]$selectedPrinter.Paused) { 'да' } else { 'нет' }) `
    -Color $(if ([bool]$selectedPrinter.Paused) {
        [ConsoleColor]::Red
    }
    else {
        [ConsoleColor]::Green
    })

Write-Value -Label 'По умолчанию' `
    -Value $(if ([bool]$selectedPrinter.Default) { 'да' } else { 'нет' })

Write-Value -Label 'Общий доступ' `
    -Value $(if ([bool]$selectedPrinter.Shared) {
        "да, $($selectedPrinter.ShareName)"
    }
    else {
        'нет'
    })

Write-Value -Label 'Комментарий' -Value ([string]$selectedPrinter.Comment)
Write-Value -Label 'Расположение' -Value ([string]$selectedPrinter.Location)

if ([bool]$selectedPrinter.WorkOffline) {
    Add-Issue -List $issues -Text 'В Windows включён режим работы принтера офлайн.'
}

if ([bool]$selectedPrinter.Paused) {
    Add-Issue -List $issues -Text 'Печать на принтере приостановлена.'
}

if ([int]$selectedPrinter.PrinterStatus -in @(6, 7)) {
    Add-Issue -List $issues -Text "Принтер сообщает состояние: $statusText."
}

if ([int]$selectedPrinter.DetectedErrorState -ge 4 -and
    [int]$selectedPrinter.DetectedErrorState -ne 5) {
    Add-Issue -List $issues -Text "Устройство сообщает ошибку: $errorText."
}
elseif ([int]$selectedPrinter.DetectedErrorState -in @(3, 5)) {
    [void]$warnings.Add("Устройство сообщает: $errorText.")
}

Write-Section -Title 'ОЧЕРЕДЬ ПЕЧАТИ'

$allJobs = @(
    Get-WmiObject -Class Win32_PrintJob -ErrorAction SilentlyContinue
)

$jobs = @(
    $allJobs |
    Where-Object {
        ([string]$_.Name).StartsWith(([string]$selectedPrinter.Name) + ',')
    }
)

Write-Value -Label 'Заданий в очереди' -Value ([string]$jobs.Count) `
    -Color $(if ($jobs.Count -eq 0) {
        [ConsoleColor]::Green
    }
    elseif ($jobs.Count -le 3) {
        [ConsoleColor]::Yellow
    }
    else {
        [ConsoleColor]::Red
    })

if ($jobs.Count -eq 0) {
    Write-Host ''
    Write-Host '[OK] Очередь пуста.' -ForegroundColor Green
}
else {
    Write-Host ''

    foreach ($job in $jobs | Select-Object -First 10) {
        $jobState = @(
            [string]$job.Status,
            [string]$job.JobStatus
        ) -join ' '

        $jobColor = if ($jobState -match '(?i)error|paused|offline|deleting|blocked|ошиб|приост|удален|офлайн') {
            [ConsoleColor]::Red
        }
        else {
            [ConsoleColor]::Yellow
        }

        Write-Host ("  #{0,-5} {1}" -f $job.JobId, (Get-ShortText -Text ([string]$job.Document) -MaxLength 50)) `
            -ForegroundColor $jobColor

        Write-Host ("           Владелец: {0}; статус: {1}" -f `
            $job.Owner,
            (Get-ShortText -Text $jobState -MaxLength 70)) `
            -ForegroundColor DarkGray
    }

    if ($jobs.Count -gt 10) {
        Write-Host "  Показаны первые 10 из $($jobs.Count) заданий." `
            -ForegroundColor DarkGray
    }

    $badJobs = @(
        $jobs |
        Where-Object {
            (([string]$_.Status + ' ' + [string]$_.JobStatus) -match `
                '(?i)error|paused|offline|deleting|blocked|ошиб|приост|удален|офлайн')
        }
    )

    if ($badJobs.Count -gt 0) {
        Add-Issue -List $issues -Text 'В очереди есть задания с ошибкой или зависшим состоянием.'
    }
    else {
        [void]$warnings.Add('В очереди есть ожидающие задания. Возможно, печать остановилась до отправки на устройство.')
    }
}

Write-Section -Title 'ПОРТ И СЕТЕВОЕ ПОДКЛЮЧЕНИЕ'

$portName = [string]$selectedPrinter.PortName
$networkHost = ''
$networkPort = 0
$portType = 'локальный или неизвестный'

$tcpPort = Get-WmiObject `
    -Class Win32_TCPIPPrinterPort `
    -Filter ("Name='{0}'" -f ($portName -replace "'", "''")) `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($null -ne $tcpPort) {
    $networkHost = [string]$tcpPort.HostAddress
    $networkPort = [int]$tcpPort.PortNumber
    $portType = if ([int]$tcpPort.Protocol -eq 2) {
        'Standard TCP/IP, LPR'
    }
    else {
        'Standard TCP/IP, RAW'
    }
}
elseif ($portName -match '^\\\\([^\\]+)\\') {
    $networkHost = $matches[1]
    $networkPort = 445
    $portType = 'общий принтер Windows'
}
elseif ($portName -match '(?i)^IP_(\d{1,3}(?:\.\d{1,3}){3})') {
    $networkHost = $matches[1]
    $networkPort = 9100
    $portType = 'предположительно RAW TCP/IP'
}
elseif ($portName -match '^(\d{1,3}(?:\.\d{1,3}){3})') {
    $networkHost = $matches[1]
    $networkPort = 9100
    $portType = 'предположительно RAW TCP/IP'
}

Write-Value -Label 'Тип порта' -Value $portType
Write-Value -Label 'Имя порта' -Value $portName

if (-not [string]::IsNullOrWhiteSpace($networkHost)) {
    Write-Value -Label 'Адрес устройства' -Value $networkHost -Color Cyan
    Write-Value -Label 'Проверяемый TCP-порт' -Value ([string]$networkPort)

    $pingResult = Test-PingHost -HostName $networkHost

    if ($pingResult.Success) {
        Write-Value `
            -Label 'Ping' `
            -Value "доступен, $($pingResult.TimeMs) мс" `
            -Color Green
    }
    else {
        Write-Value `
            -Label 'Ping' `
            -Value "нет ответа ($($pingResult.Status))" `
            -Color Yellow

        [void]$warnings.Add('Сетевой принтер не отвечает на ping. ICMP может быть запрещён, поэтому проверяем порт.')
    }

    if ($networkPort -gt 0) {
        $tcpResult = Test-TcpPort -HostName $networkHost -Port $networkPort

        if ($tcpResult.Success) {
            Write-Value `
                -Label 'TCP-подключение' `
                -Value "порт $networkPort открыт, $($tcpResult.TimeMs) мс" `
                -Color Green
        }
        else {
            Write-Value `
                -Label 'TCP-подключение' `
                -Value "порт $networkPort недоступен ($($tcpResult.Error))" `
                -Color Red

            Add-Issue `
                -List $issues `
                -Text "Сетевой порт принтера $networkHost`:$networkPort недоступен."
        }
    }
}
else {
    Write-Host ''
    Write-Host '[INFO] Это USB, виртуальный либо нестандартный локальный порт.' `
        -ForegroundColor DarkGray
}

Write-Section -Title 'ПОСЛЕДНИЕ ОШИБКИ ПЕЧАТИ'

$printEvents = @()

if (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue) {
    $since = (Get-Date).AddDays(-1)

    foreach ($logName in @(
        'Microsoft-Windows-PrintService/Admin',
        'Microsoft-Windows-PrintService/Operational'
    )) {
        try {
            $events = @(
                Get-WinEvent `
                    -FilterHashtable @{
                        LogName   = $logName
                        StartTime = $since
                        Level     = @(2, 3)
                    } `
                    -MaxEvents 10 `
                    -ErrorAction Stop
            )

            $printEvents += $events
        }
        catch {
        }
    }
}

$printEvents = @(
    $printEvents |
    Sort-Object -Property TimeCreated -Descending |
    Select-Object -First 5
)

if ($printEvents.Count -eq 0) {
    Write-Host '[OK] За последние 24 часа явных ошибок PrintService не найдено.' `
        -ForegroundColor Green
}
else {
    foreach ($event in $printEvents) {
        Write-Host ("[{0}] ID {1}: {2}" -f `
            $event.TimeCreated.ToString('dd.MM HH:mm'),
            $event.Id,
            (Get-ShortText -Text ([string]$event.Message))) `
            -ForegroundColor Yellow
    }

    [void]$warnings.Add('В журналах PrintService есть недавние предупреждения или ошибки.')
}

Write-Section -Title 'ИТОГ'

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host '[OK] Явных проблем в Windows не обнаружено.' `
        -ForegroundColor Green
    Write-Host 'Если печати всё равно нет, проверь бумагу, тонер, экран самого принтера и тестовую страницу устройства.' `
        -ForegroundColor DarkGray
}
else {
    foreach ($issue in $issues) {
        Write-Host "[FAIL] $issue" -ForegroundColor Red
    }

    foreach ($warning in $warnings) {
        Write-Host "[WARN] $warning" -ForegroundColor Yellow
    }

    if ($issues.Count -eq 0) {
        Write-Host '[INFO] Критичных ошибок не видно, но есть пункты для проверки.' `
            -ForegroundColor Cyan
    }
}
