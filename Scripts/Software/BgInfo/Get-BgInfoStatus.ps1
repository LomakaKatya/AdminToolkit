Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Value {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [AllowEmptyString()]
        [string]$Value,

        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = 'не знайдено'
        $Color = [ConsoleColor]::DarkGray
    }

    Write-Host ('{0,-24}: ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

try {
    Write-Host ''
    Write-Host 'Стан Microsoft Sysinternals BgInfo' `
        -ForegroundColor Cyan
    Write-Host ''

    $installRoot =
        'C:\ProgramData\RaccoonAdminToolkit\BgInfo'

    $binPath = Join-Path $installRoot 'Bin'
    $configPath = Join-Path `
        $installRoot `
        'Config\Raccoon-Standard.bgi'

    $helperPath = Join-Path $installRoot 'Update-BgInfo.ps1'

    $startupPath = Join-Path `
        $env:ProgramData `
        'Microsoft\Windows\Start Menu\Programs\StartUp\Raccoon BgInfo.lnk'

    $exePath = if ([Environment]::Is64BitOperatingSystem) {
        Join-Path $binPath 'Bginfo64.exe'
    }
    else {
        Join-Path $binPath 'Bginfo.exe'
    }

    Write-Value `
        -Label 'Каталог встановлення' `
        -Value $(if (Test-Path -LiteralPath $installRoot) {
            $installRoot
        }
        else {
            ''
        }) `
        -Color $(if (Test-Path -LiteralPath $installRoot) {
            [ConsoleColor]::Green
        }
        else {
            [ConsoleColor]::Red
        })

    if (Test-Path -LiteralPath $exePath -PathType Leaf) {
        $file = Get-Item -LiteralPath $exePath -ErrorAction Stop
        $signature = Get-AuthenticodeSignature `
            -LiteralPath $exePath `
            -ErrorAction Stop

        Write-Value -Label 'Виконуваний файл' -Value $exePath -Color Green
        Write-Value `
            -Label 'Версія' `
            -Value ([string]$file.VersionInfo.FileVersion)

        $signatureColor = if (
            $signature.Status -eq
            [System.Management.Automation.SignatureStatus]::Valid
        ) {
            [ConsoleColor]::Green
        }
        else {
            [ConsoleColor]::Red
        }

        Write-Value `
            -Label 'Цифровий підпис' `
            -Value ([string]$signature.Status) `
            -Color $signatureColor
    }
    else {
        Write-Value `
            -Label 'Виконуваний файл' `
            -Value '' `
            -Color Red
    }

    Write-Value `
        -Label 'Стандартний шаблон' `
        -Value $(if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $configPath
        }
        else {
            ''
        }) `
        -Color $(if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            [ConsoleColor]::Green
        }
        else {
            [ConsoleColor]::Yellow
        })

    Write-Value `
        -Label 'Допоміжний скрипт' `
        -Value $(if (Test-Path -LiteralPath $helperPath -PathType Leaf) {
            $helperPath
        }
        else {
            ''
        }) `
        -Color $(if (Test-Path -LiteralPath $helperPath -PathType Leaf) {
            [ConsoleColor]::Green
        }
        else {
            [ConsoleColor]::Red
        })

    Write-Value `
        -Label 'Автозапуск для всіх' `
        -Value $(if (Test-Path -LiteralPath $startupPath -PathType Leaf) {
            $startupPath
        }
        else {
            ''
        }) `
        -Color $(if (Test-Path -LiteralPath $startupPath -PathType Leaf) {
            [ConsoleColor]::Green
        }
        else {
            [ConsoleColor]::Red
        })

    $userTextPath = Join-Path `
        $env:LOCALAPPDATA `
        'RaccoonAdminToolkit\BgInfo\SystemInfo.txt'

    Write-Value `
        -Label 'Дані цього сеансу' `
        -Value $(if (Test-Path -LiteralPath $userTextPath -PathType Leaf) {
            $userTextPath
        }
        else {
            ''
        }) `
        -Color $(if (Test-Path -LiteralPath $userTextPath -PathType Leaf) {
            [ConsoleColor]::Green
        }
        else {
            [ConsoleColor]::DarkGray
        })

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host '  ПІДСУМОК' -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ''

    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        Write-Host '[FAIL] BgInfo не встановлено або відсутній файл потрібної розрядності.' `
            -ForegroundColor Red
    }
    elseif (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-Host '[WARN] BgInfo встановлено, але стандартний шаблон ще не створено.' `
            -ForegroundColor Yellow
        Write-Host 'Запусти налаштування шаблону.' `
            -ForegroundColor Cyan
    }
    elseif (-not (Test-Path -LiteralPath $startupPath -PathType Leaf)) {
        Write-Host '[FAIL] Шаблон є, але автозапуск для користувачів відсутній.' `
            -ForegroundColor Red
        Write-Host 'Повторно запусти встановлення BgInfo.' `
            -ForegroundColor Cyan
    }
    else {
        Write-Host '[OK] BgInfo встановлено та готово до запуску для всіх користувачів.' `
            -ForegroundColor Green
    }
}
catch {
    Write-Host ''
    Write-Host '[FAIL] Не вдалося перевірити BgInfo.' `
        -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}
