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

function Write-Value {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [AllowEmptyString()]
        [string]$Value,

        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = 'не визначено'
        $Color = [ConsoleColor]::DarkGray
    }

    Write-Host ('{0,-24}: ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Get-SafePropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-W32TimeRegistryState {
    $parametersPath =
        'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'

    $configPath =
        'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'

    $parameters = Get-ItemProperty `
        -LiteralPath $parametersPath `
        -ErrorAction SilentlyContinue

    $config = Get-ItemProperty `
        -LiteralPath $configPath `
        -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Type = [string](
            Get-SafePropertyValue `
                -InputObject $parameters `
                -Name 'Type' `
                -DefaultValue ''
        )
        NtpServer = [string](
            Get-SafePropertyValue `
                -InputObject $parameters `
                -Name 'NtpServer' `
                -DefaultValue ''
        )
        AnnounceFlags = Get-SafePropertyValue `
            -InputObject $config `
            -Name 'AnnounceFlags' `
            -DefaultValue $null
    }
}

function Format-NativeExitCode {
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    $bytes = [BitConverter]::GetBytes($ExitCode)
    $unsignedCode = [BitConverter]::ToUInt32($bytes, 0)

    return ('{0} (0x{1:X8})' -f $ExitCode, $unsignedCode)
}

function Invoke-W32TimeCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $w32tmPath = Join-Path $env:SystemRoot 'System32\w32tm.exe'

    if (-not (Test-Path -LiteralPath $w32tmPath -PathType Leaf)) {
        throw "Не знайдено системний файл: $w32tmPath"
    }

    $output = @(
        & $w32tmPath @Arguments 2>&1 |
        ForEach-Object {
            ([string]$_).Trim()
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    $exitCode = [int]$LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $exitCode
        Success  = ($exitCode -eq 0)
        Output   = $output
    }
}

function Get-CompactCommandOutput {
    param(
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [int]$MaximumLines = 4
    )

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return ''
    }

    return (
        @(
            $Lines |
            Select-Object -First $MaximumLines
        ) -join ' | '
    )
}

function Invoke-WindowsTimeRepair {
    Write-Host ''
    Write-Host 'Виправлення синхронізації часу Windows' `
        -ForegroundColor Cyan
    Write-Host 'Перевіряю роль комп''ютера, службу W32Time і поточні параметри...' `
        -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Test-IsAdministrator)) {
        Write-Host '[FAIL] Для цієї операції потрібні права адміністратора.' `
            -ForegroundColor Red
        Write-Host 'Запусти PowerShell від імені адміністратора і повтори спробу.' `
            -ForegroundColor Yellow
        return
    }

    $computerSystem = Get-WmiObject `
        -Class Win32_ComputerSystem `
        -ErrorAction Stop

    $domainRole = [int]$computerSystem.DomainRole
    $isDomainController = $domainRole -in @(4, 5)
    $pdcEmulator = $false
    $pdcDetectionError = ''

    if ($isDomainController) {
        try {
            $domain =
                [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()

            $pdcEmulator = (
                $domain.PdcRoleOwner.Name.Split('.')[0] -ieq
                $env:COMPUTERNAME
            )
        }
        catch {
            $pdcDetectionError = $_.Exception.Message
        }
    }

    if ($isDomainController -and
        -not [string]::IsNullOrWhiteSpace($pdcDetectionError)) {

        Write-Host '[FAIL] Не вдалося визначити власника ролі PDC Emulator.' `
            -ForegroundColor Red
        Write-Host $pdcDetectionError -ForegroundColor Yellow
        Write-Host 'Конфігурацію часу не змінено, щоб випадково не налаштувати PDC як звичайний контролер домену.' `
            -ForegroundColor DarkGray
        return
    }

    $roleText = if ($pdcEmulator) {
        'контролер домену, PDC Emulator'
    }
    elseif ($isDomainController) {
        'контролер домену'
    }
    elseif ($computerSystem.PartOfDomain) {
        'член домену'
    }
    else {
        'автономний комп''ютер'
    }

    $service = Get-Service -Name 'w32time' -ErrorAction SilentlyContinue

    if ($null -eq $service) {
        Write-Host '[FAIL] Службу Windows Time (w32time) не знайдено.' `
            -ForegroundColor Red
        Write-Host 'Скрипт не буде реєструвати системну службу автоматично.' `
            -ForegroundColor Yellow
        return
    }

    $serviceWmi = Get-WmiObject `
        -Class Win32_Service `
        -Filter "Name='w32time'" `
        -ErrorAction SilentlyContinue

    $startMode = [string](
        Get-SafePropertyValue `
            -InputObject $serviceWmi `
            -Name 'StartMode' `
            -DefaultValue ''
    )

    $currentState = Get-W32TimeRegistryState
    $usesDomainHierarchy = (
        $computerSystem.PartOfDomain -and
        -not $pdcEmulator
    )

    $defaultPeers =
        '0.ua.pool.ntp.org,0x8 1.ua.pool.ntp.org,0x8 2.ua.pool.ntp.org,0x8 time.google.com,0x8'

    $peers = ''
    $targetType = ''
    $targetDescription = ''
    $reliableValue = 'no'

    if ($usesDomainHierarchy) {
        $targetType = 'NT5DS'
        $targetDescription = 'ієрархія домену Active Directory'
    }
    else {
        $targetType = 'NTP'
        $targetDescription = 'зовнішні NTP-сервери'

        if ($pdcEmulator) {
            $reliableValue = 'yes'
        }

        Write-Host 'Зовнішні NTP-сервери за замовчуванням:' `
            -ForegroundColor Cyan
        Write-Host "  $defaultPeers"
        Write-Host ''

        $peerInput =
            (Read-Host 'Вкажи інший список або натисни Enter').Trim()

        $peers = if ([string]::IsNullOrWhiteSpace($peerInput)) {
            $defaultPeers
        }
        else {
            $peerInput
        }

        if ($peers.Contains('"') -or
            $peers.Contains("'") -or
            $peers.Contains("`r") -or
            $peers.Contains("`n")) {

            Write-Host ''
            Write-Host '[FAIL] Список NTP-серверів містить недопустимі лапки або перенесення рядка.' `
                -ForegroundColor Red
            return
        }
    }

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host '  ПОТОЧНИЙ СТАН' -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ''

    Write-Value -Label 'Роль' -Value $roleText -Color Cyan
    Write-Value -Label 'Служба W32Time' -Value ([string]$service.Status)
    Write-Value -Label 'Тип запуску' -Value $startMode
    Write-Value -Label 'Поточний Type' -Value $currentState.Type
    Write-Value -Label 'Поточний NtpServer' -Value $currentState.NtpServer

    $announceFlagsText = if ($null -eq $currentState.AnnounceFlags) {
        ''
    }
    else {
        '{0} (0x{0:X})' -f [int]$currentState.AnnounceFlags
    }

    Write-Value -Label 'AnnounceFlags' -Value $announceFlagsText

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host '  ПЛАН' -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ''

    Write-Host "  1. Переконатися, що служба W32Time може запускатися."
    Write-Host "  2. Запустити службу, якщо вона зупинена."
    Write-Host "  3. Налаштувати джерело часу: $targetDescription."
    Write-Host "  4. Перезапустити службу після застосування конфігурації."
    Write-Host "  5. Запросити повторну синхронізацію і перевірити джерело."
    Write-Host ''

    if ($usesDomainHierarchy) {
        Write-Value -Label 'Цільовий Type' -Value $targetType -Color Cyan
    }
    else {
        Write-Value -Label 'Цільовий Type' -Value $targetType -Color Cyan
        Write-Value -Label 'Цільові NTP-сервери' -Value $peers
        Write-Value -Label 'Надійне джерело' -Value $reliableValue
    }

    Write-Host ''
    $confirmation =
        Read-Host 'Для застосування конфігурації введи TIME'

    if ($confirmation -cne 'TIME') {
        Write-Host 'Дію скасовано. Конфігурацію не змінено.' `
            -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host 'Застосовую конфігурацію...' -ForegroundColor DarkGray
    Write-Host ''

    $changes = New-Object -TypeName System.Collections.ArrayList

    if ($startMode -ieq 'Disabled') {
        $newStartupType = if ($isDomainController) {
            'Automatic'
        }
        else {
            'Manual'
        }

        Set-Service `
            -Name 'w32time' `
            -StartupType $newStartupType `
            -ErrorAction Stop

        [void]$changes.Add(
            "Тип запуску W32Time змінено: Disabled -> $newStartupType."
        )
    }

    $service = Get-Service -Name 'w32time' -ErrorAction Stop

    if ($service.Status -ne 'Running') {
        Start-Service -Name 'w32time' -ErrorAction Stop

        $service = Get-Service -Name 'w32time' -ErrorAction Stop
        $service.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Running,
            [TimeSpan]::FromSeconds(20)
        )

        [void]$changes.Add('Службу W32Time запущено.')
    }

    $configArguments = if ($usesDomainHierarchy) {
        @(
            '/config'
            '/syncfromflags:domhier'
            '/reliable:no'
            '/update'
        )
    }
    else {
        @(
            '/config'
            ("/manualpeerlist:{0}" -f $peers)
            '/syncfromflags:manual'
            ("/reliable:{0}" -f $reliableValue)
            '/update'
        )
    }

    $configResult =
        Invoke-W32TimeCommand -Arguments $configArguments

    if (-not $configResult.Success) {
        $details =
            Get-CompactCommandOutput -Lines $configResult.Output

        throw (
            'w32tm /config не виконав конфігурацію. Код: {0}. {1}' -f
            (Format-NativeExitCode -ExitCode $configResult.ExitCode),
            $details
        )
    }

    [void]$changes.Add(
        "Налаштовано джерело часу: $targetDescription."
    )

    Restart-Service -Name 'w32time' -Force -ErrorAction Stop

    $service = Get-Service -Name 'w32time' -ErrorAction Stop
    $service.WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Running,
        [TimeSpan]::FromSeconds(20)
    )

    [void]$changes.Add('Службу W32Time перезапущено після конфігурації.')

    Start-Sleep -Seconds 2

    $resyncResult = $null

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $resyncResult =
            Invoke-W32TimeCommand `
                -Arguments @('/resync', '/rediscover')

        if ($resyncResult.Success) {
            break
        }

        if ($attempt -lt 2) {
            Start-Sleep -Seconds 3
        }
    }

    $sourceResult =
        Invoke-W32TimeCommand -Arguments @('/query', '/source')

    $finalState = Get-W32TimeRegistryState
    $service = Get-Service -Name 'w32time' -ErrorAction Stop

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host '  ПІДСУМОК' -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ''

    foreach ($change in $changes) {
        Write-Host "[OK] $change" -ForegroundColor Green
    }

    Write-Host (
        '[OK] Служба W32Time: {0}.' -f
        $service.Status
    ) -ForegroundColor Green

    Write-Host (
        '[OK] Активний режим: {0}.' -f
        $finalState.Type
    ) -ForegroundColor Green

    if ($sourceResult.Success) {
        $sourceText =
            Get-CompactCommandOutput `
                -Lines $sourceResult.Output `
                -MaximumLines 2

        Write-Host "[INFO] Джерело часу: $sourceText" `
            -ForegroundColor Cyan
    }
    else {
        Write-Host (
            '[WARN] Не вдалося прочитати джерело часу. Код: {0}.' -f
            (Format-NativeExitCode -ExitCode $sourceResult.ExitCode)
        ) -ForegroundColor Yellow
    }

    if ($resyncResult.Success) {
        Write-Host '[OK] Повторну синхронізацію виконано.' `
            -ForegroundColor Green
    }
    else {
        $resyncDetails =
            Get-CompactCommandOutput -Lines $resyncResult.Output

        Write-Host (
            '[WARN] Конфігурацію застосовано, але повторна синхронізація не завершилася успішно.' `
        ) -ForegroundColor Yellow

        Write-Host (
            '[INFO] Код w32tm /resync: {0}. {1}' -f
            (Format-NativeExitCode -ExitCode $resyncResult.ExitCode),
            $resyncDetails
        ) -ForegroundColor DarkGray

        Write-Host 'Перевір UDP 123, DNS, доступність NTP-серверів і повтори синхронізацію через кілька хвилин.' `
            -ForegroundColor Yellow
    }
}

try {
    Invoke-WindowsTimeRepair
}
catch {
    Write-Host ''
    Write-Host '[FAIL] Не вдалося виправити синхронізацію часу.' `
        -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}
