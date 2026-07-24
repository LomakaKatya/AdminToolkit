[CmdletBinding()]
param(
    [ValidateRange(1, 3650)]
    [int]$InactiveDays = 90,

    [string]$OutputRoot = (
        Join-Path `
            $env:ProgramData `
            'RaccoonAdminToolkit\Reports\UserProfileStorage'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Test-RaccoonAdministrator {
    $identity =
        [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        -TypeName Security.Principal.WindowsPrincipal `
        -ArgumentList $identity

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Convert-WmiDateTime {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetime]) {
        return [datetime]$Value
    }

    $text = [string]$Value

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime(
            $text
        )
    }
    catch {
        return $null
    }
}

function ConvertTo-HtmlText {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return [System.Net.WebUtility]::HtmlEncode(
        [string]$Value
    )
}

function Format-ReportDate {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return 'немає даних'
    }

    try {
        return ([datetime]$Value).ToString(
            'dd.MM.yyyy HH:mm'
        )
    }
    catch {
        return 'немає даних'
    }
}

function Format-Bytes {
    param(
        [long]$Bytes
    )

    if ($Bytes -ge 1TB) {
        return ('{0:N2} TB' -f ($Bytes / 1TB))
    }

    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }

    if ($Bytes -ge 1MB) {
        return ('{0:N2} MB' -f ($Bytes / 1MB))
    }

    if ($Bytes -ge 1KB) {
        return ('{0:N2} KB' -f ($Bytes / 1KB))
    }

    return ('{0} B' -f $Bytes)
}

function Export-CsvUtf8Bom {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $lines = @(
        $InputObject |
        ConvertTo-Csv `
            -NoTypeInformation `
            -Delimiter ';'
    )

    $encoding = New-Object `
        -TypeName System.Text.UTF8Encoding `
        -ArgumentList $true

    [System.IO.File]::WriteAllLines(
        $Path,
        [string[]]$lines,
        $encoding
    )
}

function Get-LocalAccountMaps {
    $bySid = @{}
    $byName = @{}

    $accounts = @(
        Get-CimInstance `
            -ClassName Win32_UserAccount `
            -Filter 'LocalAccount=True' `
            -ErrorAction SilentlyContinue
    )

    foreach ($account in $accounts) {
        $entry = [pscustomobject]@{
            Name      = [string]$account.Name
            SID       = [string]$account.SID
            Disabled  = [bool]$account.Disabled
            Lockout   = [bool]$account.Lockout
            LastLogon = $null
        }

        if (-not [string]::IsNullOrWhiteSpace($entry.SID)) {
            $bySid[$entry.SID.ToLowerInvariant()] = $entry
        }

        if (-not [string]::IsNullOrWhiteSpace($entry.Name)) {
            $byName[$entry.Name.ToLowerInvariant()] = $entry
        }
    }

    try {
        $adsi = [ADSI](
            'WinNT://{0}' -f $env:COMPUTERNAME
        )

        foreach ($child in @($adsi.Children)) {
            if ($child.SchemaClassName -ne 'user') {
                continue
            }

            $name = [string]$child.Name
            $key = $name.ToLowerInvariant()

            if (-not $byName.ContainsKey($key)) {
                continue
            }

            try {
                $lastLogin =
                    [datetime]$child.Properties['LastLogin'].Value

                $byName[$key].LastLogon = $lastLogin
            }
            catch {
            }
        }
    }
    catch {
    }

    return [pscustomobject]@{
        BySid  = $bySid
        ByName = $byName
    }
}

function Get-SessionMap {
    $map = @{}

    try {
        $lines = @(
            & "$env:SystemRoot\System32\quser.exe" 2>$null
        )

        foreach ($line in $lines) {
            $text = ([string]$line).Trim()

            if ([string]::IsNullOrWhiteSpace($text)) {
                continue
            }

            if ($text -match '^(?i)USERNAME\s+') {
                continue
            }

            $text = $text.TrimStart('>')
            $parts = @(
                $text -split '\s+' |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                }
            )

            if ($parts.Count -lt 3) {
                continue
            }

            $user = [string]$parts[0]
            $sessionName = ''
            $sessionId = ''
            $state = ''

            if ($parts[1] -match '^\d+$') {
                $sessionId = [string]$parts[1]
                $state = [string]$parts[2]
            }
            elseif ($parts.Count -ge 4 -and
                $parts[2] -match '^\d+$') {

                $sessionName = [string]$parts[1]
                $sessionId = [string]$parts[2]
                $state = [string]$parts[3]
            }
            else {
                continue
            }

            $key = $user.ToLowerInvariant()

            if (-not $map.ContainsKey($key)) {
                $map[$key] = New-Object `
                    -TypeName System.Collections.ArrayList
            }

            [void]$map[$key].Add(
                [pscustomobject]@{
                    User        = $user
                    SessionName = $sessionName
                    SessionId   = $sessionId
                    State       = $state
                }
            )
        }
    }
    catch {
    }

    return $map
}

function Get-TranslatedAccountName {
    param(
        [AllowNull()]
        [string]$Sid
    )

    if ([string]::IsNullOrWhiteSpace($Sid)) {
        return $null
    }

    try {
        $sidObject = New-Object `
            -TypeName System.Security.Principal.SecurityIdentifier `
            -ArgumentList $Sid

        $account = $sidObject.Translate(
            [System.Security.Principal.NTAccount]
        )

        return [string]$account.Value
    }
    catch {
        return $null
    }
}

function Get-AdUserCommandAvailable {
    try {
        if (Get-Command `
                -Name Get-ADUser `
                -ErrorAction SilentlyContinue) {
            return $true
        }

        if (Get-Module `
                -ListAvailable `
                -Name ActiveDirectory `
                -ErrorAction SilentlyContinue) {

            Import-Module `
                -Name ActiveDirectory `
                -ErrorAction Stop

            return [bool](
                Get-Command `
                    -Name Get-ADUser `
                    -ErrorAction SilentlyContinue
            )
        }
    }
    catch {
    }

    return $false
}

function Get-ProfileAccountInfo {
    param(
        [Parameter(Mandatory)]
        [object]$Profile,

        [Parameter(Mandatory)]
        [object]$LocalMaps,

        [Parameter(Mandatory)]
        [hashtable]$SessionMap,

        [bool]$AdAvailable
    )

    $sid = [string]$Profile.SID
    $translatedName = Get-TranslatedAccountName -Sid $sid
    $folderName = Split-Path `
        -Path ([string]$Profile.LocalPath) `
        -Leaf

    $accountName = if (
        -not [string]::IsNullOrWhiteSpace($translatedName)
    ) {
        $translatedName
    }
    else {
        $folderName
    }

    $shortName = if ($accountName -match '\\') {
        ($accountName -split '\\')[-1]
    }
    else {
        $accountName
    }

    $accountType = 'Невідомий'
    $accountExists = $null
    $enabled = $null
    $locked = $null
    $accountLastLogon = $null
    $accountSource = 'немає даних'

    $sidKey = if (
        [string]::IsNullOrWhiteSpace($sid)
    ) {
        ''
    }
    else {
        $sid.ToLowerInvariant()
    }

    $nameKey = $shortName.ToLowerInvariant()
    $localEntry = $null

    if (-not [string]::IsNullOrWhiteSpace($sidKey) -and
        $LocalMaps.BySid.ContainsKey($sidKey)) {

        $localEntry = $LocalMaps.BySid[$sidKey]
    }
    elseif ($LocalMaps.ByName.ContainsKey($nameKey)) {
        $localEntry = $LocalMaps.ByName[$nameKey]
    }

    if ($null -ne $localEntry) {
        $accountType = 'Локальний'
        $accountExists = $true
        $enabled = -not [bool]$localEntry.Disabled
        $locked = [bool]$localEntry.Lockout
        $accountLastLogon = $localEntry.LastLogon
        $accountSource = 'локальна SAM'
    }
    elseif (
        -not [string]::IsNullOrWhiteSpace($translatedName) -and
        $translatedName -match '\\'
    ) {
        $domainPart = ($translatedName -split '\\')[0]

        if ($domainPart -ieq $env:COMPUTERNAME) {
            $accountType = 'Локальний'
            $accountExists = $false
            $accountSource = 'профіль без локальної облікові записи'
        }
        else {
            $accountType = 'Доменний'

            if ($AdAvailable -and
                -not [string]::IsNullOrWhiteSpace($sid)) {

                try {
                    $adUser = Get-ADUser `
                        -Identity $sid `
                        -Properties Enabled, LastLogonDate `
                        -ErrorAction Stop

                    $accountExists = $true
                    $enabled = [bool]$adUser.Enabled
                    $accountLastLogon = $adUser.LastLogonDate
                    $accountSource = 'Active Directory'
                }
                catch {
                    $accountExists = $false
                    $accountSource =
                        'не знайдено в Active Directory'
                }
            }
            else {
                $accountSource = 'AD-модуль недоступний'
            }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($sid)) {
        $accountExists = $false
        $accountSource = 'SID не перетворено'
    }

    $sessions = @()

    if ($SessionMap.ContainsKey($nameKey)) {
        $sessions = @($SessionMap[$nameKey])
    }

    $sessionText = if ($sessions.Count -eq 0) {
        'немає'
    }
    else {
        @(
            $sessions |
            ForEach-Object {
                if ([string]::IsNullOrWhiteSpace(
                        [string]$_.SessionName
                    )) {

                    'ID {0}: {1}' -f
                    $_.SessionId,
                    $_.State
                }
                else {
                    '{0}, ID {1}: {2}' -f
                    $_.SessionName,
                    $_.SessionId,
                    $_.State
                }
            }
        ) -join '; '
    }

    return [pscustomobject]@{
        AccountName       = $accountName
        ShortName         = $shortName
        AccountType       = $accountType
        AccountExists     = $accountExists
        Enabled           = $enabled
        Locked            = $locked
        AccountLastLogon  = $accountLastLogon
        AccountSource     = $accountSource
        Sessions          = $sessions
        SessionText       = $sessionText
    }
}

function Measure-ProfileDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [int]$ProfileIndex,

        [Parameter(Mandatory)]
        [int]$ProfileCount
    )

    $result = [pscustomobject]@{
        Exists            = $false
        Bytes             = [long]0
        FileCount         = [long]0
        DirectoryCount    = [long]0
        ErrorCount        = [int]0
        ReparsePointCount = [int]0
        FolderUsage       = @()
    }

    if (-not (Test-Path `
            -LiteralPath $Path `
            -PathType Container)) {
        return $result
    }

    $result.Exists = $true

    $root = New-Object `
        -TypeName System.IO.DirectoryInfo `
        -ArgumentList $Path

    $rootPath = $root.FullName.TrimEnd('\')
    $rootPrefix = $rootPath + '\'

    $stack = New-Object `
        -TypeName 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'

    $stack.Push($root)

    $folderMap = @{}
    $processedSinceProgress = 0

    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        $result.DirectoryCount++

        try {
            foreach ($file in $directory.EnumerateFiles()) {
                try {
                    $length = [long]$file.Length
                    $result.Bytes += $length
                    $result.FileCount++
                    $processedSinceProgress++

                    $relativePath = if (
                        $file.FullName.StartsWith(
                            $rootPrefix,
                            [StringComparison]::OrdinalIgnoreCase
                        )
                    ) {
                        $file.FullName.Substring(
                            $rootPrefix.Length
                        )
                    }
                    else {
                        $file.Name
                    }

                    $separatorIndex =
                        $relativePath.IndexOf('\')

                    $bucket = if ($separatorIndex -ge 0) {
                        $relativePath.Substring(
                            0,
                            $separatorIndex
                        )
                    }
                    else {
                        '(корінь профілю)'
                    }

                    if (-not $folderMap.ContainsKey($bucket)) {
                        $folderMap[$bucket] = [pscustomobject]@{
                            Folder    = $bucket
                            Bytes     = [long]0
                            FileCount = [long]0
                        }
                    }

                    $folderMap[$bucket].Bytes += $length
                    $folderMap[$bucket].FileCount++
                }
                catch {
                    $result.ErrorCount++
                }

                if ($processedSinceProgress -ge 2000) {
                    $processedSinceProgress = 0

                    $percent = [Math]::Min(
                        99,
                        [Math]::Round(
                            (
                                ($ProfileIndex - 1) /
                                [double]$ProfileCount
                            ) * 100,
                            0
                        )
                    )

                    Write-Progress `
                        -Activity (
                            'Аналіз профілів користувачів'
                        ) `
                        -Status (
                            '{0}/{1}: {2}, файлів: {3:N0}' -f
                            $ProfileIndex,
                            $ProfileCount,
                            $Label,
                            $result.FileCount
                        ) `
                        -PercentComplete $percent
                }
            }
        }
        catch {
            $result.ErrorCount++
        }

        try {
            foreach ($child in $directory.EnumerateDirectories()) {
                try {
                    if (
                        (
                            $child.Attributes -band
                            [IO.FileAttributes]::ReparsePoint
                        ) -ne 0
                    ) {
                        $result.ReparsePointCount++
                        continue
                    }

                    $stack.Push($child)
                }
                catch {
                    $result.ErrorCount++
                }
            }
        }
        catch {
            $result.ErrorCount++
        }
    }

    $result.FolderUsage = @(
        $folderMap.Values |
        Sort-Object `
            -Property Bytes `
            -Descending
    )

    return $result
}

function Get-ProfileCandidates {
    $registered = @(
        Get-CimInstance `
            -ClassName Win32_UserProfile `
            -ErrorAction Stop |
        Where-Object {
            -not $_.Special -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$_.LocalPath
            )
        }
    )

    $byPath = @{}
    $roots = New-Object `
        -TypeName System.Collections.ArrayList

    foreach ($profile in $registered) {
        $path = [string]$profile.LocalPath
        $key = (
            $path.TrimEnd('\')
        ).ToLowerInvariant()

        $byPath[$key] = [pscustomobject]@{
            SID         = [string]$profile.SID
            LocalPath   = $path
            Loaded      = [bool]$profile.Loaded
            LastUseTime = Convert-WmiDateTime `
                -Value $profile.LastUseTime
            Registered  = $true
        }

        $parent = Split-Path -Path $path -Parent
        $qualifier = Split-Path -Path $path -Qualifier

        $parentIsDriveRoot = (
            -not [string]::IsNullOrWhiteSpace($qualifier) -and
            $parent.TrimEnd('\') -ieq
            $qualifier.TrimEnd('\')
        )

        if (-not [string]::IsNullOrWhiteSpace($parent) -and
            -not $parentIsDriveRoot -and
            $parent -notin @($roots)) {
            [void]$roots.Add($parent)
        }
    }

    $defaultRoot = Join-Path $env:SystemDrive 'Users'

    if ($defaultRoot -notin @($roots)) {
        [void]$roots.Add($defaultRoot)
    }

    $skipNames = @(
        'All Users',
        'Default',
        'Default User',
        'Public'
    )

    foreach ($root in @($roots)) {
        if (-not (Test-Path `
                -LiteralPath $root `
                -PathType Container)) {
            continue
        }

        $directories = @(
            Get-ChildItem `
                -LiteralPath $root `
                -Directory `
                -Force `
                -ErrorAction SilentlyContinue
        )

        foreach ($directory in $directories) {
            if ($directory.Name -in $skipNames) {
                continue
            }

            $key = (
                $directory.FullName.TrimEnd('\')
            ).ToLowerInvariant()

            if ($byPath.ContainsKey($key)) {
                continue
            }

            $byPath[$key] = [pscustomobject]@{
                SID         = ''
                LocalPath   = $directory.FullName
                Loaded      = $false
                LastUseTime = $directory.LastWriteTime
                Registered  = $false
            }
        }
    }

    return @(
        $byPath.Values |
        Sort-Object `
            -Property LocalPath
    )
}

if (-not (Test-RaccoonAdministrator)) {
    throw (
        'Для аналізу всіх профілів потрібні права адміністратора.'
    )
}

Write-Host ''
Write-Host 'Аналіз використання диска профілями користувачів' `
    -ForegroundColor Cyan
Write-Host (
    'Збираю профілі, облікові записи, сеанси та розмір файлів.'
) -ForegroundColor DarkGray
Write-Host (
    'Великі сервери можуть аналізуватися кілька хвилин.'
) -ForegroundColor DarkGray
Write-Host ''

$computerSystem = Get-CimInstance `
    -ClassName Win32_ComputerSystem `
    -ErrorAction SilentlyContinue

$partOfDomain = (
    $null -ne $computerSystem -and
    [bool]$computerSystem.PartOfDomain
)

$localMaps = Get-LocalAccountMaps
$sessionMap = Get-SessionMap
$adAvailable = $false

if ($partOfDomain) {
    $adAvailable = Get-AdUserCommandAvailable
}

$profiles = @(
    Get-ProfileCandidates
)

if ($profiles.Count -eq 0) {
    Write-Host '[WARN] Профілі користувачів не знайдено.' `
        -ForegroundColor Yellow
    return
}

$summary = New-Object `
    -TypeName System.Collections.ArrayList

$folderDetails = New-Object `
    -TypeName System.Collections.ArrayList

$now = Get-Date

for ($index = 0; $index -lt $profiles.Count; $index++) {
    $profile = $profiles[$index]

    $account = Get-ProfileAccountInfo `
        -Profile $profile `
        -LocalMaps $localMaps `
        -SessionMap $sessionMap `
        -AdAvailable $adAvailable

    Write-Host (
        '[{0}/{1}] {2}' -f
        ($index + 1),
        $profiles.Count,
        $account.AccountName
    ) -ForegroundColor DarkGray

    $usage = Measure-ProfileDirectory `
        -Path ([string]$profile.LocalPath) `
        -Label $account.AccountName `
        -ProfileIndex ($index + 1) `
        -ProfileCount $profiles.Count

    $lastProfileUse = $profile.LastUseTime
    $lastAccountLogon = $account.AccountLastLogon

    $lastActivity = if (
        $null -ne $lastProfileUse -and
        $null -ne $lastAccountLogon
    ) {
        if ($lastProfileUse -gt $lastAccountLogon) {
            $lastProfileUse
        }
        else {
            $lastAccountLogon
        }
    }
    elseif ($null -ne $lastProfileUse) {
        $lastProfileUse
    }
    else {
        $lastAccountLogon
    }

    $daysInactive = if ($null -eq $lastActivity) {
        $null
    }
    else {
        [Math]::Max(
            0,
            [Math]::Floor(
                ($now - $lastActivity).TotalDays
            )
        )
    }

    $accountState = if ($account.AccountExists -eq $false) {
        'Учітку не знайдено'
    }
    elseif ($account.Enabled -eq $false) {
        'Вимкнена'
    }
    elseif ($account.Locked -eq $true) {
        'Заблокована'
    }
    elseif ($account.Enabled -eq $true) {
        'Активна'
    }
    else {
        'Не визначено'
    }

    $activityState = if ($account.Sessions.Count -gt 0) {
        'Є сеанс'
    }
    elseif ($null -eq $lastActivity) {
        'Немає даних'
    }
    elseif ($daysInactive -gt $InactiveDays) {
        "Неактивний понад $InactiveDays днів"
    }
    else {
        "Активність до $InactiveDays днів"
    }

    $topFolders = @(
        $usage.FolderUsage |
        Select-Object -First 5 |
        ForEach-Object {
            '{0}: {1}' -f
            $_.Folder,
            (Format-Bytes -Bytes $_.Bytes)
        }
    ) -join '; '

    $summaryRow = [pscustomobject]@{
        AccountName       = $account.AccountName
        AccountType       = $account.AccountType
        AccountState      = $accountState
        ActivityState     = $activityState
        Session           = $account.SessionText
        LastProfileUse    = $lastProfileUse
        LastAccountLogon  = $lastAccountLogon
        LastActivity      = $lastActivity
        DaysInactive      = $daysInactive
        ProfilePath       = [string]$profile.LocalPath
        ProfileRegistered = [bool]$profile.Registered
        ProfileLoaded     = [bool]$profile.Loaded
        PathExists        = [bool]$usage.Exists
        SizeBytes         = [long]$usage.Bytes
        SizeGB            = [Math]::Round(
            $usage.Bytes / 1GB,
            3
        )
        SharePercent      = [double]0
        FileCount         = [long]$usage.FileCount
        DirectoryCount    = [long]$usage.DirectoryCount
        AccessErrors      = [int]$usage.ErrorCount
        ReparseSkipped    = [int]$usage.ReparsePointCount
        AccountDataSource = $account.AccountSource
        TopFolders        = $topFolders
    }

    [void]$summary.Add($summaryRow)

    foreach ($folder in @($usage.FolderUsage)) {
        [void]$folderDetails.Add(
            [pscustomobject]@{
                AccountName  = $account.AccountName
                ProfilePath  = [string]$profile.LocalPath
                Folder       = [string]$folder.Folder
                SizeBytes    = [long]$folder.Bytes
                SizeGB       = [Math]::Round(
                    $folder.Bytes / 1GB,
                    3
                )
                ProfileShare = if ($usage.Bytes -gt 0) {
                    [Math]::Round(
                        (
                            $folder.Bytes /
                            [double]$usage.Bytes
                        ) * 100,
                        2
                    )
                }
                else {
                    0
                }
                FileCount    = [long]$folder.FileCount
            }
        )
    }
}

Write-Progress `
    -Activity 'Аналіз профілів користувачів' `
    -Completed

$totalMeasure = $summary |
    Measure-Object `
        -Property SizeBytes `
        -Sum

$totalBytes = if ($null -eq $totalMeasure.Sum) {
    [long]0
}
else {
    [long]$totalMeasure.Sum
}

foreach ($row in $summary) {
    $row.SharePercent = if ($totalBytes -gt 0) {
        [Math]::Round(
            (
                $row.SizeBytes /
                [double]$totalBytes
            ) * 100,
            2
        )
    }
    else {
        0
    }
}

$summarySorted = @(
    $summary |
    Sort-Object `
        -Property SizeBytes `
        -Descending
)

$folderSorted = @(
    $folderDetails |
    Sort-Object `
        -Property SizeBytes `
        -Descending
)

$inactiveMeasure = $summary |
    Where-Object {
        $_.ActivityState -like 'Неактивний*' -or
        $_.AccountState -in @(
            'Вимкнена',
            'Учітку не знайдено'
        )
    } |
    Measure-Object `
        -Property SizeBytes `
        -Sum

$inactiveBytes = if ($null -eq $inactiveMeasure.Sum) {
    [long]0
}
else {
    [long]$inactiveMeasure.Sum
}

$errorProfiles = @(
    $summary |
    Where-Object {
        $_.AccessErrors -gt 0
    }
).Count

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDirectory = Join-Path `
    $OutputRoot `
    ('{0}-{1}' -f $env:COMPUTERNAME, $timestamp)

New-Item `
    -Path $reportDirectory `
    -ItemType Directory `
    -Force `
    -ErrorAction Stop |
Out-Null

$summaryCsvPath = Join-Path `
    $reportDirectory `
    'UserProfileStorage-Summary.csv'

$foldersCsvPath = Join-Path `
    $reportDirectory `
    'UserProfileStorage-Folders.csv'

$htmlPath = Join-Path `
    $reportDirectory `
    'UserProfileStorage-Report.html'

$summaryExport = @(
    $summarySorted |
    Select-Object `
        @{
            Name = 'Користувач'
            Expression = {
                $_.AccountName
            }
        },
        @{
            Name = 'Тип облікові записи'
            Expression = {
                $_.AccountType
            }
        },
        @{
            Name = 'Стан облікові записи'
            Expression = {
                $_.AccountState
            }
        },
        @{
            Name = 'Активність'
            Expression = {
                $_.ActivityState
            }
        },
        @{
            Name = 'Сеанс'
            Expression = {
                $_.Session
            }
        },
        @{
            Name = 'Останнє використання профілю'
            Expression = {
                Format-ReportDate $_.LastProfileUse
            }
        },
        @{
            Name = 'Останній вхід облікові записи'
            Expression = {
                Format-ReportDate $_.LastAccountLogon
            }
        },
        @{
            Name = 'Днів без активності'
            Expression = {
                $_.DaysInactive
            }
        },
        @{
            Name = 'Шлях профілю'
            Expression = {
                $_.ProfilePath
            }
        },
        @{
            Name = 'Розмір GB'
            Expression = {
                $_.SizeGB
            }
        },
        @{
            Name = 'Частка від усіх профілів %'
            Expression = {
                $_.SharePercent
            }
        },
        @{
            Name = 'Файлів'
            Expression = {
                $_.FileCount
            }
        },
        @{
            Name = 'Помилок доступу'
            Expression = {
                $_.AccessErrors
            }
        },
        @{
            Name = 'Топ папок'
            Expression = {
                $_.TopFolders
            }
        }
)

$foldersExport = @(
    $folderSorted |
    Select-Object `
        @{
            Name = 'Користувач'
            Expression = {
                $_.AccountName
            }
        },
        @{
            Name = 'Шлях профілю'
            Expression = {
                $_.ProfilePath
            }
        },
        @{
            Name = 'Папка верхнього рівня'
            Expression = {
                $_.Folder
            }
        },
        @{
            Name = 'Розмір GB'
            Expression = {
                $_.SizeGB
            }
        },
        @{
            Name = 'Частка профілю %'
            Expression = {
                $_.ProfileShare
            }
        },
        @{
            Name = 'Файлів'
            Expression = {
                $_.FileCount
            }
        }
)

Export-CsvUtf8Bom `
    -InputObject $summaryExport `
    -Path $summaryCsvPath

Export-CsvUtf8Bom `
    -InputObject $foldersExport `
    -Path $foldersCsvPath

$summaryRows = New-Object `
    -TypeName System.Text.StringBuilder

$rank = 0

foreach ($row in $summarySorted) {
    $rank++

    $rowClass = if ($row.AccountState -in @(
            'Вимкнена',
            'Учітку не знайдено'
        )) {
        'disabled'
    }
    elseif ($row.ActivityState -like 'Неактивний*') {
        'inactive'
    }
    elseif ($row.Session -ne 'немає') {
        'session'
    }
    else {
        ''
    }

    $daysText = if ($null -eq $row.DaysInactive) {
        'немає даних'
    }
    else {
        '{0} днів' -f $row.DaysInactive
    }

    $daysSort = if ($null -eq $row.DaysInactive) {
        999999
    }
    else {
        [int]$row.DaysInactive
    }

    $lastActivitySort = if ($null -eq $row.LastActivity) {
        0
    }
    else {
        $epoch = [datetime]'1970-01-01'
        [long](
            $row.LastActivity.ToUniversalTime().
            Subtract($epoch).
            TotalSeconds
        )
    }

    [void]$summaryRows.AppendLine(
        @"
<tr class="$rowClass">
<td data-sort="$rank">$rank</td>
<td data-sort="$(ConvertTo-HtmlText $row.AccountName)"><strong>$(ConvertTo-HtmlText $row.AccountName)</strong><br><span class="muted">$(ConvertTo-HtmlText $row.AccountType)</span></td>
<td data-sort="$(ConvertTo-HtmlText $row.AccountState)">$(ConvertTo-HtmlText $row.AccountState)<br><span class="muted">$(ConvertTo-HtmlText $row.AccountDataSource)</span></td>
<td data-sort="$(ConvertTo-HtmlText $row.ActivityState)">$(ConvertTo-HtmlText $row.ActivityState)<br><span class="muted">$(ConvertTo-HtmlText $row.Session)</span></td>
<td data-sort="$lastActivitySort">$(ConvertTo-HtmlText (Format-ReportDate $row.LastActivity))<br><span class="muted">$(ConvertTo-HtmlText $daysText)</span></td>
<td data-sort="$($row.SizeBytes)"><strong>$(ConvertTo-HtmlText (Format-Bytes $row.SizeBytes))</strong><br><span class="muted">$($row.SharePercent)%</span></td>
<td data-sort="$($row.FileCount)">$("{0:N0}" -f $row.FileCount)</td>
<td data-sort="$($row.AccessErrors)">$($row.AccessErrors)</td>
<td data-sort="$(ConvertTo-HtmlText $row.ProfilePath)"><code>$(ConvertTo-HtmlText $row.ProfilePath)</code><br><span class="muted">$(ConvertTo-HtmlText $row.TopFolders)</span></td>
</tr>
"@
    )
}

$folderRows = New-Object `
    -TypeName System.Text.StringBuilder

foreach ($row in $folderSorted) {
    [void]$folderRows.AppendLine(
        @"
<tr>
<td data-sort="$(ConvertTo-HtmlText $row.AccountName)">$(ConvertTo-HtmlText $row.AccountName)</td>
<td data-sort="$(ConvertTo-HtmlText $row.Folder)">$(ConvertTo-HtmlText $row.Folder)</td>
<td data-sort="$($row.SizeBytes)">$(ConvertTo-HtmlText (Format-Bytes $row.SizeBytes))</td>
<td data-sort="$($row.ProfileShare)">$($row.ProfileShare)%</td>
<td data-sort="$($row.FileCount)">$("{0:N0}" -f $row.FileCount)</td>
<td data-sort="$(ConvertTo-HtmlText $row.ProfilePath)"><code>$(ConvertTo-HtmlText $row.ProfilePath)</code></td>
</tr>
"@
    )
}

$largestProfile = if ($summarySorted.Count -gt 0) {
    $summarySorted[0]
}
else {
    $null
}

$largestText = if ($null -eq $largestProfile) {
    'немає'
}
else {
    '{0}, {1}' -f
    $largestProfile.AccountName,
    (Format-Bytes $largestProfile.SizeBytes)
}

$generatedAt = Get-Date -Format 'dd.MM.yyyy HH:mm:ss'

$domainText = if ($partOfDomain) {
    [string]$computerSystem.Domain
}
else {
    'робоча група'
}

$htmlDocument = @"
<!doctype html>
<html lang="uk">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Профілі користувачів - $(ConvertTo-HtmlText $env:COMPUTERNAME)</title>
<style>
:root{color-scheme:dark;--bg:#071a33;--panel:#0c294b;--line:#255f88;--text:#eaf6ff;--muted:#aac0cf;--accent:#35d4ff;--ok:#75e6a4;--warn:#ffd166;--bad:#ff8792}
*{box-sizing:border-box}
body{margin:0;background:linear-gradient(180deg,#0b2747,var(--bg));color:var(--text);font-family:"Segoe UI",system-ui,sans-serif;line-height:1.5}
main{width:min(1500px,100%);margin:auto;padding:24px}
header{padding:28px;border:1px solid var(--line);border-radius:18px;background:rgba(12,41,75,.94)}
h1{margin:0;font-size:clamp(1.8rem,4vw,3rem)}
.lead,.muted{color:var(--muted)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px;margin:20px 0}
.card{padding:16px;border:1px solid rgba(170,192,207,.2);border-radius:12px;background:var(--panel)}
.card strong{display:block;margin-top:5px;font-size:1.25rem;color:var(--accent)}
.controls{display:flex;flex-wrap:wrap;gap:10px;margin:20px 0}
input,button{min-height:42px;border:1px solid var(--line);border-radius:9px;background:#071b31;color:var(--text);font:inherit}
input{flex:1;min-width:250px;padding:9px 12px}
button{padding:9px 14px;cursor:pointer;background:#134267}
button:hover{border-color:var(--accent)}
section{margin-top:26px;padding:18px;border:1px solid rgba(170,192,207,.2);border-radius:14px;background:rgba(12,41,75,.9)}
.table-wrap{overflow:auto}
table{width:100%;border-collapse:collapse;font-size:.92rem}
th,td{padding:10px;border-bottom:1px solid rgba(170,192,207,.18);text-align:left;vertical-align:top}
th{position:sticky;top:0;background:#123d62;color:var(--accent);cursor:pointer;white-space:nowrap}
tr:hover{background:rgba(53,212,255,.06)}
tr.inactive{background:rgba(255,209,102,.06)}
tr.disabled{background:rgba(255,135,146,.07)}
tr.session{background:rgba(117,230,164,.06)}
code{font-family:Consolas,monospace;white-space:nowrap}
.note{padding:14px;border-left:4px solid var(--warn);background:rgba(255,209,102,.07);border-radius:8px}
footer{margin:24px 0;color:var(--muted);font-size:.9rem}
@media print{
:root{color-scheme:light}
body{background:#fff;color:#000}
main{width:100%;padding:0}
header,section,.card{background:#fff;color:#000;box-shadow:none}
.controls{display:none}
.muted,.lead,footer{color:#444}
th{position:static;background:#ddd;color:#000}
tr.inactive,tr.disabled,tr.session{background:#fff}
section{break-inside:avoid}
}
</style>
</head>
<body>
<main>
<header>
<p class="muted">RACCOON ADMIN TOOLKIT / КОНТРОЛЬ ТА ЗВІТИ</p>
<h1>Використання диска профілями користувачів</h1>
<p class="lead">Комп'ютер: <strong>$(ConvertTo-HtmlText $env:COMPUTERNAME)</strong> | Середовище: $(ConvertTo-HtmlText $domainText) | Створено: $(ConvertTo-HtmlText $generatedAt)</p>
</header>

<div class="cards">
<div class="card">Профілів<strong>$($summary.Count)</strong></div>
<div class="card">Загальний розмір<strong>$(ConvertTo-HtmlText (Format-Bytes $totalBytes))</strong></div>
<div class="card">Найбільший профіль<strong>$(ConvertTo-HtmlText $largestText)</strong></div>
<div class="card">Неактивні або вимкнені<strong>$(ConvertTo-HtmlText (Format-Bytes $inactiveBytes))</strong></div>
<div class="card">Профілі з помилками доступу<strong>$errorProfiles</strong></div>
</div>

<div class="controls">
<input id="filter" type="search" placeholder="Фільтр: користувач, шлях, стан, папка...">
<button type="button" onclick="window.print()">Друк / PDF</button>
<button type="button" onclick="resetTables()">Скинути сортування</button>
</div>

<p class="note">Розмір визначається як логічна сума довжин доступних файлів. NTFS-стиснення, sparse-файли, deduplication та недоступні каталоги можуть відрізняти фактичне зайняте місце. Reparse points не скануються, щоб уникнути циклів.</p>

<section>
<h2>Профілі користувачів</h2>
<div class="table-wrap">
<table id="profiles">
<thead>
<tr>
<th data-type="number">#</th>
<th>Користувач</th>
<th>Стан облікові записи</th>
<th>Активність і сеанс</th>
<th data-type="number">Остання активність</th>
<th data-type="number">Розмір</th>
<th data-type="number">Файлів</th>
<th data-type="number">Помилки</th>
<th>Профіль і найбільші папки</th>
</tr>
</thead>
<tbody>
$summaryRows
</tbody>
</table>
</div>
</section>

<section>
<h2>Папки верхнього рівня</h2>
<p class="muted">Деталізація показує, що саме всередині кожного профілю забрало місце: Desktop, Downloads, AppData, Documents та інші папки.</p>
<div class="table-wrap">
<table id="folders">
<thead>
<tr>
<th>Користувач</th>
<th>Папка</th>
<th data-type="number">Розмір</th>
<th data-type="number">Частка профілю</th>
<th data-type="number">Файлів</th>
<th>Шлях профілю</th>
</tr>
</thead>
<tbody>
$folderRows
</tbody>
</table>
</div>
</section>

<footer>
CSV-зведення: UserProfileStorage-Summary.csv<br>
CSV-деталізація: UserProfileStorage-Folders.csv
</footer>
</main>
<script>
var tables=document.getElementsByTagName("table");
var originalRows=[];

function getRows(table){
  return Array.prototype.slice.call(table.tBodies[0].rows);
}

function getCellValue(row,index){
  var cell=row.cells[index];
  if(!cell){return "";}
  return cell.getAttribute("data-sort") || cell.innerText || cell.textContent || "";
}

function sortTable(table,index,numeric){
  var body=table.tBodies[0];
  var rows=getRows(table);
  var oldIndex=Number(table.getAttribute("data-sort-index"));
  var oldDirection=table.getAttribute("data-sort-direction");
  var descending=oldIndex===index && oldDirection!=="desc";

  rows.sort(function(a,b){
    var av=getCellValue(a,index);
    var bv=getCellValue(b,index);
    var result;

    if(numeric){
      result=Number(av)-Number(bv);
    }
    else{
      result=String(av).localeCompare(String(bv));
    }

    return descending ? -result : result;
  });

  for(var i=0;i<rows.length;i++){
    body.appendChild(rows[i]);
  }

  table.setAttribute("data-sort-index",String(index));
  table.setAttribute(
    "data-sort-direction",
    descending ? "desc" : "asc"
  );
}

function bindTable(table,tableIndex){
  originalRows[tableIndex]=getRows(table);
  var cells=table.tHead.rows[0].cells;

  for(var index=0;index<cells.length;index++){
    (function(currentIndex){
      cells[currentIndex].onclick=function(){
        sortTable(
          table,
          currentIndex,
          cells[currentIndex].getAttribute("data-type")==="number"
        );
      };
    })(index);
  }
}

for(var tableIndex=0;tableIndex<tables.length;tableIndex++){
  bindTable(tables[tableIndex],tableIndex);
}

document.getElementById("filter").onkeyup=function(){
  var query=String(this.value).toLowerCase();

  for(var tableIndex=0;tableIndex<tables.length;tableIndex++){
    var rows=tables[tableIndex].tBodies[0].rows;

    for(var rowIndex=0;rowIndex<rows.length;rowIndex++){
      var value=String(
        rows[rowIndex].innerText ||
        rows[rowIndex].textContent ||
        ""
      ).toLowerCase();

      rows[rowIndex].style.display=
        query && value.indexOf(query)<0 ? "none" : "";
    }
  }
};

function resetTables(){
  for(var tableIndex=0;tableIndex<tables.length;tableIndex++){
    var table=tables[tableIndex];
    var body=table.tBodies[0];
    var rows=originalRows[tableIndex];

    for(var rowIndex=0;rowIndex<rows.length;rowIndex++){
      body.appendChild(rows[rowIndex]);
      rows[rowIndex].style.display="";
    }

    table.removeAttribute("data-sort-index");
    table.removeAttribute("data-sort-direction");
  }

  document.getElementById("filter").value="";
}
</script>
</body>
</html>
"@

$htmlEncoding = New-Object `
    -TypeName System.Text.UTF8Encoding `
    -ArgumentList $false

[System.IO.File]::WriteAllText(
    $htmlPath,
    $htmlDocument,
    $htmlEncoding
)

Write-Host ''
Write-Host '[OK] Аналіз завершено.' -ForegroundColor Green
Write-Host (
    'Профілів: {0}' -f $summary.Count
)
Write-Host (
    'Загальний розмір: {0}' -f
    (Format-Bytes $totalBytes)
)
Write-Host (
    'Неактивні або вимкнені: {0}' -f
    (Format-Bytes $inactiveBytes)
)
Write-Host ''
Write-Host 'HTML-звіт:' -ForegroundColor Cyan
Write-Host $htmlPath -ForegroundColor Green
Write-Host 'CSV-зведення:' -ForegroundColor Cyan
Write-Host $summaryCsvPath -ForegroundColor Green
Write-Host 'CSV по папках:' -ForegroundColor Cyan
Write-Host $foldersCsvPath -ForegroundColor Green

$openReport = Read-Host `
    'Відкрити HTML-звіт зараз? [Y/N | Д/Н]'

if ($openReport -match '^(?i:y|д)$') {
    try {
        Start-Process `
            -FilePath $htmlPath `
            -ErrorAction Stop
    }
    catch {
        Write-Host (
            '[WARN] Не вдалося відкрити браузер: {0}' -f
            $_.Exception.Message
        ) -ForegroundColor Yellow
    }
}
