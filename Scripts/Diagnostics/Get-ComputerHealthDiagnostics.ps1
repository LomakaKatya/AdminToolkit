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

function Get-ShortText {
    param(
        [string]$Text,
        [int]$MaxLength = 105
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

function Get-PercentColor {
    param(
        [double]$Value,
        [double]$Warning,
        [double]$Critical
    )

    if ($Value -ge $Critical) {
        return [ConsoleColor]::Red
    }

    if ($Value -ge $Warning) {
        return [ConsoleColor]::Yellow
    }

    return [ConsoleColor]::Green
}

function Get-DeviceStateInfo {
    param(
        [int]$Code
    )

    switch ($Code) {
        22 {
            return [pscustomobject]@{
                Severity = 'Info'
                Color    = [ConsoleColor]::DarkGray
                Text     = 'пристрій вимкнено'
            }
        }

        45 {
            return [pscustomobject]@{
                Severity = 'Info'
                Color    = [ConsoleColor]::DarkGray
                Text     = 'пристрій зараз не підключено'
            }
        }

        { $_ -in @(14, 18, 21, 24) } {
            return [pscustomobject]@{
                Severity = 'Warning'
                Color    = [ConsoleColor]::Yellow
                Text     = 'стан потребує перевірки'
            }
        }

        default {
            return [pscustomobject]@{
                Severity = 'Failure'
                Color    = [ConsoleColor]::Red
                Text     = 'помилка пристрою або драйвера'
            }
        }
    }
}

function Get-TopCpuProcesses {
    param(
        [int]$SampleSeconds = 2,
        [int]$LogicalProcessors = 1
    )

    $before = @{}

    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        try {
            $before[[int]$process.Id] = [pscustomobject]@{
                Name = [string]$process.ProcessName
                CPU  = [double]$process.CPU
            }
        }
        catch {
        }
    }

    $watch = New-Object -TypeName System.Diagnostics.Stopwatch
    $watch.Start()
    Start-Sleep -Seconds $SampleSeconds
    $watch.Stop()

    $elapsed = [Math]::Max($watch.Elapsed.TotalSeconds, 0.1)
    $result = @()

    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        try {
            $id = [int]$process.Id

            if (-not $before.ContainsKey($id)) {
                continue
            }

            $delta = [double]$process.CPU - [double]$before[$id].CPU

            if ($delta -lt 0) {
                continue
            }

            $cpuPercent = ($delta / $elapsed / [Math]::Max($LogicalProcessors, 1)) * 100

            $result += [pscustomobject]@{
                Name       = [string]$process.ProcessName
                Id         = $id
                CpuPercent = [Math]::Round($cpuPercent, 1)
                MemoryMB   = [Math]::Round(([double]$process.WorkingSet64 / 1MB), 1)
            }
        }
        catch {
        }
    }

    return @(
        $result |
        Sort-Object -Property CpuPercent -Descending |
        Select-Object -First 10
    )
}

Write-Host ''
Write-Host 'Діагностика зависань і продуктивності ПК' `
    -ForegroundColor Cyan
Write-Host 'Знімок займає кілька секунд: вимірюю CPU, пам’ять, диски та процеси...' `
    -ForegroundColor DarkGray

$issues = New-Object -TypeName System.Collections.ArrayList
$warnings = New-Object -TypeName System.Collections.ArrayList

$os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
$computer = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
$processors = @(Get-WmiObject -Class Win32_Processor -ErrorAction Stop)
$logicalProcessors = [int]$computer.NumberOfLogicalProcessors

if ($logicalProcessors -lt 1) {
    $logicalProcessors = @(
        $processors |
        Measure-Object -Property NumberOfLogicalProcessors -Sum
    )[0].Sum
}

if ($logicalProcessors -lt 1) {
    $logicalProcessors = 1
}

$lastBoot = [Management.ManagementDateTimeConverter]::ToDateTime(
    [string]$os.LastBootUpTime
)

