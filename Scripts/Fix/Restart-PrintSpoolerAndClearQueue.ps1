Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ''
Write-Host 'Очищення черги та перезапуск служби друку' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Усі незавершені завдання друку на цьому комп''ютері будуть видалені.' `
    -ForegroundColor Yellow

$confirmation = Read-Host 'Продовжити? [Y/N]'

if ($confirmation -notmatch '^(y|yes|д|так)$') {
    Write-Host 'Дію скасовано.' -ForegroundColor Yellow
    return
}

$service = Get-Service -Name 'Spooler' -ErrorAction Stop
$spoolPath = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'

Write-Host ''

if ($service.Status -ne 'Stopped') {
    Write-Host 'Зупиняю Print Spooler...' -ForegroundColor DarkGray
    Stop-Service -Name 'Spooler' -Force -ErrorAction Stop
    $service.WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Stopped,
        [TimeSpan]::FromSeconds(20)
    )
}

$files = @()

if (Test-Path -LiteralPath $spoolPath -PathType Container) {
    $files = @(
        Get-ChildItem `
            -LiteralPath $spoolPath `
            -Force `
            -File `
            -ErrorAction SilentlyContinue
    )

    foreach ($file in $files) {
        Remove-Item `
            -LiteralPath $file.FullName `
            -Force `
            -ErrorAction Stop
    }
}

Write-Host (
    '[OK] Видалено файлів черги: {0}' -f
    $files.Count
) -ForegroundColor Green

Write-Host 'Запускаю Print Spooler...' -ForegroundColor DarkGray
Start-Service -Name 'Spooler' -ErrorAction Stop

$service = Get-Service -Name 'Spooler' -ErrorAction Stop
$service.WaitForStatus(
    [System.ServiceProcess.ServiceControllerStatus]::Running,
    [TimeSpan]::FromSeconds(20)
)

Write-Host '[OK] Служба Print Spooler працює.' -ForegroundColor Green
