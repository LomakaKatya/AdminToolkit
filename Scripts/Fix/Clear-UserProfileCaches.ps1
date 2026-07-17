Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Format-ByteSize {
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )

    if ($Bytes -ge 1TB) {
        return ('{0:N2} ТБ' -f ($Bytes / 1TB))
    }

    if ($Bytes -ge 1GB) {
        return ('{0:N2} ГБ' -f ($Bytes / 1GB))
    }

    if ($Bytes -ge 1MB) {
        return ('{0:N1} МБ' -f ($Bytes / 1MB))
    }

    if ($Bytes -ge 1KB) {
        return ('{0:N1} КБ' -f ($Bytes / 1KB))
    }

    return ('{0} Б' -f $Bytes)
}

function Get-PathFileInfo {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $files = @()

    if (Test-Path -LiteralPath $Path -PathType Container) {
        $files = @(
            Get-ChildItem `
                -LiteralPath $Path `
                -Recurse `
                -Force `
                -File `
                -ErrorAction SilentlyContinue
        )
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        $files = @(
            Get-Item `
                -LiteralPath $Path `
                -Force `
                -ErrorAction SilentlyContinue
        )
    }

    $bytes = 0L

    if ($files.Count -gt 0) {
        $measure = $files | Measure-Object -Property Length -Sum

        if ($null -ne $measure.Sum) {
            $bytes = [long]$measure.Sum
        }
    }

    return [pscustomobject]@{
        Files = $files.Count
        Bytes = $bytes
    }
}

function Remove-CacheContent {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $result = [ordered]@{
        RemovedFiles = 0
        RemovedBytes = 0L
        FailedFiles  = 0
        FailedBytes  = 0L
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]$result
    }

    $items = @()

    if (Test-Path -LiteralPath $Path -PathType Container) {
        $items = @(
            Get-ChildItem `
                -LiteralPath $Path `
                -Force `
                -ErrorAction SilentlyContinue
        )
    }
    else {
        $items = @(
            Get-Item `
                -LiteralPath $Path `
                -Force `
                -ErrorAction SilentlyContinue
        )
    }

    foreach ($item in $items) {
        $info = Get-PathFileInfo -Path $item.FullName

        try {
            Remove-Item `
                -LiteralPath $item.FullName `
                -Recurse `
                -Force `
                -ErrorAction Stop

            $result.RemovedFiles += $info.Files
            $result.RemovedBytes += $info.Bytes
        }
        catch {
            $result.FailedFiles += $info.Files
            $result.FailedBytes += $info.Bytes
        }
    }

    return [pscustomobject]$result
}

