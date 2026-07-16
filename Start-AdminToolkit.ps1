& {
    try {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'

        if ($PSVersionTable.PSVersion.Major -lt 3) {
            throw 'Raccoon Admin Toolkit требует PowerShell 3.0 или новее.'
        }

        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor
            [Net.SecurityProtocolType]::Tls12

        $baseUrl = 'https://raw.githubusercontent.com/LomakaKatya/AdminToolkit/main'

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

                                if ($Line -match '(?i)admintoolkit\.itraccoonverse\.space' -or
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
                            $_ -notmatch '(?i)admintoolkit\.itraccoonverse\.space' -and
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
                        $filteredHistory |
                            Set-Content `
                                -LiteralPath $historyPath `
                                -Encoding UTF8 `
                                -Force `
                                -ErrorAction SilentlyContinue
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
            [void](Read-Host 'Нажми Enter, чтобы продолжить')
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
                Write-Host 'Для этого действия нужны права администратора.' `
                    -ForegroundColor Red
                Write-Host 'Закрой инструментарий и запусти PowerShell от имени администратора.' `
                    -ForegroundColor Yellow

                Pause-RaccoonToolkit
                return
            }

            if ($ChangesSystem) {
                Write-Host 'Внимание: этот пункт вносит изменения в систему.' `
                    -ForegroundColor Yellow

                $confirmation = Read-Host 'Продолжить? [Y/N]'

                if ($confirmation -notmatch '^(y|yes|д|да)$') {
                    Write-Host ''
                    Write-Host 'Действие отменено.' -ForegroundColor Yellow
                    Pause-RaccoonToolkit
                    return
                }

                Write-Host ''
            }

            $cacheToken = [DateTime]::UtcNow.Ticks
            $uri = "$baseUrl/$Path`?nocache=$cacheToken"

            try {
                Write-Host 'Скачиваю актуальную версию скрипта...' `
                    -ForegroundColor DarkGray

                $content = Invoke-RestMethod `
                    -Uri $uri `
                    -ErrorAction Stop

                if ([string]::IsNullOrWhiteSpace([string]$content)) {
                    throw "GitHub вернул пустой файл: $Path"
                }

                # Invoke-RestMethod может оставить UTF-8 BOM в начале строки.
                # Старый Windows PowerShell воспринимает его как часть имени
                # первой команды, например "﻿Set-StrictMode".
                $bomMarkers = [char[]]@(
                    [char]0xFEFF,
                    [char]0x00EF,
                    [char]0x00BB,
                    [char]0x00BF
                )

                $scriptText = ([string]$content).TrimStart($bomMarkers)

                if ([string]::IsNullOrWhiteSpace($scriptText)) {
                    throw "После нормализации получен пустой скрипт: $Path"
                }

                $scriptBlock = [ScriptBlock]::Create($scriptText)

                Write-Host 'Запускаю.' -ForegroundColor DarkGray
                Write-Host ''

                & $scriptBlock
            }
            catch {
                Write-Host ''
                Write-Host 'Не удалось выполнить скрипт.' -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Yellow
            }
            finally {
                # Удаляем загруженный текст и ScriptBlock сразу после выполнения модуля.
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

                Write-Host 'В этом разделе пока нет скриптов.' `
                    -ForegroundColor DarkYellow
                Write-Host ''
                Write-Host '  0. Вернуться в главное меню'
                Write-Host ''

                $choice = Read-Host 'Выбери действие'

                switch ($choice) {
                    '0' {
                        return
                    }

                    default {
                        Write-Host ''
                        Write-Host 'Такого пункта пока нет.' -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                    }
                }
            }
        }

        function Show-DiagnosticsMenu {
            while ($true) {
                Write-RaccoonHeader -SectionName 'ДИАГНОСТИКА'

                Write-Host '  СЕТЬ И ДОСТУП' -ForegroundColor DarkCyan
                Write-Host '  1. Проверить TCP-подключение к адресу и порту'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''
                Write-Host '  2. Комплексная диагностика Wi-Fi'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''
                Write-Host '  3. Комплексная диагностика интернета'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''
                Write-Host '  4. Диагностика доступа к сайту'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''
                Write-Host '  5. Диагностика удалённого доступа'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host '  КОМПЬЮТЕР И УСТРОЙСТВА' -ForegroundColor DarkCyan
                Write-Host '  6. Диагностика печати'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''
                Write-Host '  7. Диагностика зависаний и производительности ПК'
                Write-Host '     [SAFE] [MEMORY ONLY]'
                Write-Host ''

                Write-Host '  0. Вернуться в главное меню'
                Write-Host ''

                $choice = Read-Host 'Выбери действие'

                switch ($choice) {
                    '1' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Test-TcpConnection.ps1' `
                            -Name 'Проверка TCP-подключения'
                    }

                    '2' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-WifiDiagnostics.ps1' `
                            -Name 'Комплексная диагностика Wi-Fi'
                    }

                    '3' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-InternetDiagnostics.ps1' `
                            -Name 'Комплексная диагностика интернета'
                    }

                    '4' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Test-WebsiteAccess.ps1' `
                            -Name 'Диагностика доступа к сайту'
                    }

                    '5' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-RemoteAccessDiagnostics.ps1' `
                            -Name 'Диагностика удалённого доступа'
                    }

                    '6' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-PrinterDiagnostics.ps1' `
                            -Name 'Диагностика печати'
                    }

                    '7' {
                        Invoke-RaccoonScript `
                            -Path 'Scripts/Diagnostics/Get-ComputerHealthDiagnostics.ps1' `
                            -Name 'Диагностика зависаний и производительности ПК'
                    }

                    '0' {
                        return
                    }

                    default {
                        Write-Host ''
                        Write-Host 'Такого пункта пока нет.' -ForegroundColor Yellow
                        Start-Sleep -Seconds 1
                    }
                }
            }
        }

        function Show-MonitoringMenu {
            Show-EmptySection -SectionName 'МОНИТОРИНГ'
        }

        function Show-FixMenu {
            Show-EmptySection -SectionName 'ФИКС'
        }

        function Show-SoftwareMenu {
            Show-EmptySection -SectionName 'УСТАНОВКА СОФТА'
        }

        try {
            $Host.UI.RawUI.WindowTitle = 'Raccoon Admin Toolkit'
        }
        catch {
        }

        while ($true) {
            Write-RaccoonHeader -SectionName ''

            $adminText = if (Test-IsAdministrator) {
                'Да'
            }
            else {
                'Нет'
            }

            Write-Host "Компьютер:     $env:COMPUTERNAME"
            Write-Host "Пользователь:  $env:USERDOMAIN\$env:USERNAME"
            Write-Host "PowerShell:    $($PSVersionTable.PSVersion)"
            Write-Host "Администратор: $adminText"
            Write-Host ''

            Write-Host '  РАЗДЕЛЫ' -ForegroundColor DarkCyan
            Write-Host '  1. Диагностика'
            Write-Host '  2. Мониторинг'
            Write-Host '  3. Фикс'
            Write-Host '  4. Установка софта'
            Write-Host ''

            Write-Host '  ЧАСТО ИСПОЛЬЗУЕМЫЕ СКРИПТЫ' -ForegroundColor DarkCyan
            Write-Host '  5. Создать или восстановить кнопку «Завершення сеансу»'
            Write-Host '     [ADMIN] [CHANGES SYSTEM]'
            Write-Host ''

            Write-Host '  0. Выход и закрытие PowerShell'
            Write-Host ''

            $choice = Read-Host 'Выбери действие'

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
                        -Name 'Кнопка корректного выхода из сеанса' `
                        -RequiresAdministrator `
                        -ChangesSystem
                }

                '0' {
                    Clear-Host
                    Write-Host 'Raccoon Admin Toolkit завершил работу.' `
                        -ForegroundColor Cyan
                    return
                }

                default {
                    Write-Host ''
                    Write-Host 'Такого пункта пока нет.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
            }
        }
    }
    finally {
        # Отключаем дальнейшую запись истории в текущей сессии.
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

        # Удаляем из постоянной истории только команды, связанные с toolkit.
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
                        $_ -notmatch '(?i)admintoolkit\.itraccoonverse\.space' -and
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
                    $filteredHistory |
                        Set-Content `
                            -LiteralPath $historyPath `
                            -Encoding UTF8 `
                            -Force `
                            -ErrorAction SilentlyContinue
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
        Write-Host 'История очищена. Сеанс PowerShell закрывается.' `
            -ForegroundColor DarkGray

        Start-Sleep -Milliseconds 500

        # Закрываем именно текущий процесс PowerShell.
        exit 0
    }
}
