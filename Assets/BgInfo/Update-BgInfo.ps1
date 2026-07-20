Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-BgInfoText {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $encoding = New-Object `
        -TypeName System.Text.UTF8Encoding `
        -ArgumentList $true

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        $encoding
    )
}

function Get-CurrentSessionLogonText {
    $sessionId = (Get-Process -Id $PID).SessionId
    $quserPath = Join-Path $env:SystemRoot 'System32\quser.exe'

    if (-not (Test-Path -LiteralPath $quserPath -PathType Leaf)) {
        return (Get-Date).ToString('dd.MM.yyyy HH:mm')
    }

    try {
        $lines = @(
            & $quserPath 2>$null |
            ForEach-Object {
                ([string]$_).TrimEnd()
            }
        )

        foreach ($line in $lines) {
            $clean = $line.TrimStart(
                [char[]]@(
                    [char]'>',
                    [char]' '
                )
            )
            $tokens = @(
                $clean -split '\s+' |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                }
            )

            if ($tokens.Count -lt 4) {
                continue
            }

            for ($index = 1; $index -lt $tokens.Count; $index++) {
                $candidateId = 0

                if (-not [int]::TryParse(
                        $tokens[$index],
                        [ref]$candidateId
                    )) {
                    continue
                }

                if ($candidateId -ne $sessionId) {
                    continue
                }

                if (($index + 3) -lt $tokens.Count) {
                    $rawLogonTime = (
                        @(
                            $tokens[($index + 3)..($tokens.Count - 1)]
                        ) -join ' '
                    )

                    $parsed = [datetime]::MinValue

                    if ([datetime]::TryParse(
                            $rawLogonTime,
                            [Globalization.CultureInfo]::CurrentCulture,
                            [Globalization.DateTimeStyles]::AllowWhiteSpaces,
                            [ref]$parsed
                        )) {
                        return $parsed.ToString('dd.MM.yyyy HH:mm')
                    }

                    return $rawLogonTime
                }
            }
        }
    }
    catch {
    }

    return (Get-Date).ToString('dd.MM.yyyy HH:mm')
}

$installRoot =
    'C:\ProgramData\RaccoonAdminToolkit\BgInfo'

$binPath = Join-Path $installRoot 'Bin'
$configPath = Join-Path $installRoot 'Config\Raccoon-Standard.bgi'
$logPath = Join-Path $installRoot 'Logs\BgInfo.log'

$userRoot = Join-Path `
    $env:LOCALAPPDATA `
    'RaccoonAdminToolkit\BgInfo'

$textPath = Join-Path $userRoot 'SystemInfo.txt'

try {
    if (-not (Test-Path -LiteralPath $userRoot -PathType Container)) {
        New-Item `
            -Path $userRoot `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
        Out-Null
    }

    $userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $logonText = Get-CurrentSessionLogonText

    $systemInfo = @(
        'SYSTEM INFO'
        ''
        ('Користувач : {0}' -f $userName)
        ('Сеанс з    : {0}' -f $logonText)
        'Підтримка  : +380 67 001 10 12'
        '             дзвінки / Viber / Telegram / WhatsApp'
    ) -join [Environment]::NewLine

    Write-BgInfoText -Path $textPath -Text $systemInfo

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return
    }

    $exePath = if ([Environment]::Is64BitOperatingSystem) {
        Join-Path $binPath 'Bginfo64.exe'
    }
    else {
        Join-Path $binPath 'Bginfo.exe'
    }

    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        return
    }

    & $exePath `
        $configPath `
        '/timer:0' `
        '/silent' `
        '-accepteula' `
        "/log:$logPath" |
    Out-Null
}
catch {
    try {
        $errorText = (
            '{0} {1}' -f
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),
            $_.Exception.Message
        )

        Add-Content `
            -LiteralPath $logPath `
            -Value $errorText `
            -Encoding UTF8 `
            -ErrorAction SilentlyContinue
    }
    catch {
    }
}
