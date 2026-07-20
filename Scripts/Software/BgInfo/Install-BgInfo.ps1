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

function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor
            [Net.SecurityProtocolType]::Tls12
    }
    catch {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor 3072
    }
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

function Test-MicrosoftSignature {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $signature = Get-AuthenticodeSignature `
        -LiteralPath $Path `
        -ErrorAction Stop

    $subject = ''

    if ($null -ne $signature.SignerCertificate) {
        $subject = [string]$signature.SignerCertificate.Subject
    }

    return [pscustomobject]@{
        Valid     = (
            $signature.Status -eq
            [System.Management.Automation.SignatureStatus]::Valid -and
            $subject -match '(?i)Microsoft'
        )
        Status    = [string]$signature.Status
        Publisher = $subject
    }
}

function Expand-ZipCompatible {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item `
            -LiteralPath $DestinationPath `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }

    New-Item `
        -Path $DestinationPath `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop |
    Out-Null

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    [System.IO.Compression.ZipFile]::ExtractToDirectory(
        $ZipPath,
        $DestinationPath
    )
}

function Copy-BgInfoBinaries {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory,

        [Parameter(Mandatory)]
        [string]$DestinationDirectory
    )

    $copied = New-Object -TypeName System.Collections.ArrayList

    foreach ($fileName in @(
        'Bginfo.exe',
        'Bginfo64.exe'
    )) {
        $sourcePath = Join-Path $SourceDirectory $fileName

        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            continue
        }

        $signature = Test-MicrosoftSignature -Path $sourcePath

        if (-not $signature.Valid) {
            throw (
                'Файл {0} не має чинного підпису Microsoft. Статус: {1}. Видавець: {2}' -f
                $fileName,
                $signature.Status,
                $signature.Publisher
            )
        }

        $destinationPath = Join-Path $DestinationDirectory $fileName

        Copy-Item `
            -LiteralPath $sourcePath `
            -Destination $destinationPath `
            -Force `
            -ErrorAction Stop

        [void]$copied.Add($fileName)
    }

    if ($copied.Count -eq 0) {
        throw 'У джерелі не знайдено Bginfo.exe або Bginfo64.exe.'
    }

    if ([Environment]::Is64BitOperatingSystem -and
        -not ($copied -contains 'Bginfo64.exe')) {
        throw 'Для 64-бітної Windows не знайдено Bginfo64.exe.'
    }

    if (-not [Environment]::Is64BitOperatingSystem -and
        -not ($copied -contains 'Bginfo.exe')) {
        throw 'Для 32-бітної Windows не знайдено Bginfo.exe.'
    }

    return @($copied)
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    $output = @(
        & $FilePath @Arguments 2>&1 |
        ForEach-Object {
            ([string]$_).Trim()
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    $exitCode = [int]$LASTEXITCODE

    if ($exitCode -ne 0) {
        $details = (
            @(
                $output |
                Select-Object -First 6
            ) -join ' | '
        )

        throw (
            '{0} завершилася з кодом {1}. {2}' -f
            $Operation,
            $exitCode,
            $details
        )
    }
}

function Set-BgInfoAcl {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $takeownPath = Join-Path $env:SystemRoot 'System32\takeown.exe'
    $icaclsPath = Join-Path $env:SystemRoot 'System32\icacls.exe'

    Invoke-NativeCommand `
        -FilePath $takeownPath `
        -Arguments @(
            '/F'
            $Path
            '/A'
            '/R'
            '/D'
            'Y'
        ) `
        -Operation 'takeown'

    Invoke-NativeCommand `
        -FilePath $icaclsPath `
        -Arguments @(
            $Path
            '/inheritance:r'
            '/C'
            '/Q'
        ) `
        -Operation 'icacls /inheritance:r'

    foreach ($grant in @(
        '*S-1-5-18:(OI)(CI)(F)',
        '*S-1-5-32-544:(OI)(CI)(F)',
        '*S-1-5-32-545:(OI)(CI)(RX)'
    )) {
        Invoke-NativeCommand `
            -FilePath $icaclsPath `
            -Arguments @(
                $Path
                '/grant:r'
                $grant
                '/C'
                '/Q'
            ) `
            -Operation "icacls /grant:r $grant"
    }

    $children = @(
        Get-ChildItem `
            -LiteralPath $Path `
            -Force `
            -ErrorAction SilentlyContinue
    )

    if ($children.Count -gt 0) {
        Invoke-NativeCommand `
            -FilePath $icaclsPath `
            -Arguments @(
                (Join-Path $Path '*')
                '/reset'
                '/T'
                '/C'
                '/Q'
            ) `
            -Operation 'icacls /reset'
    }
}

function New-CommonStartupShortcut {
    param(
        [Parameter(Mandatory)]
        [string]$HelperPath
    )

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

    $shortcutPath = Join-Path $startupPath 'Raccoon BgInfo.lnk'
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    $shell = $null
    $shortcut = $null

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $powerShellPath
        $escapedHelperPath = $HelperPath.Replace(
            "'",
            "''"
        )

        $launcherCode = (
            "& ([ScriptBlock]::Create((Get-Content -LiteralPath '{0}' " +
            "-Raw -Encoding UTF8)))" -f
            $escapedHelperPath
        )

        $encodedCommand = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($launcherCode)
        )

        $shortcut.Arguments = (
            '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden ' +
            '-ExecutionPolicy Bypass -EncodedCommand {0}' -f
            $encodedCommand
        )
        $shortcut.WorkingDirectory = Split-Path -Parent $HelperPath
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

    return $shortcutPath
}

try {
    Write-Host ''
    Write-Host 'Встановлення Microsoft Sysinternals BgInfo' `
        -ForegroundColor Cyan
    Write-Host 'BgInfo буде встановлено для запуску в кожному користувацькому сеансі.' `
        -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Test-IsAdministrator)) {
        Write-Host '[FAIL] Потрібні права адміністратора.' `
            -ForegroundColor Red
        return
    }

    Write-Host 'Буде виконано:' -ForegroundColor Cyan
    Write-Host '  - перевірка цифрового підпису Microsoft;'
    Write-Host '  - копіювання BgInfo до ProgramData;'
    Write-Host '  - встановлення допоміжного скрипта;'
    Write-Host '  - створення автозапуску для всіх користувачів;'
    Write-Host '  - збереження наявного шаблону .bgi під час оновлення.'
    Write-Host ''
    Write-Host 'Виконувані файли не додаються до публічного репозиторію.' `
        -ForegroundColor DarkGray
    Write-Host ''

    Write-Host 'Джерело BgInfo:' -ForegroundColor Cyan
    Write-Host '  1. Офіційний архів Microsoft Sysinternals'
    Write-Host '  2. Локальна папка або ZIP-архів'
    Write-Host '  0. Скасувати'
    Write-Host ''

    $sourceMode = Read-Host 'Оберіть джерело'

    if ($sourceMode -eq '0') {
        Write-Host 'Встановлення скасовано.' -ForegroundColor Yellow
        return
    }

    if ($sourceMode -notin @('1', '2')) {
        throw 'Невідомий режим джерела.'
    }

    $confirmation = Read-Host 'Для встановлення введи BGINFO'

    if ($confirmation -cne 'BGINFO') {
        Write-Host 'Встановлення скасовано.' -ForegroundColor Yellow
        return
    }

    Enable-Tls12

    $installRoot =
        'C:\ProgramData\RaccoonAdminToolkit\BgInfo'

    $binPath = Join-Path $installRoot 'Bin'
    $configPath = Join-Path $installRoot 'Config'
    $logsPath = Join-Path $installRoot 'Logs'
    $helperPath = Join-Path $installRoot 'Update-BgInfo.ps1'

    if (Test-Path -LiteralPath $installRoot -PathType Container) {
        Write-Host 'Відновлюю права на наявну установку BgInfo...' `
            -ForegroundColor DarkGray

        Set-BgInfoAcl -Path $installRoot
    }

    foreach ($directory in @(
        $installRoot,
        $binPath,
        $configPath,
        $logsPath
    )) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item `
                -Path $directory `
                -ItemType Directory `
                -Force `
                -ErrorAction Stop |
            Out-Null
        }
    }

    $tempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ('Raccoon-BgInfo-' + [Guid]::NewGuid().ToString('N'))

    New-Item `
        -Path $tempRoot `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop |
    Out-Null

    try {
        $sourceDirectory = ''

        if ($sourceMode -eq '1') {
            $downloadUrl =
                'https://download.sysinternals.com/files/BGInfo.zip'

            $zipPath = Join-Path $tempRoot 'BGInfo.zip'
            $extractPath = Join-Path $tempRoot 'Extracted'

            Write-Host ''
            Write-Host 'Завантажую офіційний BGInfo.zip...' `
                -ForegroundColor DarkGray

            $webClient = New-Object -TypeName System.Net.WebClient

            try {
                $webClient.DownloadFile($downloadUrl, $zipPath)
            }
            finally {
                $webClient.Dispose()
            }

            Expand-ZipCompatible `
                -ZipPath $zipPath `
                -DestinationPath $extractPath

            $sourceDirectory = $extractPath
        }
        else {
            $localPath = (
                Read-Host 'Вкажи шлях до папки або ZIP-архіву'
            ).Trim().Trim('"')

            if ([string]::IsNullOrWhiteSpace($localPath)) {
                throw 'Шлях не може бути порожнім.'
            }

            if (Test-Path -LiteralPath $localPath -PathType Leaf) {
                if ([System.IO.Path]::GetExtension($localPath) -ine '.zip') {
                    throw 'Локальний файл має бути ZIP-архівом.'
                }

                $extractPath = Join-Path $tempRoot 'Extracted'

                Expand-ZipCompatible `
                    -ZipPath $localPath `
                    -DestinationPath $extractPath

                $sourceDirectory = $extractPath
            }
            elseif (Test-Path -LiteralPath $localPath -PathType Container) {
                $sourceDirectory = $localPath
            }
            else {
                throw "Шлях не знайдено: $localPath"
            }
        }

        $copiedBinaries = @(
            Copy-BgInfoBinaries `
                -SourceDirectory $sourceDirectory `
                -DestinationDirectory $binPath
        )

        $helperUrl =
            'https://raw.githubusercontent.com/LomakaKatya/AdminToolkit/main/Assets/BgInfo/Update-BgInfo.ps1'

        Write-Host 'Завантажую допоміжний скрипт AdminToolkit...' `
            -ForegroundColor DarkGray

        $helperCode = Invoke-RestMethod `
            -Uri ($helperUrl + '?nocache=' + [DateTime]::UtcNow.Ticks) `
            -Headers @{
                'Cache-Control' = 'no-cache'
                'Pragma'        = 'no-cache'
            } `
            -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace([string]$helperCode)) {
            throw 'GitHub повернув порожній Update-BgInfo.ps1.'
        }

        $bomMarkers = [char[]]@(
            [char]0xFEFF,
            [char]0x00EF,
            [char]0x00BB,
            [char]0x00BF
        )

        Write-Utf8NoBom `
            -Path $helperPath `
            -Text (([string]$helperCode).TrimStart($bomMarkers))

        $shortcutPath = New-CommonStartupShortcut `
            -HelperPath $helperPath

        Set-BgInfoAcl -Path $installRoot

        Write-Host ''
        Write-Host ('=' * 72) -ForegroundColor DarkCyan
        Write-Host '  ПІДСУМОК' -ForegroundColor Cyan
        Write-Host ('=' * 72) -ForegroundColor DarkCyan
        Write-Host ''

        Write-Host (
            '[OK] Встановлено файли: {0}.' -f
            ($copiedBinaries -join ', ')
        ) -ForegroundColor Green

        Write-Host "[OK] Каталог: $installRoot" `
            -ForegroundColor Green
        Write-Host "[OK] Автозапуск: $shortcutPath" `
            -ForegroundColor Green
        Write-Host '[OK] Користувачі мають лише читання та запуск.' `
            -ForegroundColor Green

        $standardConfig = Join-Path `
            $configPath `
            'Raccoon-Standard.bgi'

        if (Test-Path -LiteralPath $standardConfig -PathType Leaf) {
            Write-Host '[OK] Наявний шаблон BgInfo збережено.' `
                -ForegroundColor Green
        }
        else {
            Write-Host '[WARN] Шаблон Raccoon-Standard.bgi ще не створено.' `
                -ForegroundColor Yellow
            Write-Host 'Запусти пункт налаштування шаблону BgInfo у меню Toolkit.' `
                -ForegroundColor Cyan
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item `
                -LiteralPath $tempRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Host ''
    Write-Host '[FAIL] Не вдалося встановити BgInfo.' `
        -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}
