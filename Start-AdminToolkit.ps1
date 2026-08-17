& {
    try {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'

        if ($PSVersionTable.PSVersion.Major -lt 3) {
            throw 'Raccoon Admin Toolkit потребує PowerShell 3.0 або новішої версії.'
        }

        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor
                [Net.SecurityProtocolType]::Tls12
        }
        catch {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor 3072
        }

        $baseUrl =
            'https://raw.githubusercontent.com/LomakaKatya/AdminToolkit/main'

        function Write-Utf8NoBomLines {
            param(
                [Parameter(Mandatory)]
                [string]$Path,

                [Parameter(Mandatory)]
                [AllowEmptyCollection()]
                [string[]]$Lines
            )

            $encoding = New-Object `
                -TypeName System.Text.UTF8Encoding `
                -ArgumentList $false

            [System.IO.File]::WriteAllLines(
                $Path,
                $Lines,
                $encoding
            )
        }

        function Clear-RaccoonLaunchHistory {
            $historyPath = $null
            $historyLines = @()
            $filteredHistory = @()

            try {
                if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
                    try {
                        $historyPath =
                            (Get-PSReadLineOption).HistorySavePath
                    }
                    catch {
                    }

                    try {
                        Set-PSReadLineOption `
                            -HistorySaveStyle SaveNothing `
                            -ErrorAction SilentlyContinue
                    }
                    catch {
                    }

                    try {
                        Set-PSReadLineOption `
                            -AddToHistoryHandler {
                                param([string]$Line)

                                if ($Line -match '(?i)[a-z0-9.-]*itraccoonverse\.space' -or
                                    $Line -match '(?i)raw\.githubusercontent\.com[/\\]LomakaKatya[/\\]AdminToolkit') {
                                    return $false
                                }

                                return $true
                            } `
                            -ErrorAction SilentlyContinue
                    }
                    catch {
                    }

                    try {
                        [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
                    }
                    catch {
                    }
                }

                try {
                    Clear-History -ErrorAction SilentlyContinue
                }
                catch {
                }

                if ($historyPath -and
                    (Test-Path -LiteralPath $historyPath -PathType Leaf)) {

                    $historyLines = @(
                        Get-Content `
                            -LiteralPath $historyPath `
                            -ErrorAction SilentlyContinue
                    )

                    $filteredHistory = @(
                        $historyLines |
                        Where-Object {
                            $_ -notmatch '(?i)[a-z0-9.-]*itraccoonverse\.space' -and
                            $_ -notmatch '(?i)raw\.githubusercontent\.com[/\\]LomakaKatya[/\\]AdminToolkit'
                        }
                    )

                    if ($filteredHistory.Count -eq 0) {
                        Remove-Item `
                            -LiteralPath $historyPath `
                            -Force `
                            -ErrorAction SilentlyContinue
                    }
                    else {
                        Write-Utf8NoBomLines `
                            -Path $historyPath `
                            -Lines $filteredHistory
                    }
                }
            }
            catch {
            }
            finally {
                $historyLines = $null
                $filteredHistory = $null
            }
        }

        function Test-IsAdministrator {
            $identity =
                [Security.Principal.WindowsIdentity]::GetCurrent()

            $principal = New-Object `
                -TypeName Security.Principal.WindowsPrincipal `
                -ArgumentList $identity

            return $principal.IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )
        }

        function Pause-RaccoonToolkit {
            Write-Host ''
            [void](Read-Host 'Натисни Enter, щоб продовжити')
        }

        function Write-RaccoonHeader {
            param(
                [string]$SectionName
            )

            Clear-Host

            Write-Host (
                '=' * 72
            ) -ForegroundColor DarkCyan

            Write-Host (
                '                         RACCOON ADMIN TOOLKIT'
            ) -ForegroundColor Cyan

            Write-Host (
                '=' * 72
            ) -ForegroundColor DarkCyan

            if (-not [string]::IsNullOrWhiteSpace($SectionName)) {
                Write-Host ''
                Write-Host "  $SectionName" -ForegroundColor Cyan
                Write-Host (
                    '  ' + ('-' * 68)
                ) -ForegroundColor DarkGray
            }

            Write-Host ''
        }

        function Invoke-RaccoonScript {
            param(
                [Parameter(Mandatory)]
                [string]$Path,

                [Parameter(Mandatory)]
                [string]$Name,

                [switch]$RequiresAdministrator,

                [switch]$ChangesSystem
            )

            Write-RaccoonHeader -SectionName $Name

            if ($RequiresAdministrator -and
                -not (Test-IsAdministrator)) {

                Write-Host (
                    'Для цієї дії потрібні права адміністратора.'
                ) -ForegroundColor Red

                Write-Host (
                    'Закрий інструментарій і запусти PowerShell від імені адміністратора.'
                ) -ForegroundColor Yellow

                Pause-RaccoonToolkit
                return
            }

            if ($ChangesSystem) {
                Write-Host (
                    'Увага: цей пункт вносить зміни до системи.'
                ) -ForegroundColor Yellow

                $confirmation = Read-Host 'Продовжити? [Y/N]'

                if ($confirmation -notmatch '^(y|yes|д|так)$') {
                    Write-Host ''
                    Write-Host 'Дію скасовано.' -ForegroundColor Yellow
                    Pause-RaccoonToolkit
                    return
                }

                Write-Host ''
            }

            $cacheToken = [DateTime]::UtcNow.Ticks
            $uri = "$baseUrl/$Path`?nocache=$cacheToken"

            try {
                Write-Host (
                    'Завантажую актуальну версію скрипта...'
                ) -ForegroundColor DarkGray

                $content = Invoke-RestMethod `
                    -Uri $uri `
                    -Headers @{
                        'Cache-Control' = 'no-cache'
                        'Pragma'        = 'no-cache'
                    } `
                    -ErrorAction Stop

                if ([string]::IsNullOrWhiteSpace([string]$content)) {
                    throw "GitHub повернув порожній файл: $Path"
                }

                $bomMarkers = [char[]]@(
                    [char]0xFEFF,
                    [char]0x00EF,
                    [char]0x00BB,
                    [char]0x00BF
                )

                $scriptText =
                    ([string]$content).TrimStart($bomMarkers)

                if ([string]::IsNullOrWhiteSpace($scriptText)) {
                    throw (
                        "Після нормалізації отримано порожній скрипт: $Path"
                    )
                }

                $scriptBlock =
                    [ScriptBlock]::Create($scriptText)

                Write-Host 'Запускаю.' -ForegroundColor DarkGray
                Write-Host ''

                & $scriptBlock
            }
            catch {
                Write-Host ''
                Write-Host (
                    'Не вдалося виконати скрипт.'
                ) -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Yellow
            }
            finally {
                $content = $null
                $scriptText = $null
                $bomMarkers = $null
                $scriptBlock = $null
                $uri = $null
                $cacheToken = $null

                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
            }

            Pause-RaccoonToolkit
        }

        function Show-EmptySection {
            param(
                [Parameter(Mandatory)]
                [string]$SectionName
            )

            while ($true) {
                Write-RaccoonHeader -SectionName $SectionName

                Write-Host (
                    'У цьому розділі поки немає скриптів.'
                ) -ForegroundColor DarkYellow

                Write-Host ''
                Write-Host '  0. Повернутися до головного меню'
                Write-Host ''

                $choice = Read-Host 'Оберіть дію'

                switch ($choice) {
                    '0' {
                        return
                    }

                    default {
                        Write-Host ''
                        Write-Host (
                            'Такого пункту поки немає.'
                        ) -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                    }
                }
            }
        }

        function Show-DiagnosticsMenu {
            while ($true) {
                Write-RaccoonHeader -SectionName 'ДІАГНОСТИКА'

                Write-Host (
                    '  МЕРЕЖА ТА ДОСТУП'
                ) -ForegroundColor DarkCyan

                Write-Host '  1. Перевірити TCP-підключення до адреси й порту'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host '  2. Комплексна діагностика Wi-Fi'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host '  3. Комплексна діагностика інтернету'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host '  4. Діагностика доступу до сайту'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host '  5. Діагностика віддаленого доступу'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host (
                    "  КОМП'ЮТЕР І ПРИСТРОЇ"
                ) -ForegroundColor DarkCyan

                Write-Host '  6. Діагностика друку'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host '  7. Діагностика зависань і продуктивності ПК'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host (
                    '  ОБЛІКОВІ ЗАПИСИ ТА ЖУРНАЛИ'
                ) -ForegroundColor DarkCyan

                Write-Host '  8. Локальні користувачі та час останнього входу'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host '  9. Невдалі спроби входу, подія 4625'
                Write-Host '     [SAFE] [MEMORY ONLY] [ADMIN]'
                Write-Host ''

                Write-Host '  0. Повернутися до головного меню'
                Write-Host ''

                $choice = Read-Host 'Оберіть дію'

                switch ($choice) {
                    '1' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Test-TcpConnection.ps1' `
                            -Name 'Перевірка TCP-підключення'
                    }

                    '2' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-WifiDiagnostics.ps1' `
                            -Name 'Комплексна діагностика Wi-Fi'
                    }

                    '3' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-InternetDiagnostics.ps1' `
                            -Name 'Комплексна діагностика інтернету'
                    }

                    '4' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Test-WebsiteAccess.ps1' `
                            -Name 'Діагностика доступу до сайту'
                    }

                    '5' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-RemoteAccessDiagnostics.ps1' `
                            -Name 'Діагностика віддаленого доступу'
                    }

                    '6' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-PrinterDiagnostics.ps1' `
                            -Name 'Діагностика друку'
                    }

                    '7' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-ComputerHealthDiagnostics.ps1' `
                            -Name 'Діагностика зависань і продуктивності ПК'
                    }

                    '8' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-LocalUserLogonInfo.ps1' `
                            -Name 'Локальні користувачі та час останнього входу'
                    }

                    '9' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-FailedLogons.ps1' `
                            -Name 'Невдалі спроби входу, подія 4625' `
                            -RequiresAdministrator
                    }

                    '0' {
                        return
                    }

                    default {
                        Write-Host ''
                        Write-Host (
                            'Такого пункту поки немає.'
                        ) -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                    }
                }
            }
        }

        function Show-MonitoringMenu {
            Show-EmptySection -SectionName 'МОНІТОРИНГ'
        }

        function Show-FixMenu {
            while ($true) {
                Write-RaccoonHeader -SectionName 'ВИПРАВЛЕННЯ'

                Write-Host (
                    '  КОРИСТУВАЦЬКІ ПРОГРАМИ'
                ) -ForegroundColor DarkCyan

                Write-Host '  1. Очистити кеш 1С'
                Write-Host '     [CHANGES USER DATA]'
                Write-Host ''

                Write-Host '  2. Перезапустити буфер обміну RDP'
                Write-Host '     [CHANGES SYSTEM]'
                Write-Host ''

                Write-Host (
                    '  СИСТЕМНІ СЛУЖБИ'
                ) -ForegroundColor DarkCyan

                Write-Host '  3. Очистити чергу та перезапустити службу друку'
                Write-Host '     [ADMIN] [CHANGES SYSTEM]'
                Write-Host ''

                Write-Host '  4. Виправити синхронізацію часу Windows'
                Write-Host '     [ADMIN] [CHANGES SYSTEM]'
                Write-Host ''

                Write-Host (
                    '  РОЗШИРЕНІ НАЛАШТУВАННЯ'
                ) -ForegroundColor DarkCyan

                Write-Host '  5. Сумісність RPC-автентифікації мережевого друку'
                Write-Host (
                    '     [ADMIN] [SECURITY SENSITIVE] [CHANGES SYSTEM]'
                )
                Write-Host ''

                Write-Host (
                    '  ОБСЛУГОВУВАННЯ ПРОФІЛІВ'
                ) -ForegroundColor DarkCyan

                Write-Host '  6. Очистити стандартні кеші в профілях користувачів'
                Write-Host '     [ADMIN] [CHANGES USER DATA]'
                Write-Host ''

                Write-Host '  0. Повернутися до головного меню'
                Write-Host ''

                $choice = Read-Host 'Оберіть дію'

                switch ($choice) {
                    '1' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Fix/Clear-1CCache.ps1' `
                            -Name 'Очищення кешу 1С'
                    }

                    '2' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Fix/Restart-RdpClipboard.ps1' `
                            -Name 'Перезапуск буфера обміну RDP'
                    }

                    '3' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Fix/Restart-PrintSpoolerAndClearQueue.ps1' `
                            -Name 'Очищення черги та перезапуск служби друку' `
                            -RequiresAdministrator
                    }

                    '4' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Fix/Repair-WindowsTime.ps1' `
                            -Name 'Виправлення синхронізації часу Windows' `
                            -RequiresAdministrator
                    }

                    '5' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Fix/Configure-PrintRpcPrivacy.ps1' `
                            -Name 'Сумісність RPC-автентифікації мережевого друку' `
                            -RequiresAdministrator
                    }

                    '6' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Fix/Clear-UserProfileCaches.ps1' `
                            -Name 'Очищення кешів у профілях користувачів' `
                            -RequiresAdministrator
                    }

                    '0' {
                        return
                    }

                    default {
                        Write-Host ''
                        Write-Host (
                            'Такого пункту поки немає.'
                        ) -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                    }
                }
            }
        }

        function Show-SoftwareMenu {
            while ($true) {
                Write-RaccoonHeader -SectionName 'ВСТАНОВЛЕННЯ ПЗ'

                Write-Host (
                    '  MICROSOFT SYSINTERNALS BGINFO'
                ) -ForegroundColor DarkCyan

                Write-Host '  1. Встановити або оновити BgInfo'
                Write-Host (
                    '     [ADMIN] [DOWNLOADS SOFTWARE] [CHANGES SYSTEM]'
                )
                Write-Host ''

                Write-Host '  2. Налаштувати стандартний шаблон BgInfo'
                Write-Host (
                    '     [ADMIN] [INTERACTIVE] [CHANGES USER DESKTOP]'
                )
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
                        Write-Host (
                            'Такого пункту поки немає.'
                        ) -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                    }
                }
            }
        }

        Clear-RaccoonLaunchHistory

        try {
            $Host.UI.RawUI.WindowTitle =
                'Raccoon Admin Toolkit'
        }
        catch {
        }

        while ($true) {
            Write-RaccoonHeader -SectionName ''

            $adminText = if (Test-IsAdministrator) {
                'Так'
            }
            else {
                'Ні'
            }

            Write-Host (
                'Комп''ютер:     {0}' -f
                $env:COMPUTERNAME
            )

            Write-Host (
                'Користувач:    {0}\{1}' -f
                $env:USERDOMAIN,
                $env:USERNAME
            )

            Write-Host (
                'PowerShell:    {0}' -f
                $PSVersionTable.PSVersion
            )

            Write-Host (
                'Адміністратор: {0}' -f
                $adminText
            )

            Write-Host ''

            Write-Host (
                '  РОЗДІЛИ'
            ) -ForegroundColor DarkCyan

            Write-Host '  1. Діагностика'
            Write-Host '  2. Моніторинг'
            Write-Host '  3. Виправлення'
            Write-Host '  4. Встановлення ПЗ'
            Write-Host ''

            Write-Host (
                '  ЧАСТО ВИКОРИСТОВУВАНІ СКРИПТИ'
            ) -ForegroundColor DarkCyan

            Write-Host '  5. Створити або відновити кнопку завершення сеансу'
            Write-Host '     [ADMIN] [CHANGES SYSTEM]'
            Write-Host ''

            Write-Host '  6. Надіслати повідомлення користувачам'
            Write-Host '     [ADMIN] [USES MSG.EXE]'
            Write-Host ''

            Write-Host '  0. Вихід і закриття PowerShell'
            Write-Host ''

            $choice = Read-Host 'Оберіть дію'

            switch ($choice) {
                '1' {
                    Show-DiagnosticsMenu
                }

                '2' {
                    Show-MonitoringMenu
                }

                '3' {
                    Show-FixMenu
                }

                '4' {
                    Show-SoftwareMenu
                }

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
                    Clear-Host
                    Write-Host (
                        'Raccoon Admin Toolkit завершив роботу.'
                    ) -ForegroundColor Cyan
                    return
                }

                default {
                    Write-Host ''
                    Write-Host (
                        'Такого пункту поки немає.'
                    ) -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
            }
        }
    }
    finally {
        try {
            if (Get-Command `
                    -Name 'Clear-RaccoonLaunchHistory' `
                    -CommandType Function `
                    -ErrorAction SilentlyContinue) {
                Clear-RaccoonLaunchHistory
            }
        }
        catch {
        }

        $baseUrl = $null
        $adminText = $null
        $choice = $null

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        Write-Host ''
        Write-Host (
            'Історію очищено. Сеанс PowerShell закривається.'
        ) -ForegroundColor DarkGray

        Start-Sleep -Milliseconds 500
        exit 0
    }
}
