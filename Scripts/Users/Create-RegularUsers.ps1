#requires -version 5.1
<#
Create-RegularUsers-Universal.ps1

Что делает:
1. Проверяет часовой пояс сервера и выставляет Киев: FLE Standard Time.
2. Настраивает раскладки клавиатуры RU, UK, EN-US:
   - текущему пользователю;
   - уже существующим профилям;
   - Default-профилю;
   - через Active Setup для будущих входов пользователей.
3. Читает пользователей из локального файла ProgramData\RaccoonAdminToolkit\UserProvisioning\users.csv.
4. Если компьютер в домене и доступен модуль ActiveDirectory:
   - спрашивает OU для новых пользователей и создаёт её при необходимости;
   - создаёт доменных пользователей;
   - если пользователь уже существует, меняет ему пароль на новый;
   - выдаёт пользователю право входа через Remote Desktop Users.
5. Если домена нет или AD-модуль недоступен:
   - создаёт локальных пользователей;
   - если пользователь уже существует, меняет ему пароль на новый;
   - добавляет пользователя в локальную Remote Desktop Users.
6. Запрещает пользователям менять пароль самостоятельно.
7. Ставит "Срок действия пароля не ограничен".
8. На каждого пользователя создаёт отдельную папку:
   ProgramData\RaccoonAdminToolkit\UserProvisioning\Result\ORG_login\
      ORG_login.rdp
      ORG_login.txt
9. Создаёт CSV для внутреннего учёта:
   ProgramData\RaccoonAdminToolkit\UserProvisioning\Result\ORG_users_accounting.csv

Ожидаемый users.csv:
Login,FullName,Phone,Title
persona17,Иванов Иван,+380670000000,Бухгалтер
persona18,Петров Пётр,,Менеджер

Обязательное поле:
Login

Необязательные поля:
FullName
Phone
Title
#>

$ErrorActionPreference = 'Stop'

# =========================
# ЛОКАЛЬНЫЕ РАБОЧИЕ ДАННЫЕ
# =========================

# Сам скрипт загружается из Git и выполняется в памяти.
# CSV, отчёты и пароли остаются только на текущем сервере.
$DataRoot = Join-Path `
    $env:ProgramData `
    'RaccoonAdminToolkit\UserProvisioning'

$CsvPath = Join-Path `
    $DataRoot `
    'users.csv'

$OutputRoot = Join-Path `
    $DataRoot `
    'Result'

$LogPath = Join-Path `
    $DataRoot `
    'Create-RegularUsers.log'

if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) {
    New-Item `
        -Path $DataRoot `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop |
    Out-Null
}

# =========================
# НАСТРОЙКИ
# =========================

$PasswordLength = 15

# Киевский часовой пояс в Windows
$RequiredTimeZoneId = "FLE Standard Time"

# Раскладки:
# 00000419 = Russian
# 00000422 = Ukrainian
# 00000409 = English US
$KeyboardLayouts = @(
    "00000419",
    "00000422",
    "00000409"
)

# Группа для доменных пользователей.
# Если не надо добавлять в отдельную группу, оставить пустым.
# Пример:
# $DomainGroupToAdd = "GG_RDS_Users"
$DomainGroupToAdd = ""

# Базовая локальная группа Users и группа RDP-доступа.
$LocalGroupSidToAdd = 'S-1-5-32-545'
$RemoteDesktopUsersSid = 'S-1-5-32-555'

# Требовать смену пароля при первом входе.
# Для готовых RDP-комплектов обычно удобнее $false.
$ChangePasswordAtLogon = $false

# Разрешать пользователю самостоятельно менять пароль.
# $false = поставить "Запретить смену пароля пользователем"
$UserCanChangePassword = $false

# Срок действия пароля не ограничен.
$PasswordNeverExpires = $true

# Включать учётку после создания/обновления.
$EnableUsers = $true

# =========================
# ФУНКЦИИ
# =========================

