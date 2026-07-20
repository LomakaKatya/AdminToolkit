Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Section {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ''
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        -TypeName Security.Principal.WindowsPrincipal `
        -ArgumentList $identity

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Get-SessionQueryTool {
    $quserPath = Join-Path $env:SystemRoot 'System32\quser.exe'

    if (Test-Path -LiteralPath $quserPath -PathType Leaf) {
        return [pscustomobject]@{
            Path      = $quserPath
            Arguments = @()
        }
    }

    $queryPath = Join-Path $env:SystemRoot 'System32\query.exe'

    if (Test-Path -LiteralPath $queryPath -PathType Leaf) {
        return [pscustomobject]@{
            Path      = $queryPath
            Arguments = @('user')
        }
    }

    throw 'Не знайдено quser.exe або query.exe.'
}

function Get-UserSessions {
    $tool = Get-SessionQueryTool
    $toolArguments = @($tool.Arguments)

    $output = @(
        & $tool.Path @toolArguments 2>&1 |
        ForEach-Object { [string]$_ }
    )
    $exitCode = [int]$LASTEXITCODE

    if ($exitCode -ne 0) {
        $details = (
            @(
                $output |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Select-Object -First 4
            ) -join ' | '
        )

        throw "Не вдалося отримати список сеансів. Код $exitCode. $details"
    }

    $sessions = New-Object -TypeName System.Collections.ArrayList

    foreach ($rawLine in $output) {
        $line = ([string]$rawLine).TrimEnd()

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $trimmed = $line.TrimStart()

        if ($trimmed -match '^(?i)username\s+sessionname\s+id\s+state' -or
            $trimmed -match '^(?i)ім''я\s+користувача' -or
            $trimmed -match '^(?i)имя\s+пользователя') {
            continue
        }

        $isCurrent = $false

        if ($trimmed.StartsWith('>')) {
            $isCurrent = $true
            $trimmed = $trimmed.Substring(1).TrimStart()
        }

        $tokens = @(
            $trimmed -split '\s+' |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
        )

        if ($tokens.Count -lt 3) {
            continue
        }

        $idIndex = -1
        $sessionId = 0

        for ($index = 1; $index -lt $tokens.Count; $index++) {
            $candidateId = 0

            if ([int]::TryParse($tokens[$index], [ref]$candidateId)) {
                $idIndex = $index
                $sessionId = $candidateId
                break
            }
        }

        if ($idIndex -lt 1) {
            continue
        }

        $userName = [string]$tokens[0]

        if ([string]::IsNullOrWhiteSpace($userName)) {
            continue
        }

        $sessionName = ''

        if ($idIndex -gt 1) {
            $sessionName = (
                @(
                    $tokens[1..($idIndex - 1)]
                ) -join ' '
            )
        }

        $state = ''

        if (($idIndex + 1) -lt $tokens.Count) {
            $state = [string]$tokens[$idIndex + 1]
        }

        $idleTime = ''

        if (($idIndex + 2) -lt $tokens.Count) {
            $idleTime = [string]$tokens[$idIndex + 2]
        }

        $logonTime = ''

        if (($idIndex + 3) -lt $tokens.Count) {
            $logonTime = (
                @(
                    $tokens[($idIndex + 3)..($tokens.Count - 1)]
                ) -join ' '
            )
        }

        [void]$sessions.Add(
            [pscustomobject]@{
                UserName    = $userName
                SessionName = $sessionName
                SessionId   = $sessionId
                State       = $state
                IdleTime    = $idleTime
                LogonTime   = $logonTime
                IsCurrent   = $isCurrent
                IsActive    = (-not [string]::IsNullOrWhiteSpace($sessionName))
            }
        )
    }

    return @(
        $sessions |
        Sort-Object -Property SessionId
    )
}

function Show-SessionTable {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Sessions
    )

    Write-Host (
        '{0,-5} {1,-24} {2,-17} {3,-12} {4}' -f
        'ID',
        'Користувач',
        'Сеанс',
        'Стан',
        'Вхід'
    ) -ForegroundColor DarkGray

    Write-Host ('-' * 90) -ForegroundColor DarkGray

    foreach ($session in $Sessions) {
        $sessionName = if ([string]::IsNullOrWhiteSpace($session.SessionName)) {
            '-'
        }
        else {
            $session.SessionName
        }

        $marker = if ($session.IsCurrent) {
            '>'
        }
        else {
            ' '
        }

        $color = if ($session.IsActive) {
            [ConsoleColor]::Green
        }
        else {
            [ConsoleColor]::DarkGray
        }

        Write-Host (
            '{0}{1,-4} {2,-24} {3,-17} {4,-12} {5}' -f
            $marker,
            $session.SessionId,
            $session.UserName,
            $sessionName,
            $session.State,
            $session.LogonTime
        ) -ForegroundColor $color
    }
}

function Read-MultilineMessage {
    Write-Host ''
    Write-Host 'Введи текст повідомлення.' -ForegroundColor Cyan
    Write-Host 'Для завершення введи крапку в окремому рядку.' `
        -ForegroundColor DarkGray
    Write-Host ''

    $lines = New-Object -TypeName System.Collections.ArrayList

    while ($true) {
        $line = Read-Host

        if ($line -eq '.') {
            break
        }

        [void]$lines.Add($line)

        if ($lines.Count -ge 20) {
            Write-Host '[WARN] Досягнуто ліміт у 20 рядків.' `
                -ForegroundColor Yellow
            break
        }
    }

    $message = (
        @(
            $lines
        ) -join [Environment]::NewLine
    ).Trim()

    if ([string]::IsNullOrWhiteSpace($message)) {
        throw 'Текст повідомлення не може бути порожнім.'
    }

    if ($message.Length -gt 1500) {
        throw 'Повідомлення задовге. Максимум: 1500 символів.'
    }

    return $message
}

function Send-MessageToSession {
    param(
        [Parameter(Mandatory)]
        [int]$SessionId,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $msgPath = Join-Path $env:SystemRoot 'System32\msg.exe'

    if (-not (Test-Path -LiteralPath $msgPath -PathType Leaf)) {
        throw "Не знайдено системний файл: $msgPath"
    }

    $output = @(
        & $msgPath `
            ([string]$SessionId) `
            "/time:$TimeoutSeconds" `
            $Message `
            2>&1 |
        ForEach-Object {
            ([string]$_).Trim()
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    $exitCode = [int]$LASTEXITCODE

    return [pscustomobject]@{
        Success  = ($exitCode -eq 0)
        ExitCode = $exitCode
        Output   = ($output -join ' | ')
    }
}

try {
    Write-Host ''
    Write-Host 'Повідомлення користувачам через msg.exe' `
        -ForegroundColor Cyan
    Write-Host 'Показує активні сеанси та надсилає повідомлення адресно.' `
        -ForegroundColor DarkGray

    if (-not (Test-IsAdministrator)) {
        Write-Host ''
        Write-Host '[FAIL] Для надсилання повідомлень потрібні права адміністратора.' `
            -ForegroundColor Red
        return
    }

    $sessions = @(Get-UserSessions)

    Write-Section -Title 'СЕАНСИ КОРИСТУВАЧІВ'

    if ($sessions.Count -eq 0) {
        Write-Host '[WARN] Сеанси користувачів не знайдено.' `
            -ForegroundColor Yellow
        return
    }

    Show-SessionTable -Sessions $sessions

    Write-Host ''
    Write-Host '  1. Усім активним користувачам'
    Write-Host '  2. Конкретному користувачу'
    Write-Host '  3. Конкретному сеансу'
    Write-Host '  0. Скасувати'
    Write-Host ''

    $mode = Read-Host 'Оберіть одержувача'
    $targets = @()

    switch ($mode) {
        '1' {
            $targets = @(
                $sessions |
                Where-Object {
                    $_.IsActive
                }
            )

            if ($targets.Count -eq 0) {
                throw 'Активних сеансів для надсилання не знайдено.'
            }
        }

        '2' {
            $users = @(
                $sessions |
                Where-Object {
                    $_.IsActive
                } |
                Select-Object -ExpandProperty UserName -Unique |
                Sort-Object
            )

            if ($users.Count -eq 0) {
                throw 'Активних користувачів не знайдено.'
            }

            Write-Host ''

            for ($index = 0; $index -lt $users.Count; $index++) {
                Write-Host (
                    '  {0}. {1}' -f
                    ($index + 1),
                    $users[$index]
                )
            }

            Write-Host ''
            $selectionText = Read-Host 'Оберіть користувача'
            $selection = 0

            if (-not [int]::TryParse($selectionText, [ref]$selection) -or
                $selection -lt 1 -or
                $selection -gt $users.Count) {
                throw 'Невірний номер користувача.'
            }

            $selectedUser = $users[$selection - 1]

            $targets = @(
                $sessions |
                Where-Object {
                    $_.IsActive -and
                    $_.UserName -ieq $selectedUser
                }
            )
        }

        '3' {
            $sessionText = Read-Host 'Введи ID сеансу'
            $selectedSessionId = 0

            if (-not [int]::TryParse(
                    $sessionText,
                    [ref]$selectedSessionId
                )) {
                throw 'ID сеансу має бути числом.'
            }

            $targets = @(
                $sessions |
                Where-Object {
                    $_.SessionId -eq $selectedSessionId
                }
            )

            if ($targets.Count -eq 0) {
                throw "Сеанс ID $selectedSessionId не знайдено."
            }
        }

        '0' {
            Write-Host 'Дію скасовано.' -ForegroundColor Yellow
            return
        }

        default {
            throw 'Невідомий режим надсилання.'
        }
    }

    $timeoutText = (
        Read-Host 'Час показу в секундах [Enter = 300]'
    ).Trim()

    $timeoutSeconds = 300

    if (-not [string]::IsNullOrWhiteSpace($timeoutText)) {
        if (-not [int]::TryParse(
                $timeoutText,
                [ref]$timeoutSeconds
            ) -or
            $timeoutSeconds -lt 10 -or
            $timeoutSeconds -gt 86400) {
            throw 'Час показу має бути від 10 до 86400 секунд.'
        }
    }

    $body = Read-MultilineMessage

    $message = (
        "ПОВІДОМЛЕННЯ ВІД ПІДТРИМКИ{0}{0}{1}{0}{0}" +
        "Підтримка: +380 67 001 10 12, дзвінки/Viber/Telegram/WhatsApp"
    ) -f [Environment]::NewLine, $body

    Write-Section -Title 'ПЕРЕВІРКА ПЕРЕД НАДСИЛАННЯМ'

    Write-Host 'Одержувачі:' -ForegroundColor Cyan

    foreach ($target in $targets) {
        Write-Host (
            '  ID {0}: {1}, {2}' -f
            $target.SessionId,
            $target.UserName,
            $(if ($target.IsActive) {
                'активний сеанс'
            }
            else {
                'сеанс може бути відключений'
            })
        )
    }

    Write-Host ''
    Write-Host 'Текст:' -ForegroundColor Cyan
    Write-Host ('-' * 72) -ForegroundColor DarkGray
    Write-Host $message
    Write-Host ('-' * 72) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "Час показу: $timeoutSeconds секунд."
    Write-Host ''

    $confirmation = Read-Host 'Для надсилання введи MESSAGE'

    if ($confirmation -cne 'MESSAGE') {
        Write-Host 'Надсилання скасовано.' -ForegroundColor Yellow
        return
    }

    Write-Section -Title 'НАДСИЛАННЯ'

    $sent = 0
    $failed = 0

    foreach ($target in $targets) {
        $result = Send-MessageToSession `
            -SessionId $target.SessionId `
            -Message $message `
            -TimeoutSeconds $timeoutSeconds

        if ($result.Success) {
            Write-Host (
                '[OK] ID {0}, {1}: повідомлення надіслано.' -f
                $target.SessionId,
                $target.UserName
            ) -ForegroundColor Green

            $sent++
        }
        else {
            $details = if ([string]::IsNullOrWhiteSpace($result.Output)) {
                'msg.exe не повернув пояснення.'
            }
            else {
                $result.Output
            }

            Write-Host (
                '[FAIL] ID {0}, {1}: код {2}. {3}' -f
                $target.SessionId,
                $target.UserName,
                $result.ExitCode,
                $details
            ) -ForegroundColor Red

            $failed++
        }
    }

    Write-Section -Title 'ПІДСУМОК'

    Write-Host "[OK] Надіслано: $sent." -ForegroundColor Green

    if ($failed -gt 0) {
        Write-Host "[WARN] Не доставлено: $failed." `
            -ForegroundColor Yellow
        Write-Host 'Відключені сеанси та сеанси без дозволу Message можуть відхиляти повідомлення.' `
            -ForegroundColor DarkGray
    }
    else {
        Write-Host '[OK] Помилок доставки не отримано.' `
            -ForegroundColor Green
    }
}
catch {
    Write-Host ''
    Write-Host '[FAIL] Не вдалося надіслати повідомлення.' `
        -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}
