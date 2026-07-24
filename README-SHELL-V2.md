# Raccoon Admin Toolkit Shell v2

Replace or add:

- `Start-AdminToolkit.ps1`
- `Scripts/Common/Raccoon-Ui.ps1`
- `Config/ToolkitMenu.json`
- `docs/faq.html`
- `docs/help/getting-started.html`
- `docs/help/navigation.html`

The runtime PowerShell files are UTF-8 without BOM.

## Controls

- `1-9`: select without Enter
- `0` or `Esc`: back
- `F1`: FAQ
- `F2`: search
- `F3`: quick access
- `Y` or `Д`: confirm
- `N` or `Н`: cancel

The shell intercepts old confirmation prompts from existing modules and converts
them to the common single-key format. Normal text input still uses Enter.

Recent tool IDs are stored per user in:

`%LOCALAPPDATA%\RaccoonAdminToolkit\Shell\state.json`
