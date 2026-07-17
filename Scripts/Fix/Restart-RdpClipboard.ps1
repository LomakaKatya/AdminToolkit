Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ''
Write-Host 'Перезапуск буфера обміну RDP' -ForegroundColor Cyan
Write-Host ''

$processes = @(
    Get-Process -Name 'rdpclip' -ErrorAction SilentlyContinue
)

if ($processes.Count -gt 0) {
    foreach ($process in $processes) {
        Stop-Process `
            -Id $process.Id `
            -Force `
            -ErrorAction Stop
    }

    Write-Host (
        '[OK] Зупинено процесів rdpclip.exe: {0}' -f
        $processes.Count
    ) -ForegroundColor Green
}
else {
    Write-Host '[INFO] Процес rdpclip.exe не був запущений.' `
        -ForegroundColor DarkGray
}

$rdpClipPath = Join-Path $env:SystemRoot 'System32\rdpclip.exe'

if (-not (Test-Path -LiteralPath $rdpClipPath -PathType Leaf)) {
    throw "Не знайдено системний файл: $rdpClipPath"
}

$started = Start-Process `
    -FilePath $rdpClipPath `
    -PassThru `
    -ErrorAction Stop

Start-Sleep -Milliseconds 500

if ($started.HasExited) {
    throw (
        'rdpclip.exe завершився одразу після запуску, код {0}.' -f
        $started.ExitCode
    )
}

Write-Host (
    '[OK] rdpclip.exe запущено, PID {0}.' -f
    $started.Id
) -ForegroundColor Green
