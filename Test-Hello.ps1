Write-Host ''
Write-Host 'AdminToolkit успешно запущен!' -ForegroundColor Green
Write-Host ''

Write-Host "Компьютер: $env:COMPUTERNAME"
Write-Host "Пользователь: $env:USERDOMAIN\$env:USERNAME"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
Write-Host "Время: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ''
