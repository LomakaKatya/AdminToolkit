#requires -version 5.1
<#
.SYNOPSIS
    Launches RDP Session Audit GUI in a separate Windows PowerShell STA process.

.DESCRIPTION
    Raccoon Admin Toolkit executes runtime tools inside its own PowerShell
    session. RDP Session Audit is a full WinForms application, so this launcher
    downloads the current GUI script, writes a temporary UTF-8 BOM copy for
    Windows PowerShell 5.1, starts it in a separate STA process, waits for the
    GUI to close, and removes the temporary script.

    Production main uses the Cloudflare Worker. Explicit feature refs continue
    to use GitHub Raw, matching Start-AdminToolkit.ps1 behavior.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repositoryRef = 'main'

if (-not [string]::IsNullOrWhiteSpace(
        [string]$env:RACCOON_TOOLKIT_REF
    )) {

    $candidateRef = (
        [string]$env:RACCOON_TOOLKIT_REF
    ).Trim()

    if ($candidateRef -notmatch '^[A-Za-z0-9._/-]+$' -or
        $candidateRef.Contains('..') -or
        $candidateRef.StartsWith('/') -or
        $candidateRef.EndsWith('/')) {

        throw (
            'Некоректне значення RACCOON_TOOLKIT_REF: {0}' -f
            $candidateRef
        )
    }

    $repositoryRef = $candidateRef
}

if ($repositoryRef -eq 'main') {
    $baseUrl = 'https://admintoolkit.itraccoonverse.space'
}
else {
    $baseUrl = (
        'https://raw.githubusercontent.com/' +
        'LomakaKatya/AdminToolkit/{0}' -f
        $repositoryRef
    )
}

$tempRoot = 'C:\Temp\RaccoonAdminToolkit\RdpSessionAudit'
$tempScript = Join-Path $tempRoot 'RdpSessionAudit.ps1'
$sourcePath = 'Scripts/Reports/RdpSessionAudit.ps1'
$cacheToken = [DateTime]::UtcNow.Ticks
$uri = "$baseUrl/$sourcePath`?nocache=$cacheToken"

try {
    if (-not (Test-Path -LiteralPath $tempRoot -PathType Container)) {
        New-Item `
            -ItemType Directory `
            -Path $tempRoot `
            -Force `
            -ErrorAction Stop |
        Out-Null
    }

    Write-Host 'Завантажую RDP Session Audit...' `
        -ForegroundColor DarkGray

    $response = Invoke-WebRequest `
        -Uri $uri `
        -Headers @{
            'Cache-Control' = 'no-cache'
            'Pragma'        = 'no-cache'
        } `
        -UseBasicParsing `
        -ErrorAction Stop

    $scriptText = [string]$response.Content

    if ([string]::IsNullOrWhiteSpace($scriptText)) {
        throw 'Службове джерело повернуло порожній RDP Session Audit.'
    }

    $bomMarkers = [char[]]@(
        [char]0xFEFF,
        [char]0x00EF,
        [char]0x00BB,
        [char]0x00BF
    )

    $scriptText = $scriptText.TrimStart($bomMarkers)

    if ([string]::IsNullOrWhiteSpace($scriptText)) {
        throw 'Після нормалізації RDP Session Audit порожній.'
    }

    # Windows PowerShell 5.1 does not reliably detect UTF-8 without BOM when
    # executing a .ps1 file from disk. The repository copy remains UTF-8
    # without BOM; only this temporary execution copy gets a BOM.
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)

    [System.IO.File]::WriteAllText(
        $tempScript,
        $scriptText,
        $utf8WithBom
    )

    $windowsPowerShell = Join-Path `
        $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "Windows PowerShell не знайдено: $windowsPowerShell"
    }

    Write-Host 'Відкриваю GUI аудиту RDP-сесій.' `
        -ForegroundColor Green

    $arguments = @(
        '-NoProfile'
        '-STA'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        ('"{0}"' -f $tempScript)
    )

    $process = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -Wait `
        -PassThru `
        -ErrorAction Stop

    if ($process.ExitCode -ne 0) {
        Write-Warning (
            'RDP Session Audit завершився з кодом: {0}' -f
            $process.ExitCode
        )
    }
}
finally {
    Remove-Item `
        -LiteralPath $tempScript `
        -Force `
        -ErrorAction SilentlyContinue

    $scriptText = $null
    $response = $null
    $process = $null
    $arguments = $null
}
