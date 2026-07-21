# BgInfo environment-fields revision

This revision removes the per-user `SystemInfo.txt` dependency.

The BgInfo template now reads two environment variables created immediately
before BgInfo starts:

- `RACCOON_BGINFO_USER`
- `RACCOON_BGINFO_SESSION_SINCE`

Replace these repository files:

- `Scripts/Software/BgInfo/Install-BgInfo.ps1`
- `Scripts/Software/BgInfo/Configure-BgInfo.ps1`
- `Scripts/Software/BgInfo/Get-BgInfoStatus.ps1`
- `Scripts/Software/BgInfo/Prepare-BgInfoGpoPackage.ps1`
- `Scripts/Software/BgInfo/Uninstall-BgInfo.ps1`
- `Assets/BgInfo/Update-BgInfo.ps1`

After upload:

1. Run `Встановити або оновити BgInfo`.
2. Run `Налаштувати стандартний шаблон BgInfo`.
3. Delete any old `File contents` custom field.
4. Create two custom fields of type `Environment variable`.
5. Save the `.bgi` file to the path shown by the configuration script.
6. Sign out and sign in with a test user.

All interactive confirmations in these BgInfo modules now use:

`[Y/N | Д/Н]`
