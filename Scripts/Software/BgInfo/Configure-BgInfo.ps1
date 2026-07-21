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

function Confirm-Action {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $answer = (
        Read-Host "$Prompt [Y/N | Д/Н]"
    ).Trim()

    return ($answer -match '^(?i:y|yes|д|да|так)$')
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

    if ([string]::IsNullOrWhiteSpace($env:RACCOON_BGINFO_USER)) {
        throw 'Допоміжний скрипт не створив RACCOON_BGINFO_USER.'
    }

    if ([string]::IsNullOrWhiteSpace(
            $env:RACCOON_BGINFO_SESSION_SINCE
        )) {
        throw 'Допоміжний скрипт не створив RACCOON_BGINFO_SESSION_SINCE.'
    }

    Write-Host 'BgInfo зараз відкриється у звичайному графічному режимі.' `
        -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Поточні значення для перевірки:' `
        -ForegroundColor Cyan
    Write-Host (
        '  RACCOON_BGINFO_USER          = {0}' -f
        $env:RACCOON_BGINFO_USER
    )
    Write-Host (
        '  RACCOON_BGINFO_SESSION_SINCE = {0}' -f
        $env:RACCOON_BGINFO_SESSION_SINCE
    )
    Write-Host ''
    Write-Host 'Налаштуй шаблон один раз:' -ForegroundColor Cyan
    Write-Host '  1. Якщо є старе поле File contents, видали його.'
    Write-Host '  2. Видали непотрібні стандартні поля з макета.'
    Write-Host '  3. Натисни Custom -> New.'
    Write-Host '  4. Створи поле:'
    Write-Host '     Назва: Raccoon User'
    Write-Host '     Тип: Environment variable'
    Write-Host '     Змінна: RACCOON_BGINFO_USER'
    Write-Host '  5. Створи друге поле:'
    Write-Host '     Назва: Raccoon Session Since'
    Write-Host '     Тип: Environment variable'
    Write-Host '     Змінна: RACCOON_BGINFO_SESSION_SINCE'
    Write-Host '  6. Додай обидва поля до макета.'
    Write-Host '  7. Оформи блок так:'
    Write-Host ''
    Write-Host '     SYSTEM INFO'
    Write-Host ''
    Write-Host '     Користувач : <Raccoon User>'
    Write-Host '     Сеанс з    : <Raccoon Session Since>'
    Write-Host '     Підтримка  : +380 67 001 10 12'
    Write-Host '                  дзвінки / Viber / Telegram / WhatsApp'
    Write-Host ''
    Write-Host '  8. Розмісти блок у правому верхньому куті.'
    Write-Host '  9. У Background вибери Copy existing settings.'
    Write-Host ' 10. Для Bitmap Location використовуй:'
    Write-Host '     %LOCALAPPDATA%\RaccoonAdminToolkit\BgInfo\Raccoon-BgInfo.bmp'
    Write-Host ' 11. File -> Save As і збережи точно сюди:'
    Write-Host "     $configPath"
    Write-Host ''

    if (-not (Confirm-Action -Prompt 'Відкрити редактор BgInfo?')) {
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

    Start-Process `
        -FilePath $exePath `
        -ArgumentList $arguments `
        -Wait `
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
