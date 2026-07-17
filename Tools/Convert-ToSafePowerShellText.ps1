[CmdletBinding()]
param(
    [string]$RepositoryRoot = (
        Split-Path -Parent $PSScriptRoot
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8WithoutBom = New-Object `
    -TypeName System.Text.UTF8Encoding `
    -ArgumentList $false

$files = @(
    Get-ChildItem `
        -LiteralPath $RepositoryRoot `
        -Recurse `
        -File `
        -Filter '*.ps1' |
    Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]'
    }
)

foreach ($file in $files) {
    $text = [System.IO.File]::ReadAllText($file.FullName)

    $text = $text.Replace([char]0x2018, "'")
    $text = $text.Replace([char]0x2019, "'")
    $text = $text.Replace([char]0x201C, '"')
    $text = $text.Replace([char]0x201D, '"')
    $text = $text.Replace([char]0x00A0, ' ')

    [System.IO.File]::WriteAllText(
        $file.FullName,
        $text,
        $utf8WithoutBom
    )

    Write-Host "[OK] $($file.FullName)"
}