function Test-RunAsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        -TypeName Security.Principal.WindowsPrincipal `
        -ArgumentList $Identity

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Time] [$Level] $Message"

    Write-Host $Line
    Add-Content -Path $LogPath -Value $Line -Encoding UTF8
}

function Get-SafeFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return ($Name.Trim() -replace '[\\/:*?"<>|]', '_')
}

function Get-ValueOrDash {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return "-"
    }

    $Text = [string]$Value

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "-"
    }

    return $Text.Trim()
}

function New-StrongPassword {
    param(
        [int]$Length = 15
    )

    if ($Length -lt 8) {
        throw "Длина пароля должна быть не меньше 8 символов."
    }

    $Upper   = [char[]]"ABCDEFGHJKLMNPQRSTUVWXYZ"
    $Lower   = [char[]]"abcdefghijkmnopqrstuvwxyz"
    $Digits  = [char[]]"23456789"
    $Special = [char[]]"!@#$%_-+=?"

    # Первый символ только буква или цифра.
    $FirstPool = @($Upper + $Lower + $Digits)
    $FirstChar = $FirstPool | Get-Random

    # В хвосте гарантируем все обязательные категории.
    $Required = @(
        ($Upper   | Get-Random),
        ($Lower   | Get-Random),
        ($Digits  | Get-Random),
        ($Special | Get-Random)
    )

    $RemainingCount = $Length - 1 - $Required.Count
    $AllPool = @($Upper + $Lower + $Digits + $Special)
    $Remaining = @()

    for ($i = 0; $i -lt $RemainingCount; $i++) {
        $Remaining += ($AllPool | Get-Random)
    }

    $Tail = @($Required + $Remaining) |
        Sort-Object {
            Get-Random
        }

    return (
        -join @($FirstChar) +
        ($Tail -join "")
    )
}

function Ensure-HKUDrive {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive `
            -Name HKU `
            -PSProvider Registry `
            -Root HKEY_USERS `
            -Scope Script `
            -ErrorAction Stop |
        Out-Null
    }
}

function Set-KeyboardLayoutsInHive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HiveRoot
    )

    $PreloadPath = Join-Path $HiveRoot "Keyboard Layout\Preload"

    if (-not (Test-Path $PreloadPath)) {
        New-Item -Path $PreloadPath -Force | Out-Null
    }

    $Existing = Get-ItemProperty -Path $PreloadPath -ErrorAction SilentlyContinue

    if ($Existing) {
        $Existing.PSObject.Properties |
            Where-Object { $_.Name -match '^\d+$' } |
            ForEach-Object {
                Remove-ItemProperty -Path $PreloadPath -Name $_.Name -ErrorAction SilentlyContinue
            }
    }

    for ($i = 0; $i -lt $KeyboardLayouts.Count; $i++) {
        $Name = [string]($i + 1)
        $Value = $KeyboardLayouts[$i]
        New-ItemProperty -Path $PreloadPath -Name $Name -Value $Value -PropertyType String -Force | Out-Null
    }
}

function Set-KeyboardLayoutsForCurrentUser {
    try {
        Write-Log "Настраиваю раскладки для текущего пользователя."

        $LanguageList = New-WinUserLanguageList -Language "ru-RU"
        $LanguageList.Add("uk-UA")
        $LanguageList.Add("en-US")

        Set-WinUserLanguageList -LanguageList $LanguageList -Force

        Set-KeyboardLayoutsInHive -HiveRoot "HKCU:"

        Write-Log "Раскладки для текущего пользователя настроены: RU, UK, EN-US."
    }
    catch {
        Write-Log "Не удалось настроить раскладки через Set-WinUserLanguageList. Пробую только через реестр: $($_.Exception.Message)" "WARN"

        try {
            Set-KeyboardLayoutsInHive -HiveRoot "HKCU:"
            Write-Log "Раскладки для текущего пользователя настроены через реестр."
        }
        catch {
            Write-Log "Не удалось настроить раскладки текущего пользователя: $($_.Exception.Message)" "WARN"
        }
    }
}

function Set-KeyboardLayoutsForDefaultProfile {
    Ensure-HKUDrive

    $DefaultNtUser = "C:\Users\Default\NTUSER.DAT"
    $TempHiveName = "DEFAULT_USER_KEYBOARD_TEMP"
    $TempHivePath = "HKU:\$TempHiveName"

    if (-not (Test-Path $DefaultNtUser)) {
        Write-Log "Default-профиль не найден: $DefaultNtUser" "WARN"
        return
    }

    try {
        Write-Log "Настраиваю раскладки в Default-профиле."

        reg load "HKU\$TempHiveName" "$DefaultNtUser" | Out-Null

        try {
            Set-KeyboardLayoutsInHive -HiveRoot $TempHivePath
            Write-Log "Раскладки в Default-профиле настроены."
        }
        finally {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 500
            reg unload "HKU\$TempHiveName" | Out-Null
        }
    }
    catch {
        Write-Log "Не удалось настроить Default-профиль: $($_.Exception.Message)" "WARN"

        try {
            reg unload "HKU\$TempHiveName" | Out-Null
        }
        catch {
        }
    }
}

