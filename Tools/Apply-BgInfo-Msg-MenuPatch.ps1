[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

$startPath = Join-Path $RepositoryRoot 'Start-AdminToolkit.ps1'

if (-not (Test-Path -LiteralPath $startPath -PathType Leaf)) {
    throw "Не знайдено файл: $startPath"
}

$source = [System.IO.File]::ReadAllText(
    $startPath,
    (New-Object `
        -TypeName System.Text.UTF8Encoding `
        -ArgumentList $false, $true)
)

$source = $source.Replace("`r`n", "`n")

$oldSoftwareMenu = @'
        function Show-SoftwareMenu {
            Show-EmptySection -SectionName 'ВСТАНОВЛЕННЯ ПЗ'
        }
'@

$newSoftwareMenu = @'
        function Show-SoftwareMenu {
            while ($true) {
                Write-RaccoonHeader -SectionName 'ВСТАНОВЛЕННЯ ПЗ'

                Write-Host '  MICROSOFT SYSINTERNALS BGINFO' -ForegroundColor DarkCyan
                Write-Host '  1. Встановити або оновити BgInfo'
                Write-Host '     [ADMIN] [DOWNLOADS SOFTWARE] [CHANGES SYSTEM]'
                Write-Host ''
                Write-Host '  2. Налаштувати стандартний шаблон BgInfo'
                Write-Host '     [ADMIN] [INTERACTIVE] [CHANGES USER DESKTOP]'
                Write-Host ''
                Write-Host '  3. Перевірити стан BgInfo'
                Write-Host '     [SAFE]'
                Write-Host ''
                Write-Host '  4. Підготувати пакет BgInfo для доменної політики'
                Write-Host '     [ADMIN] [CREATES FILES]'
                Write-Host ''
                Write-Host '  5. Видалити BgInfo'
                Write-Host '     [ADMIN] [CHANGES SYSTEM]'
                Write-Host ''

                Write-Host '  0. Повернутися до головного меню'
                Write-Host ''

                $choice = Read-Host 'Оберіть дію'

                switch ($choice) {
                    '1' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Software/BgInfo/Install-BgInfo.ps1' `
                            -Name 'Встановлення Microsoft Sysinternals BgInfo' `
                            -RequiresAdministrator
                    }

                    '2' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Software/BgInfo/Configure-BgInfo.ps1' `
                            -Name 'Налаштування стандартного шаблону BgInfo' `
                            -RequiresAdministrator
                    }

                    '3' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Software/BgInfo/Get-BgInfoStatus.ps1' `
                            -Name 'Стан Microsoft Sysinternals BgInfo'
                    }

                    '4' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Software/BgInfo/Prepare-BgInfoGpoPackage.ps1' `
                            -Name 'Пакет BgInfo для доменної політики' `
                            -RequiresAdministrator
                    }

                    '5' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Software/BgInfo/Uninstall-BgInfo.ps1' `
                            -Name 'Видалення Raccoon BgInfo' `
                            -RequiresAdministrator
                    }

                    '0' {
                        return
                    }

                    default {
                        Write-Host ''
                        Write-Host 'Такого пункту поки немає.' -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                    }
                }
            }
        }
'@

if (-not $source.Contains($oldSoftwareMenu)) {
    throw 'Не знайдено очікуваний блок Show-SoftwareMenu. Файл міг змінитися.'
}

$source = $source.Replace(
    $oldSoftwareMenu,
    $newSoftwareMenu
)

$leftQuote = [char]0x00AB
$rightQuote = [char]0x00BB

$oldFrequentMenu = @"
            Write-Host '  5. Створити або відновити кнопку ${leftQuote}Завершення сеансу${rightQuote}'
            Write-Host '     [ADMIN] [CHANGES SYSTEM]'
            Write-Host ''

            Write-Host '  0. Вихід і закриття PowerShell'
"@

$newFrequentMenu = @'
            Write-Host '  5. Створити або відновити кнопку завершення сеансу'
            Write-Host '     [ADMIN] [CHANGES SYSTEM]'
            Write-Host ''
            Write-Host '  6. Надіслати повідомлення користувачам'
            Write-Host '     [ADMIN] [USES MSG.EXE]'
            Write-Host ''

            Write-Host '  0. Вихід і закриття PowerShell'
'@

if (-not $source.Contains($oldFrequentMenu)) {
    throw 'Не знайдено очікуваний блок часто використовуваних скриптів.'
}

$source = $source.Replace(
    $oldFrequentMenu,
    $newFrequentMenu
)

$oldSwitchBlock = @'
                '5' {
                    Invoke-RaccoonScript `
                        -Path 'Scripts/Server/Create-LogoffShortcut.ps1' `
                        -Name 'Кнопка коректного завершення сеансу' `
                        -RequiresAdministrator `
                        -ChangesSystem
                }

                '0' {
'@

$newSwitchBlock = @'
                '5' {
                    Invoke-RaccoonScript `
                        -Path 'Scripts/Server/Create-LogoffShortcut.ps1' `
                        -Name 'Кнопка коректного завершення сеансу' `
                        -RequiresAdministrator `
                        -ChangesSystem
                }

                '6' {
                    Invoke-RaccoonScript `
                        -Path 'Scripts/Server/Send-UserMessage.ps1' `
                        -Name 'Повідомлення користувачам через msg.exe' `
                        -RequiresAdministrator
                }

                '0' {
'@

if (-not $source.Contains($oldSwitchBlock)) {
    throw 'Не знайдено очікуваний блок головного switch.'
}

$source = $source.Replace(
    $oldSwitchBlock,
    $newSwitchBlock
)

Write-Utf8NoBom -Path $startPath -Text $source

Write-Host '[OK] Меню Start-AdminToolkit.ps1 оновлено локально.'
Write-Host '[INFO] Запусти Tools\Test-Repository.ps1 перед завантаженням у GitHub.'
