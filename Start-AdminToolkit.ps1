& {
    try {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'

        $version = $PSVersionTable.PSVersion

        if ($version.Major -lt 5 -or
            ($version.Major -eq 5 -and $version.Minor -lt 1)) {
            throw (
                'Raccoon Admin Toolkit потребує Windows PowerShell 5.1 ' +
                'або PowerShell 7+.'
            )
        }

        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor
                [Net.SecurityProtocolType]::Tls12
        }
        catch {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor 3072
        }

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
            $baseUrl =
                'https://admintoolkit.itraccoonverse.space'
        }
        else {
            $baseUrl = (
                'https://raw.githubusercontent.com/' +
                'LomakaKatya/AdminToolkit/{0}' -f
                $repositoryRef
            )
        }

        $faqUrl =
            'https://admintoolkit.itraccoonverse.space/faq.html'

        function Write-Utf8NoBomLines {
            param(
                [Parameter(Mandatory)]
                [string]$Path,

                [Parameter(Mandatory)]
                [AllowEmptyCollection()]
                [string[]]$Lines
            )

            $encoding = New-Object `
                -TypeName System.Text.UTF8Encoding `
                -ArgumentList $false

            [System.IO.File]::WriteAllLines(
                $Path,
                $Lines,
                $encoding
            )
        }

        function Clear-RaccoonLaunchHistory {
            $historyPath = $null
            $historyLines = @()
            $filteredHistory = @()

            try {
                if (Get-Module `
                        -Name PSReadLine `
                        -ErrorAction SilentlyContinue) {

                    try {
                        $historyPath =
                            (Get-PSReadLineOption).HistorySavePath
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

                                if ($Line -match
                                        '(?i)[a-z0-9.-]*itraccoonverse\.space' -or
                                    $Line -match
                                        '(?i)raw\.githubusercontent\.com[/\\]LomakaKatya[/\\]AdminToolkit') {
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
                    (Test-Path `
                        -LiteralPath $historyPath `
                        -PathType Leaf)) {

                    $historyLines = @(
                        Get-Content `
                            -LiteralPath $historyPath `
                            -ErrorAction SilentlyContinue
                    )

                    $filteredHistory = @(
                        $historyLines |
                        Where-Object {
                            $_ -notmatch
                                '(?i)[a-z0-9.-]*itraccoonverse\.space' -and
                            $_ -notmatch
                                '(?i)raw\.githubusercontent\.com[/\\]LomakaKatya[/\\]AdminToolkit'
                        }
                    )

                    if ($filteredHistory.Count -eq 0) {
                        Remove-Item `
                            -LiteralPath $historyPath `
                            -Force `
                            -ErrorAction SilentlyContinue
                    }
                    else {
                        Write-Utf8NoBomLines `
                            -Path $historyPath `
                            -Lines $filteredHistory
                    }
                }
            }
            catch {
            }
            finally {
                $historyLines = $null
                $filteredHistory = $null
            }
        }

        function Get-RaccoonRemoteText {
            param(
                [Parameter(Mandatory)]
                [string]$Path
            )

            $cacheToken = [DateTime]::UtcNow.Ticks
            $uri = "$baseUrl/$Path`?nocache=$cacheToken"

            $response = Invoke-WebRequest `
                -Uri $uri `
                -Headers @{
                    'Cache-Control' = 'no-cache'
                    'Pragma'        = 'no-cache'
                } `
                -UseBasicParsing `
                -ErrorAction Stop

            $content = [string]$response.Content

            if ([string]::IsNullOrWhiteSpace($content)) {
                throw "Службове джерело повернуло порожній файл: $Path"
            }

            $bomMarkers = [char[]]@(
                [char]0xFEFF,
                [char]0x00EF,
                [char]0x00BB,
                [char]0x00BF
            )

            $normalized = ([string]$content).TrimStart($bomMarkers)

            if ([string]::IsNullOrWhiteSpace($normalized)) {
                throw "Після нормалізації отримано порожній файл: $Path"
            }

            return $normalized
        }

        Clear-RaccoonLaunchHistory

        try {
            $Host.UI.RawUI.WindowTitle =
                'Raccoon Admin Toolkit'
        }
        catch {
        }

        $uiText = Get-RaccoonRemoteText `
            -Path 'Scripts/Common/Raccoon-Ui.ps1'

        $uiBlock = [ScriptBlock]::Create($uiText)
        . $uiBlock

        $registryText = Get-RaccoonRemoteText `
            -Path 'Config/ToolkitMenu.json'

        $registry = $registryText |
            ConvertFrom-Json `
                -ErrorAction Stop

        Start-RaccoonShell `
            -Registry $registry `
            -BaseUrl $baseUrl `
            -FaqUrl $faqUrl
    }
    catch {
        Write-Host ''
        Write-Host 'Raccoon Admin Toolkit не вдалося запустити.' `
            -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        Write-Host ''

        try {
            [void](
                Microsoft.PowerShell.Utility\Read-Host `
                    -Prompt 'Натисни Enter, щоб закрити'
            )
        }
        catch {
        }
    }
    finally {
        try {
            Clear-RaccoonLaunchHistory
        }
        catch {
        }

        $version = $null
        $candidateRef = $null
        $repositoryRef = $null
        $baseUrl = $null
        $faqUrl = $null
        $uiText = $null
        $uiBlock = $null
        $response = $null
        $registryText = $null
        $registry = $null

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        Write-Host ''
        Write-Host (
            'Історію очищено. Сеанс PowerShell закривається.'
        ) -ForegroundColor DarkGray

        Start-Sleep -Milliseconds 350
        exit 0
    }
}
