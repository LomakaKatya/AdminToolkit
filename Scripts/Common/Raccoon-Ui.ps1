Set-StrictMode -Version Latest

function Get-RaccoonValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Test-RaccoonAdministrator {
    $identity =
        [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        -TypeName Security.Principal.WindowsPrincipal `
        -ArgumentList $identity

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Write-RaccoonHeader {
    param(
        [string]$SectionName
    )

    Clear-Host

    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host (
        '                         RACCOON ADMIN TOOLKIT'
    ) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan

    if (-not [string]::IsNullOrWhiteSpace($SectionName)) {
        Write-Host ''
        Write-Host "  $SectionName" -ForegroundColor Cyan
        Write-Host (
            '  ' + ('-' * 68)
        ) -ForegroundColor DarkGray
    }

    Write-Host ''
}

function Read-RaccoonKey {
    param(
        [string]$Prompt = 'Обери пункт'
    )

    Write-Host "  $Prompt`: " -NoNewline

    try {
        $key = [Console]::ReadKey($true)

        $result = ''

        switch ($key.Key) {
            'Escape' {
                $result = 'esc'
            }

            'LeftArrow' {
                $result = 'left'
            }

            'RightArrow' {
                $result = 'right'
            }

            'F1' {
                $result = 'f1'
            }

            'F2' {
                $result = 'f2'
            }

            'F3' {
                $result = 'f3'
            }

            default {
                if ($key.KeyChar -ne [char]0) {
                    $result = (
                        [string]$key.KeyChar
                    ).ToLowerInvariant()
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($result)) {
            Write-Host ''
        }
        else {
            Write-Host $result -ForegroundColor Cyan
        }

        return $result
    }
    catch {
        Write-Host ''

        return (
            Microsoft.PowerShell.Utility\Read-Host `
                -Prompt $Prompt
        ).Trim().ToLowerInvariant()
    }
}

function Pause-RaccoonToolkit {
    Write-Host ''
    Write-Host '  Натисни будь-яку клавішу, щоб продовжити...' `
        -ForegroundColor DarkGray

    try {
        [void]$Host.UI.RawUI.ReadKey(
            'NoEcho,IncludeKeyDown'
        )
    }
    catch {
        [void](
            Microsoft.PowerShell.Utility\Read-Host `
                -Prompt 'Натисни Enter, щоб продовжити'
        )
    }
}

function Confirm-RaccoonAction {
    param(
        [string]$Prompt = 'Підтвердити дію?'
    )

    while ($true) {
        Write-Host ''
        Write-Host "  $Prompt" -ForegroundColor Yellow
        Write-Host (
            '  [Y/Д] Так     [N/Н] Ні'
        ) -ForegroundColor DarkGray

        $answer = Read-RaccoonKey -Prompt 'Підтвердження'

        if ($answer -in @(
                'y',
                'д'
            )) {
            return $true
        }

        if ($answer -in @(
                'n',
                'н',
                'esc',
                '0'
            )) {
            return $false
        }
    }
}

function Read-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Prompt = '',

        [switch]$AsSecureString
    )

    if ($AsSecureString) {
        if ([string]::IsNullOrWhiteSpace($Prompt)) {
            return Microsoft.PowerShell.Utility\Read-Host `
                -AsSecureString
        }

        return Microsoft.PowerShell.Utility\Read-Host `
            -Prompt $Prompt `
            -AsSecureString
    }

    if ($Prompt -match
            '(?i)^\s*(оберіть|оберите|выберите)\s+(дію|джерело|одержувача)\s*$') {

        while ($true) {
            $menuKey = Read-RaccoonKey -Prompt 'Обери пункт'

            if ($menuKey -eq 'esc') {
                return '0'
            }

            if ($menuKey -match '^[0-9]$') {
                return $menuKey
            }
        }
    }

    $token = ''

    if ($Prompt -match
            '(?i)(?:введи|введите)\s+([A-Z][A-Z0-9_-]{2,})') {
        $token = [string]$Matches[1]
    }

    $isConfirmation = (
        -not [string]::IsNullOrWhiteSpace($token) -or
        $Prompt -match '(?i)\[\s*y\s*/\s*n' -or
        $Prompt -match '(?i)\[\s*y\s*/\s*n\s*\|\s*д\s*/\s*н' -or
        $Prompt -match '(?i)^\s*(продовжити|продолжить|підтвердити|подтвердить)' -or
        $Prompt -match '(?i)^\s*(надіслати|відкрити|встановити|видалити|створити пакет|застосувати).*\?'
    )

    if ($isConfirmation) {
        $displayPrompt = $Prompt

        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $displayPrompt = 'Підтвердити дію?'
        }
        else {
            $displayPrompt = (
                $displayPrompt -replace
                    '\s*\[[^\]]*Y[^\]]*N[^\]]*\]\s*$',
                    ''
            ).Trim()

            if ([string]::IsNullOrWhiteSpace($displayPrompt)) {
                $displayPrompt = 'Підтвердити дію?'
            }
        }

        $accepted = Confirm-RaccoonAction `
            -Prompt $displayPrompt

        if ($accepted) {
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                return $token
            }

            return 'y'
        }

        if (-not [string]::IsNullOrWhiteSpace($token)) {
            return ''
        }

        return 'n'
    }

    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        return Microsoft.PowerShell.Utility\Read-Host
    }

    return Microsoft.PowerShell.Utility\Read-Host `
        -Prompt $Prompt
}

function Get-RaccoonStatePath {
    $stateRoot = Join-Path `
        $env:LOCALAPPDATA `
        'RaccoonAdminToolkit\Shell'

    if (-not (Test-Path `
            -LiteralPath $stateRoot `
            -PathType Container)) {

        New-Item `
            -Path $stateRoot `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
        Out-Null
    }

    return (Join-Path $stateRoot 'state.json')
}

function Read-RaccoonState {
    $defaultState = [pscustomobject]@{
        recent = @()
    }

    try {
        $path = Get-RaccoonStatePath

        if (-not (Test-Path `
                -LiteralPath $path `
                -PathType Leaf)) {
            return $defaultState
        }

        $text = [System.IO.File]::ReadAllText(
            $path,
            [System.Text.Encoding]::UTF8
        )

        if ([string]::IsNullOrWhiteSpace($text)) {
            return $defaultState
        }

        $state = $text | ConvertFrom-Json -ErrorAction Stop

        if ($null -eq $state.PSObject.Properties['recent']) {
            $state |
                Add-Member `
                    -NotePropertyName recent `
                    -NotePropertyValue @()
        }

        return $state
    }
    catch {
        return $defaultState
    }
}

function Save-RaccoonState {
    param(
        [Parameter(Mandatory)]
        [object]$State
    )

    try {
        $path = Get-RaccoonStatePath
        $json = $State |
            ConvertTo-Json `
                -Depth 6 `
                -Compress

        $encoding = New-Object `
            -TypeName System.Text.UTF8Encoding `
            -ArgumentList $false

        [System.IO.File]::WriteAllText(
            $path,
            $json,
            $encoding
        )
    }
    catch {
    }
}

function Add-RaccoonRecentTool {
    param(
        [Parameter(Mandatory)]
        [string]$ToolId
    )

    $state = Read-RaccoonState

    $recent = @(
        $ToolId
        @(
            $state.recent |
            Where-Object {
                [string]$_ -ne $ToolId
            }
        )
    ) |
        Select-Object -First 8

    $state.recent = @($recent)
    Save-RaccoonState -State $state
}

function Get-RaccoonTool {
    param(
        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$Id
    )

    return @(
        $Registry.tools |
        Where-Object {
            [string]$_.id -eq $Id
        }
    ) |
        Select-Object -First 1
}

function Get-RaccoonToolsByIds {
    param(
        [Parameter(Mandatory)]
        [object]$Registry,

        [AllowEmptyCollection()]
        [object[]]$Ids
    )

    $result = New-Object `
        -TypeName System.Collections.ArrayList

    foreach ($id in @($Ids)) {
        $tool = Get-RaccoonTool `
            -Registry $Registry `
            -Id ([string]$id)

        if ($null -ne $tool) {
            [void]$result.Add($tool)
        }
    }

    return @($result)
}

function Get-RaccoonLabelsText {
    param(
        [Parameter(Mandatory)]
        [object]$Tool
    )

    $labels = @(
        Get-RaccoonValue `
            -Object $Tool `
            -Name 'labels' `
            -DefaultValue @()
    )

    if ($labels.Count -eq 0) {
        return ''
    }

    return (
        @(
            $labels |
            ForEach-Object {
                '[{0}]' -f ([string]$_)
            }
        ) -join ' '
    )
}

function Write-RaccoonToolLine {
    param(
        [Parameter(Mandatory)]
        [int]$Index,

        [Parameter(Mandatory)]
        [object]$Tool
    )

    Write-Host (
        '  {0}. {1}' -f
        $Index,
        [string]$Tool.title
    )

    $labelsText = Get-RaccoonLabelsText -Tool $Tool

    if (-not [string]::IsNullOrWhiteSpace($labelsText)) {
        Write-Host "     $labelsText" `
            -ForegroundColor DarkGray
    }

    Write-Host ''
}

function Open-RaccoonFaq {
    param(
        [Parameter(Mandatory)]
        [string]$FaqUrl
    )

    Write-RaccoonHeader -SectionName 'FAQ І ДОВІДКА'

    try {
        Start-Process `
            -FilePath $FaqUrl `
            -ErrorAction Stop

        Write-Host 'FAQ відкрито у браузері.' `
            -ForegroundColor Green
    }
    catch {
        Write-Host 'Не вдалося автоматично відкрити браузер.' `
            -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Відкрий адресу вручну:' `
            -ForegroundColor DarkGray
        Write-Host $FaqUrl -ForegroundColor Cyan
    }

    Pause-RaccoonToolkit
}

function Invoke-RaccoonTool {
    param(
        [Parameter(Mandatory)]
        [object]$Tool,

        [Parameter(Mandatory)]
        [string]$BaseUrl
    )

    Write-RaccoonHeader -SectionName ([string]$Tool.title)

    $requiresAdmin = [bool](
        Get-RaccoonValue `
            -Object $Tool `
            -Name 'requiresAdmin' `
            -DefaultValue $false
    )

    if ($requiresAdmin -and
        -not (Test-RaccoonAdministrator)) {

        Write-Host (
            'Для цієї дії потрібні права адміністратора.'
        ) -ForegroundColor Red

        Write-Host (
            'Закрий Toolkit і запусти PowerShell від імені адміністратора.'
        ) -ForegroundColor Yellow

        Pause-RaccoonToolkit
        return
    }

    $confirmBeforeRun = [bool](
        Get-RaccoonValue `
            -Object $Tool `
            -Name 'confirmBeforeRun' `
            -DefaultValue $false
    )

    if ($confirmBeforeRun) {
        $confirmPrompt = [string](
            Get-RaccoonValue `
                -Object $Tool `
                -Name 'confirmPrompt' `
                -DefaultValue 'Запустити інструмент?'
        )

        if (-not (Confirm-RaccoonAction -Prompt $confirmPrompt)) {
            Write-Host ''
            Write-Host 'Дію скасовано.' -ForegroundColor Yellow
            Pause-RaccoonToolkit
            return
        }

        Write-Host ''
    }

    $path = [string]$Tool.path
    $cacheToken = [DateTime]::UtcNow.Ticks
    $uri = "$BaseUrl/$path`?nocache=$cacheToken"

    try {
        Write-Host 'Завантажую актуальну версію скрипта...' `
            -ForegroundColor DarkGray

        $content = Invoke-RestMethod `
            -Uri $uri `
            -Headers @{
                'Cache-Control' = 'no-cache'
                'Pragma'        = 'no-cache'
            } `
            -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace([string]$content)) {
            throw "Службове джерело повернуло порожній файл: $path"
        }

        $bomMarkers = [char[]]@(
            [char]0xFEFF,
            [char]0x00EF,
            [char]0x00BB,
            [char]0x00BF
        )

        $scriptText =
            ([string]$content).TrimStart($bomMarkers)

        if ([string]::IsNullOrWhiteSpace($scriptText)) {
            throw "Після нормалізації отримано порожній скрипт: $path"
        }

        $scriptBlock = [ScriptBlock]::Create($scriptText)

        Write-Host 'Запускаю.' -ForegroundColor DarkGray
        Write-Host ''

        & $scriptBlock

        Add-RaccoonRecentTool -ToolId ([string]$Tool.id)
    }
    catch {
        Write-Host ''
        Write-Host 'Не вдалося виконати скрипт.' `
            -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }
    finally {
        $content = $null
        $scriptText = $null
        $bomMarkers = $null
        $scriptBlock = $null
        $uri = $null
        $cacheToken = $null

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }

    Pause-RaccoonToolkit
}

function Get-RaccoonSearchResults {
    param(
        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$Query
    )

    $queryText = $Query.Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($queryText)) {
        return @()
    }

    $terms = @(
        $queryText -split '\s+' |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    $results = foreach ($tool in @($Registry.tools)) {
        $title = ([string]$tool.title).ToLowerInvariant()
        $description = (
            [string](
                Get-RaccoonValue `
                    -Object $tool `
                    -Name 'description' `
                    -DefaultValue ''
            )
        ).ToLowerInvariant()

        $keywords = (
            @(
                Get-RaccoonValue `
                    -Object $tool `
                    -Name 'keywords' `
                    -DefaultValue @()
            ) -join ' '
        ).ToLowerInvariant()

        $haystack = (
            '{0} {1} {2} {3}' -f
            ([string]$tool.id).ToLowerInvariant(),
            $title,
            $description,
            $keywords
        )

        $score = 0

        if ($title -eq $queryText) {
            $score += 100
        }
        elseif ($title.Contains($queryText)) {
            $score += 45
        }

        foreach ($term in $terms) {
            if ($title.Contains($term)) {
                $score += 12
            }

            if ($keywords.Contains($term)) {
                $score += 8
            }

            if ($description.Contains($term)) {
                $score += 4
            }
        }

        if ($score -gt 0 -and
            @(
                $terms |
                Where-Object {
                    -not $haystack.Contains($_)
                }
            ).Count -eq 0) {

            [pscustomobject]@{
                Tool  = $tool
                Score = $score
            }
        }
    }

    return @(
        $results |
        Sort-Object `
            -Property @(
                @{
                    Expression = 'Score'
                    Descending = $true
                },
                @{
                    Expression = {
                        [string]$_.Tool.title
                    }
                    Descending = $false
                }
            ) |
        Select-Object -First 9 |
        ForEach-Object {
            $_.Tool
        }
    )
}

function Show-RaccoonSearch {
    param(
        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$FaqUrl
    )

    Write-RaccoonHeader -SectionName 'ПОШУК ІНСТРУМЕНТА'

    Write-Host (
        '  Введи назву, компонент або опис проблеми.'
    ) -ForegroundColor DarkGray
    Write-Host (
        '  Приклади: принтер, час, 4625, сайт, 1с база, повідомлення.'
    ) -ForegroundColor DarkGray
    Write-Host ''

    $query = (
        Microsoft.PowerShell.Utility\Read-Host `
            -Prompt 'Пошук'
    ).Trim()

    if ([string]::IsNullOrWhiteSpace($query)) {
        return
    }

    $results = @(
        Get-RaccoonSearchResults `
            -Registry $Registry `
            -Query $query
    )

    if ($results.Count -eq 0) {
        Write-Host ''
        Write-Host 'Нічого не знайдено.' `
            -ForegroundColor Yellow
        Pause-RaccoonToolkit
        return
    }

    Show-RaccoonToolList `
        -Title "ПОШУК: $query" `
        -Tools $results `
        -Registry $Registry `
        -BaseUrl $BaseUrl `
        -FaqUrl $FaqUrl `
        -DisableGlobalSearch
}

function Invoke-RaccoonGlobalKey {
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$FaqUrl
    )

    switch ($Key) {
        'f1' {
            Open-RaccoonFaq -FaqUrl $FaqUrl
            return $true
        }

        'f2' {
            Show-RaccoonSearch `
                -Registry $Registry `
                -BaseUrl $BaseUrl `
                -FaqUrl $FaqUrl

            return $true
        }

        'f3' {
            Show-RaccoonQuickAccess `
                -Registry $Registry `
                -BaseUrl $BaseUrl `
                -FaqUrl $FaqUrl

            return $true
        }
    }

    return $false
}

function Show-RaccoonToolList {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [AllowEmptyCollection()]
        [object[]]$Tools,

        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$FaqUrl,

        [switch]$DisableGlobalSearch
    )

    $toolList = @($Tools)

    if ($toolList.Count -eq 0) {
        Write-RaccoonHeader -SectionName $Title
        Write-Host 'У цьому розділі поки немає інструментів.' `
            -ForegroundColor DarkYellow
        Pause-RaccoonToolkit
        return
    }

    $page = 0
    $pageSize = 9
    $pageCount = [Math]::Ceiling(
        $toolList.Count / [double]$pageSize
    )

    while ($true) {
        Write-RaccoonHeader -SectionName $Title

        $start = $page * $pageSize
        $end = [Math]::Min(
            $start + $pageSize - 1,
            $toolList.Count - 1
        )

        $visible = @(
            $toolList[$start..$end]
        )

        for ($index = 0; $index -lt $visible.Count; $index++) {
            Write-RaccoonToolLine `
                -Index ($index + 1) `
                -Tool $visible[$index]
        }

        Write-Host '  0. Назад' -ForegroundColor DarkGray

        if ($pageCount -gt 1) {
            Write-Host (
                '  Сторінка {0}/{1}. Стрілки вліво/вправо перемикають сторінки.' -f
                ($page + 1),
                $pageCount
            ) -ForegroundColor DarkGray
        }

        Write-Host (
            '  F1 Довідка   F2 Пошук   F3 Швидкий доступ   Esc Назад'
        ) -ForegroundColor DarkGray
        Write-Host ''

        $key = Read-RaccoonKey

        if ($key -in @(
                '0',
                'esc'
            )) {
            return
        }

        if ($key -eq 'left' -and $pageCount -gt 1) {
            $page--

            if ($page -lt 0) {
                $page = $pageCount - 1
            }

            continue
        }

        if ($key -eq 'right' -and $pageCount -gt 1) {
            $page = ($page + 1) % $pageCount
            continue
        }

        if (-not $DisableGlobalSearch -or
            $key -ne 'f2') {

            if (Invoke-RaccoonGlobalKey `
                    -Key $key `
                    -Registry $Registry `
                    -BaseUrl $BaseUrl `
                    -FaqUrl $FaqUrl) {
                continue
            }
        }

        if ($key -match '^[1-9]$') {
            $selectedIndex = [int]$key - 1

            if ($selectedIndex -lt $visible.Count) {
                Invoke-RaccoonTool `
                    -Tool $visible[$selectedIndex] `
                    -BaseUrl $BaseUrl
            }
        }
    }
}

function Show-RaccoonQuickAccess {
    param(
        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$FaqUrl
    )

    $favoriteIds = @(
        Get-RaccoonValue `
            -Object $Registry `
            -Name 'favorites' `
            -DefaultValue @()
    )

    $favorites = Get-RaccoonToolsByIds `
        -Registry $Registry `
        -Ids $favoriteIds

    $state = Read-RaccoonState
    $recentIds = @(
        $state.recent |
        Where-Object {
            [string]$_ -notin @($favoriteIds)
        }
    )

    $recent = Get-RaccoonToolsByIds `
        -Registry $Registry `
        -Ids $recentIds

    $entries = New-Object `
        -TypeName System.Collections.ArrayList

    foreach ($tool in @($favorites)) {
        [void]$entries.Add(
            [pscustomobject]@{
                Group = 'ОБРАНЕ'
                Tool  = $tool
            }
        )
    }

    $remaining = 9 - $entries.Count

    if ($remaining -gt 0) {
        foreach ($tool in @($recent | Select-Object -First $remaining)) {
            [void]$entries.Add(
                [pscustomobject]@{
                    Group = 'ОСТАННІ'
                    Tool  = $tool
                }
            )
        }
    }

    while ($true) {
        Write-RaccoonHeader -SectionName 'ШВИДКИЙ ДОСТУП'

        $lastGroup = ''

        for ($index = 0; $index -lt $entries.Count; $index++) {
            $entry = $entries[$index]

            if ([string]$entry.Group -ne $lastGroup) {
                Write-Host "  $($entry.Group)" `
                    -ForegroundColor DarkCyan
                Write-Host ''
                $lastGroup = [string]$entry.Group
            }

            Write-RaccoonToolLine `
                -Index ($index + 1) `
                -Tool $entry.Tool
        }

        if ($entries.Count -eq 0) {
            Write-Host '  Історія запусків поки порожня.' `
                -ForegroundColor DarkGray
            Write-Host ''
        }

        Write-Host '  0. Назад' -ForegroundColor DarkGray
        Write-Host (
            '  F1 Довідка   F2 Пошук   Esc Назад'
        ) -ForegroundColor DarkGray
        Write-Host ''

        $key = Read-RaccoonKey

        if ($key -in @(
                '0',
                'esc'
            )) {
            return
        }

        if ($key -eq 'f1') {
            Open-RaccoonFaq -FaqUrl $FaqUrl
            continue
        }

        if ($key -eq 'f2') {
            Show-RaccoonSearch `
                -Registry $Registry `
                -BaseUrl $BaseUrl `
                -FaqUrl $FaqUrl

            continue
        }

        if ($key -match '^[1-9]$') {
            $selectedIndex = [int]$key - 1

            if ($selectedIndex -lt $entries.Count) {
                Invoke-RaccoonTool `
                    -Tool $entries[$selectedIndex].Tool `
                    -BaseUrl $BaseUrl
            }
        }
    }
}

