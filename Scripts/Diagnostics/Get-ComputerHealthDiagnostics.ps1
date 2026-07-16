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
Write-Host 'Диагностика зависаний и производительности ПК' `
    -ForegroundColor Cyan
Write-Host 'Снимок занимает несколько секунд: измеряю CPU, память, диски и процессы...' `
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

Write-Section -Title 'ОБЩЕЕ СОСТОЯНИЕ'

Write-Value -Label 'Компьютер' -Value ([string]$computer.Name) -Color Cyan
Write-Value -Label 'ОС' -Value ("{0} {1}" -f $os.Caption, $os.OSArchitecture)
Write-Value -Label 'Последняя загрузка' -Value $lastBoot.ToString('dd.MM.yyyy HH:mm')
Write-Value `
    -Label 'Время работы' `
    -Value ("{0} дн. {1} ч. {2} мин." -f `
        [int]$uptime.TotalDays,
        $uptime.Hours,
        $uptime.Minutes)

Write-Value -Label 'Логических процессоров' -Value ([string]$logicalProcessors)
Write-Value `
    -Label 'Текущая загрузка CPU' `
    -Value ("{0}%" -f $cpuLoad) `
    -Color (Get-PercentColor -Value $cpuLoad -Warning 60 -Critical 85)

Write-Value `
    -Label 'Оперативная память' `
    -Value ("использовано {0}% ({1} из {2} ГБ свободно)" -f `
        $usedMemoryPercent,
        $freeMemoryGB,
        $totalMemoryGB) `
    -Color (Get-PercentColor -Value $usedMemoryPercent -Warning 80 -Critical 92)

if ($cpuLoad -ge 85) {
    Add-Issue -List $issues -Text 'Процессор сейчас загружен более чем на 85%.'
}
elseif ($cpuLoad -ge 60) {
    [void]$warnings.Add('Загрузка процессора повышена.')
}

if ($usedMemoryPercent -ge 92) {
    Add-Issue -List $issues -Text 'Оперативная память почти полностью занята.'
}
elseif ($usedMemoryPercent -ge 80) {
    [void]$warnings.Add('Оперативная память заметно загружена.')
}

if ($uptime.TotalDays -ge 30) {
    [void]$warnings.Add("Компьютер не перезагружался $([int]$uptime.TotalDays) дней.")
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
    Write-Host '[WARN] Не удалось получить информацию о локальных дисках.' `
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
            -Value ("свободно {0} ГБ из {1} ГБ ({2}%)" -f `
                $freeGB,
                $sizeGB,
                $freePercent) `
            -Color $color

        if ($freePercent -lt 8) {
            Add-Issue `
                -List $issues `
                -Text "На диске $($disk.DeviceID) осталось менее 8% свободного места."
        }
        elseif ($freePercent -lt 15) {
            [void]$warnings.Add(
                "На диске $($disk.DeviceID) осталось менее 15% свободного места."
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
            -Label 'Файл подкачки' `
            -Value ("{0}: используется {1} МБ из {2} МБ" -f `
                $pageFile.Name,
                $pageFile.CurrentUsage,
                $pageFile.AllocatedBaseSize)
    }
}

Write-Section -Title 'ПРОЦЕССЫ: ТЕКУЩАЯ НАГРУЗКА CPU'

$topCpu = @(Get-TopCpuProcesses `
    -SampleSeconds 2 `
    -LogicalProcessors $logicalProcessors)

if ($topCpu.Count -eq 0) {
    Write-Host '[INFO] Не удалось измерить нагрузку процессов.' `
        -ForegroundColor DarkGray
}
else {
    Write-Host ('  {0,-28} {1,7} {2,10} {3,10}' -f `
        'Процесс',
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
            -Text "Процесс $($topCpu[0].Name) использует около $($topCpu[0].CpuPercent)% CPU."
    }
    elseif ($topCpu[0].CpuPercent -ge 20) {
        [void]$warnings.Add(
            "Наиболее активный процесс: $($topCpu[0].Name), около $($topCpu[0].CpuPercent)% CPU."
        )
    }
}

Write-Section -Title 'ПРОЦЕССЫ: ПОТРЕБЛЕНИЕ ПАМЯТИ'

$topMemory = @(
    Get-Process -ErrorAction SilentlyContinue |
    Sort-Object -Property WorkingSet64 -Descending |
    Select-Object -First 10
)

Write-Host ('  {0,-28} {1,7} {2,12}' -f `
    'Процесс',
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

Write-Section -Title 'УСТРОЙСТВА С ОШИБКАМИ'

$deviceErrors = @(
    Get-WmiObject `
        -Class Win32_PnPEntity `
        -Filter 'ConfigManagerErrorCode <> 0' `
        -ErrorAction SilentlyContinue |
    Sort-Object -Property Name
)

if ($deviceErrors.Count -eq 0) {
    Write-Host '[OK] Windows не сообщает об ошибках устройств.' `
        -ForegroundColor Green
}
else {
    foreach ($device in $deviceErrors | Select-Object -First 10) {
        Write-Host ("[FAIL] {0}, код {1}" -f `
            $device.Name,
            $device.ConfigManagerErrorCode) `
            -ForegroundColor Red
    }

    if ($deviceErrors.Count -gt 10) {
        Write-Host "Показаны первые 10 из $($deviceErrors.Count) устройств." `
            -ForegroundColor DarkGray
    }

    Add-Issue `
        -List $issues `
        -Text "Диспетчер устройств сообщает об ошибках: $($deviceErrors.Count)."
}

Write-Section -Title 'НЕДАВНИЕ СИСТЕМНЫЕ СОБЫТИЯ'

$events = @()
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
                -MaxEvents 300 `
                -ErrorAction Stop |
            Where-Object {
                $_.Id -in @(7, 11, 41, 51, 55, 129, 153, 157, 2004, 4101) -or
                $_.ProviderName -match '(?i)WHEA|Disk|Ntfs|storahci|stornvme|Display|Resource-Exhaustion'
            }
        )

        $events += $systemEvents
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
                -MaxEvents 200 `
                -ErrorAction Stop |
            Where-Object {
                $_.Id -in @(1000, 1001, 1002) -or
                $_.ProviderName -match '(?i)Application Hang|Application Error|Windows Error Reporting'
            }
        )

        $events += $applicationEvents
    }
    catch {
    }
}

$events = @(
    $events |
    Sort-Object -Property TimeCreated -Descending |
    Select-Object -First 12
)

if ($events.Count -eq 0) {
    Write-Host '[OK] За 24 часа не найдено явных событий зависания, диска или аппаратных ошибок.' `
        -ForegroundColor Green
}
else {
    foreach ($event in $events) {
        $color = if ($event.LevelDisplayName -match '(?i)critical|error|крит|ошиб') {
            [ConsoleColor]::Red
        }
        else {
            [ConsoleColor]::Yellow
        }

        Write-Host ("[{0}] {1}, ID {2}: {3}" -f `
            $event.TimeCreated.ToString('dd.MM HH:mm'),
            $event.ProviderName,
            $event.Id,
            (Get-ShortText -Text ([string]$event.Message))) `
            -ForegroundColor $color
    }

    [void]$warnings.Add(
        "За последние 24 часа найдено подозрительных событий: $($events.Count)."
    )
}

Write-Section -Title 'ИТОГ'

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host '[OK] На момент проверки явного дефицита ресурсов или системных ошибок не видно.' `
        -ForegroundColor Green
    Write-Host 'Если зависание повторяется, запускай диагностику во время проблемы: снимок отражает текущее состояние.' `
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
