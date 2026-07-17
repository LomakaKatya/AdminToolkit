[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepositoryRoot = (
        Split-Path -Parent $PSScriptRoot
    ),

    [Parameter()]
    [ValidateSet('WindowsPowerShell', 'PowerShellCore')]
    [string]$Parser = 'WindowsPowerShell'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-CheckHeader {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Add-ValidationError {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Errors,

        [Parameter(Mandatory)]
        [string]$File,

        [Parameter(Mandatory)]
        [string]$Message,

        [int]$Line = 0,

        [int]$Column = 0
    )

    $location = $File

    if ($Line -gt 0) {
        $location += ":$Line"

        if ($Column -gt 0) {
            $location += ":$Column"
        }
    }

    [void]$Errors.Add(
        [pscustomobject]@{
            Location = $location
            Message  = $Message
        }
    )
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,

        [Parameter(Mandatory)]
        [string]$FullPath
    )

    $baseUri = New-Object `
        -TypeName System.Uri `
        -ArgumentList (
            ([System.IO.Path]::GetFullPath($BasePath).TrimEnd(
                [System.IO.Path]::DirectorySeparatorChar
            ) + [System.IO.Path]::DirectorySeparatorChar)
        )

    $fileUri = New-Object `
        -TypeName System.Uri `
        -ArgumentList ([System.IO.Path]::GetFullPath($FullPath))

    return [System.Uri]::UnescapeDataString(
        $baseUri.MakeRelativeUri($fileUri).ToString()
    ).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

$resolvedRoot = (
    Resolve-Path `
        -LiteralPath $RepositoryRoot `
        -ErrorAction Stop
).Path

$errors = New-Object -TypeName System.Collections.ArrayList

$excludedDirectories = @(
    '.git',
    '.github'
)

$powerShellFiles = @(
    Get-ChildItem `
        -LiteralPath $resolvedRoot `
        -Recurse `
        -File `
        -Filter '*.ps1' |
    Where-Object {
        $relativePath = Get-RelativePath `
            -BasePath $resolvedRoot `
            -FullPath $_.FullName

        $segments = $relativePath -split '[\\/]'

        -not (
            $segments |
            Where-Object {
                $_ -in $excludedDirectories
            }
        )
    } |
    Sort-Object -Property FullName
)

Write-CheckHeader -Text "Синтаксис PowerShell: $Parser"
Write-Host "Знайдено файлів: $($powerShellFiles.Count)"

if ($powerShellFiles.Count -eq 0) {
    Add-ValidationError `
        -Errors $errors `
        -File '.' `
        -Message 'У репозиторії не знайдено жодного файлу .ps1.'
}

foreach ($file in $powerShellFiles) {
    $relativePath = Get-RelativePath `
        -BasePath $resolvedRoot `
        -FullPath $file.FullName

    $tokens = $null
    $parseErrors = $null

    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -eq 0) {
        Write-Host "[OK] $relativePath" -ForegroundColor Green
    }
    else {
        foreach ($parseError in $parseErrors) {
            Add-ValidationError `
                -Errors $errors `
                -File $relativePath `
                -Line $parseError.Extent.StartLineNumber `
                -Column $parseError.Extent.StartColumnNumber `
                -Message $parseError.Message
        }
    }
}

Write-CheckHeader -Text 'Кодування та небезпечні символи'

$forbiddenCharacters = [ordered]@{
    ([char]0x2018) = "лівий типографський апостроф U+2018"
    ([char]0x2019) = "правий типографський апостроф U+2019"
    ([char]0x201C) = "ліва типографська лапка U+201C"
    ([char]0x201D) = "права типографська лапка U+201D"
    ([char]0x00AB) = "ліва кутова лапка U+00AB"
    ([char]0x00BB) = "права кутова лапка U+00BB"
    ([char]0x2013) = "коротке тире U+2013"
    ([char]0x2014) = "довге тире U+2014"
    ([char]0x2026) = "символ трикрапки U+2026"
    ([char]0x00A0) = "нерозривний пробіл U+00A0"
}

foreach ($file in $powerShellFiles) {
    $relativePath = Get-RelativePath `
        -BasePath $resolvedRoot `
        -FullPath $file.FullName

    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)

    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {

        Add-ValidationError `
            -Errors $errors `
            -File $relativePath `
            -Line 1 `
            -Column 1 `
            -Message 'Файл містить UTF-8 BOM. Для .ps1 потрібен UTF-8 без BOM.'
    }

    $text = [System.IO.File]::ReadAllText(
        $file.FullName,
        (New-Object `
            -TypeName System.Text.UTF8Encoding `
            -ArgumentList $false, $true)
    )

    $lines = $text -split "`r?`n", -1

    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]

        foreach ($entry in $forbiddenCharacters.GetEnumerator()) {
            $position = $line.IndexOf([string]$entry.Key)

            while ($position -ge 0) {
                Add-ValidationError `
                    -Errors $errors `
                    -File $relativePath `
                    -Line ($lineIndex + 1) `
                    -Column ($position + 1) `
                    -Message (
                        "Знайдено {0}. Використовуйте звичайні ASCII-символи." `
                        -f $entry.Value
                    )

                $position = $line.IndexOf(
                    [string]$entry.Key,
                    $position + 1
                )
            }
        }

        if ($line -match '`[ \t]+$') {
            Add-ValidationError `
                -Errors $errors `
                -File $relativePath `
                -Line ($lineIndex + 1) `
                -Column ($line.LastIndexOf('`') + 1) `
                -Message (
                    'Після символу продовження рядка ` є пробіли. ' +
                    'PowerShell не продовжить такий рядок.'
                )
        }
    }
}

Write-CheckHeader -Text 'Результат'

if ($errors.Count -gt 0) {
    foreach ($validationError in $errors) {
        Write-Host (
            "[FAIL] {0}: {1}" -f
            $validationError.Location,
            $validationError.Message
        ) -ForegroundColor Red
    }

    Write-Host ''
    Write-Host "Перевірку не пройдено. Помилок: $($errors.Count)" `
        -ForegroundColor Red

    exit 1
}

Write-Host '[OK] Усі PowerShell-файли пройшли перевірку.' `
    -ForegroundColor Green

exit 0
