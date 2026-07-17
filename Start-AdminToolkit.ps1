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

        $baseUrl = 'https://raw.githubusercontent.com/LomakaKatya/AdminToolkit/main'

        function Write-Utf8NoBomLines {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines
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
                        $historyPath = (Get-PSReadLineOption).HistorySavePath
                    }
                    catch {
                    }

                    # The launch command is still running at this moment.
                    # SaveNothing prevents PSReadLine from writing it after completion.
                    try {
                        Set-PSReadLineOption `
                            -HistorySaveStyle SaveNothing `
                            -ErrorAction SilentlyContinue
                    }
                    catch {
                    }

                    # Skip toolkit commands if this PSReadLine version supports
                    # AddToHistoryHandler.
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

        # Clean immediately. The final cleanup still runs during a normal exit.
        Clear-RaccoonLaunchHistory


        function Test-IsAdministrator {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

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
            param (
                [string]$SectionName
            )

            Clear-Host

            Write-Host '========================================================================' `
                -ForegroundColor DarkCyan
            Write-Host '                         RACCOON ADMIN TOOLKIT' `
                -ForegroundColor Cyan
            Write-Host '========================================================================' `
                -ForegroundColor DarkCyan

            if (-not [string]::IsNullOrWhiteSpace($SectionName)) {
                Write-Host ''
                Write-Host "  $SectionName" -ForegroundColor Cyan
                Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray
            }

            Write-Host ''
        }

        function Invoke-RaccoonScript {
            param (
                [Parameter(Mandatory)]
                [string]$Path,

                [Parameter(Mandatory)]
                [string]$Name,

                [switch]$RequiresAdministrator,

                [switch]$ChangesSystem
            )

            Write-RaccoonHeader -SectionName $Name

            if ($RequiresAdministrator -and -not (Test-IsAdministrator)) {
                Write-Host 'Для цієї дії потрібні права адміністратора.' `
                    -ForegroundColor Red
                Write-Host 'Закрий інструментарій і запусти PowerShell від імені адміністратора.' `
                    -ForegroundColor Yellow

                Pause-RaccoonToolkit
                return
            }

            if ($ChangesSystem) {
                Write-Host 'Увага: цей пункт вносить зміни до системи.' `
                    -ForegroundColor Yellow

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
                Write-Host 'Завантажую актуальну версію скрипта...' `
                    -ForegroundColor DarkGray

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

                # Invoke-RestMethod може оставить UTF-8 BOM в начале рядка.
                # Старый Windows PowerShell воспринимает его как часть имени
                # першої команди, например "﻿Set-StrictMode".
                $bomMarkers = [char[]]@(
                    [char]0xFEFF,
                    [char]0x00EF,
                    [char]0x00BB,
                    [char]0x00BF
                )

                $scriptText = ([string]$content).TrimStart($bomMarkers)

                if ([string]::IsNullOrWhiteSpace($scriptText)) {
                    throw "Після нормалізації отримано порожній скрипт: $Path"
                }

                $scriptBlock = [ScriptBlock]::Create($scriptText)

                Write-Host 'Запускаю.' -ForegroundColor DarkGray
                Write-Host ''

                & $scriptBlock
            }
            catch {
                Write-Host ''
                Write-Host 'Не втаклося виконати скрипт.' -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Yellow
            }
            finally {
                # Витакляємо завантажений текст и ScriptBlock одразу після виконання модуля.
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
            param (
                [Parameter(Mandatory)]
                [string]$SectionName
            )

            while ($true) {
                Write-RaccoonHeader -SectionName $SectionName

                Write-Host 'У цьому розділі поки немає скриптів.' `
                    -ForegroundColor DarkYellow
                Write-Host ''
                Write-Host '  0. Повернутися в головного меню'
                Write-Host ''

                $choice = Read-Host 'Оберіть действие'

                switch ($choice) {
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

        function Show-DiagnosticsMenu {
            while ($true) {
                Write-RaccoonHeader -SectionName 'ДІАГНОСТИКА'

                Write-Host '  МЕРЕЖА ТА ДОСТУП' -ForegroundColor DarkCyan
                Write-Host '  1. Перевірити TCP-подключение к адресу и порту'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''
                Write-Host '  2. Комплексна діагностика Wi-Fi'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''
                Write-Host '  3. Комплексна діагностика інтерніу'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''
                Write-Host '  4. Діагностика доступу до сайту'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''
                Write-Host '  5. Діагностика відтакленого доступу'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host '  КОМП’ЮТЕР І ПРИСТРОЇ' -ForegroundColor DarkCyan
                Write-Host '  6. Діагностика друку'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''
                Write-Host '  7. Діагностика зависань і продуктивності ПК'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host '  0. Повернутися в головного меню'
                Write-Host ''

                $choice = Read-Host 'Оберіть действие'

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
                            -Name 'Комплексна діагностика інтерніу'
                    }

                    '4' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Test-WebsiteAccess.ps1' `
                            -Name 'Діагностика доступу до сайту'
                    }

                    '5' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-RemoteAccessDiagnostics.ps1' `
                            -Name 'Діагностика відтакленого доступу'
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

        function Show-MonitoringMenu {
            Show-EmptySection -SectionName 'МОНІТОРИНГ'
        }

        function Show-FixMenu {
            Show-EmptySection -SectionName 'ВИПРАВЛЕННЯ'
        }

        function Show-SoftwareMenu {
            Show-EmptySection -SectionName 'ВСТАНОВЛЕННЯ ПЗ'
        }

        try {
            $Host.UI.RawUI.WindowTitle = 'Raccoon Admin Toolkit'
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

            Write-Host "Комп’ютер:     $env:COMPUTERNAME"
            Write-Host "Користувач:  $env:USERDOMAIN\$env:USERNAME"
            Write-Host "PowerShell:    $($PSVersionTable.PSVersion)"
            Write-Host "Адміністратор: $adminText"
            Write-Host ''

            Write-Host '  РОЗДІЛИ' -ForegroundColor DarkCyan
            Write-Host '  1. Диагностика'
            Write-Host '  2. Мониторинг'
            Write-Host '  3. Фикс'
            Write-Host '  4. Установка софта'
            Write-Host ''

            Write-Host '  ЧАСТО ВИКОРИСТОВУВАНІ СКРИПТИ' -ForegroundColor DarkCyan
            Write-Host '  5. Створити або відновити кнопку «Завершення сеансу»'
            Write-Host '     [ADMIN] [CHANGES SYSTEM]'
            Write-Host ''

            Write-Host '  0. Вихід і закриття PowerShell'
            Write-Host ''

            $choice = Read-Host 'Оберіть действие'

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

                '0' {
                    Clear-Host
                    Write-Host 'Raccoon Admin Toolkit завершив роботу.' `
                        -ForegroundColor Cyan
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
    finally {
        # Отключаем такльнейшую запись истории в текущей сессии.
        $historyPath = $null

        try {
            if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
                $historyPath = (Get-PSReadLineOption).HistorySavePath

                Set-PSReadLineOption `
                    -HistorySaveStyle SaveNothing `
                    -ErrorAction SilentlyContinue

                try {
                    [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
                }
                catch {
                }
            }
        }
        catch {
        }

        # Витакляємо з постоянной истории лише команды, связанные с toolkit.
        try {
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

        # Чистим обычную историю текущего PowerShell-процесса.
        try {
            Clear-History -ErrorAction SilentlyContinue
        }
        catch {
        }

        # Убираем известные переменные и просим .NET освободить мусор.
        $baseUrl = $null
        $adminText = $null
        $choice = $null
        $historyLines = $null
        $filteredHistory = $null

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        Write-Host ''
        Write-Host 'Історію очищено. Сеанс PowerShell закривається.' `
            -ForegroundColor DarkGray

        Start-Sleep -Milliseconds 500

        # Закрываем именно текущий процесс PowerShell.
        exit 0
    }
}
