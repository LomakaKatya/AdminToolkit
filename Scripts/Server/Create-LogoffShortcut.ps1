Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 3) {
    throw 'Цей модуль потребує PowerShell 3.0 або новішої версії.'
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
    throw 'Для створення ярлика на спільному робочому столі запусти PowerShell від імені адміністратора.'
}

$publicDesktop = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonDesktopDirectory
)

if ([string]::IsNullOrWhiteSpace($publicDesktop) -or
    -not (Test-Path -LiteralPath $publicDesktop -PathType Container)) {
    throw "Не знайдено спільний робочий стіл: $publicDesktop"
}

$shortcutPath = Join-Path `
    -Path $publicDesktop `
    -ChildPath 'Завершення сеансу.lnk'

$system32Path = Join-Path -Path $env:SystemRoot -ChildPath 'System32'
$targetPath = Join-Path -Path $system32Path -ChildPath 'logoff.exe'
$iconPath = Join-Path -Path $system32Path -ChildPath 'SHELL32.dll'

if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    throw "Не знайдено системний файл завершення сеансу: $targetPath"
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
    throw "Ярлик не з’явився після збереження: $shortcutPath"
}

$action = if ($shortcutAlreadyExisted) {
    'оновлена'
}
else {
    'створена'
}

Write-Host ''
Write-Host "[OK] Кнопка $action." -ForegroundColor Green
Write-Host "[OK] Ярлик: $shortcutPath" -ForegroundColor Green
Write-Host "[OK] Комантак: $targetPath" -ForegroundColor Green
Write-Host ''
