Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Section {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Value {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [AllowEmptyString()]
        [string]$Value,

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
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$List,

        [Parameter(Mandatory)]
        [string]$Text
    )

    [void]$List.Add($Text)
}

function Get-SafePropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$DefaultValue = $null
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

function Get-PrinterStatusText {
    param(
        [int]$Code
    )

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
    param(
        [int]$Code
    )

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

function Get-ShortText {
    param(
        [string]$Text,
        [int]$MaxLength = 100
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

function Test-PingHost {
    param(
        [Parameter(Mandatory)]
        [string]$HostName,

        [int]$TimeoutMilliseconds = 1200
    )

    $ping = New-Object -TypeName System.Net.NetworkInformation.Ping

    try {
        $reply = $ping.Send($HostName, $TimeoutMilliseconds)
        $success =
            $reply.Status -eq
            [System.Net.NetworkInformation.IPStatus]::Success

        return [pscustomobject]@{
            Success = $success
            TimeMs  = if ($success) {
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
        [Parameter(Mandatory)]
        [string]$HostName,

        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutMilliseconds = 2500
    )

    $client = $null
    $asyncResult = $null
    $waitHandle = $null
    $stopwatch = New-Object -TypeName System.Diagnostics.Stopwatch

    try {
        $client = New-Object -TypeName System.Net.Sockets.TcpClient
        $stopwatch.Start()

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
                TimeMs  = [int]$stopwatch.ElapsedMilliseconds
                Error   = 'тайм-аут'
            }
        }

        $client.EndConnect($asyncResult)

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

Write-Host ''
Write-Host 'Диагностика печати' -ForegroundColor Cyan
Write-Host 'Собираю состояние очереди, драйвера, порта и службы печати...' `
    -ForegroundColor DarkGray

$issues = New-Object -TypeName System.Collections.ArrayList
$warnings = New-Object -TypeName System.Collections.ArrayList

$spooler = Get-Service `
    -Name 'Spooler' `
    -ErrorAction SilentlyContinue

$printers = @()
$printerQueryError = ''

try {
    $printers = @(
        Get-WmiObject `
            -Class Win32_Printer `
            -ErrorAction Stop |
        Sort-Object `
            -Property @{
                Expression = {
                    -not [bool](
                        Get-SafePropertyValue `
                            -InputObject $_ `
                            -Name 'Default' `
                            -DefaultValue $false
                    )
                }
            }, Name
    )
}
catch {
    $printerQueryError = $_.Exception.Message
}

Write-Section -Title 'СЛУЖБА ПЕЧАТИ'

if ($null -eq $spooler) {
    Write-Value `
        -Label 'Print Spooler' `
        -Value 'служба не найдена' `
        -Color Red

    Add-Issue `
        -List $issues `
        -Text 'Служба Print Spooler не найдена.'
}
elseif ($spooler.Status -eq 'Running') {
    Write-Value `
        -Label 'Print Spooler' `
        -Value 'работает' `
        -Color Green
}
else {
    Write-Value `
        -Label 'Print Spooler' `
        -Value "не запущена ($($spooler.Status))" `
        -Color Red

    Add-Issue `
        -List $issues `
        -Text 'Служба Print Spooler не запущена.'
}

if ($printers.Count -eq 0) {
    Write-Section -Title 'ПРИНТЕРЫ'

    if (-not [string]::IsNullOrWhiteSpace($printerQueryError)) {
        Write-Host '[FAIL] Не удалось получить список принтеров.' `
            -ForegroundColor Red
        Write-Host $printerQueryError -ForegroundColor Yellow
    }
    else {
        Write-Host '[FAIL] В системе не найдено ни одного принтера.' `
            -ForegroundColor Red
    }

    if ($null -ne $spooler -and $spooler.Status -ne 'Running') {
        Write-Host 'Сначала запусти службу Print Spooler и повтори проверку.' `
            -ForegroundColor Yellow
    }

    return
}

Write-Section -Title 'ВЫБОР ПРИНТЕРА'

for ($index = 0; $index -lt $printers.Count; $index++) {
    $printer = $printers[$index]
    $markers = @()

    $isDefault = [bool](
        Get-SafePropertyValue `
            -InputObject $printer `
            -Name 'Default' `
            -DefaultValue $false
    )

    $isOffline = [bool](
        Get-SafePropertyValue `
            -InputObject $printer `
            -Name 'WorkOffline' `
            -DefaultValue $false
    )

    $isShared = [bool](
        Get-SafePropertyValue `
            -InputObject $printer `
            -Name 'Shared' `
            -DefaultValue $false
    )

    if ($isDefault) {
        $markers += 'по умолчанию'
    }

    if ($isOffline) {
        $markers += 'офлайн'
    }

    if ($isShared) {
        $markers += 'общий'
    }

    $markerText = ''

    if ($markers.Count -gt 0) {
        $markerText = ' [' + ($markers -join ', ') + ']'
    }

    $printerName = [string](
        Get-SafePropertyValue `
            -InputObject $printer `
            -Name 'Name' `
            -DefaultValue 'без имени'
    )

    Write-Host (
        "  {0}. {1}{2}" -f
        ($index + 1),
        $printerName,
        $markerText
    )
}

Write-Host ''

$defaultIndex = 1

for ($index = 0; $index -lt $printers.Count; $index++) {
    $isDefault = [bool](
        Get-SafePropertyValue `
            -InputObject $printers[$index] `
            -Name 'Default' `
            -DefaultValue $false
    )

    if ($isDefault) {
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

$printerName = [string](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'Name' `
        -DefaultValue ''
)

$driverName = [string](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'DriverName' `
        -DefaultValue ''
)

$portName = [string](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'PortName' `
        -DefaultValue ''
)

$printerStatus = [int](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'PrinterStatus' `
        -DefaultValue 0
)

$errorState = [int](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'DetectedErrorState' `
        -DefaultValue 0
)

$workOffline = [bool](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'WorkOffline' `
        -DefaultValue $false
)

$pausedRaw = Get-SafePropertyValue `
    -InputObject $selectedPrinter `
    -Name 'Paused' `
    -DefaultValue $null

$pausedKnown = $null -ne $pausedRaw
$isPaused = $false

if ($pausedKnown) {
    $isPaused = [bool]$pausedRaw
}

$isDefault = [bool](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'Default' `
        -DefaultValue $false
)

$isShared = [bool](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'Shared' `
        -DefaultValue $false
)

$shareName = [string](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'ShareName' `
        -DefaultValue ''
)

$comment = [string](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'Comment' `
        -DefaultValue ''
)

$location = [string](
    Get-SafePropertyValue `
        -InputObject $selectedPrinter `
        -Name 'Location' `
        -DefaultValue ''
)

$statusText = Get-PrinterStatusText -Code $printerStatus
$errorText = Get-ErrorStateText -Code $errorState

Write-Section -Title 'СОСТОЯНИЕ ПРИНТЕРА'

Write-Value -Label 'Имя' -Value $printerName -Color Cyan
Write-Value -Label 'Драйвер' -Value $driverName
Write-Value -Label 'Порт' -Value $portName

$statusColor = [ConsoleColor]::Yellow

if ($printerStatus -in @(3, 4, 5)) {
    $statusColor = [ConsoleColor]::Green
}
elseif ($printerStatus -in @(6, 7)) {
    $statusColor = [ConsoleColor]::Red
}

Write-Value `
    -Label 'Состояние' `
    -Value $statusText `
    -Color $statusColor

$errorColor = [ConsoleColor]::DarkGray

if ($errorState -eq 2) {
    $errorColor = [ConsoleColor]::Green
}
elseif ($errorState -in @(3, 5)) {
    $errorColor = [ConsoleColor]::Yellow
}
elseif ($errorState -ge 4) {
    $errorColor = [ConsoleColor]::Red
}

Write-Value `
    -Label 'Ошибка устройства' `
    -Value $errorText `
    -Color $errorColor

Write-Value `
    -Label 'Работа офлайн' `
    -Value $(if ($workOffline) { 'да' } else { 'нет' }) `
    -Color $(if ($workOffline) {
        [ConsoleColor]::Red
    }
    else {
        [ConsoleColor]::Green
    })

if ($pausedKnown) {
    Write-Value `
        -Label 'Приостановлен' `
        -Value $(if ($isPaused) { 'да' } else { 'нет' }) `
        -Color $(if ($isPaused) {
            [ConsoleColor]::Red
        }
        else {
            [ConsoleColor]::Green
        })
}
else {
    Write-Value `
        -Label 'Приостановлен' `
        -Value 'не сообщается этим драйвером' `
        -Color DarkGray
}

Write-Value `
    -Label 'По умолчанию' `
    -Value $(if ($isDefault) { 'да' } else { 'нет' })

Write-Value `
    -Label 'Общий доступ' `
    -Value $(if ($isShared) {
        if ([string]::IsNullOrWhiteSpace($shareName)) {
            'да'
        }
        else {
            "да, $shareName"
        }
    }
    else {
        'нет'
    })

Write-Value -Label 'Комментарий' -Value $comment
Write-Value -Label 'Расположение' -Value $location

if ($workOffline) {
    Add-Issue `
        -List $issues `
        -Text 'В Windows включён режим работы принтера офлайн.'
}

if ($pausedKnown -and $isPaused) {
    Add-Issue `
        -List $issues `
        -Text 'Печать на принтере приостановлена.'
}

if ($printerStatus -in @(6, 7)) {
    Add-Issue `
        -List $issues `
        -Text "Принтер сообщает состояние: $statusText."
}

if ($errorState -ge 4 -and $errorState -ne 5) {
    Add-Issue `
        -List $issues `
        -Text "Устройство сообщает ошибку: $errorText."
}
elseif ($errorState -in @(3, 5)) {
    [void]$warnings.Add("Устройство сообщает: $errorText.")
}

Write-Section -Title 'ОЧЕРЕДЬ ПЕЧАТИ'

$allJobs = @(
    Get-WmiObject `
        -Class Win32_PrintJob `
        -ErrorAction SilentlyContinue
)

$jobs = @(
    $allJobs |
    Where-Object {
        $jobName = [string](
            Get-SafePropertyValue `
                -InputObject $_ `
                -Name 'Name' `
                -DefaultValue ''
        )

        $jobName.StartsWith($printerName + ',')
    }
)

Write-Value `
    -Label 'Заданий в очереди' `
    -Value ([string]$jobs.Count) `
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
        $jobId = Get-SafePropertyValue `
            -InputObject $job `
            -Name 'JobId' `
            -DefaultValue '?'

        $document = [string](
            Get-SafePropertyValue `
                -InputObject $job `
                -Name 'Document' `
                -DefaultValue 'без имени'
        )

        $owner = [string](
            Get-SafePropertyValue `
                -InputObject $job `
                -Name 'Owner' `
                -DefaultValue 'неизвестно'
        )

        $status = [string](
            Get-SafePropertyValue `
                -InputObject $job `
                -Name 'Status' `
                -DefaultValue ''
        )

        $jobStatus = [string](
            Get-SafePropertyValue `
                -InputObject $job `
                -Name 'JobStatus' `
                -DefaultValue ''
        )

        $jobState = ($status + ' ' + $jobStatus).Trim()

        $badStatePattern =
            '(?i)error|paused|offline|deleting|blocked|' +
            'ошиб|приост|удален|офлайн'

        $jobColor = if ($jobState -match $badStatePattern) {
            [ConsoleColor]::Red
        }
        else {
            [ConsoleColor]::Yellow
        }

        Write-Host (
            "  #{0,-5} {1}" -f
            $jobId,
            (Get-ShortText -Text $document -MaxLength 50)
        ) -ForegroundColor $jobColor

        Write-Host (
            "           Владелец: {0}; статус: {1}" -f
            $owner,
            (Get-ShortText -Text $jobState -MaxLength 70)
        ) -ForegroundColor DarkGray
    }

    $badJobs = @(
        $jobs |
        Where-Object {
            $status = [string](
                Get-SafePropertyValue `
                    -InputObject $_ `
                    -Name 'Status' `
                    -DefaultValue ''
            )

            $jobStatus = [string](
                Get-SafePropertyValue `
                    -InputObject $_ `
                    -Name 'JobStatus' `
                    -DefaultValue ''
            )

            ($status + ' ' + $jobStatus) -match
                '(?i)error|paused|offline|deleting|blocked|ошиб|приост|удален|офлайн'
        }
    )

    if ($badJobs.Count -gt 0) {
        Add-Issue `
            -List $issues `
            -Text 'В очереди есть задания с ошибкой или зависшим состоянием.'
    }
    else {
        [void]$warnings.Add(
            'В очереди есть ожидающие задания. Возможно, печать остановилась до отправки на устройство.'
        )
    }
}

Write-Section -Title 'ПОРТ И СЕТЕВОЕ ПОДКЛЮЧЕНИЕ'

$networkHost = ''
$networkPort = 0
$portType = 'локальный или неизвестный'

$tcpPort = Get-WmiObject `
    -Class Win32_TCPIPPrinterPort `
    -Filter ("Name='{0}'" -f ($portName -replace "'", "''")) `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($null -ne $tcpPort) {
    $networkHost = [string](
        Get-SafePropertyValue `
            -InputObject $tcpPort `
            -Name 'HostAddress' `
            -DefaultValue ''
    )

    $networkPort = [int](
        Get-SafePropertyValue `
            -InputObject $tcpPort `
            -Name 'PortNumber' `
            -DefaultValue 0
    )

    $protocol = [int](
        Get-SafePropertyValue `
            -InputObject $tcpPort `
            -Name 'Protocol' `
            -DefaultValue 1
    )

    $portType = if ($protocol -eq 2) {
        if ($networkPort -le 0) {
            $networkPort = 515
        }

        'Standard TCP/IP, LPR'
    }
    else {
        if ($networkPort -le 0) {
            $networkPort = 9100
        }

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
    Write-Value `
        -Label 'Адрес устройства' `
        -Value $networkHost `
        -Color Cyan

    Write-Value `
        -Label 'Проверяемый TCP-порт' `
        -Value ([string]$networkPort)

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

        [void]$warnings.Add(
            'Сетевой принтер не отвечает на ping. ICMP может быть запрещён, поэтому проверяем порт.'
        )
    }

    if ($networkPort -gt 0) {
        $tcpResult = Test-TcpPort `
            -HostName $networkHost `
            -Port $networkPort

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
$checkedPrintLogs = 0

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

            $checkedPrintLogs++
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

if ($checkedPrintLogs -eq 0) {
    Write-Host '[INFO] Журналы PrintService недоступны или отключены.' `
        -ForegroundColor DarkGray
}
elseif ($printEvents.Count -eq 0) {
    Write-Host '[OK] За последние 24 часа явных ошибок PrintService не найдено.' `
        -ForegroundColor Green
}
else {
    foreach ($event in $printEvents) {
        $timeCreated = Get-SafePropertyValue `
            -InputObject $event `
            -Name 'TimeCreated' `
            -DefaultValue $null

        $eventTime = if ($null -ne $timeCreated) {
            $timeCreated.ToString('dd.MM HH:mm')
        }
        else {
            'время неизвестно'
        }

        $eventId = Get-SafePropertyValue `
            -InputObject $event `
            -Name 'Id' `
            -DefaultValue '?'

        $message = [string](
            Get-SafePropertyValue `
                -InputObject $event `
                -Name 'Message' `
                -DefaultValue ''
        )

        Write-Host (
            "[{0}] ID {1}: {2}" -f
            $eventTime,
            $eventId,
            (Get-ShortText -Text $message)
        ) -ForegroundColor Yellow
    }

    [void]$warnings.Add(
        'В журналах PrintService есть недавние предупреждения или ошибки.'
    )
}

Write-Section -Title 'ИТОГ'

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host '[OK] Явных проблем в Windows не обнаружено.' `
        -ForegroundColor Green

    Write-Host (
        'Если печати всё равно нет, проверь бумагу, тонер, экран ' +
        'самого принтера и тестовую страницу устройства.'
    ) -ForegroundColor DarkGray
}
else {
    foreach ($issue in $issues) {
        Write-Host "[FAIL] $issue" -ForegroundColor Red
    }

    foreach ($warning in $warnings) {
        Write-Host "[WARN] $warning" -ForegroundColor Yellow
    }

    if ($issues.Count -eq 0) {
        Write-Host (
            '[INFO] Критичных ошибок не видно, но есть пункты для проверки.'
        ) -ForegroundColor Cyan
    }
}
