# User script integration

Додано сім модулів на основі робочих заготовок:

## Діагностика

- `Get-LocalUserLogonInfo.ps1`
- `Get-FailedLogons.ps1`

## Виправлення

- `Clear-1CCache.ps1`
- `Restart-RdpClipboard.ps1`
- `Restart-PrintSpoolerAndClearQueue.ps1`
- `Repair-WindowsTime.ps1`
- `Configure-PrintRpcPrivacy.ps1`

`Configure-PrintRpcPrivacy.ps1` підтримує три дії: увімкнути legacy-режим,
повернути захист або видалити параметр. Legacy-режим потребує окремого
підтвердження словом `LEGACY`.
