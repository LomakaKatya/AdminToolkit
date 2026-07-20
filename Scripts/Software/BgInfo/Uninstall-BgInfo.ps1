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

try {
    Write-Host ''
    Write-Host 'Видалення Raccoon BgInfo' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-IsAdministrator)) {
        Write-Host '[FAIL] Потрібні права адміністратора.' `
            -ForegroundColor Red
        return
    }

    $installRoot =
        'C:\ProgramData\RaccoonAdminToolkit\BgInfo'

    $startupPath = Join-Path `
        $env:ProgramData `
        'Microsoft\Windows\Start Menu\Programs\StartUp\Raccoon BgInfo.lnk'

    Write-Host 'Буде видалено:' -ForegroundColor Yellow
    Write-Host "  - $startupPath"
    Write-Host "  - $installRoot"
    Write-Host ''
    Write-Host 'Поточне зображення робочого столу користувачів не відновлюється автоматично.' `
        -ForegroundColor DarkGray
    Write-Host 'Воно зміниться після вибору іншого фону або застосування доменної політики.' `
        -ForegroundColor DarkGray
    Write-Host ''

    $confirmation = Read-Host 'Для видалення введи REMOVE'

    if ($confirmation -cne 'REMOVE') {
        Write-Host 'Видалення скасовано.' -ForegroundColor Yellow
        return
    }

    $removedShortcut = $false
    $removedRoot = $false

    if (Test-Path -LiteralPath $startupPath -PathType Leaf) {
        Remove-Item `
            -LiteralPath $startupPath `
            -Force `
            -ErrorAction Stop

        $removedShortcut = $true
    }

    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item `
            -LiteralPath $installRoot `
            -Recurse `
            -Force `
            -ErrorAction Stop

        $removedRoot = $true
    }

    Write-Host ''

    if ($removedShortcut) {
        Write-Host '[OK] Автозапуск видалено.' `
            -ForegroundColor Green
    }
    else {
        Write-Host '[INFO] Ярлик автозапуску вже був відсутній.' `
            -ForegroundColor DarkGray
    }

    if ($removedRoot) {
        Write-Host '[OK] Каталог BgInfo видалено.' `
            -ForegroundColor Green
    }
    else {
        Write-Host '[INFO] Каталог BgInfo вже був відсутній.' `
            -ForegroundColor DarkGray
    }

    Write-Host '[OK] Нові користувацькі сеанси більше не запускатимуть BgInfo.' `
        -ForegroundColor Green
}
catch {
    Write-Host ''
    Write-Host '[FAIL] Не вдалося видалити BgInfo.' `
        -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}