function Get-ProfileCacheTargets {
    param(
        [Parameter(Mandatory)]
        [string]$ProfilePath,

        [switch]$IncludeBrowsers
    )

    $targets = New-Object -TypeName System.Collections.ArrayList

    foreach ($target in @(
        [pscustomobject]@{
            Name = 'Тимчасові файли користувача'
            Path = Join-Path $ProfilePath 'AppData\Local\Temp'
        },
        [pscustomobject]@{
            Name = 'Internet Cache Windows'
            Path = Join-Path $ProfilePath 'AppData\Local\Microsoft\Windows\INetCache'
        },
        [pscustomobject]@{
            Name = 'DirectX Shader Cache'
            Path = Join-Path $ProfilePath 'AppData\Local\D3DSCache'
        },
        [pscustomobject]@{
            Name = 'Crash Dumps'
            Path = Join-Path $ProfilePath 'AppData\Local\CrashDumps'
        }
    )) {
        [void]$targets.Add($target)
    }

    $explorerPath = Join-Path `
        $ProfilePath `
        'AppData\Local\Microsoft\Windows\Explorer'

    if (Test-Path -LiteralPath $explorerPath -PathType Container) {
        $explorerCaches = @(
            Get-ChildItem `
                -LiteralPath $explorerPath `
                -Force `
                -File `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like 'thumbcache_*.db' -or
                $_.Name -like 'iconcache_*.db'
            }
        )

        foreach ($cacheFile in $explorerCaches) {
            [void]$targets.Add(
                [pscustomobject]@{
                    Name = 'Кеш ескізів Explorer'
                    Path = $cacheFile.FullName
                }
            )
        }
    }

    if ($IncludeBrowsers) {
        $chromiumRoots = @(
            [pscustomobject]@{
                Name = 'Google Chrome'
                Path = Join-Path $ProfilePath 'AppData\Local\Google\Chrome\User Data'
            },
            [pscustomobject]@{
                Name = 'Microsoft Edge'
                Path = Join-Path $ProfilePath 'AppData\Local\Microsoft\Edge\User Data'
            }
        )

        foreach ($browser in $chromiumRoots) {
            if (-not (Test-Path -LiteralPath $browser.Path -PathType Container)) {
                continue
            }

            $browserProfiles = @(
                Get-ChildItem `
                    -LiteralPath $browser.Path `
                    -Directory `
                    -Force `
                    -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -eq 'Default' -or
                    $_.Name -like 'Profile *' -or
                    $_.Name -eq 'Guest Profile'
                }
            )

            foreach ($browserProfile in $browserProfiles) {
                foreach ($relativeCachePath in @(
                    'Cache',
                    'Code Cache',
                    'GPUCache',
                    'Service Worker\CacheStorage'
                )) {
                    [void]$targets.Add(
                        [pscustomobject]@{
                            Name = (
                                '{0}, {1}, {2}' -f
                                $browser.Name,
                                $browserProfile.Name,
                                $relativeCachePath
                            )
                            Path = Join-Path `
                                $browserProfile.FullName `
                                $relativeCachePath
                        }
                    )
                }
            }
        }

        $firefoxProfilesPath = Join-Path `
            $ProfilePath `
            'AppData\Local\Mozilla\Firefox\Profiles'

        if (Test-Path -LiteralPath $firefoxProfilesPath -PathType Container) {
            $firefoxProfiles = @(
                Get-ChildItem `
                    -LiteralPath $firefoxProfilesPath `
                    -Directory `
                    -Force `
                    -ErrorAction SilentlyContinue
            )

            foreach ($firefoxProfile in $firefoxProfiles) {
                [void]$targets.Add(
                    [pscustomobject]@{
                        Name = "Mozilla Firefox, $($firefoxProfile.Name), cache2"
                        Path = Join-Path $firefoxProfile.FullName 'cache2'
                    }
                )
            }
        }
    }

    return @($targets)
}

Write-Host ''
Write-Host 'Очищення стандартних кешів у профілях користувачів' `
    -ForegroundColor Cyan
Write-Host ''
Write-Host 'Скрипт очищує лише відомі кеші. Документи, робочий стіл,' `
    -ForegroundColor DarkGray
