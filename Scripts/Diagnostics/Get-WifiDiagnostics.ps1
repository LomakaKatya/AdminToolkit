Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Section {
    param (
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Value {
    param (
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

function Test-Label {
    param (
        [string]$Label,
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ($Label -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-PropertyValue {
    param (
        [hashtable]$Properties,
        [string[]]$Patterns
    )

    foreach ($key in $Properties.Keys) {
        if (Test-Label -Label $key -Patterns $Patterns) {
            return [string]$Properties[$key]
        }
    }

    return ''
}

function Get-SignalPercent {
    param (
        [string]$Text
    )

    $value = -1

    if ($Text -match '(\d{1,3})\s*%') {
        $value = [int]$matches[1]

        if ($value -gt 100) {
            $value = 100
        }
    }

    return $value
}

function Get-SignalInfo {
    param (
        [int]$Percent
    )

    $label = ''
    $color = [ConsoleColor]::DarkGray

    if ($Percent -lt 0) {
        return [pscustomobject]@{
            Percent = $Percent
            Label   = 'не визначено'
            Color   = [ConsoleColor]::DarkGray
            Bar     = '----------'
            Known   = $false
        }
    }

    if ($Percent -ge 80) {
        $label = 'відмінний'
        $color = [ConsoleColor]::Green
    }
    elseif ($Percent -ge 65) {
        $label = 'хороший'
        $color = [ConsoleColor]::Green
    }
    elseif ($Percent -ge 50) {
        $label = 'прийнятний'
        $color = [ConsoleColor]::Yellow
    }
    elseif ($Percent -ge 35) {
        $label = 'слабкий'
        $color = [ConsoleColor]::DarkYellow
    }
    else {
        $label = 'поганий'
        $color = [ConsoleColor]::Red
    }

    $filled = [Math]::Round($Percent / 10)
    $empty = 10 - $filled

    $bar = ('#' * $filled) + ('-' * $empty)

    return [pscustomobject]@{
        Percent = $Percent
        Label   = $label
        Color   = $color
        Bar     = $bar
        Known   = $true
    }
}

function Test-ConnectedState {
    param (
        [string]$State
    )

    if ([string]::IsNullOrWhiteSpace($State)) {
        return $false
    }

    if ($State -match '(?i)disconnected|отключ|відключ|не\s+подключ|не\s+підключ') {
        return $false
    }

    return ($State -match '(?i)connected|подключ|підключ|соедин')
}

function ConvertTo-KeyValue {
    param (
        [string]$Line
    )

    if ($Line -match '^\s*([^:]+?)\s*:\s*(.*)$') {
        return [pscustomobject]@{
            Label = $matches[1].Trim()
            Value = $matches[2].Trim()
        }
    }

    return $null
}

function Get-WlanInterfaceBlocks {
    param (
        [string[]]$Lines
    )

    $blocks = @()
    $current = $null

    foreach ($line in $Lines) {
        $pair = ConvertTo-KeyValue -Line $line

        if ($null -eq $pair) {
            continue
        }

        $isName = Test-Label `
            -Label $pair.Label `
            -Patterns @(
                '^(?i)name$',
                '^(?i)имя$',
                "^(?i)ім['’]?я$"
            )

        if ($isName) {
            if ($null -ne $current) {
                $blocks += ,$current
            }

            $current = @{}
        }

        if ($null -ne $current) {
            $current[$pair.Label] = $pair.Value
        }
    }

    if ($null -ne $current) {
        $blocks += ,$current
    }

    return $blocks
}

function Get-DriverProperties {
    param (
        [string[]]$Lines
    )

    $properties = @{}

    foreach ($line in $Lines) {
        $pair = ConvertTo-KeyValue -Line $line

        if ($null -eq $pair) {
            continue
        }

        if (-not $properties.ContainsKey($pair.Label)) {
            $properties[$pair.Label] = $pair.Value
        }
    }

    return $properties
}

function Get-VisibleAccessPoints {
    param (
        [string[]]$Lines
    )

    $accessPoints = @()
    $currentNetwork = @{}
    $currentBssid = $null

    foreach ($line in $Lines) {
        if ($line -match '^\s*SSID\s+\d+\s*:\s*(.*)$') {
            if ($null -ne $currentBssid) {
                $accessPoints += [pscustomobject]$currentBssid
                $currentBssid = $null
            }

            $currentNetwork = @{
                SSID        = $matches[1].Trim()
                NetworkType = ''
                Auth        = ''
                Encryption  = ''
            }

            continue
        }

        if ($line -match '^\s*BSSID\s+\d+\s*:\s*(.*)$') {
            if ($null -ne $currentBssid) {
                $accessPoints += [pscustomobject]$currentBssid
            }

            $currentBssid = @{
                SSID        = [string]$currentNetwork.SSID
                BSSID       = $matches[1].Trim()
                NetworkType = [string]$currentNetwork.NetworkType
                Auth        = [string]$currentNetwork.Auth
                Encryption  = [string]$currentNetwork.Encryption
                Signal      = 0
                RadioType   = ''
                Channel     = 0
            }

            continue
        }

        $pair = ConvertTo-KeyValue -Line $line

        if ($null -eq $pair) {
            continue
        }

        if (Test-Label -Label $pair.Label -Patterns @(
                '(?i)network\s*type',
                '(?i)тип\s+мережі',
                '(?i)тип\s+мереж'
            )) {
            $currentNetwork.NetworkType = $pair.Value
            continue
        }

        if (Test-Label -Label $pair.Label -Patterns @(
                '(?i)authentication',
                '(?i)проверка\s+автентичності',
                '(?i)автентифікац',
                '(?i)аутентифікац'
            )) {
            $currentNetwork.Auth = $pair.Value
            continue
        }

        if (Test-Label -Label $pair.Label -Patterns @(
                '(?i)cipher',
                '(?i)шифр'
            )) {
            $currentNetwork.Encryption = $pair.Value
            continue
        }

        if ($null -eq $currentBssid) {
            continue
        }

        if (Test-Label -Label $pair.Label -Patterns @(
                '^(?i)signal$',
                '^(?i)сигнал$'
            )) {
            $currentBssid.Signal = Get-SignalPercent -Text $pair.Value
            continue
        }

        if (Test-Label -Label $pair.Label -Patterns @(
                '(?i)radio\s*type',
                '(?i)тип\s+радио',
                '(?i)тип\s+радіо'
            )) {
            $currentBssid.RadioType = $pair.Value
            continue
        }

        if (Test-Label -Label $pair.Label -Patterns @(
                '^(?i)channel$',
                '^(?i)канал$'
            )) {
            $channel = 0

            if ([int]::TryParse($pair.Value, [ref]$channel)) {
                $currentBssid.Channel = $channel
            }
        }
    }

    if ($null -ne $currentBssid) {
        $accessPoints += [pscustomobject]$currentBssid
    }

    return $accessPoints
}

function Get-ShortText {
    param (
        [string]$Text,
        [int]$MaxLength
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return '[прихована мережа]'
    }

    if ($Text.Length -le $MaxLength) {
        return $Text
    }

    return $Text.Substring(0, $MaxLength - 3) + '...'
}

function Get-CompetingAccessPoints {
    param(
        [object[]]$AccessPoints,
        [int]$CurrentChannel,
        [string]$CurrentBssid
    )

    if ($CurrentChannel -lt 1) {
        return @()
    }

    return @(
        $AccessPoints |
        Where-Object {
            $isCurrent = (
                -not [string]::IsNullOrWhiteSpace($CurrentBssid) -and
                ([string]$_.BSSID).Equals(
                    $CurrentBssid,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            )

            if ($isCurrent) {
                $false
            }
            elseif ($CurrentChannel -le 14) {
                # У діапазоні 2,4 ГГц сусідні канали перекриваються.
                (
                    [int]$_.Channel -ge [Math]::Max(1, $CurrentChannel - 4) -and
                    [int]$_.Channel -le [Math]::Min(14, $CurrentChannel + 4)
                )
            }
            else {
                [int]$_.Channel -eq $CurrentChannel
            }
        }
    )
}

function Get-ChannelColor {
    param (
        [int]$Count
    )

    if ($Count -le 2) {
        return [ConsoleColor]::Green
    }

    if ($Count -le 5) {
        return [ConsoleColor]::Yellow
    }

    return [ConsoleColor]::Red
}

Write-Host ''
Write-Host 'Комплексна діагностика Wi-Fi' -ForegroundColor Cyan
Write-Host 'Збирання даних через netsh wlan...' -ForegroundColor DarkGray

$wlanService = Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue

$interfaceLines = @(
    & netsh wlan show interfaces 2>&1 |
    ForEach-Object { [string]$_ }
)

$driverLines = @(
    & netsh wlan show drivers 2>&1 |
    ForEach-Object { [string]$_ }
)

$networkLines = @(
    & netsh wlan show networks mode=bssid 2>&1 |
    ForEach-Object { [string]$_ }
)

$interfaces = @(Get-WlanInterfaceBlocks -Lines $interfaceLines)
$driverProperties = Get-DriverProperties -Lines $driverLines
$accessPoints = @(Get-VisibleAccessPoints -Lines $networkLines)

$netshProblemPattern = (
    '(?i)access is denied|доступ запрещ|відмовлено в доступі|' +
    'location.*required|потрібна.*местополож|потріб.*розташув|' +
    'wireless.*service.*not running|служба.*автонастрой.*не запущ'
)

$netshMessages = @(
    @($interfaceLines + $driverLines + $networkLines) |
    Where-Object { $_ -match $netshProblemPattern } |
    Select-Object -Unique
)

Write-Section -Title 'СЛУЖБА ТА АДАПТЕР'

if ($null -eq $wlanService) {
    Write-Value -Label 'Служба WLAN' -Value 'не знайдена' -Color Red
}
elseif ($wlanService.Status -eq 'Running') {
    Write-Value -Label 'Служба WLAN' -Value 'працює' -Color Green
}
else {
    Write-Value `
        -Label 'Служба WLAN' `
        -Value "не запущена ($($wlanService.Status))" `
        -Color Red
}

if ($interfaces.Count -eq 0) {
    Write-Host ''
    Write-Host '[FAIL] Бездротовий інтерфейс не знайдено або вимкнено.' `
        -ForegroundColor Red
    Write-Host ''
    Write-Host 'Перевір наявність Wi-Fi адаптера, драйвера та стан служби WlanSvc.' `
        -ForegroundColor Yellow

    Write-Section -Title 'ДРАЙВЕР'

    Write-Value `
        -Label 'Драйвер' `
        -Value (Get-PropertyValue -Properties $driverProperties -Patterns @(
            '^(?i)driver$',
            '^(?i)драйвер$'
        ))

    Write-Value `
        -Label 'Версія' `
        -Value (Get-PropertyValue -Properties $driverProperties -Patterns @(
            '(?i)version',
            '(?i)версия',
            '(?i)версія'
        ))

    return
}

$currentSsid = ''
$currentBssidAddress = ''
$currentChannel = 0

$interfaceNumber = 0

foreach ($interface in $interfaces) {
    $interfaceNumber++

    $name = Get-PropertyValue -Properties $interface -Patterns @(
        '^(?i)name$',
        '^(?i)имя$',
        "^(?i)ім['’]?я$"
    )

    $description = Get-PropertyValue -Properties $interface -Patterns @(
        '(?i)description',
        '(?i)описание',
        '(?i)опис'
    )

    $state = Get-PropertyValue -Properties $interface -Patterns @(
        '^(?i)state$',
        '^(?i)состояние$',
        '^(?i)стан$'
    )

    $ssid = Get-PropertyValue -Properties $interface -Patterns @(
        '^(?i)SSID$'
    )

    $bssid = Get-PropertyValue -Properties $interface -Patterns @(
        '^(?i)BSSID$'
    )

    $radioType = Get-PropertyValue -Properties $interface -Patterns @(
        '(?i)radio\s*type',
        '(?i)тип\s+радио',
        '(?i)тип\s+радіо'
    )

    $auth = Get-PropertyValue -Properties $interface -Patterns @(
        '(?i)authentication',
        '(?i)проверка\s+автентичності',
        '(?i)автентифікац',
        '(?i)аутентифікац'
    )

    $cipher = Get-PropertyValue -Properties $interface -Patterns @(
        '(?i)cipher',
        '(?i)шифр'
    )

    $channelText = Get-PropertyValue -Properties $interface -Patterns @(
        '^(?i)channel$',
        '^(?i)канал$'
    )

    $signalText = Get-PropertyValue -Properties $interface -Patterns @(
        '^(?i)signal$',
        '^(?i)сигнал$'
    )

    $receiveRate = Get-PropertyValue -Properties $interface -Patterns @(
        '(?i)receive\s*rate',
        '(?i)скорость\s+приема',
        '(?i)швидкість\s+прийм',
        '(?i)швидкість\s+отрим'
    )

    $transmitRate = Get-PropertyValue -Properties $interface -Patterns @(
        '(?i)transmit\s*rate',
        '(?i)скорость\s+перетакчи',
        '(?i)швидкість\s+перед'
    )

    $profile = Get-PropertyValue -Properties $interface -Patterns @(
        '^(?i)profile$',
        '^(?i)профиль$',
        '^(?i)профіль$'
    )

    $connected = Test-ConnectedState -State $state

    Write-Host "Інтерфейс $interfaceNumber" -ForegroundColor Cyan
    Write-Value -Label 'Ім’я' -Value $name
    Write-Value -Label 'Адаптер' -Value $description

    if ($connected) {
        Write-Value -Label 'Стан' -Value $state -Color Green
    }
    else {
        Write-Value -Label 'Стан' -Value $state -Color Red
    }

    if ($connected) {
        Write-Value -Label 'SSID' -Value $ssid -Color Cyan
        Write-Value -Label 'BSSID точки' -Value $bssid
        Write-Value -Label 'Стандарт Wi-Fi' -Value $radioType
        Write-Value -Label 'Захист' -Value "$auth / $cipher"
        Write-Value -Label 'Канал' -Value $channelText
        Write-Value -Label 'Приймання, Мбіт/с' -Value $receiveRate
        Write-Value -Label 'Передавання, Мбіт/с' -Value $transmitRate
        Write-Value -Label 'Профіль' -Value $profile

        $signal = Get-SignalInfo -Percent (Get-SignalPercent -Text $signalText)

        Write-Host ('{0,-24}: ' -f 'Сигнал') -NoNewline

        if ($signal.Known) {
            Write-Host "[$($signal.Bar)] $($signal.Percent)% — $($signal.Label)" `
                -ForegroundColor $signal.Color
        }
        else {
            Write-Host "[$($signal.Bar)] $($signal.Label)" `
                -ForegroundColor $signal.Color
        }

        if ([string]::IsNullOrWhiteSpace($currentSsid)) {
            $currentSsid = $ssid
            $currentBssidAddress = $bssid

            [void][int]::TryParse($channelText, [ref]$currentChannel)
        }
    }
    else {
        Write-Host ''
        Write-Host 'Адаптер зараз не підключений до бездротової мережі.' `
            -ForegroundColor Yellow
    }

    Write-Host ''
}

Write-Section -Title 'ДРАЙВЕР І МОЖЛИВОСТІ'

Write-Value `
    -Label 'Драйвер' `
    -Value (Get-PropertyValue -Properties $driverProperties -Patterns @(
        '^(?i)driver$',
        '^(?i)драйвер$'
    ))

Write-Value `
    -Label 'Виробник' `
    -Value (Get-PropertyValue -Properties $driverProperties -Patterns @(
        '(?i)vendor',
        '(?i)производитель',
        '(?i)виробник'
    ))

Write-Value `
    -Label 'Постачальник' `
    -Value (Get-PropertyValue -Properties $driverProperties -Patterns @(
        '(?i)provider',
        '(?i)поставщик',
        '(?i)постачальник'
    ))

Write-Value `
    -Label 'Такта' `
    -Value (Get-PropertyValue -Properties $driverProperties -Patterns @(
        '^(?i)date$',
        '^(?i)такта$'
    ))

Write-Value `
    -Label 'Версія' `
    -Value (Get-PropertyValue -Properties $driverProperties -Patterns @(
        '(?i)version',
        '(?i)версия',
        '(?i)версія'
    ))

Write-Value `
    -Label 'Підтримувані режими' `
    -Value (Get-PropertyValue -Properties $driverProperties -Patterns @(
        '(?i)radio\s*types\s*supported',
        '(?i)поддерживаемые\s+типы\s+радио',
        '(?i)підтримувані\s+типи\s+радіо'
    ))

if ($accessPoints.Count -eq 0) {
    Write-Section -Title 'ЕФІР'

    Write-Host '[WARN] Точки доступу не виявлено.' -ForegroundColor Yellow
    Write-Host 'Можливо, Wi-Fi вимкнено, сканування заборонене або поруч немає мереж.' `
        -ForegroundColor DarkYellow

    if ($netshMessages.Count -gt 0) {
        Write-Host ''

        foreach ($message in $netshMessages | Select-Object -First 4) {
            Write-Host ("  $message") -ForegroundColor Yellow
        }
    }

    return
}

Write-Section -Title 'НАЙБЛИЖЧІ МЕРЕЖІ'

$networkSummary = @()

$ssidGroups = $accessPoints | Group-Object -Property SSID

foreach ($group in $ssidGroups) {
    $strongest = $group.Group |
        Sort-Object -Property Signal -Descending |
        Select-Object -First 1

    $channels = @(
        $group.Group |
        Where-Object { $_.Channel -gt 0 } |
        Select-Object -ExpandProperty Channel -Unique |
        Sort-Object
    )

    $radioTypes = @(
        $group.Group |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.RadioType) } |
        Select-Object -ExpandProperty RadioType -Unique
    )

    $networkSummary += [pscustomobject]@{
        SSID       = $group.Name
        Signal     = [int]$strongest.Signal
        BssidCount = $group.Count
        Channels   = ($channels -join ', ')
        RadioTypes = ($radioTypes -join ', ')
        Auth       = [string]$strongest.Auth
    }
}

$networkSummary = @(
    $networkSummary |
    Sort-Object -Property Signal -Descending
)

$shown = 0

foreach ($network in $networkSummary) {
    $shown++

    if ($shown -gt 20) {
        break
    }

    $signal = Get-SignalInfo -Percent $network.Signal
    $ssidText = Get-ShortText -Text $network.SSID -MaxLength 32
    $marker = ' '

    if (-not [string]::IsNullOrWhiteSpace($currentSsid) -and
        $network.SSID -eq $currentSsid) {
        $marker = '*'
    }

    Write-Host ("$marker {0,-32} " -f $ssidText) -NoNewline

    Write-Host ("{0,3}% " -f $signal.Percent) `
        -NoNewline `
        -ForegroundColor $signal.Color

    Write-Host ("AP: {0,-2} Канали: {1,-12} {2}" -f `
        $network.BssidCount,
        $network.Channels,
        $network.RadioTypes)
}

if ($networkSummary.Count -gt 20) {
    Write-Host ''
    Write-Host "Показано 20 з $($networkSummary.Count) мереж." `
        -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '* — мережа, до якої зараз підключений комп’ютер' `
    -ForegroundColor DarkGray

Write-Section -Title 'ЗАВАНТАЖЕНІСТЬ КАНАЛІВ'

$channelGroups = @(
    $accessPoints |
    Where-Object { $_.Channel -gt 0 } |
    Group-Object -Property Channel |
    Sort-Object { [int]$_.Name }
)

foreach ($channelGroup in $channelGroups) {
    $channelNumber = [int]$channelGroup.Name
    $count = $channelGroup.Count
    $color = Get-ChannelColor -Count $count
    $currentMarker = ''

    if ($currentChannel -eq $channelNumber) {
        $currentMarker = '  <-- поточний канал'
    }

    Write-Host ("Канал {0,-4}: " -f $channelNumber) -NoNewline
    Write-Host ("{0} точок доступу{1}" -f $count, $currentMarker) `
        -ForegroundColor $color
}

if ($currentChannel -gt 0) {
    $competitorAccessPoints = @(
        Get-CompetingAccessPoints `
            -AccessPoints $accessPoints `
            -CurrentChannel $currentChannel `
            -CurrentBssid $currentBssidAddress
    )

    $competitors = $competitorAccessPoints.Count
    $competitionLabel = if ($currentChannel -le 14) {
        'Сусідніх BSSID на каналах, що перекриваються'
    }
    else {
        'Сусідніх BSSID на тому самому каналі'
    }

    Write-Host ''
    Write-Host "$competitionLabel`: " -NoNewline

    $competitionColor = Get-ChannelColor -Count ($competitors + 1)

    Write-Host $competitors -ForegroundColor $competitionColor

    if ($competitors -eq 0) {
        Write-Host '[OK] Явної конкуренції в ефірі не видно.' -ForegroundColor Green
    }
    elseif ($competitors -le 3) {
        Write-Host '[WARN] Ефір помірно завантажений.' -ForegroundColor Yellow
    }
    else {
        Write-Host '[FAIL] Ефір біля поточного каналу помітно перевантажений.' `
            -ForegroundColor Red
    }
}

Write-Section -Title 'ПІДСУМОК'

$connectedInterface = $null

foreach ($interface in $interfaces) {
    $state = Get-PropertyValue -Properties $interface -Patterns @(
        '^(?i)state$',
        '^(?i)состояние$',
        '^(?i)стан$'
    )

    if (Test-ConnectedState -State $state) {
        $connectedInterface = $interface
        break
    }
}

if ($null -eq $connectedInterface) {
    Write-Host '[FAIL] Комп’ютер не підключено до Wi-Fi.' -ForegroundColor Red
}
else {
    $signalText = Get-PropertyValue -Properties $connectedInterface -Patterns @(
        '^(?i)signal$',
        '^(?i)сигнал$'
    )

    $signal = Get-SignalInfo -Percent (Get-SignalPercent -Text $signalText)

    if (-not $signal.Known) {
        Write-Host '[WARN] Драйвер не повідомив рівень сигналу.' `
            -ForegroundColor Yellow
    }
    elseif ($signal.Percent -ge 65) {
        Write-Host '[OK] Рівень сигналу достатній.' -ForegroundColor Green
    }
    elseif ($signal.Percent -ge 50) {
        Write-Host '[WARN] Сигнал прийнятний, але можливі просідання швидкості.' `
            -ForegroundColor Yellow
    }
    else {
        Write-Host '[FAIL] Слабкий сигнал може бути причиною нестабільної роботи.' `
            -ForegroundColor Red
    }

    if ($currentChannel -gt 0) {
        $competitorCount = @(
            Get-CompetingAccessPoints `
                -AccessPoints $accessPoints `
                -CurrentChannel $currentChannel `
                -CurrentBssid $currentBssidAddress
        ).Count

        if ($competitorCount -ge 4) {
            Write-Host '[FAIL] Радіоефір біля поточного каналу перевантажений.' `
                -ForegroundColor Red
        }
        elseif ($competitorCount -ge 2) {
            Write-Host '[WARN] У радіоефірі є помітна конкуренція.' `
                -ForegroundColor Yellow
        }
        else {
            Write-Host '[OK] Критичної конкуренції в радіоефірі не видно.' `
                -ForegroundColor Green
        }
    }
}

Write-Host ''
Write-Host 'Примітка: відсоток сигналу повідомляє драйвер Wi-Fi; це оцінка, а не dBm.' `
    -ForegroundColor DarkGray
