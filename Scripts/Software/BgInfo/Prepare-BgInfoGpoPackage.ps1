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

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $encoding = New-Object `
        -TypeName System.Text.UTF8Encoding `
        -ArgumentList $false

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        $encoding
    )
}

try {
    Write-Host ''
    Write-Host 'Підготовка пакета BgInfo для доменної політики' `
        -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-IsAdministrator)) {
        Write-Host '[FAIL] Потрібні права адміністратора.' `
            -ForegroundColor Red
        return
    }

    $installRoot =
        'C:\ProgramData\RaccoonAdminToolkit\BgInfo'

    $requiredPaths = @(
        (Join-Path $installRoot 'Bin'),
        (Join-Path $installRoot 'Config\Raccoon-Standard.bgi'),
        (Join-Path $installRoot 'Update-BgInfo.ps1')
    )

    foreach ($requiredPath in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw (
                'Локальна еталонна установка не готова. Не знайдено: {0}' -f
                $requiredPath
            )
        }
    }

    Write-Host 'Пакет міститиме:' -ForegroundColor Cyan
    Write-Host '  - підписані виконувані файли BgInfo;'
    Write-Host '  - налаштований Raccoon-Standard.bgi;'
    Write-Host '  - Update-BgInfo.ps1;'
    Write-Host '  - комп''ютерний startup-скрипт для GPO;'
    Write-Host '  - інструкцію з розгортання.'
    Write-Host ''

    $destinationRoot = (
        Read-Host 'Вкажи папку для створення пакета'
    ).Trim().Trim('"')

    if ([string]::IsNullOrWhiteSpace($destinationRoot)) {
        throw 'Шлях не може бути порожнім.'
    }

    $packageRoot = Join-Path `
        $destinationRoot `
        ('Raccoon-BgInfo-GPO-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))

    $payloadRoot = Join-Path $packageRoot 'Payload'

    $confirmation = Read-Host 'Для створення пакета введи GPO'

    if ($confirmation -cne 'GPO') {
        Write-Host 'Створення пакета скасовано.' `
            -ForegroundColor Yellow
        return
    }

    New-Item `
        -Path $payloadRoot `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop |
    Out-Null

    Copy-Item `
        -LiteralPath (Join-Path $installRoot 'Bin') `
        -Destination (Join-Path $payloadRoot 'Bin') `
        -Recurse `
        -Force `
        -ErrorAction Stop

    Copy-Item `
        -LiteralPath (Join-Path $installRoot 'Config') `
        -Destination (Join-Path $payloadRoot 'Config') `
        -Recurse `
        -Force `
        -ErrorAction Stop

    Copy-Item `
        -LiteralPath (Join-Path $installRoot 'Update-BgInfo.ps1') `
        -Destination (Join-Path $payloadRoot 'Update-BgInfo.ps1') `
        -Force `
        -ErrorAction Stop

    $deployScript = @'
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

if (-not (Test-IsAdministrator)) {
    throw 'Deploy-BgInfo-Computer.ps1 має виконуватися від SYSTEM або адміністратора.'
}

$payloadRoot = Join-Path $PSScriptRoot 'Payload'
$installRoot = 'C:\ProgramData\RaccoonAdminToolkit\BgInfo'

if (-not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
    throw "Не знайдено Payload: $payloadRoot"
}

foreach ($fileName in @(
    'Bginfo.exe',
    'Bginfo64.exe'
)) {
    $candidatePath = Join-Path `
        (Join-Path $payloadRoot 'Bin') `
        $fileName

    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
        continue
    }

    $signature = Get-AuthenticodeSignature `
        -LiteralPath $candidatePath `
        -ErrorAction Stop

    $publisher = ''

    if ($null -ne $signature.SignerCertificate) {
        $publisher = [string]$signature.SignerCertificate.Subject
    }

    if ($signature.Status -ne
        [System.Management.Automation.SignatureStatus]::Valid -or
        $publisher -notmatch '(?i)Microsoft') {
        throw (
            'Файл {0} не має чинного підпису Microsoft. Статус: {1}. Видавець: {2}' -f
            $fileName,
            $signature.Status,
            $publisher
        )
    }
}

if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
    New-Item `
        -Path $installRoot `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop |
    Out-Null
}

Copy-Item `
    -Path (Join-Path $payloadRoot '*') `
    -Destination $installRoot `
    -Recurse `
    -Force `
    -ErrorAction Stop

$logsPath = Join-Path $installRoot 'Logs'

if (-not (Test-Path -LiteralPath $logsPath -PathType Container)) {
    New-Item `
        -Path $logsPath `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop |
    Out-Null
}

$startupPath = Join-Path `
    $env:ProgramData `
    'Microsoft\Windows\Start Menu\Programs\StartUp'

if (-not (Test-Path -LiteralPath $startupPath -PathType Container)) {
    New-Item `
        -Path $startupPath `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop |
    Out-Null
}

$helperPath = Join-Path $installRoot 'Update-BgInfo.ps1'
$shortcutPath = Join-Path $startupPath 'Raccoon BgInfo.lnk'
$powerShellPath = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'

$shell = $null
$shortcut = $null

try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powerShellPath
    $shortcut.Arguments = (
        '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden ' +
        '-ExecutionPolicy Bypass -File "{0}"' -f
        $helperPath
    )
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Description =
        'Оновлення інформаційної таблички Raccoon BgInfo'
    $shortcut.Save()
}
finally {
    if ($null -ne $shortcut -and
        [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
            $shortcut
        )
    }

    if ($null -ne $shell -and
        [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
            $shell
        )
    }
}

$icaclsPath = Join-Path $env:SystemRoot 'System32\icacls.exe'

& $icaclsPath `
    $installRoot `
    '/inheritance:r' `
    '/grant:r' `
    '*S-1-5-18:(OI)(CI)(F)' `
    '*S-1-5-32-544:(OI)(CI)(F)' `
    '*S-1-5-32-545:(OI)(CI)(RX)' `
    '/T' `
    '/C' |
Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "icacls завершився з кодом $LASTEXITCODE."
}