Write-Host 'закладки, паролі та налаштування програм не видаляються.' `
    -ForegroundColor DarkGray
Write-Host ''
Write-Host '  1. Стандартні кеші Windows'
Write-Host '  2. Windows + кеші Chrome, Edge і Firefox'
Write-Host '  0. Скасувати'
Write-Host ''

$mode = Read-Host 'Оберіть режим'

switch ($mode) {
    '1' {
        $includeBrowsers = $false
    }

    '2' {
        $includeBrowsers = $true
    }

    '0' {
        Write-Host 'Дію скасовано.' -ForegroundColor Yellow
        return
    }

    default {
        throw 'Невідомий режим очищення.'
    }
}

$excludedProfileNames = @(
    'All Users',
    'Default',
    'Default User',
    'Public',
    'defaultuser0',
    'WDAGUtilityAccount'
)

$profiles = @(
    Get-ChildItem `
        -LiteralPath 'C:\Users' `
        -Directory `
        -Force `
        -ErrorAction Stop |
    Where-Object {
        $_.Name -notin $excludedProfileNames -and
        -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    } |
    Sort-Object -Property Name
)

if ($profiles.Count -eq 0) {
    Write-Host '[WARN] Профілі користувачів не знайдено.' `
        -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host 'Оцінюю обсяг кешів. Це може зайняти кілька хвилин...' `
    -ForegroundColor DarkGray
Write-Host ''

$profilePlans = New-Object -TypeName System.Collections.ArrayList
$totalFiles = 0
$totalBytes = 0L

foreach ($profile in $profiles) {
    $targets = @(
        Get-ProfileCacheTargets `
            -ProfilePath $profile.FullName `
            -IncludeBrowsers:$includeBrowsers
    )

    $profileFiles = 0
    $profileBytes = 0L

    foreach ($target in $targets) {
        $info = Get-PathFileInfo -Path $target.Path
        $profileFiles += $info.Files
        $profileBytes += $info.Bytes
    }

    [void]$profilePlans.Add(
        [pscustomobject]@{
            Name    = $profile.Name
            Targets = $targets
            Files   = $profileFiles
            Bytes   = $profileBytes
        }
    )

    $totalFiles += $profileFiles
    $totalBytes += $profileBytes

    $color = if ($profileBytes -ge 5GB) {
        [ConsoleColor]::Red
    }
    elseif ($profileBytes -ge 1GB) {
        [ConsoleColor]::Yellow
    }
    else {
        [ConsoleColor]::Green
    }

    Write-Host (
        '{0,-28} {1,9} файлів  {2,12}' -f
        $profile.Name,
        $profileFiles,
        (Format-ByteSize -Bytes $profileBytes)
    ) -ForegroundColor $color
}

Write-Host ''
Write-Host ('-' * 68) -ForegroundColor DarkGray
Write-Host (
    'Разом: {0} файлів, приблизно {1}' -f
    $totalFiles,
    (Format-ByteSize -Bytes $totalBytes)
) -ForegroundColor Cyan
Write-Host ''

if ($totalFiles -eq 0 -and $totalBytes -eq 0) {
    Write-Host '[OK] Відомі кеші вже порожні.' -ForegroundColor Green
    return
}

Write-Host 'Перед очищенням бажано закрити браузери та 1С.' `
    -ForegroundColor Yellow
Write-Host 'Файли, які використовуються активними програмами, буде пропущено.' `
    -ForegroundColor DarkGray

$confirmation = Read-Host 'Для початку очищення введи CLEAN'

if ($confirmation -cne 'CLEAN') {
    Write-Host 'Очищення скасовано.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host 'Очищую...' -ForegroundColor DarkGray
Write-Host ''

$removedFiles = 0
$removedBytes = 0L
$failedFiles = 0
$failedBytes = 0L

foreach ($profilePlan in $profilePlans) {
    $profileRemovedBytes = 0L
    $profileFailedFiles = 0

    foreach ($target in $profilePlan.Targets) {
        $result = Remove-CacheContent -Path $target.Path

        $profileRemovedBytes += $result.RemovedBytes
        $profileFailedFiles += $result.FailedFiles

        $removedFiles += $result.RemovedFiles
        $removedBytes += $result.RemovedBytes
        $failedFiles += $result.FailedFiles
        $failedBytes += $result.FailedBytes
    }

    $color = if ($profileFailedFiles -gt 0) {
        [ConsoleColor]::Yellow
    }
    else {
        [ConsoleColor]::Green
    }

    Write-Host (
        '[{0}] {1,-24} видалено {2}, пропущено файлів: {3}' -f
        $(if ($profileFailedFiles -gt 0) {
            'WARN'
        }
        else {
            'OK'
        }),
        $profilePlan.Name,
        (Format-ByteSize -Bytes $profileRemovedBytes),
        $profileFailedFiles
    ) -ForegroundColor $color
}

Write-Host ''
Write-Host ('=' * 68) -ForegroundColor DarkCyan
Write-Host 'ПІДСУМОК' -ForegroundColor Cyan
Write-Host ('=' * 68) -ForegroundColor DarkCyan
Write-Host ''

Write-Host (
    '[OK] Видалено: {0} файлів, {1}' -f
    $removedFiles,
    (Format-ByteSize -Bytes $removedBytes)
) -ForegroundColor Green

if ($failedFiles -gt 0) {
    Write-Host (
        '[WARN] Не видалено: {0} файлів, приблизно {1}' -f
        $failedFiles,
        (Format-ByteSize -Bytes $failedBytes)
    ) -ForegroundColor Yellow

    Write-Host 'Зазвичай це файли, відкриті активними програмами або сеансами користувачів.' `
        -ForegroundColor DarkGray
}
else {
    Write-Host '[OK] Заблокованих файлів не залишилося.' `
        -ForegroundColor Green
}
