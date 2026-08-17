#requires -version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-RunAsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object `
        -TypeName Security.Principal.WindowsPrincipal `
        -ArgumentList $Identity

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-RunAsAdministrator)) {
    throw 'Запусти Raccoon Admin Toolkit від імені адміністратора.'
}

$RegPath = 'HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services\Client'
$Name = 'RedirectionWarningDialogVersion'
$Value = 1

if (-not (Test-Path -LiteralPath $RegPath)) {
    New-Item `
        -Path $RegPath `
        -Force `
        -ErrorAction Stop |
    Out-Null
}

New-ItemProperty `
    -Path $RegPath `
    -Name $Name `
    -Value $Value `
    -PropertyType DWord `
    -Force `
    -ErrorAction Stop |
Out-Null

$ActualValue = Get-ItemPropertyValue `
    -Path $RegPath `
    -Name $Name `
    -ErrorAction Stop

if ([int]$ActualValue -ne $Value) {
    throw "Перевірка не пройдена: $Name = $ActualValue, очікувалось $Value."
}

Write-Host ''
Write-Host '[OK] Готово.' -ForegroundColor Green
Write-Host "[OK] $Name = $Value" -ForegroundColor Green
Write-Host "[OK] $RegPath" -ForegroundColor Green
Write-Host ''