function Set-KeyboardLayoutsForExistingProfiles {
    Ensure-HKUDrive

    Write-Log "Настраиваю раскладки для существующих профилей пользователей."

    $ProfileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

    $Profiles = Get-ChildItem $ProfileListPath -ErrorAction SilentlyContinue |
        ForEach-Object {
            $Profile = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue

            if ($Profile.ProfileImagePath) {
                [pscustomobject]@{
                    Sid  = $_.PSChildName
                    Path = $Profile.ProfileImagePath
                }
            }
        } |
        Where-Object {
            $_.Sid -match '^S-1-5-21-' -and
            $_.Path -notmatch '\\(Default|Default User|Public|All Users)$'
        }

    foreach ($Profile in $Profiles) {
        $Sid = $Profile.Sid
        $ProfilePath = [Environment]::ExpandEnvironmentVariables($Profile.Path)
        $NtUserDat = Join-Path $ProfilePath "NTUSER.DAT"

        try {
            if (Test-Path "HKU:\$Sid") {
                Set-KeyboardLayoutsInHive -HiveRoot "HKU:\$Sid"
                Write-Log "Раскладки настроены для загруженного профиля: $ProfilePath"
                continue
            }

            if (-not (Test-Path $NtUserDat)) {
                Write-Log "NTUSER.DAT не найден для профиля $ProfilePath" "WARN"
                continue
            }

            $TempHiveName = "TEMP_KEYBOARD_$($Sid -replace '-', '_')"
            $TempHivePath = "HKU:\$TempHiveName"

            reg load "HKU\$TempHiveName" "$NtUserDat" | Out-Null

            try {
                Set-KeyboardLayoutsInHive -HiveRoot $TempHivePath
                Write-Log "Раскладки настроены для профиля: $ProfilePath"
            }
            finally {
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                Start-Sleep -Milliseconds 500
                reg unload "HKU\$TempHiveName" | Out-Null
            }
        }
        catch {
            Write-Log "Не удалось настроить раскладки для профиля $ProfilePath : $($_.Exception.Message)" "WARN"

            if ($TempHiveName) {
                try {
                    reg unload "HKU\$TempHiveName" | Out-Null
                }
                catch {
                }
            }
        }
    }
}

function Register-KeyboardLayoutsActiveSetup {
    try {
        Write-Log "Регистрирую Active Setup для раскладок новых пользователей."

        $ActiveSetupPath = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\BIT_SetKeyboardLayouts_RU_UK_EN"

        if (-not (Test-Path $ActiveSetupPath)) {
            New-Item -Path $ActiveSetupPath -Force | Out-Null
        }

        $StubCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=''HKCU:\Keyboard Layout\Preload''; New-Item -Path $p -Force | Out-Null; Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | ForEach-Object { $_.PSObject.Properties | Where-Object { $_.Name -match ''^\d+$'' } | ForEach-Object { Remove-ItemProperty -Path $p -Name $_.Name -ErrorAction SilentlyContinue } }; New-ItemProperty -Path $p -Name ''1'' -Value ''00000419'' -PropertyType String -Force | Out-Null; New-ItemProperty -Path $p -Name ''2'' -Value ''00000422'' -PropertyType String -Force | Out-Null; New-ItemProperty -Path $p -Name ''3'' -Value ''00000409'' -PropertyType String -Force | Out-Null"'

        New-ItemProperty -Path $ActiveSetupPath -Name "Version" -Value "1,0,0,1" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $ActiveSetupPath -Name "StubPath" -Value $StubCommand -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $ActiveSetupPath -Name "IsInstalled" -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $ActiveSetupPath -Name "Locale" -Value "*" -PropertyType String -Force | Out-Null

        Write-Log "Active Setup для раскладок зарегистрирован."
    }
    catch {
        Write-Log "Не удалось зарегистрировать Active Setup для раскладок: $($_.Exception.Message)" "WARN"
    }
}

