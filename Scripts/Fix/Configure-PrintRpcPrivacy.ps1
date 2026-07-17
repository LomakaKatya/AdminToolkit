Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ''
Write-Host 'Сумісність RPC-автентифікації мережевого друку' -ForegroundColor Cyan
Write-Host ''

$registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print'
$valueName = 'RpcAuthnLevelPrivacyEnabled'

$currentValue = $null

try {
    $currentValue = (
        Get-ItemProperty `
            -LiteralPath $registryPath `
            -Name $valueName `
            -ErrorAction Stop
    ).$valueName
}
catch {
}

Write-Host 'Поточний стан:' -ForegroundColor Cyan

if ($null -eq $currentValue) {
    Write-Host '  параметр відсутній, використовується системне значення за замовчуванням' `
        -ForegroundColor Green
}
elseif ([int]$currentValue -eq 0) {
    Write-Host '  захист RPC privacy вимкнено, legacy-сумісність увімкнена' `
        -ForegroundColor Red
}
else {
    Write-Host '  захист RPC privacy увімкнено' -ForegroundColor Green
}

Write-Host ''
Write-Host '  1. Увімкнути legacy-сумісність, встановити значення 0' `
    -ForegroundColor Yellow
Write-Host '  2. Повернути захист, встановити значення 1' `
    -ForegroundColor Green
Write-Host '  3. Видалити параметр і повернути системну поведінку'
Write-Host '  0. Скасувати'
Write-Host ''

$choice = Read-Host 'Оберіть дію'

switch ($choice) {
    '1' {
        Write-Host ''
        Write-Host '[НЕБЕЗПЕЧНО] Цей режим послаблює захист RPC для друку.' `
            -ForegroundColor Red
        Write-Host 'Використовуй лише як тимчасовий обхід для старих клієнтів або серверів друку.' `
            -ForegroundColor Yellow

        $confirmation = Read-Host 'Для підтвердження введи LEGACY'

        if ($confirmation -cne 'LEGACY') {
            Write-Host 'Дію скасовано.' -ForegroundColor Yellow
            return
        }

        New-Item `
            -Path $registryPath `
            -Force `
            -ErrorAction Stop |
            Out-Null

        New-ItemProperty `
            -LiteralPath $registryPath `
            -Name $valueName `
            -PropertyType DWord `
            -Value 0 `
            -Force `
            -ErrorAction Stop |
            Out-Null

        Write-Host '[WARN] Legacy-сумісність увімкнено. Захист послаблено.' `
            -ForegroundColor Yellow
    }

    '2' {
        New-Item `
            -Path $registryPath `
            -Force `
            -ErrorAction Stop |
            Out-Null

        New-ItemProperty `
            -LiteralPath $registryPath `
            -Name $valueName `
            -PropertyType DWord `
            -Value 1 `
            -Force `
            -ErrorAction Stop |
            Out-Null

        Write-Host '[OK] Захист RPC privacy увімкнено.' -ForegroundColor Green
    }

    '3' {
        Remove-ItemProperty `
            -LiteralPath $registryPath `
            -Name $valueName `
            -Force `
            -ErrorAction SilentlyContinue

        Write-Host '[OK] Параметр видалено. Діє системна поведінка за замовчуванням.' `
            -ForegroundColor Green
    }

    '0' {
        Write-Host 'Дію скасовано.' -ForegroundColor Yellow
        return
    }

    default {
        throw 'Невідомий пункт меню.'
    }
}

Write-Host ''
Write-Host 'Для гарантованого застосування параметра може знадобитися перезапуск служби Print Spooler або комп''ютера.' `
    -ForegroundColor DarkGray
