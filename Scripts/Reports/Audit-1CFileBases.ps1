<#
.SYNOPSIS
    Инвентаризация файловых баз 1С/BAS на Windows Server.

.DESCRIPTION
    1. Читает ibases.v8i во всех локальных пользовательских профилях.
    2. Находит все подключения Connect=File="...".
    3. Группирует одну физическую базу независимо от пользовательского названия.
    4. Проверяет наличие 1Cv8.1CD, размер и дату последнего изменения.
    5. По умолчанию дополнительно ищет 1Cv8.1CD на всех локальных fixed-дисках,
       чтобы найти базы, не прописанные ни у одного пользователя.
    6. Формирует автономный HTML-отчёт без внешних библиотек.

    Совместимость: Windows PowerShell 3.0+ / Windows Server 2012+.
    v1.4:
      - служебные каталоги cfg-cache и cgf-cache жёстко исключаются на всех этапах;
      - добавлена дата создания файла базы (CreationTime 1Cv8.1CD);
      - верхняя панель отчёта адаптирована для отправки клиенту;
      - добавлена справка по статусам и требованиям к резервному копированию.

.PARAMETER OutputPath
    Путь к HTML-отчёту. По умолчанию отчёт создаётся рядом со скриптом.

.PARAMETER ProfileOnly
    Не выполнять глубокий поиск по дискам. Анализировать только базы,
    найденные в ibases.v8i пользовательских профилей.

.PARAMETER ScanRoot
    Ограничить глубокий поиск указанными корнями, например:
      -ScanRoot 'D:\','E:\Bases'
    Если параметр не задан, сканируются все локальные fixed-диски.

.PARAMETER OpenReport
    Открыть HTML-отчёт после завершения.

.EXAMPLE
    .\Audit-1CFileBases.ps1

.EXAMPLE
    .\Audit-1CFileBases.ps1 -ProfileOnly

.EXAMPLE
    .\Audit-1CFileBases.ps1 -ScanRoot 'D:\','E:\1C'
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$ProfileOnly,
    [string[]]$ScanRoot,
    [switch]$OpenReport
)

$ErrorActionPreference = 'Continue'

# -----------------------------------------------------------------------------
# Общие функции
# -----------------------------------------------------------------------------