function Ensure-KyivTimeZone {
    try {
        $CurrentTimeZone = Get-TimeZone

        if ($CurrentTimeZone.Id -ne $RequiredTimeZoneId) {
            Write-Log "Текущий часовой пояс: $($CurrentTimeZone.Id). Меняю на $RequiredTimeZoneId."
            Set-TimeZone -Id $RequiredTimeZoneId
            $NewTimeZone = Get-TimeZone
            Write-Log "Часовой пояс установлен: $($NewTimeZone.Id), $($NewTimeZone.DisplayName)."
        }
        else {
            Write-Log "Часовой пояс уже корректный: $($CurrentTimeZone.Id), $($CurrentTimeZone.DisplayName)."
        }
    }
    catch {
        Write-Log "Не удалось проверить или изменить часовой пояс: $($_.Exception.Message)" "WARN"
    }
}

function Ensure-KeyboardLayouts {
    Set-KeyboardLayoutsForCurrentUser
    Set-KeyboardLayoutsForExistingProfiles
    Set-KeyboardLayoutsForDefaultProfile
    Register-KeyboardLayoutsActiveSetup
}

function Test-IsDomainJoined {
    try {
        $ComputerSystem = Get-CimInstance Win32_ComputerSystem
        return [bool]$ComputerSystem.PartOfDomain
    }
    catch {
        Write-Log "Не удалось определить, в домене ли компьютер: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Test-ADModuleAvailable {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Test-IsDomainController {
    $ComputerSystem = Get-CimInstance `
        -ClassName Win32_ComputerSystem `
        -ErrorAction Stop

    return ([int]$ComputerSystem.DomainRole -in @(4, 5))
}

function Add-LocalGroupMemberSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupName,

        [Parameter(Mandatory = $true)]
        [string]$MemberName
    )

    try {
        Add-LocalGroupMember `
            -Group $GroupName `
            -Member $MemberName `
            -ErrorAction Stop

        Write-Log "'$MemberName' добавлен в локальную группу '$GroupName'."
    }
    catch {
        if ($_.Exception.Message -match 'already|уже|вже|ist bereits|является членом') {
            Write-Log "'$MemberName' уже состоит в локальной группе '$GroupName'."
            return
        }

        throw
    }
}

function Ensure-DomainUserRdpAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Login
    )

    if (Test-IsDomainController) {
        $RdpGroup = Get-ADGroup `
            -Identity $RemoteDesktopUsersSid `
            -ErrorAction Stop

        $Account = Get-ADUser `
            -Identity $Login `
            -Properties SID `
            -ErrorAction Stop

        $AlreadyMember = @(
            Get-ADGroupMember `
                -Identity $RdpGroup `
                -ErrorAction Stop |
            Where-Object {
                $_.SID -eq $Account.SID
            }
        ).Count -gt 0

        if (-not $AlreadyMember) {
            Add-ADGroupMember `
                -Identity $RdpGroup `
                -Members $Account `
                -ErrorAction Stop
        }

        Write-Log (
            "RDP-доступ разрешён пользователю '$Login' через " +
            "'$($RdpGroup.Name)' на контроллере домена."
        )

        return
    }

    $RdpGroupName = Resolve-LocalGroupNameBySid `
        -Sid $RemoteDesktopUsersSid

    if ([string]::IsNullOrWhiteSpace($RdpGroupName)) {
        throw "Локальная группа Remote Desktop Users не найдена. SID: $RemoteDesktopUsersSid"
    }

    $Domain = Get-ADDomain -ErrorAction Stop
    $MemberName = "$($Domain.NetBIOSName)\$Login"

    Add-LocalGroupMemberSafe `
        -GroupName $RdpGroupName `
        -MemberName $MemberName

    Write-Log "RDP-доступ разрешён доменному пользователю '$MemberName'."
}

function Ensure-LocalUserRdpAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Login
    )

    $RdpGroupName = Resolve-LocalGroupNameBySid `
        -Sid $RemoteDesktopUsersSid

    if ([string]::IsNullOrWhiteSpace($RdpGroupName)) {
        throw "Локальная группа Remote Desktop Users не найдена. SID: $RemoteDesktopUsersSid"
    }

    Add-LocalGroupMemberSafe `
        -GroupName $RdpGroupName `
        -MemberName $Login

    Write-Log "RDP-доступ разрешён локальному пользователю '$Login'."
}

function Resolve-DomainOrganizationalUnit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DomainDN
    )

    Write-Host ''
    Write-Host (
        "Текущий домен: $DomainDN"
    ) -ForegroundColor DarkCyan

    Write-Host (
        'Введите имя OU или полный distinguishedName. ' +
        'Оставьте пустым, чтобы использовать стандартный контейнер Users.'
    ) -ForegroundColor Cyan

    $RequestedOU = Read-Host 'OU'

    if ([string]::IsNullOrWhiteSpace($RequestedOU)) {
        return ''
    }

    $RequestedOU = $RequestedOU.Trim()

    if ($RequestedOU -match '(?i)^OU=') {
        try {
            $OU = Get-ADOrganizationalUnit `
                -Identity $RequestedOU `
                -ErrorAction Stop
        }
        catch {
            throw (
                "Указанная OU не найдена: $RequestedOU. " +
                $_.Exception.Message
            )
        }

        if (
            -not $OU.DistinguishedName.EndsWith(
                ",$DomainDN",
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw (
                'Указанная OU не принадлежит текущему домену: ' +
                $OU.DistinguishedName
            )
        }

        return [string]$OU.DistinguishedName
    }

    $Matches = @(
        Get-ADOrganizationalUnit `
            -Filter * `
            -SearchBase $DomainDN `
            -SearchScope Subtree `
            -ErrorAction Stop |
        Where-Object {
            $_.Name -eq $RequestedOU
        }
    )

    if ($Matches.Count -eq 1) {
        return [string]$Matches[0].DistinguishedName
    }

    if ($Matches.Count -eq 0) {
        Write-Log (
            "OU '$RequestedOU' не найдена. " +
            "Создаю её в корне домена $DomainDN."
        ) 'WARN'

        $CreatedOU = New-ADOrganizationalUnit `
            -Name $RequestedOU `
            -Path $DomainDN `
            -ProtectedFromAccidentalDeletion $true `
            -PassThru `
            -ErrorAction Stop

        Write-Log (
            'OU создана: ' +
            $CreatedOU.DistinguishedName
        )

        return [string]$CreatedOU.DistinguishedName
    }

    $DistinguishedNames = @(
        $Matches |
        Select-Object -ExpandProperty DistinguishedName
    ) -join "`r`n  "

    throw (
        "Найдено несколько OU с именем '$RequestedOU'. " +
        "Повтори запуск и укажи полный distinguishedName:`r`n  " +
        $DistinguishedNames
    )
}

