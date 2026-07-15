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
        [void](Read-Host 'Нажми Enter, чтобы вернуться в меню')
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

        Clear-Host
        Write-Host "Raccoon Admin Toolkit > $Name" -ForegroundColor Cyan
        Write-Host ('=' * 72) -ForegroundColor DarkGray
        Write-Host ''

        if ($RequiresAdministrator -and -not (Test-IsAdministrator)) {
            Write-Host 'Для этого действия нужны права администратора.' -ForegroundColor Red
            Write-Host 'Закрой инструментарий и запусти PowerShell от имени администратора.' `
                -ForegroundColor Yellow

            Pause-RaccoonToolkit
            return
        }

        if ($ChangesSystem) {
            Write-Host 'Внимание: этот пункт изменяет систему.' -ForegroundColor Yellow
            $confirmation = Read-Host 'Продолжить? [Y/N]'

            if ($confirmation -notmatch '^(?i:y|yes|д|да)$') {
                Write-Host ''
                Write-Host 'Действие отменено.' -ForegroundColor Yellow
                Pause-RaccoonToolkit
                return
            }

            Write-Host ''
        }

        $uri = "$baseUrl/$Path"

        try {
            Write-Host 'Скачиваю актуальную версию скрипта...' -ForegroundColor DarkGray

            $content = Invoke-RestMethod -Uri $uri -ErrorAction Stop

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

    try {
        $Host.UI.RawUI.WindowTitle = 'Raccoon Admin Toolkit'
    }
    catch {
    }

    while ($true) {
        Clear-Host

        $adminText = if (Test-IsAdministrator) {
            'Да'
        }
        else {
            'Нет'
        }

        Write-Host '========================================================================' `
            -ForegroundColor DarkCyan
        Write-Host '                         RACCOON ADMIN TOOLKIT' `
            -ForegroundColor Cyan
        Write-Host '========================================================================' `
            -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host "Компьютер:     $env:COMPUTERNAME"
        Write-Host "Пользователь:  $env:USERDOMAIN\$env:USERNAME"
        Write-Host "PowerShell:    $($PSVersionTable.PSVersion)"
        Write-Host "Администратор: $adminText"
        Write-Host ''

        Write-Host '  СЕРВЕР / RDS' -ForegroundColor DarkCyan
        Write-Host '  1. Создать или восстановить кнопку «Завершення сеансу»'
        Write-Host '     [ADMIN] [CHANGES SYSTEM]'
        Write-Host ''

        Write-Host '  СЛУЖЕБНОЕ' -ForegroundColor DarkCyan
        Write-Host '  9. Проверить работу инструментария [SAFE]'
        Write-Host ''
        Write-Host '  0. Выход'
        Write-Host ''

        $choice = Read-Host 'Выбери действие'

        switch ($choice) {
            '1' {
                Invoke-RaccoonScript `
                    -Path 'Scripts/Server/Create-LogoffShortcut.ps1' `
                    -Name 'Кнопка корректного выхода из сеанса' `
                    -RequiresAdministrator `
                    -ChangesSystem
            }

            '9' {
                Invoke-RaccoonScript `
                    -Path 'Test-Hello.ps1' `
                    -Name 'Проверка инструментария'
            }

            '0' {
                Clear-Host
                Write-Host 'Raccoon Admin Toolkit завершил работу.' -ForegroundColor Cyan
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
