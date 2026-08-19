param(
    [string]$RepositoryRoot = "$env:USERPROFILE\source\AdminToolkit"
)

$ErrorActionPreference = 'Stop'

$Path = Join-Path `
    $RepositoryRoot `
    'Scripts\Common\Raccoon-Ui.ps1'

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Не найден файл: $Path"
}

$Text = [System.IO.File]::ReadAllText(
    $Path,
    [System.Text.Encoding]::UTF8
)

$NewLine = if ($Text.Contains("`r`n")) {
    "`r`n"
}
else {
    "`n"
}

$Pattern = '(?s)function Read-RaccoonKey \{.*?\r?\n\}\r?\n\r?\nfunction Pause-RaccoonToolkit \{'

$ReplacementLines = @(
    'function Read-RaccoonKey {',
    '    param(',
    "        [string]`$Prompt = 'Обери пункт'",
    '    )',
    '',
    '    Write-Host "  $Prompt`: " -NoNewline',
    '',
    '    try {',
    '        $key = [Console]::ReadKey($true)',
    '',
    "        `$result = ''",
    '',
    '        switch ($key.Key) {',
    "            'Escape' {",
    "                `$result = 'esc'",
    '            }',
    '',
    "            'LeftArrow' {",
    "                `$result = 'left'",
    '            }',
    '',
    "            'RightArrow' {",
    "                `$result = 'right'",
    '            }',
    '',
    "            'F1' {",
    "                `$result = 'f1'",
    '            }',
    '',
    "            'F2' {",
    "                `$result = 'f2'",
    '            }',
    '',
    "            'F3' {",
    "                `$result = 'f3'",
    '            }',
    '',
    '            default {',
    '                if ($key.KeyChar -ne [char]0) {',
    '                    $result = (',
    '                        [string]$key.KeyChar',
    '                    ).ToLowerInvariant()',
    '                }',
    '            }',
    '        }',
    '',
    '        if ([string]::IsNullOrWhiteSpace($result)) {',
    "            Write-Host ''",
    '        }',
    '        else {',
    '            Write-Host $result -ForegroundColor Cyan',
    '        }',
    '',
    '        return $result',
    '    }',
    '    catch {',
    "        Write-Host ''",
    '',
    '        return (',
    '            Microsoft.PowerShell.Utility\Read-Host `',
    '                -Prompt $Prompt',
    '        ).Trim().ToLowerInvariant()',
    '    }',
    '}',
    '',
    'function Pause-RaccoonToolkit {'
)

$Replacement = $ReplacementLines -join $NewLine

$Regex = New-Object `
    System.Text.RegularExpressions.Regex(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

$Matches = $Regex.Matches($Text)

if ($Matches.Count -ne 1) {
    throw (
        'Ожидался ровно один блок Read-RaccoonKey, найдено: ' +
        $Matches.Count
    )
}

$Updated = $Regex.Replace(
    $Text,
    [System.Text.RegularExpressions.MatchEvaluator]{
        param($Match)
        return $Replacement
    },
    1
)

$Tokens = $null
$Errors = $null

[void][System.Management.Automation.Language.Parser]::ParseInput(
    $Updated,
    [ref]$Tokens,
    [ref]$Errors
)

if ($Errors.Count -gt 0) {
    $Messages = @(
        $Errors |
        ForEach-Object {
            $_.Message
        }
    )

    throw (
        "После замены PowerShell parser нашёл ошибки:`r`n" +
        ($Messages -join "`r`n")
    )
}

$Utf8NoBom = New-Object `
    System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    $Path,
    $Updated,
    $Utf8NoBom
)

Write-Host ''
Write-Host '[OK] Read-RaccoonKey обновлён.' -ForegroundColor Green
Write-Host '[OK] Кириллические Y/Д и N/Н теперь читаются через Console.ReadKey().' -ForegroundColor Green
Write-Host ''

Set-Location -LiteralPath $RepositoryRoot

git status --short
git diff --check
