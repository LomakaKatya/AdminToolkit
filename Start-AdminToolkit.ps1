& {
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

        $uri = "$baseUrl/$Path"

        try {
            Write-Host 'Скачиваю актуальную версию скрипта...' `
                -ForegroundColor DarkGray

            $content = Invoke-RestMethod `
                -Uri $uri `
                -ErrorAction Stop

            if ([string]::IsNullOrWhiteSpace([string]$content)) {
                throw "GitHub вернул пустой файл: $Path"
            }

            $scriptBlock = [ScriptBlock]::Create([string]$content)

            Write-Host 'Запускаю.' -ForegroundColor DarkGray
            Write-Host ''

            & $scriptBlock
        }
        catch {
            Write-Host ''
            Write-Host 'Не удалось выполнить скрипт.' -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Yellow
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

            Write-Host '  1. Проверить TCP-подключение к адресу и порту'
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

        Write-Host '  0. Выход'
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
