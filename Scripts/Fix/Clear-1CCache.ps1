Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ''
Write-Host 'Очищення кешу 1С' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Перед очищенням закрий усі запущені вікна 1С для поточного користувача.' `
    -ForegroundColor Yellow

$confirmation = Read-Host 'Продовжити очищення? [Y/N]'

if ($confirmation -notmatch '^(y|yes|д|так)$') {
    Write-Host 'Очищення скасовано.' -ForegroundColor Yellow
    return
}

$paths = @(
    (Join-Path $env:LOCALAPPDATA '1C'),
    (Join-Path $env:APPDATA '1C\1cv8'),
    (Join-Path $env:APPDATA '1C\1cv82')
)

$removed = 0
$missing = 0
$failed = New-Object -TypeName System.Collections.ArrayList

Write-Host ''

foreach ($path in $paths) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ("[INFO] Немає: {0}" -f $path) -ForegroundColor DarkGray
        $missing++
        continue
    }

    try {
        Remove-Item `
            -LiteralPath $path `
            -Recurse `
            -Force `
            -ErrorAction Stop

        Write-Host ("[OK] Видалено: {0}" -f $path) -ForegroundColor Green
        $removed++
    }
    catch {
        [void]$failed.Add(
            "{0}: {1}" -f $path, $_.Exception.Message
        )

        Write-Host ("[FAIL] Не видалено: {0}" -f $path) -ForegroundColor Red
    }
}

Write-Host ''

if ($failed.Count -gt 0) {
    foreach ($item in $failed) {
        Write-Host ("[FAIL] {0}" -f $item) -ForegroundColor Red
    }

    throw 'Кеш очищено не повністю. Переконайся, що 1С закрита.'
}

Write-Host (
    '[OK] Очищення завершено. Видалено каталогів: {0}; відсутні: {1}.' -f
    $removed,
    $missing
) -ForegroundColor Green