function Write-Step {
    param([string]$Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Test-IsAdministrator {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal -ArgumentList $identity
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function HtmlEncode {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-Bytes {
    param($Bytes)

    if ($null -eq $Bytes) { return '—' }

    try {
        $value = [double]([Int64]$Bytes)
    }
    catch {
        return '—'
    }

    if ($value -ge 1TB) { return ('{0:N2} TB' -f ($value / 1TB)) }
    if ($value -ge 1GB) { return ('{0:N2} GB' -f ($value / 1GB)) }
    if ($value -ge 1MB) { return ('{0:N2} MB' -f ($value / 1MB)) }
    if ($value -ge 1KB) { return ('{0:N2} KB' -f ($value / 1KB)) }
    return ('{0:N0} B' -f $value)
}

function Add-UniqueString {
    param(
        [System.Collections.ArrayList]$List,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }

    foreach ($existing in $List) {
        if ([string]::Equals([string]$existing, $Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    [void]$List.Add($Value)
}

function Read-AllBytesShared {
    param([string]$Path)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )

        $bytes = [System.Array]::CreateInstance([byte], [int]$stream.Length)
        $offset = 0

        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }

        return ,$bytes
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-TextFileAutoEncoding {
    param([string]$Path)

    $bytes = Read-AllBytesShared -Path $Path

    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {

        $enc = New-Object System.Text.UTF8Encoding -ArgumentList $true
        return [pscustomobject]@{
            Text     = $enc.GetString($bytes, 3, $bytes.Length - 3)
            Encoding = 'UTF8-BOM'
        }
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = [System.Text.Encoding]::Unicode
        return [pscustomobject]@{
            Text     = $enc.GetString($bytes, 2, $bytes.Length - 2)
            Encoding = 'UTF16-LE'
        }
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $enc = [System.Text.Encoding]::BigEndianUnicode
        return [pscustomobject]@{
            Text     = $enc.GetString($bytes, 2, $bytes.Length - 2)
            Encoding = 'UTF16-BE'
        }
    }

    # Сначала пробуем строгий UTF-8. Если не получилось — Windows-1251.
    try {
        $utf8Strict = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
        $text = $utf8Strict.GetString($bytes)
        return [pscustomobject]@{
            Text     = $text
            Encoding = 'UTF8'
        }
    }
    catch {
        $enc = [System.Text.Encoding]::GetEncoding(1251)
        return [pscustomobject]@{
            Text     = $enc.GetString($bytes)
            Encoding = 'Windows-1251'
        }
    }
}

function Resolve-ProfileRelativeVariables {
    param(
        [string]$RawPath,
        [string]$ProfilePath
    )

    $result = $RawPath

    if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
        $result = [regex]::Replace(
            $result,
            '%USERPROFILE%',
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $ProfilePath },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        $result = [regex]::Replace(
            $result,
            '%HOMEDRIVE%%HOMEPATH%',
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $ProfilePath },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        $result = [regex]::Replace(
            $result,
            '%APPDATA%',
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) (Join-Path $ProfilePath 'AppData\Roaming') },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        $result = [regex]::Replace(
            $result,
            '%LOCALAPPDATA%',
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) (Join-Path $ProfilePath 'AppData\Local') },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    return $result
}

function Normalize-BasePath {
    param(
        [string]$RawPath,
        [string]$ProfilePath
    )

    if ([string]::IsNullOrWhiteSpace($RawPath)) { return $null }

    $path = Resolve-ProfileRelativeVariables -RawPath $RawPath.Trim() -ProfilePath $ProfilePath
    $path = $path.Replace('/', '\')

    # Если на этом же сервере база прописана через административную шару
    # вида \\SERVER\D$\Base, приводим к D:\Base, чтобы не задваивать одну базу.
    if ($path -match '^\\\\([^\\]+)\\([A-Za-z])\$(\\.*)?$') {
        $hostName = $Matches[1]
        $drive = $Matches[2]
        $tail = $Matches[3]

        $localNames = @(
            $env:COMPUTERNAME,
            'localhost',
            '127.0.0.1'
        )

        $isLocal = $false
        foreach ($name in $localNames) {
            if (-not [string]::IsNullOrWhiteSpace($name) -and
                [string]::Equals($hostName, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isLocal = $true
                break
            }
        }

        if (-not $isLocal -and $hostName.Contains('.')) {
            $shortHost = $hostName.Split('.')[0]
            if ([string]::Equals($shortHost, $env:COMPUTERNAME, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isLocal = $true
            }
        }

        if ($isLocal) {
            if ([string]::IsNullOrEmpty($tail)) { $tail = '\' }
            $path = ('{0}:{1}' -f $drive.ToUpper(), $tail)
        }
    }

    try {
        if ([System.IO.Path]::IsPathRooted($path)) {
            $path = [System.IO.Path]::GetFullPath($path)
        }
    }
    catch {
        # Оставляем путь как записан, чтобы он всё равно попал в отчёт.
    }

    # Если кто-то умудрился прописать путь прямо к 1Cv8.1CD,
    # считаем базой каталог, в котором лежит файл.
    if ([System.IO.Path]::GetFileName($path) -ieq '1Cv8.1CD') {
        $path = Split-Path $path -Parent
    }

    # Не срезаем обратный слэш у корня диска C:\
    if ($path.Length -gt 3) {
        $path = $path.TrimEnd('\')
    }

    return $path
}

# -----------------------------------------------------------------------------
# Пользовательские профили
# -----------------------------------------------------------------------------

function Get-LocalUserProfiles {
    $profilesByPath = @{}

    # Основной источник: ProfileList. Так поймаем профили, если Users перенесён.
    $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

    if (Test-Path $profileList) {
        foreach ($key in Get-ChildItem $profileList -ErrorAction SilentlyContinue) {
            if ($key.PSChildName -like '*.bak') { continue }

            try {
                $props = Get-ItemProperty $key.PSPath -ErrorAction Stop
                $profilePath = [Environment]::ExpandEnvironmentVariables([string]$props.ProfileImagePath)

                if ([string]::IsNullOrWhiteSpace($profilePath)) { continue }
                if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) { continue }

                $leaf = Split-Path $profilePath -Leaf
                if ($leaf -in @('Public','Default','Default User','All Users','defaultuser0')) { continue }
                if ($profilePath -match '\\Windows\\(ServiceProfiles|System32\\config\\systemprofile)') { continue }

                $keyPath = $profilePath.ToLowerInvariant()

                if (-not $profilesByPath.ContainsKey($keyPath)) {
                    $profilesByPath[$keyPath] = [pscustomobject]@{
                        User        = $leaf
                        ProfilePath = $profilePath
                        SID         = $key.PSChildName
                    }
                }
            }
            catch {
                # Один повреждённый профиль не должен валить весь аудит.
            }
        }
    }

    # Добираем старые/остаточные каталоги из C:\Users, которых уже нет в ProfileList.
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (Test-Path $usersRoot) {
        foreach ($dir in Get-ChildItem $usersRoot -Directory -Force -ErrorAction SilentlyContinue) {
            if ($dir.Name -in @('Public','Default','Default User','All Users','defaultuser0')) { continue }

            $keyPath = $dir.FullName.ToLowerInvariant()
            if (-not $profilesByPath.ContainsKey($keyPath)) {
                $profilesByPath[$keyPath] = [pscustomobject]@{
                    User        = $dir.Name
                    ProfilePath = $dir.FullName
                    SID         = $null
                }
            }
        }
    }

    return @($profilesByPath.Values | Sort-Object User)
}

# -----------------------------------------------------------------------------
# Парсинг ibases.v8i
# -----------------------------------------------------------------------------

function Get-IBaseEntries {
    param(
        [string]$Path,
        [string]$User,
        [string]$ProfilePath
    )

    $result = New-Object System.Collections.ArrayList

    try {
        $file = Read-TextFileAutoEncoding -Path $Path
        $lines = [regex]::Split($file.Text, '\r?\n')
        $section = $null

        foreach ($line in $lines) {
            if ($line -match '^\s*\[(.*)\]\s*$') {
                $section = $Matches[1]
                continue
            }

            if ($line -match '^\s*Connect\s*=\s*(.+?)\s*$') {
                $connectValue = $Matches[1]

                if ($connectValue -match '^File\s*=\s*"([^"]*)"') {
                    $rawPath = $Matches[1]

                    [void]$result.Add([pscustomobject]@{
                        User        = $User
                        ProfilePath = $ProfilePath
                        ConfigPath  = $Path
                        Encoding    = $file.Encoding
                        Alias       = $section
                        RawPath     = $rawPath
                        ConnectLine = $line.Trim()
                        Type        = 'File'
                    })
                }
            }
        }
    }
    catch {
        [void]$result.Add([pscustomobject]@{
            User        = $User
            ProfilePath = $ProfilePath
            ConfigPath  = $Path
            Encoding    = $null
            Alias       = $null
            RawPath     = $null
            ConnectLine = $null
            Type        = 'ReadError'
            Error       = $_.Exception.Message
        })
    }

    return @($result)
}

# -----------------------------------------------------------------------------
# Глубокий поиск 1Cv8.1CD
# -----------------------------------------------------------------------------

function Test-Is1CCachePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    # Проверяем ВСЕ компоненты пути, а не только имя текущего каталога.
    # Это даёт дополнительную страховку: даже если сканирование стартовало
    # внутри служебного каталога, 1Cv8.1CD из cfg-cache в отчёт не попадёт.
    $normalized = $Path.Replace('/', '\').TrimEnd('\')
    $parts = @($normalized -split '\\')

    foreach ($part in $parts) {
        if ($part -ieq 'cfg-cache' -or $part -ieq 'cgf-cache') {
            return $true
        }
    }

    return $false
}

function Test-SkipDeepScanDirectory {
    param([string]$Path)

    if (Test-Is1CCachePath -Path $Path) {
        return $true
    }

    $name = Split-Path $Path -Leaf

    # Системные каталоги не сканируем. cfg-cache/cgf-cache проверяются отдельно выше
    # по полному пути, поэтому фильтр работает независимо от глубины вложенности.
    if ($name -in @(
        '$Recycle.Bin',
        'System Volume Information',
        'Recovery',
        'Windows',
        'Windows.old'
    )) {
        return $true
    }

    try {
        $attrs = [System.IO.File]::GetAttributes($Path)
        if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $true
        }
    }
    catch {
        return $true
    }

    return $false
}

function Find-1CBaseFiles {
    param([string[]]$Roots)

    $found = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $visited = 0

    foreach ($root in $Roots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            $stack.Push((Get-Item -LiteralPath $root -Force).FullName)
        }
    }

    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        $visited++

        if (($visited % 250) -eq 0) {
            Write-Progress -Activity 'Поиск файловых баз 1С/BAS' -Status "Каталогов просмотрено: $visited`n$dir"
        }

        try {
            $files = [System.IO.Directory]::GetFiles($dir, '1Cv8.1CD', [System.IO.SearchOption]::TopDirectoryOnly)
            foreach ($file in $files) {
                # Финальный жёсткий фильтр: никакой 1Cv8.1CD из cfg-cache/cgf-cache
                # не должен попасть в список найденных файлов даже при нестандартном ScanRoot.
                if (Test-Is1CCachePath -Path $file) {
                    continue
                }

                [void]$found.Add($file)
            }
        }
        catch {
            # Нет доступа — просто идём дальше.
        }

        try {
            $subDirs = [System.IO.Directory]::GetDirectories($dir)
            foreach ($subDir in $subDirs) {
                if (-not (Test-SkipDeepScanDirectory -Path $subDir)) {
                    $stack.Push($subDir)
                }
            }
        }
        catch {
            # Нет доступа к каталогу — пропускаем.
        }
    }

    Write-Progress -Activity 'Поиск файловых баз 1С/BAS' -Completed
    return @($found)
}

# -----------------------------------------------------------------------------
# Модель базы
# -----------------------------------------------------------------------------

function New-BaseRecord {
    param([string]$NormalizedPath)

    return [pscustomobject]@{
        Path             = $NormalizedPath
        OriginalPaths    = New-Object System.Collections.ArrayList
        Aliases          = New-Object System.Collections.ArrayList
        Users            = New-Object System.Collections.ArrayList
        UserAliases      = New-Object System.Collections.ArrayList
        Referenced       = $false
        FoundOnDisk      = $false
        DatabaseFile     = $null
        DatabaseExists   = $false
        DirectoryExists  = $false
        SizeBytes        = $null
        CreationTime     = $null
        LastWriteTime    = $null
    }
}

function Refresh-BaseFileInfo {
    param($Base)

    $path = $Base.Path

    if ([string]::IsNullOrWhiteSpace($path)) { return }

    $dbFile = $null
    $baseDir = $path

    if ([System.IO.Path]::GetFileName($path) -ieq '1Cv8.1CD') {
        $dbFile = $path
        $baseDir = Split-Path $path -Parent
        $Base.Path = $baseDir
    }
    else {
        $dbFile = Join-Path $path '1Cv8.1CD'
    }

    $Base.DatabaseFile = $dbFile
    $Base.DirectoryExists = Test-Path -LiteralPath $baseDir -PathType Container
    $Base.DatabaseExists = Test-Path -LiteralPath $dbFile -PathType Leaf

    if ($Base.DatabaseExists) {
        try {
            $fi = Get-Item -LiteralPath $dbFile -Force -ErrorAction Stop
            $Base.SizeBytes = [Int64]$fi.Length
            $Base.CreationTime = $fi.CreationTime
            $Base.LastWriteTime = $fi.LastWriteTime
        }
        catch {
            $Base.SizeBytes = $null
            $Base.CreationTime = $null
            $Base.LastWriteTime = $null
        }
    }
}

# -----------------------------------------------------------------------------
# Начало аудита
# -----------------------------------------------------------------------------

$started = Get-Date
$isAdmin = Test-IsAdministrator

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $reportRoot = $PSScriptRoot
    }
    else {
        $reportRoot = (Get-Location).Path
    }

    $OutputPath = Join-Path $reportRoot ('1C_FileBases_{0}_{1}.html' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

$outputDir = Split-Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

Write-Step 'Профили пользователей'

if (-not $isAdmin) {
    Write-Warning 'PowerShell запущен НЕ от администратора. Часть профилей или каталогов может быть недоступна.'
}

$profiles = @(Get-LocalUserProfiles)
Write-Host ('Найдено профилей: {0}' -f $profiles.Count)

$bases = @{}
$configProblems = New-Object System.Collections.ArrayList
$configFilesFound = 0
$fileConnectionsFound = 0

foreach ($profile in $profiles) {
    $ibases = Join-Path $profile.ProfilePath 'AppData\Roaming\1C\1CEStart\ibases.v8i'

    if (-not (Test-Path -LiteralPath $ibases -PathType Leaf)) {
        continue
    }

    $configFilesFound++

    $entries = @(Get-IBaseEntries -Path $ibases -User $profile.User -ProfilePath $profile.ProfilePath)

    foreach ($entry in $entries) {
        if ($entry.Type -eq 'ReadError') {
            [void]$configProblems.Add([pscustomobject]@{
                User  = $profile.User
                Alias = '—'
                Value = $ibases
                Issue = 'Не удалось прочитать ibases.v8i: ' + $entry.Error
            })
            continue
        }

        $fileConnectionsFound++

        # Сегодняшний любимец: File="Srvr=...". Это не файловая база,
        # а ошибочно вставленная серверная строка подключения.
        if ($entry.RawPath -match '^\s*Srvr\s*=') {
            [void]$configProblems.Add([pscustomobject]@{
                User  = $entry.User
                Alias = $entry.Alias
                Value = $entry.ConnectLine
                Issue = 'Серверная строка ошибочно записана как File=...'
            })
            continue
        }

        if ([string]::IsNullOrWhiteSpace($entry.RawPath)) {
            [void]$configProblems.Add([pscustomobject]@{
                User  = $entry.User
                Alias = $entry.Alias
                Value = $entry.ConnectLine
                Issue = 'Пустой путь файловой базы'
            })
            continue
        }

        $normalized = Normalize-BasePath -RawPath $entry.RawPath -ProfilePath $entry.ProfilePath

        if ([string]::IsNullOrWhiteSpace($normalized)) {
            [void]$configProblems.Add([pscustomobject]@{
                User  = $entry.User
                Alias = $entry.Alias
                Value = $entry.ConnectLine
                Issue = 'Не удалось нормализовать путь'
            })
            continue
        }

        $key = $normalized.ToLowerInvariant()

        if (-not $bases.ContainsKey($key)) {
            $bases[$key] = New-BaseRecord -NormalizedPath $normalized
        }

        $base = $bases[$key]
        $base.Referenced = $true

        Add-UniqueString -List $base.OriginalPaths -Value $entry.RawPath
        Add-UniqueString -List $base.Aliases -Value $(if ([string]::IsNullOrWhiteSpace($entry.Alias)) { '(без названия)' } else { $entry.Alias })
        Add-UniqueString -List $base.Users -Value $entry.User

        [void]$base.UserAliases.Add([pscustomobject]@{
            User  = $entry.User
            Alias = $(if ([string]::IsNullOrWhiteSpace($entry.Alias)) { '(без названия)' } else { $entry.Alias })
            Path  = $entry.RawPath
        })
    }
}

Write-Host ('ibases.v8i найдено: {0}' -f $configFilesFound)
Write-Host ('File-подключений найдено: {0}' -f $fileConnectionsFound)

# -----------------------------------------------------------------------------
# Глубокий поиск локальных 1Cv8.1CD
# -----------------------------------------------------------------------------

if (-not $ProfileOnly) {
    Write-Step 'Глубокий поиск 1Cv8.1CD'

    if ($ScanRoot -and $ScanRoot.Count -gt 0) {
        $roots = @($ScanRoot)
    }
    else {
        try {
            $roots = @(
                Get-WmiObject Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
                    Select-Object -ExpandProperty DeviceID |
                    ForEach-Object { $_ + '\' }
            )
        }
        catch {
            try {
                $roots = @(
                    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
                        Select-Object -ExpandProperty DeviceID |
                        ForEach-Object { $_ + '\' }
                )
            }
            catch {
                # Последний fallback. На обычном Windows Server сюда почти не попадём.
                $roots = @(
                    Get-PSDrive -PSProvider FileSystem |
                        Where-Object { $_.Root -match '^[A-Za-z]:\\$' } |
                        Select-Object -ExpandProperty Root
                )
            }
        }
    }

    Write-Host ('Корни сканирования: {0}' -f ($roots -join ', '))

    $diskFiles = @(Find-1CBaseFiles -Roots $roots)
    Write-Host ('1Cv8.1CD найдено на дисках: {0}' -f $diskFiles.Count)

    foreach ($dbFile in $diskFiles) {
        $dir = Split-Path $dbFile -Parent
        $normalized = Normalize-BasePath -RawPath $dir -ProfilePath $null
        $key = $normalized.ToLowerInvariant()

        if (-not $bases.ContainsKey($key)) {
            $bases[$key] = New-BaseRecord -NormalizedPath $normalized
        }

        $base = $bases[$key]
        $base.FoundOnDisk = $true
        Add-UniqueString -List $base.OriginalPaths -Value $dir
    }
}

# Освежаем фактическую информацию о каждой базе.
foreach ($base in $bases.Values) {
    Refresh-BaseFileInfo -Base $base

    if ($base.DatabaseExists) {
        $base.FoundOnDisk = $true
    }
}

# -----------------------------------------------------------------------------
# Готовим строки отчёта
# -----------------------------------------------------------------------------

Write-Step 'Формирование отчёта'

$reportRows = New-Object System.Collections.ArrayList

foreach ($base in $bases.Values) {
    # Последняя страховка от служебных кэшей, независимо от источника записи.
    if (Test-Is1CCachePath -Path $base.Path) {
        continue
    }

    $baseName = Split-Path $base.Path -Leaf
    if ([string]::IsNullOrWhiteSpace($baseName)) { $baseName = $base.Path }

    if (-not $base.DatabaseExists) {
        $status = 'MISSING'
        $statusText = 'Не найдена'
    }
    elseif (-not $base.Referenced) {
        $status = 'ORPHAN'
        $statusText = 'Не прописана у пользователей'
    }
    else {
        $status = 'OK'
        $statusText = 'OK'
    }

    $aliases = @($base.Aliases | Sort-Object)
    $users = @($base.Users | Sort-Object)

    $pairs = @(
        $base.UserAliases |
            Sort-Object User, Alias |
            ForEach-Object { '{0} → {1}' -f $_.User, $_.Alias }
    )

    [void]$reportRows.Add([pscustomobject]@{
        Status          = $status
        StatusText      = $statusText
        BaseName        = $baseName
        Path            = $base.Path
        OriginalPaths   = @($base.OriginalPaths | Sort-Object)
        Aliases         = $aliases
        Users           = $users
        UserAliasPairs  = $pairs
        UserCount       = $users.Count
        SizeBytes       = $base.SizeBytes
        SizeText        = Format-Bytes -Bytes $base.SizeBytes
        CreationTime    = $base.CreationTime
        CreationText    = $(if ($null -eq $base.CreationTime) { '—' } else { $base.CreationTime.ToString('dd.MM.yyyy HH:mm:ss') })
        LastWriteTime   = $base.LastWriteTime
        LastWriteText   = $(if ($null -eq $base.LastWriteTime) { '—' } else { $base.LastWriteTime.ToString('dd.MM.yyyy HH:mm:ss') })
        Referenced      = $base.Referenced
        FoundOnDisk     = $base.FoundOnDisk
    })
}

$reportRows = @(
    $reportRows |
        Sort-Object @{ Expression = { if ($null -eq $_.LastWriteTime) { [datetime]::MinValue } else { $_.LastWriteTime } }; Descending = $true }, BaseName
)

$totalBases = $reportRows.Count
$existingBases = @($reportRows | Where-Object { $_.Status -ne 'MISSING' }).Count
$missingBases = @($reportRows | Where-Object { $_.Status -eq 'MISSING' }).Count
$orphanBases = @($reportRows | Where-Object { $_.Status -eq 'ORPHAN' }).Count
$problemCount = $configProblems.Count
$totalBytes = [Int64]0
foreach ($row in $reportRows) {
    if ($null -ne $row.SizeBytes) { $totalBytes += [Int64]$row.SizeBytes }
}

$finished = Get-Date
$duration = $finished - $started

# -----------------------------------------------------------------------------
# HTML
# -----------------------------------------------------------------------------

$sb = New-Object System.Text.StringBuilder

[void]$sb.AppendLine('<!DOCTYPE html>')
[void]$sb.AppendLine('<html lang="ru">')
[void]$sb.AppendLine('<head>')
[void]$sb.AppendLine('<meta charset="utf-8">')
[void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
[void]$sb.AppendLine('<title>Аудит файловых баз 1С/BAS</title>')
[void]$sb.AppendLine(@'
<style>
:root {
    --bg: #f4f6f8;
    --panel: #ffffff;
    --text: #17202a;
    --muted: #65727e;
    --line: #dfe5ea;
    --accent: #315efb;
    --ok-bg: #e8f7ee;
    --ok: #176b3a;
    --warn-bg: #fff4da;
    --warn: #8a5b00;
    --bad-bg: #fdeaea;
    --bad: #a22727;
    --orphan-bg: #edf0ff;
    --orphan: #3f4ca3;
}
* { box-sizing: border-box; }
body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: "Segoe UI", Arial, sans-serif;
}
.container {
    max-width: 1700px;
    margin: 0 auto;
    padding: 28px;
}
.header {
    background: linear-gradient(135deg, #172033 0%, #263a68 100%);
    color: white;
    border-radius: 18px;
    padding: 28px 30px;
    box-shadow: 0 10px 30px rgba(24, 38, 69, .18);
}
.header h1 { margin: 0 0 8px; font-size: 28px; }
.header .meta { opacity: .82; line-height: 1.6; font-size: 14px; }
.header .intro {
    margin-top: 14px;
    max-width: 1350px;
    line-height: 1.55;
    font-size: 14px;
}
.header .legend {
    display: grid;
    grid-template-columns: repeat(3, minmax(220px, 1fr));
    gap: 10px;
    margin-top: 16px;
}
.header .legend-item {
    background: rgba(255,255,255,.08);
    border: 1px solid rgba(255,255,255,.12);
    border-radius: 12px;
    padding: 11px 13px;
    line-height: 1.45;
    font-size: 13px;
}
.header .legend-item strong {
    display: block;
    margin-bottom: 3px;
    font-size: 14px;
}
.header .client-request {
    margin-top: 12px;
    padding: 12px 14px;
    border-radius: 12px;
    background: rgba(255,255,255,.10);
    line-height: 1.5;
    font-size: 14px;
}
.header .backup-warning {
    margin-top: 10px;
    padding: 12px 14px;
    border-radius: 12px;
    background: rgba(255, 196, 80, .14);
    border: 1px solid rgba(255, 211, 119, .28);
    line-height: 1.5;
    font-size: 13px;
}
.cards {
    display: grid;
    grid-template-columns: repeat(6, minmax(150px, 1fr));
    gap: 14px;
    margin: 18px 0;
}
.card {
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: 14px;
    padding: 16px 18px;
    box-shadow: 0 3px 12px rgba(0,0,0,.04);
}
.card .value { font-size: 25px; font-weight: 700; margin-bottom: 3px; }
.card .label { color: var(--muted); font-size: 13px; }
.panel {
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: 16px;
    margin-top: 18px;
    overflow: hidden;
    box-shadow: 0 3px 12px rgba(0,0,0,.04);
}
.panel-head {
    display: flex;
    gap: 16px;
    align-items: center;
    justify-content: space-between;
    padding: 16px 18px;
    border-bottom: 1px solid var(--line);
}
.panel-head h2 { margin: 0; font-size: 18px; }
.search {
    width: min(480px, 45vw);
    border: 1px solid #cfd7df;
    border-radius: 9px;
    padding: 10px 12px;
    font: inherit;
    outline: none;
}
.search:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(49,94,251,.10); }
.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th {
    position: sticky;
    top: 0;
    background: #f8fafc;
    text-align: left;
    padding: 11px 12px;
    border-bottom: 1px solid var(--line);
    color: #45525e;
    white-space: nowrap;
    cursor: pointer;
    user-select: none;
}
td {
    padding: 11px 12px;
    border-bottom: 1px solid #edf1f4;
    vertical-align: top;
}
tr:hover td { background: #fafcff; }
.path { font-family: Consolas, "Courier New", monospace; font-size: 12px; word-break: break-all; }
.badge {
    display: inline-block;
    padding: 3px 7px;
    border-radius: 999px;
    margin: 1px 3px 2px 0;
    background: #eef2f6;
    border: 1px solid #dce3e9;
    white-space: nowrap;
}
.status {
    display: inline-block;
    padding: 4px 8px;
    border-radius: 999px;
    font-weight: 600;
    white-space: nowrap;
}
.status-ok { background: var(--ok-bg); color: var(--ok); }
.status-missing { background: var(--bad-bg); color: var(--bad); }
.status-orphan { background: var(--orphan-bg); color: var(--orphan); }
.muted { color: var(--muted); }
details summary { cursor: pointer; color: #40516a; }
details .detail-body { margin-top: 7px; line-height: 1.55; }
.problem { color: var(--bad); font-weight: 600; }
.footer { color: var(--muted); font-size: 12px; padding: 18px 2px 4px; line-height: 1.6; }
@media (max-width: 1100px) {
    .cards { grid-template-columns: repeat(3, 1fr); }
    .header .legend { grid-template-columns: 1fr; }
}
@media (max-width: 700px) {
    .container { padding: 12px; }
    .cards { grid-template-columns: repeat(2, 1fr); }
    .panel-head { align-items: stretch; flex-direction: column; }
    .search { width: 100%; }
}
</style>
<script>
function filterTable(inputId, tableId) {
    const q = document.getElementById(inputId).value.toLowerCase();
    const rows = document.querySelectorAll('#' + tableId + ' tbody tr');
    rows.forEach(row => {
        row.style.display = row.innerText.toLowerCase().includes(q) ? '' : 'none';
    });
}
function sortTable(tableId, col) {
    const table = document.getElementById(tableId);
    const tbody = table.tBodies[0];
    const rows = Array.from(tbody.rows);
    const th = table.tHead.rows[0].cells[col];
    const asc = th.dataset.order !== 'asc';
    table.querySelectorAll('th').forEach(x => x.dataset.order = '');
    th.dataset.order = asc ? 'asc' : 'desc';
    rows.sort((a,b) => {
        const av = (a.cells[col].dataset.sort || a.cells[col].innerText).toLowerCase();
        const bv = (b.cells[col].dataset.sort || b.cells[col].innerText).toLowerCase();
        return asc ? av.localeCompare(bv, 'ru', {numeric:true}) : bv.localeCompare(av, 'ru', {numeric:true});
    });
    rows.forEach(r => tbody.appendChild(r));
}
</script>
'@)
[void]$sb.AppendLine('</head>')
[void]$sb.AppendLine('<body><div class="container">')

[void]$sb.AppendLine('<section class="header">')
[void]$sb.AppendLine('<h1>Аудит файловых баз 1С / BAS</h1>')
[void]$sb.AppendLine(('<div class="meta"><b>Сервер:</b> {0} &nbsp;•&nbsp; <b>Сформирован:</b> {1}</div>' -f
    (HtmlEncode $env:COMPUTERNAME),
    (HtmlEncode $finished.ToString('dd.MM.yyyy HH:mm:ss'))))
[void]$sb.AppendLine('<div class="intro">Этот отчёт подготовлен для ревизии файловых баз 1С/BAS, обнаруженных на сервере и в списках запуска пользователей. Просим проверить перечень ниже и определить, какие базы необходимо сохранить в работе, а какие больше не используются.</div>')
[void]$sb.AppendLine('<div class="legend">')
[void]$sb.AppendLine('<div class="legend-item"><strong>OK</strong>База найдена на сервере и прописана в списках запуска (ярлыках) одного или нескольких пользователей.</div>')
[void]$sb.AppendLine('<div class="legend-item"><strong>Не прописана у пользователей</strong>База существует на сервере, но не прописана в списках запуска пользователей.</div>')
[void]$sb.AppendLine('<div class="legend-item"><strong>Не найдена</strong>База прописана в списках запуска пользователей, но по указанному пути на сервере не найдена. Возможно, она была удалена или перенесена.</div>')
[void]$sb.AppendLine('</div>')
[void]$sb.AppendLine('<div class="client-request"><b>Что нужно сообщить по результатам проверки:</b> для каждой базы укажите, нужна она или больше не используется. Для каждой нужной базы укажите желаемую периодичность резервного копирования.</div>')
[void]$sb.AppendLine('<div class="backup-warning"><b>Важно по резервному копированию:</b> на время создания резервной копии файловой базы необходимо завершить активные процессы/сеансы 1С/BAS на сервере, чтобы база не изменялась во время копирования. Поэтому такие резервные копии могут выполняться только в нерабочее время. Просим учитывать это при выборе расписания.</div>')
[void]$sb.AppendLine('</section>')

[void]$sb.AppendLine('<section class="cards">')
$cards = @(
    @('Уникальных баз', $totalBases),
    @('Найдены на диске', $existingBases),
    @('Не найдены', $missingBases),
    @('Ни у кого не прописаны', $orphanBases),
    @('Проблем конфигурации', $problemCount),
    @('Общий размер 1CD', (Format-Bytes -Bytes ([Nullable[Int64]]$totalBytes)))
)
foreach ($card in $cards) {
    [void]$sb.AppendLine(('<div class="card"><div class="value">{0}</div><div class="label">{1}</div></div>' -f (HtmlEncode $card[1]), (HtmlEncode $card[0])))
}
[void]$sb.AppendLine('</section>')

[void]$sb.AppendLine('<section class="panel">')
[void]$sb.AppendLine('<div class="panel-head"><h2>Файловые базы</h2><input id="baseSearch" class="search" type="search" placeholder="Поиск по базе, пути, пользователю, названию…" oninput="filterTable(''baseSearch'',''basesTable'')"></div>')
[void]$sb.AppendLine('<div class="table-wrap"><table id="basesTable">')
[void]$sb.AppendLine('<thead><tr>')
$headers = @('Статус','База / каталог','Путь','Названия у пользователей','Пользователи','Размер','Дата создания','Последнее изменение')
for ($i = 0; $i -lt $headers.Count; $i++) {
    [void]$sb.AppendLine(('<th onclick="sortTable(''basesTable'',{0})">{1}</th>' -f $i, (HtmlEncode $headers[$i])))
}
[void]$sb.AppendLine('</tr></thead><tbody>')

foreach ($row in $reportRows) {
    switch ($row.Status) {
        'OK'      { $statusClass = 'status-ok' }
        'MISSING' { $statusClass = 'status-missing' }
        'ORPHAN'  { $statusClass = 'status-orphan' }
        default   { $statusClass = '' }
    }

    $aliasHtml = if ($row.Aliases.Count -eq 0) {
        '<span class="muted">—</span>'
    }
    else {
        (($row.Aliases | ForEach-Object { '<span class="badge">' + (HtmlEncode $_) + '</span>' }) -join '')
    }

    if ($row.Users.Count -eq 0) {
        $usersHtml = '<span class="muted">—</span>'
    }
    else {
        $userBadges = (($row.Users | ForEach-Object { '<span class="badge">' + (HtmlEncode $_) + '</span>' }) -join '')
        $pairsHtml = (($row.UserAliasPairs | ForEach-Object { '<div>' + (HtmlEncode $_) + '</div>' }) -join '')
        $usersHtml = $userBadges + '<details><summary>' + $row.UserCount + ' профиль(я/ей): кто как назвал</summary><div class="detail-body">' + $pairsHtml + '</div></details>'
    }

    $originalPathDetails = ''
    if ($row.OriginalPaths.Count -gt 1) {
        $pathVariants = (($row.OriginalPaths | ForEach-Object { '<div class="path">' + (HtmlEncode $_) + '</div>' }) -join '')
        $originalPathDetails = '<details><summary>Варианты записи пути</summary><div class="detail-body">' + $pathVariants + '</div></details>'
    }

    $createdSort = if ($null -eq $row.CreationTime) { '00000000000000' } else { $row.CreationTime.ToString('yyyyMMddHHmmss') }
    $dateSort = if ($null -eq $row.LastWriteTime) { '00000000000000' } else { $row.LastWriteTime.ToString('yyyyMMddHHmmss') }
    $sizeSort = if ($null -eq $row.SizeBytes) { '0' } else { ([Int64]$row.SizeBytes).ToString('D20') }

    [void]$sb.AppendLine('<tr>')
    [void]$sb.AppendLine(('<td><span class="status {0}">{1}</span></td>' -f $statusClass, (HtmlEncode $row.StatusText)))
    [void]$sb.AppendLine(('<td><b>{0}</b></td>' -f (HtmlEncode $row.BaseName)))
    [void]$sb.AppendLine(('<td><div class="path">{0}</div>{1}</td>' -f (HtmlEncode $row.Path), $originalPathDetails))
    [void]$sb.AppendLine(('<td>{0}</td>' -f $aliasHtml))
    [void]$sb.AppendLine(('<td>{0}</td>' -f $usersHtml))
    [void]$sb.AppendLine(('<td data-sort="{0}">{1}</td>' -f $sizeSort, (HtmlEncode $row.SizeText)))
    [void]$sb.AppendLine(('<td data-sort="{0}">{1}</td>' -f $createdSort, (HtmlEncode $row.CreationText)))
    [void]$sb.AppendLine(('<td data-sort="{0}">{1}</td>' -f $dateSort, (HtmlEncode $row.LastWriteText)))
    [void]$sb.AppendLine('</tr>')
}

[void]$sb.AppendLine('</tbody></table></div></section>')

if ($configProblems.Count -gt 0) {
    [void]$sb.AppendLine('<section class="panel">')
    [void]$sb.AppendLine('<div class="panel-head"><h2>Проблемы в конфигурации пользователей</h2><input id="problemSearch" class="search" type="search" placeholder="Поиск…" oninput="filterTable(''problemSearch'',''problemsTable'')"></div>')
    [void]$sb.AppendLine('<div class="table-wrap"><table id="problemsTable">')
    [void]$sb.AppendLine('<thead><tr><th>Пользователь</th><th>Название</th><th>Запись</th><th>Проблема</th></tr></thead><tbody>')

    foreach ($problem in ($configProblems | Sort-Object User, Alias)) {
        [void]$sb.AppendLine('<tr>')
        [void]$sb.AppendLine(('<td>{0}</td>' -f (HtmlEncode $problem.User)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (HtmlEncode $problem.Alias)))
        [void]$sb.AppendLine(('<td class="path">{0}</td>' -f (HtmlEncode $problem.Value)))
        [void]$sb.AppendLine(('<td class="problem">{0}</td>' -f (HtmlEncode $problem.Issue)))
        [void]$sb.AppendLine('</tr>')
    }

    [void]$sb.AppendLine('</tbody></table></div></section>')
}

[void]$sb.AppendLine(('<div class="footer">Проверено профилей: {0}; файлов ibases.v8i: {1}; время выполнения: {2:N1} сек.<br>Размер базы считается по файлу <b>1Cv8.1CD</b>. «Дата создания» — CreationTime этого файла, «Последнее изменение» — LastWriteTime. При копировании или восстановлении базы CreationTime может отражать дату появления файла на текущем диске, а не первоначальную дату создания базы. Базы, найденные глубоким поиском, но отсутствующие во всех ibases.v8i, помечаются как «Не прописана у пользователей». Служебные каталоги <b>cfg-cache</b> и <b>cgf-cache</b> исключаются из отчёта.</div>' -f
    $profiles.Count,
    $configFilesFound,
    $duration.TotalSeconds))

[void]$sb.AppendLine('</div></body></html>')

$utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
[System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), $utf8Bom)

# -----------------------------------------------------------------------------
# Консольный итог
# -----------------------------------------------------------------------------

$consoleRows = @(
    $reportRows | ForEach-Object {
        [pscustomobject]@{
            Status     = $_.StatusText
            Base       = $_.BaseName
            Path       = $_.Path
            Aliases    = ($_.Aliases -join '; ')
            Users      = ($_.Users -join '; ')
            Size       = $_.SizeText
            LastChange = $_.LastWriteText
        }
    }
)

$consoleRows | Format-Table Status, Base, Path, Size, LastChange -AutoSize

Write-Host "`nHTML report:" -ForegroundColor Green
Write-Host $OutputPath -ForegroundColor Yellow
Write-Host ('Bases: {0}; missing: {1}; orphan: {2}; config problems: {3}' -f $totalBases, $missingBases, $orphanBases, $problemCount) -ForegroundColor Green

if ($OpenReport) {
    Start-Process $OutputPath
}