function Show-RaccoonView {
    param(
        [Parameter(Mandatory)]
        [object]$View,

        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$FaqUrl
    )

    $categories = @(
        Get-RaccoonValue `
            -Object $View `
            -Name 'categories' `
            -DefaultValue @()
    )

    while ($true) {
        Write-RaccoonHeader -SectionName ([string]$View.title)

        for ($index = 0; $index -lt $categories.Count; $index++) {
            $category = $categories[$index]

            Write-Host (
                '  {0}. {1}' -f
                ($index + 1),
                [string]$category.title
            )

            $description = [string](
                Get-RaccoonValue `
                    -Object $category `
                    -Name 'description' `
                    -DefaultValue ''
            )

            if (-not [string]::IsNullOrWhiteSpace($description)) {
                Write-Host "     $description" `
                    -ForegroundColor DarkGray
            }

            Write-Host ''
        }

        Write-Host '  0. Назад' -ForegroundColor DarkGray
        Write-Host (
            '  F1 Довідка   F2 Пошук   F3 Швидкий доступ   Esc Назад'
        ) -ForegroundColor DarkGray
        Write-Host ''

        $key = Read-RaccoonKey

        if ($key -in @(
                '0',
                'esc'
            )) {
            return
        }

        if (Invoke-RaccoonGlobalKey `
                -Key $key `
                -Registry $Registry `
                -BaseUrl $BaseUrl `
                -FaqUrl $FaqUrl) {
            continue
        }

        if ($key -match '^[1-9]$') {
            $selectedIndex = [int]$key - 1

            if ($selectedIndex -lt $categories.Count) {
                $category = $categories[$selectedIndex]

                $toolIds = @(
                    Get-RaccoonValue `
                        -Object $category `
                        -Name 'toolIds' `
                        -DefaultValue @()
                )

                $tools = Get-RaccoonToolsByIds `
                    -Registry $Registry `
                    -Ids $toolIds

                Show-RaccoonToolList `
                    -Title ([string]$category.title).ToUpperInvariant() `
                    -Tools $tools `
                    -Registry $Registry `
                    -BaseUrl $BaseUrl `
                    -FaqUrl $FaqUrl
            }
        }
    }
}

function Show-RaccoonCatalog {
    param(
        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$FaqUrl
    )

    $catalogView = [pscustomobject]@{
        title      = 'КАТАЛОГ ІНСТРУМЕНТІВ'
        categories = @($Registry.catalog)
    }

    Show-RaccoonView `
        -View $catalogView `
        -Registry $Registry `
        -BaseUrl $BaseUrl `
        -FaqUrl $FaqUrl
}

function Show-RaccoonMainSection {
    param(
        [Parameter(Mandatory)]
        [object]$Section,

        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$FaqUrl
    )

    $toolIds = @(
        Get-RaccoonValue `
            -Object $Section `
            -Name 'toolIds' `
            -DefaultValue @()
    )

    $categories = @(
        Get-RaccoonValue `
            -Object $Section `
            -Name 'categories' `
            -DefaultValue @()
    )

    $tools = Get-RaccoonToolsByIds `
        -Registry $Registry `
        -Ids $toolIds

    if ($tools.Count -gt 0 -and $categories.Count -gt 0) {
        if (($tools.Count + $categories.Count) -gt 9) {
            throw (
                'Змішаний розділ підтримує не більше дев''яти ' +
                'інструментів і підрозділів на одному екрані.'
            )
        }

        while ($true) {
            Write-RaccoonHeader `
                -SectionName ([string]$Section.title)

            $entryIndex = 1

            foreach ($tool in @($tools)) {
                Write-RaccoonToolLine `
                    -Index $entryIndex `
                    -Tool $tool

                $entryIndex++
            }

            foreach ($category in @($categories)) {
                Write-Host (
                    '  {0}. {1}' -f
                    $entryIndex,
                    [string]$category.title
                )

                $description = [string](
                    Get-RaccoonValue `
                        -Object $category `
                        -Name 'description' `
                        -DefaultValue ''
                )

                if (-not [string]::IsNullOrWhiteSpace($description)) {
                    Write-Host "     $description" `
                        -ForegroundColor DarkGray
                }

                Write-Host ''
                $entryIndex++
            }

            Write-Host '  0. Назад' -ForegroundColor DarkGray
            Write-Host (
                '  F1 Довідка   F2 Пошук   F3 Швидкий доступ   Esc Назад'
            ) -ForegroundColor DarkGray
            Write-Host ''

            $key = Read-RaccoonKey

            if ($key -in @(
                    '0',
                    'esc'
                )) {
                return
            }

            if (Invoke-RaccoonGlobalKey `
                    -Key $key `
                    -Registry $Registry `
                    -BaseUrl $BaseUrl `
                    -FaqUrl $FaqUrl) {
                continue
            }

            if ($key -match '^[1-9]$') {
                $selectedIndex = [int]$key - 1

                if ($selectedIndex -lt $tools.Count) {
                    Invoke-RaccoonTool `
                        -Tool $tools[$selectedIndex] `
                        -BaseUrl $BaseUrl

                    continue
                }

                $categoryIndex = $selectedIndex - $tools.Count

                if ($categoryIndex -ge 0 -and
                    $categoryIndex -lt $categories.Count) {

                    $category = $categories[$categoryIndex]
                    $categoryToolIds = @(
                        Get-RaccoonValue `
                            -Object $category `
                            -Name 'toolIds' `
                            -DefaultValue @()
                    )

                    $categoryTools = Get-RaccoonToolsByIds `
                        -Registry $Registry `
                        -Ids $categoryToolIds

                    Show-RaccoonToolList `
                        -Title ([string]$category.title).ToUpperInvariant() `
                        -Tools $categoryTools `
                        -Registry $Registry `
                        -BaseUrl $BaseUrl `
                        -FaqUrl $FaqUrl
                }
            }
        }
    }

    if ($categories.Count -gt 0) {
        $view = [pscustomobject]@{
            title      = [string]$Section.title
            categories = $categories
        }

        Show-RaccoonView `
            -View $view `
            -Registry $Registry `
            -BaseUrl $BaseUrl `
            -FaqUrl $FaqUrl

        return
    }

    Show-RaccoonToolList `
        -Title ([string]$Section.title).ToUpperInvariant() `
        -Tools $tools `
        -Registry $Registry `
        -BaseUrl $BaseUrl `
        -FaqUrl $FaqUrl
}

function Show-RaccoonMainMenu {
    param(
        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$FaqUrl
    )

    $sections = @(
        Get-RaccoonValue `
            -Object $Registry `
            -Name 'mainMenu' `
            -DefaultValue @()
    )

    if ($sections.Count -eq 0) {
        throw 'У Config/ToolkitMenu.json відсутній mainMenu.'
    }

    if ($sections.Count -gt 8) {
        throw 'Головне меню підтримує не більше восьми функціональних розділів.'
    }

    while ($true) {
        Write-RaccoonHeader -SectionName ''

        $adminText = if (Test-RaccoonAdministrator) {
            'Так'
        }
        else {
            'Ні'
        }

        Write-Host (
            'Комп''ютер:     {0}' -f
            $env:COMPUTERNAME
        )

        Write-Host (
            'Користувач:    {0}\{1}' -f
            $env:USERDOMAIN,
            $env:USERNAME
        )

        Write-Host (
            'PowerShell:    {0}' -f
            $PSVersionTable.PSVersion
        )

        Write-Host (
            'Адміністратор: {0}' -f
            $adminText
        )

        Write-Host ''
        Write-Host '  РОЗДІЛИ' -ForegroundColor DarkCyan
        Write-Host ''

        for ($index = 0; $index -lt $sections.Count; $index++) {
            $section = $sections[$index]

            Write-Host (
                '  {0}. {1}' -f
                ($index + 1),
                [string]$section.title
            )

            $description = [string](
                Get-RaccoonValue `
                    -Object $section `
                    -Name 'description' `
                    -DefaultValue ''
            )

            if (-not [string]::IsNullOrWhiteSpace($description)) {
                Write-Host "     $description" `
                    -ForegroundColor DarkGray
            }

            Write-Host ''
        }

        $faqIndex = $sections.Count + 1

        if ($faqIndex -le 9) {
            Write-Host "  $faqIndex. FAQ і довідка"
            Write-Host ''
        }

        Write-Host '  0. Вихід' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host (
            '  F1 Довідка   F2 Пошук   F3 Швидкий доступ   Esc Вихід'
        ) -ForegroundColor DarkGray
        Write-Host ''

        $key = Read-RaccoonKey

        if ($key -eq 'f1') {
            Open-RaccoonFaq -FaqUrl $FaqUrl
            continue
        }

        if ($key -eq 'f2') {
            Show-RaccoonSearch `
                -Registry $Registry `
                -BaseUrl $BaseUrl `
                -FaqUrl $FaqUrl

            continue
        }

        if ($key -eq 'f3') {
            Show-RaccoonQuickAccess `
                -Registry $Registry `
                -BaseUrl $BaseUrl `
                -FaqUrl $FaqUrl

            continue
        }

        if ($key -match '^[1-9]$') {
            $selected = [int]$key

            if ($selected -ge 1 -and $selected -le $sections.Count) {
                Show-RaccoonMainSection `
                    -Section $sections[$selected - 1] `
                    -Registry $Registry `
                    -BaseUrl $BaseUrl `
                    -FaqUrl $FaqUrl

                continue
            }

            if ($selected -eq $faqIndex) {
                Open-RaccoonFaq -FaqUrl $FaqUrl
                continue
            }
        }

        if ($key -in @(
                '0',
                'esc'
            )) {

            if (Confirm-RaccoonAction `
                    -Prompt 'Завершити роботу Toolkit?') {
                return
            }
        }
    }
}

function Start-RaccoonShell {
    param(
        [Parameter(Mandatory)]
        [object]$Registry,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$FaqUrl
    )

    $schemaVersion = [int](
        Get-RaccoonValue `
            -Object $Registry `
            -Name 'schemaVersion' `
            -DefaultValue 0
    )

    if ($schemaVersion -ne 2) {
        throw (
            'Непідтримувана версія реєстру меню: {0}' -f
            $schemaVersion
        )
    }

    if (@($Registry.tools).Count -eq 0) {
        throw 'Реєстр інструментів порожній.'
    }

    Show-RaccoonMainMenu `
        -Registry $Registry `
        -BaseUrl $BaseUrl `
        -FaqUrl $FaqUrl
}
