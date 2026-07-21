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

function Repair-BgInfoAccess {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $takeownPath = Join-Path $env:SystemRoot 'System32\takeown.exe'
    $icaclsPath = Join-Path $env:SystemRoot 'System32\icacls.exe'

    & $takeownPath `
        '/F' `
        $Path `
        '/A' `
        '/R' `
        '/D' `
        'Y' |
    Out-Null

    & $icaclsPath `
        $Path `
        '/grant:r' `
        '*S-1-5-32-544:(OI)(CI)(F)' `
        '/T' `
        '/C' `
        '/Q' |
    Out-Null
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

    if (-not (Confirm-Action -Prompt 'Видалити Raccoon BgInfo?')) {
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
        Repair-BgInfoAccess -Path $installRoot

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
