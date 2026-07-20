Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        -TypeName Security.Principal.WindowsPrincipal `
        -ArgumentList $identity

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-Utf8ScriptFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $scriptText = Get-Content `
        -LiteralPath $Path `
        -Raw `
        -Encoding UTF8 `
        -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($scriptText)) {
        throw "Отримано порожній скрипт: $Path"
    }

    $scriptBlock = [ScriptBlock]::Create($scriptText)

    try {
        & $scriptBlock
    }
    finally {
        $scriptText = $null
        $scriptBlock = $null
    }
}

try {
    Write-Host ''
    Write-Host 'Налаштування стандартного шаблону BgInfo' `
        -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-IsAdministrator)) {
        Write-Host '[FAIL] Потрібні права адміністратора.' `
            -ForegroundColor Red
        return
    }

    $installRoot =
        'C:\ProgramData\RaccoonAdminToolkit\BgInfo'

    $binPath = Join-Path $installRoot 'Bin'
    $configPath = Join-Path `
        $installRoot `
        'Config\Raccoon-Standard.bgi'

    $helperPath = Join-Path $installRoot 'Update-BgInfo.ps1'

    $exePath = if ([Environment]::Is64BitOperatingSystem) {
        Join-Path $binPath 'Bginfo64.exe'
    }
    else {
        Join-Path $binPath 'Bginfo.exe'
    }

    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw 'BgInfo не встановлено. Спочатку запусти встановлення.'
    }

    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "Не знайдено допоміжний скрипт: $helperPath"
    }

    Invoke-Utf8ScriptFile -Path $helperPath

    $textPath = Join-Path `
        $env:LOCALAPPDATA `
        'RaccoonAdminToolkit\BgInfo\SystemInfo.txt'

    Write-Host 'BgInfo зараз відкриється у звичайному графічному режимі.' `
        -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Налаштуй шаблон один раз:' -ForegroundColor Cyan
    Write-Host '  1. Видали стандартні поля з макета.'
    Write-Host '  2. Натисни Custom -> New.'
    Write-Host '  3. Назва поля: Raccoon System Info.'
    Write-Host '  4. Тип: File contents.'
    Write-Host "  5. Файл: $textPath"
    Write-Host '  6. Розмісти блок у правому верхньому куті.'
    Write-Host '  7. У Background вибери Copy existing settings.'
    Write-Host '  8. Для Bitmap Location використовуй:'
    Write-Host '     %LOCALAPPDATA%\RaccoonAdminToolkit\BgInfo\Raccoon-BgInfo.bmp'
    Write-Host '  9. File -> Save As і збережи точно сюди:'
    Write-Host "     $configPath"
    Write-Host ''
    Write-Host 'Рекомендований текст уже створено у SystemInfo.txt.' `
        -ForegroundColor DarkGray
    Write-Host ''

    $confirmation = Read-Host 'Для відкриття редактора введи TEMPLATE'

    if ($confirmation -cne 'TEMPLATE') {
        Write-Host 'Налаштування скасовано.' -ForegroundColor Yellow
        return
    }

    $arguments = @(
        '/timer:300'
        '-accepteula'
    )

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $arguments = @(
            $configPath
            '/timer:300'
            '-accepteula'
        )
    }

    $process = Start-Process `
        -FilePath $exePath `
        -ArgumentList $arguments `
        -Wait `
        -PassThru `
        -ErrorAction Stop

    Write-Host ''

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-Host '[WARN] Файл шаблону не знайдено після закриття BgInfo.' `
            -ForegroundColor Yellow
        Write-Host "Очікувався файл: $configPath" `
            -ForegroundColor DarkGray
        return
    }

    Invoke-Utf8ScriptFile -Path $helperPath

    Write-Host '[OK] Шаблон Raccoon-Standard.bgi знайдено.' `
        -ForegroundColor Green
    Write-Host '[OK] Табличку застосовано до поточного користувача.' `
        -ForegroundColor Green
    Write-Host 'Для інших користувачів вона застосовуватиметься під час входу.' `
        -ForegroundColor Cyan
}
catch {
    Write-Host ''
    Write-Host '[FAIL] Не вдалося налаштувати шаблон BgInfo.' `
        -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}
