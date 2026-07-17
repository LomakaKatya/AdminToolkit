[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('WindowsPowerShell', 'PowerShellCore')]
    [string]$Parser = 'WindowsPowerShell'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

    $baseFullPath = [System.IO.Path]::GetFullPath($BasePath)
    $fileFullPath = [System.IO.Path]::GetFullPath($FullPath)

    $baseUri = New-Object `
        -TypeName System.Uri `
        -ArgumentList (
            $baseFullPath.TrimEnd(
                [System.IO.Path]::DirectorySeparatorChar
            ) + [System.IO.Path]::DirectorySeparatorChar
        )

    $fileUri = New-Object `
        -TypeName System.Uri `
        -ArgumentList $fileFullPath

    return [System.Uri]::UnescapeDataString(
        $baseUri.MakeRelativeUri($fileUri).ToString()
    ).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

$resolvedRoot = (
    Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop
).Path

$errors = New-Object -TypeName System.Collections.ArrayList

$powerShellFiles = @(
    Get-ChildItem `
        -LiteralPath $resolvedRoot `
        -Recurse `
        -File `
        -Filter '*.ps1' |
    Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and
        $_.FullName -notmatch '[\\/]\.github[\\/]'
    } |
    Sort-Object -Property FullName
)

Write-Host ''
Write-Host ('=' * 72)
Write-Host "PowerShell parser: $Parser"
Write-Host ('=' * 72)
Write-Host "Files found: $($powerShellFiles.Count)"

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
        Write-Host "[OK] $relativePath"
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

Write-Host ''
Write-Host ('=' * 72)
Write-Host 'Encoding and parser-risk characters'
Write-Host ('=' * 72)

$forbiddenCharacters = @(
    [pscustomobject]@{
        Character = [char]0x2018
        Name      = 'typographic apostrophe U+2018'
    },
    [pscustomobject]@{
        Character = [char]0x2019
        Name      = 'typographic apostrophe U+2019'
    },
    [pscustomobject]@{
        Character = [char]0x201C
        Name      = 'typographic quote U+201C'
    },
    [pscustomobject]@{
        Character = [char]0x201D
        Name      = 'typographic quote U+201D'
    },
    [pscustomobject]@{
        Character = [char]0x00A0
        Name      = 'non-breaking space U+00A0'
    }
)

$strictUtf8 = New-Object `
    -TypeName System.Text.UTF8Encoding `
    -ArgumentList $false, $true

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
            -Message 'UTF-8 BOM is not allowed in runtime .ps1 files.'
    }

    try {
        $text = [System.IO.File]::ReadAllText(
            $file.FullName,
            $strictUtf8
        )
    }
    catch {
        Add-ValidationError `
            -Errors $errors `
            -File $relativePath `
            -Message 'The file is not valid UTF-8.'

        continue
    }

    $lines = $text -split "`r?`n"

    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]

        foreach ($entry in $forbiddenCharacters) {
            $position = $line.IndexOf(
                [string]$entry.Character
            )

            while ($position -ge 0) {
                Add-ValidationError `
                    -Errors $errors `
                    -File $relativePath `
                    -Line ($lineIndex + 1) `
                    -Column ($position + 1) `
                    -Message (
                        "Forbidden character: {0}. Use ASCII punctuation." `
                        -f $entry.Name
                    )

                $position = $line.IndexOf(
                    [string]$entry.Character,
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
                -Message 'Whitespace follows the PowerShell line-continuation character.'
        }
    }
}

Write-Host ''
Write-Host ('=' * 72)
Write-Host 'Result'
Write-Host ('=' * 72)

if ($errors.Count -gt 0) {
    foreach ($validationError in $errors) {
        Write-Host (
            "[FAIL] {0}: {1}" -f
            $validationError.Location,
            $validationError.Message
        )
    }

    Write-Host ''
    Write-Host "Validation failed. Errors: $($errors.Count)"
    exit 1
}

Write-Host '[OK] All PowerShell files passed validation.'
exit 0