function New-RdpFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$UserName
    )

    $RdpContent = @"
screen mode id:i:2
use multimon:i:0
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
winposstr:s:0,3,0,0,800,600
compression:i:1
keyboardhook:i:2
audiocapturemode:i:0
videoplaybackmode:i:1
connection type:i:7
networkautodetect:i:1
bandwidthautodetect:i:1
displayconnectionbar:i:1
enableworkspacereconnect:i:0
disable wallpaper:i:0
allow font smoothing:i:1
allow desktop composition:i:1
disable full window drag:i:0
disable menu anims:i:0
disable themes:i:0
disable cursor setting:i:0
bitmapcachepersistenable:i:1
full address:s:$Server
audiomode:i:0
redirectprinters:i:1
redirectcomports:i:0
redirectsmartcards:i:1
redirectclipboard:i:1
redirectposdevices:i:0
drivestoredirect:s:
autoreconnection enabled:i:1
authentication level:i:2
prompt for credentials:i:1
negotiate security layer:i:1
remoteapplicationmode:i:0
alternate shell:s:
shell working directory:s:
gatewayhostname:s:
gatewayusagemethod:i:4
gatewaycredentialssource:i:4
gatewayprofileusagemethod:i:0
promptcredentialonce:i:0
use redirection server name:i:0
username:s:$UserName
"@

    $RdpContent | Out-File -FilePath $Path -Encoding ASCII -Force
}

function New-CredentialTxtFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Login,

        [Parameter(Mandatory = $true)]
        [string]$Password,

        [Parameter(Mandatory = $true)]
        [string]$Server
    )

    $TxtContent = @"
login: $Login
password: $Password
server: $Server
"@

    $TxtContent | Out-File -FilePath $Path -Encoding UTF8 -Force
}

function Resolve-LocalGroupNameBySid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sid
    )

    try {
        return (
            Get-LocalGroup `
                -SID $Sid `
                -ErrorAction Stop
        ).Name
    }
    catch {
        Write-Log (
            "Локальная группа с SID $Sid не найдена: " +
            $_.Exception.Message
        ) 'WARN'

        return $null
    }
}

function Set-LocalUserPasswordChangePermission {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Login,

        [Parameter(Mandatory = $true)]
        [bool]$CanChangePassword
    )

    try {
        if ($CanChangePassword) {
            cmd /c "net user `"$Login`" /passwordchg:yes" | Out-Null
        }
        else {
            cmd /c "net user `"$Login`" /passwordchg:no" | Out-Null
        }
    }
    catch {
        Write-Log "Не удалось изменить право смены пароля для локального пользователя '$Login': $($_.Exception.Message)" "WARN"
    }
}

