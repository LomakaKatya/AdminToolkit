Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

$userRoot = Join-Path `
    $env:LOCALAPPDATA `
    'RaccoonAdminToolkit\BgInfo'

$logPath = Join-Path $userRoot 'BgInfo.log'
$legacyTextPath = Join-Path $userRoot 'SystemInfo.txt'

try {
    if (-not (Test-Path -LiteralPath $userRoot -PathType Container)) {
        New-Item `
            -Path $userRoot `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
        Out-Null
    }

    Remove-Item `
        -LiteralPath $legacyTextPath `
        -Force `
        -ErrorAction SilentlyContinue

    $env:RACCOON_BGINFO_USER =
        [Security.Principal.WindowsIdentity]::GetCurrent().Name

    $env:RACCOON_BGINFO_SESSION_SINCE =
        Get-CurrentSessionLogonText

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
        if (-not (Test-Path -LiteralPath $userRoot -PathType Container)) {
            New-Item `
                -Path $userRoot `
                -ItemType Directory `
                -Force `
                -ErrorAction SilentlyContinue |
            Out-Null
        }

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