Write-Host '[OK] Raccoon BgInfo встановлено або оновлено через GPO.'
'@

    $deployPath = Join-Path `
        $packageRoot `
        'Deploy-BgInfo-Computer.ps1'

    Write-Utf8NoBom `
        -Path $deployPath `
        -Text $deployScript

    $readme = @'
RACCOON BGINFO - GPO PACKAGE

1. Copy the whole package to a protected domain share or SYSVOL folder.
2. Grant Domain Computers read access to the package.
3. Create or edit a GPO linked to the target computer OU.
4. Open:
   Computer Configuration
   -> Windows Settings
   -> Scripts (Startup/Shutdown)
   -> PowerShell Scripts
5. Add Deploy-BgInfo-Computer.ps1 as a startup script.
6. Apply the GPO to a test computer first.
7. Reboot the test computer or run gpupdate /force and reboot.
8. BgInfo runs for each user through the common Startup shortcut.

The package installs files locally to:
C:\ProgramData\RaccoonAdminToolkit\BgInfo

The configuration uses the current user's wallpaper and writes a unique bitmap
to the user's LocalAppData directory.

Do not place the package on a public web server.
The included executables are Microsoft Sysinternals files for internal deployment.
'@

    Write-Utf8NoBom `
        -Path (Join-Path $packageRoot 'README-GPO.txt') `
        -Text $readme

    Write-Host ''
    Write-Host '[OK] Пакет для GPO створено.' `
        -ForegroundColor Green
    Write-Host "[OK] Папка: $packageRoot" `
        -ForegroundColor Green
    Write-Host '[INFO] Спочатку перевір пакет на тестовому комп''ютері або тестовій OU.' `
        -ForegroundColor Cyan
}
catch {
    Write-Host ''
    Write-Host '[FAIL] Не вдалося підготувати пакет для GPO.' `
        -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}