function Create-OrUpdateDomainUser {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$User,

        [Parameter(Mandatory = $true)]
        [string]$PasswordPlain,

        [string]$DomainOU
    )

    $Login = $User.Login.Trim()
    $SecurePassword = ConvertTo-SecureString $PasswordPlain -AsPlainText -Force

    $ExistingUser = Get-ADUser -Filter "SamAccountName -eq '$Login'" -Properties PasswordNeverExpires -ErrorAction SilentlyContinue

    if ($ExistingUser) {
        Write-Log "Доменный пользователь '$Login' уже существует. Меняю пароль и параметры."

        Set-ADAccountPassword `
            -Identity $ExistingUser `
            -Reset `
            -NewPassword $SecurePassword `
            -ErrorAction Stop

        if ($EnableUsers) {
            Enable-ADAccount -Identity $ExistingUser -ErrorAction SilentlyContinue
        }

        Set-ADUser `
            -Identity $ExistingUser `
            -ChangePasswordAtLogon $ChangePasswordAtLogon `
            -PasswordNeverExpires $PasswordNeverExpires `
            -ErrorAction SilentlyContinue

        Set-ADAccountControl `
            -Identity $ExistingUser `
            -CannotChangePassword (-not $UserCanChangePassword) `
            -ErrorAction SilentlyContinue

        Ensure-DomainUserRdpAccess -Login $Login

        Write-Log "Пароль доменного пользователя '$Login' изменён. Смена пароля пользователем запрещена."
        return "PasswordChanged"
    }

    $Domain = Get-ADDomain

    $Params = @{
        SamAccountName        = $Login
        Name                  = if ($User.FullName) { $User.FullName } else { $Login }
        UserPrincipalName     = "$Login@$($Domain.DNSRoot)"
        AccountPassword       = $SecurePassword
        Enabled               = $EnableUsers
        ChangePasswordAtLogon = $ChangePasswordAtLogon
        PasswordNeverExpires  = $PasswordNeverExpires
    }

    if ($User.FullName) {
        $Params["DisplayName"] = $User.FullName
    }

    if ($User.Title) {
        $Params["Title"] = $User.Title
    }

    if ($User.Phone) {
        $Params["OfficePhone"] = $User.Phone
    }

    if (-not [string]::IsNullOrWhiteSpace($DomainOU)) {
        $Params["Path"] = $DomainOU
    }

    New-ADUser @Params

    Set-ADAccountControl `
        -Identity $Login `
        -CannotChangePassword (-not $UserCanChangePassword) `
        -ErrorAction SilentlyContinue

    if (-not [string]::IsNullOrWhiteSpace($DomainGroupToAdd)) {
        try {
            Add-ADGroupMember -Identity $DomainGroupToAdd -Members $Login -ErrorAction Stop
            Write-Log "Пользователь '$Login' добавлен в доменную группу '$DomainGroupToAdd'."
        }
        catch {
            Write-Log "Не удалось добавить '$Login' в группу '$DomainGroupToAdd': $($_.Exception.Message)" "WARN"
        }
    }

    Ensure-DomainUserRdpAccess -Login $Login

    Write-Log "Создан доменный пользователь '$Login'. Смена пароля пользователем запрещена."
    return "Created"
}

