# PowerShell validation

Автоматична перевірка запускається:

- після кожного `push` до `main`, якщо змінено `.ps1` або workflow;
- для pull request до `main`;
- вручну через вкладку **Actions**.

Перевіряються:

1. Синтаксис усіх `.ps1` через Windows PowerShell 5.1.
2. Синтаксис усіх `.ps1` через PowerShell 7.
3. UTF-8 BOM.
4. Типографські апострофи й лапки.
5. Кутові лапки.
6. Довгі тире та символ трикрапки.
7. Нерозривні пробіли.
8. Пробіли після символу продовження рядка PowerShell.

## Локальний запуск

Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Tools\Test-Repository.ps1 `
    -RepositoryRoot .
```

PowerShell 7:

```powershell
pwsh -NoProfile `
    -File ./Tools/Test-Repository.ps1 `
    -RepositoryRoot . `
    -Parser PowerShellCore
```

Успішна перевірка повертає код `0`. Помилка повертає код `1`.