$uptime = (Get-Date) - $lastBoot
$totalMemoryGB = [Math]::Round(([double]$os.TotalVisibleMemorySize / 1MB), 1)
$freeMemoryGB = [Math]::Round(([double]$os.FreePhysicalMemory / 1MB), 1)
$usedMemoryPercent = [Math]::Round(
    (([double]$os.TotalVisibleMemorySize - [double]$os.FreePhysicalMemory) /
        [Math]::Max([double]$os.TotalVisibleMemorySize, 1)) * 100,
    1
)

$cpuLoads = @(
    $processors |
    Where-Object { $null -ne $_.LoadPercentage } |
    Select-Object -ExpandProperty LoadPercentage
)

$cpuLoad = 0

if ($cpuLoads.Count -gt 0) {
    $cpuLoad = [Math]::Round(
        (
            $cpuLoads |
            Measure-Object -Average
        ).Average,
        1
    )
}

Write-Section -Title 'ЗАГАЛЬНИЙ СТАН'

Write-Value -Label 'Комп’ютер' -Value ([string]$computer.Name) -Color Cyan
Write-Value -Label 'ОС' -Value ("{0} {1}" -f $os.Caption, $os.OSArchitecture)
Write-Value -Label 'Останнє завантаження' -Value $lastBoot.ToString('dd.MM.yyyy HH:mm')
Write-Value `
    -Label 'Час роботи' `
    -Value ("{0} дн. {1} ч. {2} хв." -f `
        [int]$uptime.TotalDays,
        $uptime.Hours,
        $uptime.Minutes)

Write-Value -Label 'Логічних процесорів' -Value ([string]$logicalProcessors)
Write-Value `
    -Label 'Поточне завантаження CPU' `
    -Value ("{0}%" -f $cpuLoad) `
    -Color (Get-PercentColor -Value $cpuLoad -Warning 60 -Critical 85)

Write-Value `
    -Label 'Оперативна пам’ять' `
    -Value ("використано {0}%; вільно {1} ГБ з {2} ГБ" -f `
        $usedMemoryPercent,
        $freeMemoryGB,
        $totalMemoryGB) `
    -Color (Get-PercentColor -Value $usedMemoryPercent -Warning 80 -Critical 92)

if ($cpuLoad -ge 85) {
    Add-Issue -List $issues -Text 'Процесор зараз завантажений більш ніж на 85%.'
}
elseif ($cpuLoad -ge 60) {
    [void]$warnings.Add('Завантаження процесора підвищене.')
}

if ($usedMemoryPercent -ge 92) {
    Add-Issue -List $issues -Text 'Оперативна пам’ять майже повністю зайнята.'
}
elseif ($usedMemoryPercent -ge 80) {
    [void]$warnings.Add('Оперативна пам’ять помітно завантажена.')
}

if ($uptime.TotalDays -ge 30) {
    [void]$warnings.Add("Комп’ютер не перезавантажувався $([int]$uptime.TotalDays) днів.")
}

Write-Section -Title 'ДИСКИ'

$disks = @(
    Get-WmiObject `
        -Class Win32_LogicalDisk `
        -Filter 'DriveType=3' `
        -ErrorAction SilentlyContinue |
    Sort-Object -Property DeviceID
)

if ($disks.Count -eq 0) {
    Write-Host '[WARN] Не вдалося отримати інформацію про локальні диски.' `
        -ForegroundColor Yellow
}
else {
    foreach ($disk in $disks) {
        $sizeGB = [Math]::Round(([double]$disk.Size / 1GB), 1)
        $freeGB = [Math]::Round(([double]$disk.FreeSpace / 1GB), 1)
        $freePercent = 0

        if ([double]$disk.Size -gt 0) {
            $freePercent = [Math]::Round(
                ([double]$disk.FreeSpace / [double]$disk.Size) * 100,
                1
            )
        }

        $color = if ($freePercent -lt 8) {
            [ConsoleColor]::Red
        }
        elseif ($freePercent -lt 15) {
            [ConsoleColor]::Yellow
        }
        else {
            [ConsoleColor]::Green
        }

        Write-Value `
            -Label ("Диск {0}" -f $disk.DeviceID) `
            -Value ("вільно {0} ГБ з {1} ГБ ({2}%)" -f `
                $freeGB,
                $sizeGB,
                $freePercent) `
            -Color $color

        if ($freePercent -lt 8) {
            Add-Issue `
                -List $issues `
                -Text "На диску $($disk.DeviceID) залишилося менше 8% вільного місця."
        }
        elseif ($freePercent -lt 15) {
            [void]$warnings.Add(
                "На диску $($disk.DeviceID) залишилося менше 15% вільного місця."
            )
        }
    }
}

$pageFiles = @(
    Get-WmiObject -Class Win32_PageFileUsage -ErrorAction SilentlyContinue
)

if ($pageFiles.Count -gt 0) {
    Write-Host ''

    foreach ($pageFile in $pageFiles) {
        Write-Value `
            -Label 'Файл підкачки' `
            -Value ("{0}: використовується {1} МБ з {2} МБ" -f `
                $pageFile.Name,
                $pageFile.CurrentUsage,
                $pageFile.AllocatedBaseSize)
    }
}

Write-Section -Title 'АКТИВНІСТЬ ДИСКІВ'

$diskPerformance = @(
    Get-WmiObject `
        -Class Win32_PerfFormattedData_PerfDisk_PhysicalDisk `
        -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '_Total' } |
    Sort-Object -Property Name
)

if ($diskPerformance.Count -eq 0) {
    Write-Host '[INFO] Лічильники активності дисків недоступні.' `
        -ForegroundColor DarkGray
}
else {
    foreach ($diskCounter in $diskPerformance) {
        $activePercent = [double]$diskCounter.PercentDiskTime
        $queueLength = [double]$diskCounter.CurrentDiskQueueLength

        $color = if ($activePercent -ge 95 -or $queueLength -ge 4) {
            [ConsoleColor]::Red
        }
        elseif ($activePercent -ge 80 -or $queueLength -ge 2) {
            [ConsoleColor]::Yellow
        }
        else {
            [ConsoleColor]::Green
        }

        Write-Value `
            -Label ("Диск {0}" -f $diskCounter.Name) `
            -Value ("активність {0}%; черга {1}" -f `
                [Math]::Round($activePercent, 1),
                [Math]::Round($queueLength, 1)) `
            -Color $color

        if ($activePercent -ge 95 -or $queueLength -ge 4) {
            [void]$warnings.Add(
                "Диск $($diskCounter.Name) зараз сильно завантажений."
            )
        }
    }
}

Write-Section -Title 'ПРОЦЕСИ: ПОТОЧНЕ НАВАНТАЖЕННЯ CPU'

$topCpu = @(Get-TopCpuProcesses `
    -SampleSeconds 2 `
    -LogicalProcessors $logicalProcessors)

if ($topCpu.Count -eq 0) {
    Write-Host '[INFO] Не вдалося виміряти навантаження процесів.' `
        -ForegroundColor DarkGray
}
else {
    Write-Host ('  {0,-28} {1,7} {2,10} {3,10}' -f `
        'Процес',
        'PID',
        'CPU %',
        'RAM МБ') `
        -ForegroundColor DarkGray

    foreach ($process in $topCpu) {
        $color = Get-PercentColor `
            -Value $process.CpuPercent `
            -Warning 20 `
            -Critical 50

        Write-Host ('  {0,-28} {1,7} {2,10} {3,10}' -f `
            (($process.Name | Out-String).Trim().PadRight(28).Substring(0, 28)),
            $process.Id,
            $process.CpuPercent,
            $process.MemoryMB) `
            -ForegroundColor $color
    }

    if ($topCpu[0].CpuPercent -ge 50) {
        Add-Issue `
            -List $issues `
            -Text "Процес $($topCpu[0].Name) використовує близько $($topCpu[0].CpuPercent)% CPU."
    }
    elseif ($topCpu[0].CpuPercent -ge 20) {
        [void]$warnings.Add(
            "Найактивніший процес: $($topCpu[0].Name), близько $($topCpu[0].CpuPercent)% CPU."
        )
    }
}

Write-Section -Title 'ПРОЦЕСИ: СПОЖИВАННЯ ПАМ’ЯТІ'

$topMemory = @(
    Get-Process -ErrorAction SilentlyContinue |
    Sort-Object -Property WorkingSet64 -Descending |
    Select-Object -First 10
)

if ($topMemory.Count -eq 0) {
    Write-Host '[INFO] Не вдалося отримати список процесів.' `
        -ForegroundColor DarkGray
}
else {
    Write-Host ('  {0,-28} {1,7} {2,12}' -f `
        'Процес',
        'PID',
        'RAM МБ') `
        -ForegroundColor DarkGray

    foreach ($process in $topMemory) {
        try {
            $memoryMB = [Math]::Round(([double]$process.WorkingSet64 / 1MB), 1)
            $name = [string]$process.ProcessName

            if ($name.Length -gt 28) {
                $name = $name.Substring(0, 28)
            }

            Write-Host ('  {0,-28} {1,7} {2,12}' -f `
                $name,
                $process.Id,
                $memoryMB)
        }
        catch {
        }
    }
}

Write-Section -Title 'ПРИСТРОЇ З ПОМИЛКАМИ'

$deviceErrors = @(
    Get-WmiObject `
        -Class Win32_PnPEntity `
        -Filter 'ConfigManagerErrorCode <> 0' `
        -ErrorAction SilentlyContinue |
    Sort-Object -Property Name
)

if ($deviceErrors.Count -eq 0) {
    Write-Host '[OK] Windows не повідомляє про проблемні пристрої.' `
        -ForegroundColor Green
}
else {
    $classifiedDevices = @(
        foreach ($device in $deviceErrors) {
            $code = [int]$device.ConfigManagerErrorCode
            $state = Get-DeviceStateInfo -Code $code

            [pscustomobject]@{
                Device = $device
                Code   = $code
                State  = $state
            }
        }
    )

    $deviceFailureCount = @(
        $classifiedDevices |
        Where-Object { $_.State.Severity -eq 'Failure' }
    ).Count

    $deviceWarningCount = @(
        $classifiedDevices |
        Where-Object { $_.State.Severity -eq 'Warning' }
    ).Count

    $deviceInfoCount = @(
        $classifiedDevices |
        Where-Object { $_.State.Severity -eq 'Info' }
    ).Count

    foreach ($item in $classifiedDevices | Select-Object -First 15) {
        $prefix = switch ($item.State.Severity) {
            'Failure' { '[FAIL]' }
            'Warning' { '[WARN]' }
            default   { '[INFO]' }
        }

        Write-Host ("{0} {1}, код {2}: {3}" -f `
            $prefix,
            $item.Device.Name,
            $item.Code,
            $item.State.Text) `
            -ForegroundColor $item.State.Color
    }

    if ($deviceErrors.Count -gt 15) {
        Write-Host "Показано перші 15 з $($deviceErrors.Count) пристроїв." `
            -ForegroundColor DarkGray
    }

    if ($deviceFailureCount -gt 0) {
        Add-Issue `
            -List $issues `
            -Text "Диспетчер пристроїв повідомляє про серйозні помилки: $deviceFailureCount."
    }

    if ($deviceWarningCount -gt 0) {
        [void]$warnings.Add(
            "Пристроїв, стан яких потребує перевірки: $deviceWarningCount."
        )
    }

    if ($deviceInfoCount -gt 0) {
        Write-Host ''
        Write-Host 'Коди 22 і 45 зазвичай означають вимкнений або від’єднаний пристрій, а не поломку.' `
            -ForegroundColor DarkGray
    }
}

Write-Section -Title 'СИСТЕМНІ ТА АПАРАТНІ ПОДІЇ'

$systemEvents = @()
$applicationEvents = @()
$since = (Get-Date).AddHours(-24)

if (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue) {
    try {
        $systemEvents = @(
            Get-WinEvent `
                -FilterHashtable @{
                    LogName   = 'System'
                    StartTime = $since
                    Level     = @(1, 2, 3)
                } `
                -MaxEvents 400 `
                -ErrorAction Stop |
            Where-Object {
                $_.Id -in @(7, 11, 41, 51, 55, 129, 153, 157, 2004, 4101) -or
                $_.ProviderName -match '(?i)WHEA|Disk|Ntfs|storahci|stornvme|Display|Resource-Exhaustion'
            } |
            Sort-Object -Property TimeCreated -Descending
        )
    }
    catch {
    }

    try {
        $applicationEvents = @(
            Get-WinEvent `
                -FilterHashtable @{
                    LogName   = 'Application'
                    StartTime = $since
                    Level     = @(1, 2, 3)
                } `
                -MaxEvents 300 `
                -ErrorAction Stop |
            Where-Object {
                $_.ProviderName -match '(?i)Application Hang|Application Error|Windows Error Reporting'
            } |
            Sort-Object -Property TimeCreated -Descending
        )
    }
    catch {
    }
}

if ($systemEvents.Count -eq 0) {
    Write-Host '[OK] За 24 години не знайдено подій диска, WHEA, нестачі ресурсів або аварійного живлення.' `
        -ForegroundColor Green
}
else {
    foreach ($event in $systemEvents | Select-Object -First 8) {
        $isDisplayRecovery = (
            $event.Id -eq 4101 -or
            $event.ProviderName -match '(?i)^Display$'
        )

        $color = if ($isDisplayRecovery) {
            [ConsoleColor]::Yellow
        }
        else {
            [ConsoleColor]::Red
        }

        Write-Host ("[{0}] {1}, ID {2}: {3}" -f `
            $event.TimeCreated.ToString('dd.MM HH:mm'),
            $event.ProviderName,
            $event.Id,
            (Get-ShortText -Text ([string]$event.Message))) `
            -ForegroundColor $color
    }

    $seriousSystemEvents = @(
        $systemEvents |
        Where-Object {
            $_.Id -ne 4101 -and
            $_.ProviderName -notmatch '(?i)^Display$'
        }
    )

    if ($seriousSystemEvents.Count -gt 0) {
        Add-Issue `
            -List $issues `
            -Text "За 24 години знайдено серйозних системних або апаратних подій: $($seriousSystemEvents.Count)."
    }
    else {
        [void]$warnings.Add(
            "За 24 години були перезапуски графічного драйвера: $($systemEvents.Count)."
        )
    }
}

Write-Section -Title 'ЗБОЇ ТА ЗАВИСАННЯ ЗАСТОСУНКІВ'

if ($applicationEvents.Count -eq 0) {
    Write-Host '[OK] За 24 години явних збоїв і зависань застосунків не знайдено.' `
        -ForegroundColor Green
}
else {
    foreach ($event in $applicationEvents | Select-Object -First 8) {
        Write-Host ("[{0}] {1}, ID {2}: {3}" -f `
            $event.TimeCreated.ToString('dd.MM HH:mm'),
            $event.ProviderName,
            $event.Id,
            (Get-ShortText -Text ([string]$event.Message))) `
            -ForegroundColor Yellow
    }

    [void]$warnings.Add(
        "За 24 години знайдено збоїв або зависань застосунків: $($applicationEvents.Count)."
    )
}

Write-Section -Title 'ПІДСУМОК'

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host '[OK] На момент перевірки явного дефіциту ресурсів або системних помилок не видно.' `
        -ForegroundColor Green
    Write-Host 'Якщо зависання повторюється, запускай діагностику під час проблеми: знімок відображає поточний стан.' `
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