function Create-OrUpdateLocalUser {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$User,

        [Parameter(Mandatory = $true)]
        [string]$PasswordPlain
    )

    $Login = $User.Login.Trim()
    $SecurePassword = ConvertTo-SecureString $PasswordPlain -AsPlainText -Force

    $ExistingUser = Get-LocalUser -Name $Login -ErrorAction SilentlyContinue

    if ($ExistingUser) {
        Write-Log "Локальный пользователь '$Login' уже существует. Меняю пароль и параметры."

        Set-LocalUser `
            -Name $Login `
            -Password $SecurePassword `
            -PasswordNeverExpires $PasswordNeverExpires `
            -ErrorAction Stop

        if ($EnableUsers) {
            Enable-LocalUser -Name $Login -ErrorAction SilentlyContinue
        }

        Set-LocalUserPasswordChangePermission `
            -Login $Login `
            -CanChangePassword $UserCanChangePassword

        Ensure-LocalUserRdpAccess -Login $Login

        Write-Log "Пароль локального пользователя '$Login' изменён. Смена пароля пользователем запрещена."
        return "PasswordChanged"
    }

    $DescriptionParts = @()

    if ($User.Title) {
        $DescriptionParts += "Должность: $($User.Title)"
    }

    if ($User.Phone) {
        $DescriptionParts += "Телефон: $($User.Phone)"
    }

    $Description = $DescriptionParts -join "; "

    $Params = @{
        Name                     = $Login
        Password                 = $SecurePassword
        AccountNeverExpires      = $true
        PasswordNeverExpires     = $PasswordNeverExpires
        UserMayNotChangePassword = (-not $UserCanChangePassword)
    }

    if ($User.FullName) {
        $Params["FullName"] = $User.FullName
    }

    if ($Description) {
        $Params["Description"] = $Description
    }

    New-LocalUser @Params

    if ($EnableUsers) {
        Enable-LocalUser -Name $Login -ErrorAction SilentlyContinue
    }

    Set-LocalUserPasswordChangePermission `
        -Login $Login `
        -CanChangePassword $UserCanChangePassword

    $LocalGroupToAdd = Resolve-LocalGroupNameBySid `
        -Sid $LocalGroupSidToAdd

    if (-not [string]::IsNullOrWhiteSpace($LocalGroupToAdd)) {
        Add-LocalGroupMemberSafe `
            -GroupName $LocalGroupToAdd `
            -MemberName $Login
    }

    Ensure-LocalUserRdpAccess -Login $Login

    Write-Log "Создан локальный пользователь '$Login'. Смена пароля пользователем запрещена."
    return "Created"
}

# =========================
# СТАРТ
# =========================

if (-not (Test-RunAsAdministrator)) {
    throw 'Запусти Raccoon Admin Toolkit от имени администратора.'
}

Write-Log "============================================================"
Write-Log "Старт скрипта создания пользователей"
Write-Log "Рабочая папка: $DataRoot"
Write-Log "CSV: $CsvPath"
Write-Log "Папка результата: $OutputRoot"

if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    'Login,FullName,Phone,Title' |
        Set-Content `
            -LiteralPath $CsvPath `
            -Encoding UTF8 `
            -Force

    Write-Host ''
    Write-Host '[INFO] Создан пустой шаблон users.csv.' `
        -ForegroundColor Cyan
    Write-Host $CsvPath -ForegroundColor Green
    Write-Host ''
    Write-Host (
        'Заполни CSV и повторно запусти этот инструмент. ' +
        'Код инструмента при этом снова загрузится из Git.'
    ) -ForegroundColor Yellow

    return
}

if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
    New-Item `
        -Path $OutputRoot `
        -ItemType Directory `
        -Force |
    Out-Null
}

# Финальные настройки сервера
Ensure-KyivTimeZone
Ensure-KeyboardLayouts

# =========================
# РУЧНОЙ ВВОД
# =========================

$OrgName = Read-Host "Введите имя организации для названий файлов и папок, например BIT"
$ServerAddress = Read-Host "Введите адрес RDP-сервера, например 10.10.10.12 или ts.domain.local"

if ([string]::IsNullOrWhiteSpace($OrgName)) {
    throw "Имя организации не указано. Скрипт остановлен."
}

if ([string]::IsNullOrWhiteSpace($ServerAddress)) {
    throw "Адрес RDP-сервера не указан. Скрипт остановлен."
}

$OrgNameSafe = Get-SafeFileName -Name $OrgName
$ServerAddress = $ServerAddress.Trim()

Write-Log "Организация: $OrgNameSafe"
Write-Log "RDP-сервер: $ServerAddress"

# =========================
# ОПРЕДЕЛЯЕМ РЕЖИМ
# =========================

$IsDomainJoined = Test-IsDomainJoined
$ADAvailable = $false
$DomainOU = ""

if ($IsDomainJoined) {
    $ADAvailable = Test-ADModuleAvailable
}

