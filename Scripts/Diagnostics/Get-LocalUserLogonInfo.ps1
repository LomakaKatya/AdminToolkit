Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ''
Write-Host 'Локальні користувачі та час останнього входу' -ForegroundColor Cyan
Write-Host 'Збираю дані локальних облікових записів...' -ForegroundColor DarkGray
Write-Host ''

$adsi = [ADSI]("WinNT://{0}" -f $env:COMPUTERNAME)

$users = @(
    $adsi.Children |
    Where-Object {
        $_.SchemaClassName -eq 'user'
    } |
    ForEach-Object {
        $lastLogin = $null
        $disabled = $null

        try {
            $lastLogin = [datetime]$_.Properties['LastLogin'].Value
        }
        catch {
        }

        try {
            $flags = [int]$_.Properties['UserFlags'].Value
            $disabled = (($flags -band 2) -eq 2)
        }
        catch {
        }

        [pscustomobject]@{
            Name       = [string]$_.Name
            LastLogon  = $lastLogin
            Disabled   = $disabled
        }
    } |
    Sort-Object `
        -Property @{
            Expression = {
                if ($null -eq $_.LastLogon) {
                    [datetime]::MinValue
                }
                else {
                    $_.LastLogon
                }
            }
            Descending = $true
        }, Name
)

if ($users.Count -eq 0) {
    Write-Host '[WARN] Локальних користувачів не знайдено.' -ForegroundColor Yellow
    return
}

Write-Host ('{0,-28} {1,-20} {2}' -f 'Користувач', 'Останній вхід', 'Стан') `
    -ForegroundColor DarkGray
Write-Host ('-' * 68) -ForegroundColor DarkGray

foreach ($user in $users) {
    $lastLogonText = if ($null -eq $user.LastLogon) {
        'немає даних'
    }
    else {
        $user.LastLogon.ToString('dd.MM.yyyy HH:mm:ss')
    }

    $stateText = if ($user.Disabled -eq $true) {
        'вимкнений'
    }
    elseif ($user.Disabled -eq $false) {
        'активний'
    }
    else {
        'не визначено'
    }

    $color = if ($user.Disabled -eq $true) {
        [ConsoleColor]::DarkGray
    }
    elseif ($null -eq $user.LastLogon) {
        [ConsoleColor]::Yellow
    }
    else {
        [ConsoleColor]::Green
    }

    Write-Host (
        '{0,-28} {1,-20} {2}' -f
        $user.Name,
        $lastLogonText,
        $stateText
    ) -ForegroundColor $color
}

Write-Host ''
Write-Host ('[OK] Облікових записів: {0}' -f $users.Count) -ForegroundColor Green
Write-Host 'Примітка: для локальних облікових записів поле LastLogin може бути порожнім або не відображати всі типи входу.' `
    -ForegroundColor DarkGray
