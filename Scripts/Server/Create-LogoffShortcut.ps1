Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 3) {
    throw 'Этот модуль требует PowerShell 3.0 или новее.'
}

function Test-RunAsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        -TypeName Security.Principal.WindowsPrincipal `
        -ArgumentList $identity

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-RunAsAdministrator)) {
    throw 'Для создания ярлыка на общем рабочем столе запусти PowerShell от имени администратора.'
}

$publicDesktop = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonDesktopDirectory
)

if ([string]::IsNullOrWhiteSpace($publicDesktop) -or
    -not (Test-Path -LiteralPath $publicDesktop -PathType Container)) {
    throw "Не найден общий рабочий стол: $publicDesktop"
}

$shortcutPath = Join-Path `
    -Path $publicDesktop `
    -ChildPath 'Завершення сеансу.lnk'

$system32Path = Join-Path -Path $env:SystemRoot -ChildPath 'System32'
$targetPath = Join-Path -Path $system32Path -ChildPath 'logoff.exe'
$iconPath = Join-Path -Path $system32Path -ChildPath 'SHELL32.dll'

if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    throw "Не найден системный файл выхода из сеанса: $targetPath"
}

$shortcutAlreadyExisted = Test-Path -LiteralPath $shortcutPath -PathType Leaf

$wshShell = $null
$shortcut = $null

try {
    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($shortcutPath)

    $shortcut.TargetPath = $targetPath
    $shortcut.WorkingDirectory = $system32Path
    $shortcut.Description = 'Коректне завершення сеансу користувача'
    $shortcut.IconLocation = "$iconPath,27"

    $shortcut.Save()
}
finally {
    if ($null -ne $shortcut -and
        [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
    }

    if ($null -ne $wshShell -and
        [Runtime.InteropServices.Marshal]::IsComObject($wshShell)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($wshShell)
    }

    $shortcut = $null
    $wshShell = $null
}

if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
    throw "Ярлык не появился после сохранения: $shortcutPath"
}

$action = if ($shortcutAlreadyExisted) {
    'обновлена'
}
else {
    'создана'
}

Write-Host ''
Write-Host "[OK] Кнопка $action." -ForegroundColor Green
Write-Host "[OK] Ярлык: $shortcutPath" -ForegroundColor Green
Write-Host "[OK] Команда: $targetPath" -ForegroundColor Green
Write-Host ''
