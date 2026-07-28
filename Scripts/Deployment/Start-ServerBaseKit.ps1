[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'Z',

    [string]$RemotePath =
        '\\u292275-sub7.your-storagebox.de\u292275-sub7',

    [string]$ServerInstallDirectory = 'Server_install',

    [string]$UserName = 'u292275-sub7',

    [switch]$DisconnectAfterRun,

    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Test-RaccoonAdministrator {
    $Identity =
        [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        -TypeName Security.Principal.WindowsPrincipal `
        -ArgumentList $Identity

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Normalize-RaccoonUncPath {
    param(
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    return $Path.Trim().TrimEnd('\').ToLowerInvariant()
}

function Get-RaccoonDriveState {
    param(
        [Parameter(Mandatory)]
        [string]$LocalPath
    )

    try {
        $Mapping = Get-SmbMapping `
            -LocalPath $LocalPath `
            -ErrorAction Stop |
        Select-Object -First 1

        if ($null -ne $Mapping) {
            return [pscustomobject]@{
                Exists     = $true
                IsNetwork  = $true
                RemotePath = [string]$Mapping.RemotePath
                Source     = 'Get-SmbMapping'
            }
        }
    }
    catch {
    }

    try {
        $Disk = Get-CimInstance `
            -ClassName Win32_LogicalDisk `
            -Filter (
                "DeviceID='{0}'" -f $LocalPath
            ) `
            -ErrorAction SilentlyContinue

        if ($null -ne $Disk) {
            return [pscustomobject]@{
                Exists     = $true
                IsNetwork  = (
                    [int]$Disk.DriveType -eq 4
                )
                RemotePath = [string]$Disk.ProviderName
                Source     = 'Win32_LogicalDisk'
            }
        }
    }
    catch {
    }

    $DriveName = $LocalPath.TrimEnd(':')

    try {
        $PsDrive = Get-PSDrive `
            -Name $DriveName `
            -ErrorAction SilentlyContinue

        if ($null -ne $PsDrive) {
            return [pscustomobject]@{
                Exists     = $true
                IsNetwork  = $false
                RemotePath = ''
                Source     = 'PowerShell drive'
            }
        }
    }
    catch {
    }

    return [pscustomobject]@{
        Exists     = $false
        IsNetwork  = $false
        RemotePath = ''
        Source     = 'not found'
    }
}

function Connect-RaccoonNetworkDrive {
    param(
        [Parameter(Mandatory)]
        [string]$LocalPath,

        [Parameter(Mandatory)]
        [string]$SharePath,

        [Parameter(Mandatory)]
        [string]$ShareUser
    )

    $NetExe = Join-Path `
        $env:SystemRoot `
        'System32\net.exe'

    Write-Host ''
    Write-Host (
        'Підключаю {0} до {1}' -f
        $LocalPath,
        $SharePath
    ) -ForegroundColor Cyan

    $Connected = $false

    try {
        if (Test-Path `
                -LiteralPath $SharePath `
                -PathType Container `
                -ErrorAction SilentlyContinue) {

            & $NetExe `
                use `
                $LocalPath `
                $SharePath `
                '/persistent:no'

            if ($LASTEXITCODE -eq 0) {
                $Connected = $true
            }
        }
    }
    catch {
    }

    if (-not $Connected) {
        Write-Host ''
        Write-Host (
            'Введи пароль для {0}. Пароль не зберігається у Toolkit.' -f
            $ShareUser
        ) -ForegroundColor Yellow

        & $NetExe `
            use `
            $LocalPath `
            $SharePath `
            "/user:$ShareUser" `
            '*' `
            '/persistent:no'

        if ($LASTEXITCODE -ne 0) {
            throw (
                'Не вдалося підключити мережевий диск. ' +
                'Перевір пароль, доступ до SMB і наявні підключення ' +
                'до цього сервера під іншими обліковими даними.'
            )
        }
    }

    Start-Sleep -Seconds 1

    if (-not (Test-Path `
            -LiteralPath ($LocalPath + '\') `
            -PathType Container)) {

        throw (
            'Windows повідомила про успішне підключення, ' +
            'але диск недоступний: ' +
            $LocalPath
        )
    }
}

function Test-RaccoonServerBaseKit {
    param(
        [Parameter(Mandatory)]
        [string]$KitRoot
    )

    $RequiredPaths = @(
        (Join-Path $KitRoot 'Install-ServerBase.ps1'),
        (Join-Path $KitRoot 'config.json'),
        (Join-Path $KitRoot 'Installers')
    )

    $MissingCore = @(
        $RequiredPaths |
        Where-Object {
            -not (Test-Path -LiteralPath $_)
        }
    )

    if ($MissingCore.Count -gt 0) {
        throw (
            "Комплект Server Base Kit неповний.`r`n" +
            "Не знайдено:`r`n  " +
            ($MissingCore -join "`r`n  ")
        )
    }

    $ConfigPath = Join-Path $KitRoot 'config.json'

    try {
        $Config = Get-Content `
            -LiteralPath $ConfigPath `
            -Raw `
            -Encoding UTF8 |
        ConvertFrom-Json
    }
    catch {
        throw (
            'Не вдалося прочитати config.json: ' +
            $_.Exception.Message
        )
    }

    if ($null -eq $Config.Packages) {
        throw 'У config.json відсутній масив Packages.'
    }

    $InstallersPath = Join-Path `
        $KitRoot `
        ([string]$Config.InstallersPath)

    $EnabledPackages = New-Object `
        -TypeName System.Collections.ArrayList

    $MissingInstallers = New-Object `
        -TypeName System.Collections.ArrayList

    foreach ($Package in @($Config.Packages)) {
        $Enabled = $true

        if (
            $Package.PSObject.Properties.Name -contains
            'Enabled'
        ) {
            $Enabled = [bool]$Package.Enabled
        }

        if (-not $Enabled) {
            continue
        }

        [void]$EnabledPackages.Add($Package)

        $PackagePath = Join-Path `
            $InstallersPath `
            ([string]$Package.File)

        if (-not (Test-Path `
                -LiteralPath $PackagePath `
                -PathType Leaf)) {

            [void]$MissingInstallers.Add(
                [string]$Package.File
            )
        }
    }

    if ($MissingInstallers.Count -gt 0) {
        throw (
            "Не знайдено увімкнені інсталятори:`r`n  " +
            (@($MissingInstallers) -join "`r`n  ")
        )
    }

    $TechsysPath = Join-Path `
        $InstallersPath `
        'techsys.dll'

    if (-not (Test-Path `
            -LiteralPath $TechsysPath `
            -PathType Leaf)) {

        Write-Warning (
            'Не знайдено Installers\techsys.dll. ' +
            'Встановлення продовжиться, але заміна DLL для 1C ' +
            'буде пропущена.'
        )
    }

    return [pscustomobject]@{
        Config          = $Config
        EnabledPackages = @($EnabledPackages)
        InstallerScript = Join-Path `
            $KitRoot `
            'Install-ServerBase.ps1'
        LogsPath        = Join-Path `
            $KitRoot `
            ([string]$Config.LogsPath)
    }
}

function Disconnect-RaccoonNetworkDrive {
    param(
        [Parameter(Mandatory)]
        [string]$LocalPath
    )

    $NetExe = Join-Path `
        $env:SystemRoot `
        'System32\net.exe'

    & $NetExe `
        use `
        $LocalPath `
        '/delete' `
        '/y'

    if ($LASTEXITCODE -ne 0) {
        Write-Warning (
            'Не вдалося автоматично відключити ' +
            $LocalPath
        )
    }
}

if (-not (Test-RaccoonAdministrator)) {
    throw (
        'Запусти Raccoon Admin Toolkit від імені адміністратора.'
    )
}

$DriveLetter = $DriveLetter.ToUpperInvariant()
$LocalPath = $DriveLetter + ':'
$DriveRoot = $LocalPath + '\'
$KitRoot = Join-Path `
    $DriveRoot `
    $ServerInstallDirectory

$CreatedMapping = $false
$DriveState = Get-RaccoonDriveState `
    -LocalPath $LocalPath

if ($DriveState.Exists) {
    if (-not $DriveState.IsNetwork) {
        $OccupiedDriveMessage = (
            '{0} вже зайнятий локальним або PowerShell-диском. ' -f
            $LocalPath
        ) + 'Toolkit не буде його змінювати.'

        throw $OccupiedDriveMessage
    }

    $ExpectedRemotePath = Normalize-RaccoonUncPath `
        -Path $RemotePath

    $ActualRemotePath = Normalize-RaccoonUncPath `
        -Path $DriveState.RemotePath

    if (
        -not [string]::IsNullOrWhiteSpace($ActualRemotePath) -and
        $ActualRemotePath -ne $ExpectedRemotePath
    ) {
        throw (
            '{0} вже підключений до іншого ресурсу: {1}' -f
            $LocalPath,
            $DriveState.RemotePath
        )
    }

    Write-Host (
        '[OK] {0} вже підключений: {1}' -f
        $LocalPath,
        $RemotePath
    ) -ForegroundColor Green
}
else {
    Connect-RaccoonNetworkDrive `
        -LocalPath $LocalPath `
        -SharePath $RemotePath `
        -ShareUser $UserName

    $CreatedMapping = $true

    Write-Host (
        '[OK] {0} підключений лише для поточного входу Windows.' -f
        $LocalPath
    ) -ForegroundColor Green
}

try {
    if (-not (Test-Path `
            -LiteralPath $KitRoot `
            -PathType Container)) {

        throw (
            'На сховищі не знайдено каталог: ' +
            $KitRoot
        )
    }

    Write-Host ''
    Write-Host 'Перевіряю Server Base Kit...' `
        -ForegroundColor Cyan

    $Kit = Test-RaccoonServerBaseKit `
        -KitRoot $KitRoot

    Write-Host (
        '[OK] Увімкнених пакетів: {0}' -f
        $Kit.EnabledPackages.Count
    ) -ForegroundColor Green

    Write-Host (
        '[OK] Скрипт запуску: {0}' -f
        $Kit.InstallerScript
    ) -ForegroundColor Green

    Write-Host ''
    Write-Host (
        'Не запускай цей комплект одночасно на кількох серверах: ' +
        'спільний каталог Work перевикористовується під час розпакування.'
    ) -ForegroundColor Yellow

    if ($ValidateOnly) {
        Write-Host ''
        Write-Host (
            '[OK] Перевірка завершена. ' +
            'Режим ValidateOnly: встановлення не запускалося.'
        ) -ForegroundColor Green

        return
    }

    Write-Host ''
    Write-Host 'Запускаю Server Base Kit...' `
        -ForegroundColor Cyan

    $PreviousExecutionPolicy = Get-ExecutionPolicy `
        -Scope Process

    $LocationWasPushed = $false

    try {
        Set-ExecutionPolicy `
            -Scope Process `
            -ExecutionPolicy Bypass `
            -Force

        Push-Location -LiteralPath $KitRoot
        $LocationWasPushed = $true

        $InstallerScript = [string]$Kit.InstallerScript
        & $InstallerScript
    }
    finally {
        if ($LocationWasPushed) {
            Pop-Location
        }

        try {
            Set-ExecutionPolicy `
                -Scope Process `
                -ExecutionPolicy $PreviousExecutionPolicy `
                -Force
        }
        catch {
        }
    }

    Write-Host ''
    Write-Host '[OK] Server Base Kit завершив виконання.' `
        -ForegroundColor Green

    Write-Host (
        'Журнали комплекту: {0}' -f
        $Kit.LogsPath
    ) -ForegroundColor Cyan
}
finally {
    if ($DisconnectAfterRun -and $CreatedMapping) {
        Disconnect-RaccoonNetworkDrive `
            -LocalPath $LocalPath
    }
    elseif ($CreatedMapping) {
        Write-Host ''
        Write-Host (
            '{0} залишено підключеним до завершення поточного входу Windows.' -f
            $LocalPath
        ) -ForegroundColor DarkGray

        Write-Host (
            'Відключити вручну: net use {0} /delete /y' -f
            $LocalPath
        ) -ForegroundColor DarkGray
    }
}