if ($IsDomainJoined -and $ADAvailable) {
    $Mode = "Domain"
    Write-Log "Режим работы: доменный. Будут создаваться/обновляться пользователи Active Directory."

    $Domain = Get-ADDomain -ErrorAction Stop
    $DomainDN = [string]$Domain.DistinguishedName

    Write-Log "Текущий домен: $($Domain.DNSRoot)"
    Write-Log "Текущий Domain DN: $DomainDN"

    $DomainOU = Resolve-DomainOrganizationalUnit `
        -DomainDN $DomainDN

    if (-not [string]::IsNullOrWhiteSpace($DomainOU)) {
        Write-Log "OU найдена: $DomainOU"
    }
    else {
        Write-Log "OU не указана. Новые пользователи будут созданы в стандартном контейнере Users."
    }
}
else {
    $Mode = "Local"
    Write-Log "Режим работы: локальный. Будут создаваться/обновляться локальные пользователи."
}

# =========================
# ЧИТАЕМ CSV
# =========================

$Users = @(
    Import-Csv `
        -LiteralPath $CsvPath `
        -Encoding UTF8
)

if ($Users.Count -eq 0) {
    Write-Host ''
    Write-Host 'В users.csv нет строк с пользователями.' `
        -ForegroundColor Yellow
    Write-Host $CsvPath -ForegroundColor Cyan
    return
}

$AccountingRows = New-Object System.Collections.Generic.List[object]

# =========================
# ОБРАБОТКА ПОЛЬЗОВАТЕЛЕЙ
# =========================

foreach ($User in $Users) {
    try {
        if (-not $User.Login -or [string]::IsNullOrWhiteSpace($User.Login)) {
            Write-Log "Строка CSV без Login пропущена." "WARN"
            continue
        }

        $Login = $User.Login.Trim()
        $SafeLogin = Get-SafeFileName -Name $Login

        Write-Log "----- Обработка пользователя '$Login' -----"

        $PasswordPlain = New-StrongPassword -Length $PasswordLength

        if ($Mode -eq "Domain") {
            $CreateStatus = Create-OrUpdateDomainUser `
                -User $User `
                -PasswordPlain $PasswordPlain `
                -DomainOU $DomainOU
        }
        else {
            $CreateStatus = Create-OrUpdateLocalUser `
                -User $User `
                -PasswordPlain $PasswordPlain
        }

        $BaseName = "${OrgNameSafe}_${SafeLogin}"
        $UserOutputDir = Join-Path $OutputRoot $BaseName

        if (-not (Test-Path $UserOutputDir)) {
            New-Item -ItemType Directory -Path $UserOutputDir -Force | Out-Null
        }

        $RdpFile = Join-Path $UserOutputDir "$BaseName.rdp"
        $TxtFile = Join-Path $UserOutputDir "$BaseName.txt"

        if ($Mode -eq "Domain") {
            try {
                $DomainNetBIOS = (Get-ADDomain).NetBIOSName
                $RdpUserName = "$DomainNetBIOS\$Login"
            }
            catch {
                $RdpUserName = $Login
            }
        }
        else {
            $ComputerName = $env:COMPUTERNAME
            $RdpUserName = "$ComputerName\$Login"
        }

        New-RdpFile `
            -Path $RdpFile `
            -Server $ServerAddress `
            -UserName $RdpUserName

        New-CredentialTxtFile `
            -Path $TxtFile `
            -Login $Login `
            -Password $PasswordPlain `
            -Server $ServerAddress

        Write-Log "Создан комплект файлов: $UserOutputDir"

        $AccountingRows.Add([pscustomobject]@{
            Login    = Get-ValueOrDash $User.Login
            FullName = Get-ValueOrDash $User.FullName
            Phone    = Get-ValueOrDash $User.Phone
            Title    = Get-ValueOrDash $User.Title
            Password = $PasswordPlain
        })
    }
    catch {
        Write-Log "Ошибка при обработке пользователя '$($User.Login)': $($_.Exception.Message)" "ERROR"
    }
}

# =========================
# CSV ДЛЯ ВНУТРЕННЕГО УЧЁТА
# =========================

$AccountingCsvPath = Join-Path $OutputRoot "${OrgNameSafe}_users_accounting.csv"

$AccountingRows | Export-Csv `
    -Path $AccountingCsvPath `
    -NoTypeInformation `
    -Encoding UTF8

Write-Log "============================================================"
Write-Log "Готово."
Write-Log "CSV для внутреннего учёта: $AccountingCsvPath"
Write-Log "Комплекты пользователей лежат тут: $OutputRoot"
Write-Log "Лог: $LogPath"

Write-Host ""
Write-Host "ГОТОВО." -ForegroundColor Green
Write-Host "Комплекты пользователей: $OutputRoot" -ForegroundColor Cyan
Write-Host "CSV для внутреннего учёта: $AccountingCsvPath" -ForegroundColor Cyan
Write-Host "Лог: $LogPath" -ForegroundColor Cyan