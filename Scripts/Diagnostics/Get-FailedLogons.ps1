Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ''
Write-Host 'Невдалі спроби входу, подія 4625' -ForegroundColor Cyan
Write-Host ''

$minutesText = Read-Host 'За скільки останніх хвилин перевірити? [Enter = 40]'
$minutes = 40

if (-not [string]::IsNullOrWhiteSpace($minutesText)) {
    if (-not [int]::TryParse($minutesText, [ref]$minutes) -or
        $minutes -lt 1 -or
        $minutes -gt 10080) {

        throw 'Вкажи ціле число від 1 до 10080 хвилин.'
    }
}

$startTime = (Get-Date).AddMinutes(-$minutes)

Write-Host ''
Write-Host (
    'Читаю журнал Security від {0}...' -f
    $startTime.ToString('dd.MM.yyyy HH:mm:ss')
) -ForegroundColor DarkGray
Write-Host ''

$events = @(
    Get-WinEvent `
        -FilterHashtable @{
            LogName   = 'Security'
            Id        = 4625
            StartTime = $startTime
        } `
        -ErrorAction Stop
)

if ($events.Count -eq 0) {
    Write-Host (
        '[OK] За останні {0} хв. подій 4625 не знайдено.' -f
        $minutes
    ) -ForegroundColor Green
    return
}

$rows = @(
    foreach ($event in $events) {
        $properties = @($event.Properties)

        [pscustomobject]@{
            Time    = $event.TimeCreated
            User    = if ($properties.Count -gt 5) {
                [string]$properties[5].Value
            }
            else {
                ''
            }
            Domain  = if ($properties.Count -gt 6) {
                [string]$properties[6].Value
            }
            else {
                ''
            }
            IP      = if ($properties.Count -gt 19) {
                [string]$properties[19].Value
            }
            else {
                ''
            }
            LogonType = if ($properties.Count -gt 10) {
                [string]$properties[10].Value
            }
            else {
                ''
            }
            Status  = if ($properties.Count -gt 7) {
                [string]$properties[7].Value
            }
            else {
                ''
            }
        }
    }
)

Write-Host ('{0,-17} {1,-24} {2,-16} {3,-6} {4}' -f `
    'Час', 'Користувач', 'IP', 'Тип', 'Статус') -ForegroundColor DarkGray
Write-Host ('-' * 92) -ForegroundColor DarkGray

foreach ($row in $rows) {
    $account = if ([string]::IsNullOrWhiteSpace($row.Domain)) {
        $row.User
    }
    else {
        '{0}\{1}' -f $row.Domain, $row.User
    }

    Write-Host (
        '{0,-17} {1,-24} {2,-16} {3,-6} {4}' -f
        $row.Time.ToString('dd.MM HH:mm:ss'),
        $account,
        $row.IP,
        $row.LogonType,
        $row.Status
    ) -ForegroundColor Yellow
}

Write-Host ''
Write-Host (
    '[WARN] Знайдено невдалих спроб входу: {0}' -f
    $rows.Count
) -ForegroundColor Yellow

$topSources = @(
    $rows |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.IP) -and
        $_.IP -notin @('-', '::1', '127.0.0.1')
    } |
    Group-Object -Property IP |
    Sort-Object -Property Count -Descending |
    Select-Object -First 5
)

if ($topSources.Count -gt 0) {
    Write-Host ''
    Write-Host 'Найактивніші IP-адреси:' -ForegroundColor Cyan

    foreach ($source in $topSources) {
        Write-Host (
            '  {0,-18} {1} спроб' -f
            $source.Name,
            $source.Count
        )
    }
}
