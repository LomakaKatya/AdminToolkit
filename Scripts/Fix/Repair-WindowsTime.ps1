Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ''
Write-Host 'Виправлення синхронізації часу Windows' -ForegroundColor Cyan
Write-Host ''

$computerSystem = Get-WmiObject `
    -Class Win32_ComputerSystem `
    -ErrorAction Stop

$domainRole = [int]$computerSystem.DomainRole
$isDomainController = $domainRole -in @(4, 5)

$pdcEmulator = $false

if ($isDomainController) {
    try {
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $pdcEmulator = (
            $domain.PdcRoleOwner.Name.Split('.')[0] -ieq
            $env:COMPUTERNAME
        )
    }
    catch {
    }
}

Write-Host (
    'Роль: {0}' -f
    $(if ($pdcEmulator) {
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
    })
)

if ($computerSystem.PartOfDomain -and -not $pdcEmulator) {
    Write-Host ''
    Write-Host 'Для члена домену або звичайного контролера домену рекомендована синхронізація з ієрархією домену.' `
        -ForegroundColor Cyan
    Write-Host 'Налаштовую syncfromflags:domhier...' -ForegroundColor DarkGray

    Stop-Service -Name 'w32time' -Force -ErrorAction Stop

    & w32tm.exe /config /syncfromflags:domhier /reliable:no /update
    if ($LASTEXITCODE -ne 0) {
        throw "w32tm /config завершився з кодом $LASTEXITCODE."
    }

    Start-Service -Name 'w32time' -ErrorAction Stop
}
else {
    $defaultPeers = '0.ua.pool.ntp.org,0x8 1.ua.pool.ntp.org,0x8 2.ua.pool.ntp.org,0x8 time.google.com,0x8'
    Write-Host ''
    Write-Host 'Зовнішні NTP-сервери:' -ForegroundColor Cyan
    Write-Host "  $defaultPeers"
    Write-Host ''

    $peerInput = Read-Host 'Вкажи інший список або натисни Enter'
    $peers = if ([string]::IsNullOrWhiteSpace($peerInput)) {
        $defaultPeers
    }
    else {
        $peerInput.Trim()
    }

    $reliableValue = if ($pdcEmulator) {
        'yes'
    }
    else {
        'no'
    }

    Stop-Service -Name 'w32time' -Force -ErrorAction Stop

    & w32tm.exe /config `
        /manualpeerlist:"$peers" `
        /syncfromflags:manual `
        /reliable:$reliableValue `
        /update

    if ($LASTEXITCODE -ne 0) {
        throw "w32tm /config завершився з кодом $LASTEXITCODE."
    }

    Start-Service -Name 'w32time' -ErrorAction Stop
}

Write-Host ''
Write-Host 'Запитую повторну синхронізацію...' -ForegroundColor DarkGray

& w32tm.exe /resync /rediscover
$resyncCode = $LASTEXITCODE

Write-Host ''
Write-Host 'Джерело часу:' -ForegroundColor Cyan
& w32tm.exe /query /source

Write-Host ''
Write-Host 'Стан служби часу:' -ForegroundColor Cyan
& w32tm.exe /query /status

Write-Host ''

if ($resyncCode -eq 0) {
    Write-Host '[OK] Команду повторної синхронізації виконано.' `
        -ForegroundColor Green
}
else {
    Write-Host (
        '[WARN] w32tm /resync повернув код {0}. Перевір вивід вище.' -f
        $resyncCode
    ) -ForegroundColor Yellow
}
