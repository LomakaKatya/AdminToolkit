# BgInfo ACL fix

Replace these files in the repository:

- `Scripts/Software/BgInfo/Install-BgInfo.ps1`
- `Scripts/Software/BgInfo/Configure-BgInfo.ps1`
- `Scripts/Software/BgInfo/Get-BgInfoStatus.ps1`
- `Scripts/Software/BgInfo/Prepare-BgInfoGpoPackage.ps1`
- `Assets/BgInfo/Update-BgInfo.ps1`

Then run Raccoon Admin Toolkit as administrator and select:

1. `Встановлення ПЗ`
2. `Встановити або оновити BgInfo`
3. Use the official Microsoft archive

The updated installer repairs the ACL of an existing broken installation before
copying files. It grants:

- SYSTEM: Full Control
- Administrators: Full Control
- Users: Read and Execute

It also launches the UTF-8 helper through an encoded command instead of using
Windows PowerShell 5.1 `-File`, and stores the BgInfo log in each user's
`LocalAppData`.

After installation:

1. Run `Перевірити стан BgInfo`.
2. Run `Налаштувати стандартний шаблон BgInfo`.
3. Sign out and sign in with a test user.
