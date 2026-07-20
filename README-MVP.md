# BgInfo + msg.exe MVP

This package is prepared for manual upload to `LomakaKatya/AdminToolkit`.

## Files to add

- `Scripts/Server/Send-UserMessage.ps1`
- `Scripts/Software/BgInfo/Install-BgInfo.ps1`
- `Scripts/Software/BgInfo/Configure-BgInfo.ps1`
- `Scripts/Software/BgInfo/Get-BgInfoStatus.ps1`
- `Scripts/Software/BgInfo/Prepare-BgInfoGpoPackage.ps1`
- `Scripts/Software/BgInfo/Uninstall-BgInfo.ps1`
- `Assets/BgInfo/Update-BgInfo.ps1`

## Menu update

Run locally from the repository root:

```powershell
.\Tools\Apply-BgInfo-Msg-MenuPatch.ps1
```

The patch checks the exact current menu blocks before editing. If `Start-AdminToolkit.ps1`
has changed, it stops instead of making a blind replacement.

Then validate:

```powershell
powershell.exe -NoProfile -File .\Tools\Test-Repository.ps1 `
    -RepositoryRoot $PWD `
    -Parser WindowsPowerShell
```

and, when PowerShell 7 is installed:

```powershell
pwsh -NoProfile -File ./Tools/Test-Repository.ps1 `
    -RepositoryRoot $PWD `
    -Parser PowerShellCore
```

## BgInfo first test

1. Upload all runtime files and the patched `Start-AdminToolkit.ps1`.
2. Run Toolkit as administrator.
3. Open `Встановлення ПЗ`.
4. Install BgInfo from the official Microsoft archive or a local folder.
5. Run template configuration.
6. In BgInfo create one custom `File contents` field pointing to:

   `%LOCALAPPDATA%\RaccoonAdminToolkit\BgInfo\SystemInfo.txt`

7. Save the configuration exactly to:

   `C:\ProgramData\RaccoonAdminToolkit\BgInfo\Config\Raccoon-Standard.bgi`

8. Sign out and sign in with a test user.

## Standard displayed text

```text
SYSTEM INFO

Користувач : DOMAIN\ivanov
Сеанс з    : 16.07.2026 03:12
Підтримка  : +380 67 001 10 12
             дзвінки / Viber / Telegram / WhatsApp
```

## GPO

After the local template works, run `Підготувати пакет BgInfo для доменної політики`.
The exported package includes the current signed executables, the `.bgi` template,
the per-user updater, and a computer startup deployment script.

No repository files were changed automatically while this archive was created.
