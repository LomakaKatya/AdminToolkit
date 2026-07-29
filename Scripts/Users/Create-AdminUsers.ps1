#requires -version 5.1
# Creates or updates administrative accounts in two modes:
# 1) Domain mode: AD users in a selected OU + Domain Admins
# 2) Local mode: local users + local Administrators + Remote Desktop Users
#
# Runtime module for Raccoon Admin Toolkit.
# The Toolkit downloads it from Git and executes it in the current PowerShell session.

$ErrorActionPreference = 'Stop'

# =========================
# Settings
# =========================

$DefaultOUName = 'БІТ'
$CsvPath = 'C:\Admin_Accounts_Passwords.csv'

$Users = @(
    @{ Login = 'y.koshmanenko'; DisplayName = 'Koshmanenko Yaroslav' },
    @{ Login = 'a.borysonok';   DisplayName = 'Artem Borysonok' },
    @{ Login = 'm.skorokhod';   DisplayName = 'Skorokhod Mykola' },
    @{ Login = 'k.lomaka';      DisplayName = 'Lomaka Kateryna' },
    @{ Login = 'r.ignatenko';   DisplayName = 'Rodion Ignatenko' },
    @{ Login = 'o.sushko';      DisplayName = 'Oleksii Sushko' }
)

$Results = New-Object `
    -TypeName 'System.Collections.Generic.List[object]'

# =========================
# Functions
# =========================

function Test-RunAsAdmin {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        -TypeName Security.Principal.WindowsPrincipal `
        -ArgumentList $Identity

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function New-StrongPassword {
    param(
        [int]$Length = 15
    )

    if ($Length -lt 8) {
        throw 'Password length must be at least 8 characters.'
    }

    $Upper   = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $Lower   = [char[]]'abcdefghijklmnopqrstuvwxyz'
    $Digits  = [char[]]'0123456789'
    $Special = [char[]]'!@#$%^&*-_=+?'

    $FirstPool = @($Upper + $Lower + $Digits)
    $FirstChar = $FirstPool | Get-Random

    $Required = @(
        ($Upper   | Get-Random),
        ($Lower   | Get-Random),
        ($Digits  | Get-Random),
        ($Special | Get-Random)
    )

    $RemainingCount = $Length - 1 - $Required.Count
    $AllPool = @($Upper + $Lower + $Digits + $Special)
    $Remaining = @()

    for ($Index = 0; $Index -lt $RemainingCount; $Index++) {
        $Remaining += ($AllPool | Get-Random)
    }

    $Tail = @($Required + $Remaining) |
        Sort-Object {
            Get-Random
        }

    return (
        -join @($FirstChar) +
        ($Tail -join '')
    )
}

function Resolve-LocalGroupNameBySid {
    param(
        [Parameter(Mandatory)]
        [string]$Sid
    )

    try {
        $Group = Get-LocalGroup `
            -SID $Sid `
            -ErrorAction Stop

        return $Group.Name
    }
    catch {
        Write-Warning (
            "Local group with SID $Sid was not found: " +
            $_.Exception.Message
        )

        return $null
    }
}

function Add-LocalGroupMemberSafe {
    param(
        [Parameter(Mandatory)]
        [string]$GroupName,

        [Parameter(Mandatory)]
        [string]$MemberName
    )

    try {
        Add-LocalGroupMember `
            -Group $GroupName `
            -Member $MemberName `
            -ErrorAction Stop

        Write-Host (
            "[OK] Added to local group '$GroupName': $MemberName"
        )
    }
    catch {
        if ($_.Exception.Message -match 'already|уже|вже|ist bereits') {
            Write-Host (
                "[OK] Already in local group '$GroupName': $MemberName"
            )
        }
        else {
            Write-Warning (
                "Failed to add '$MemberName' to local group " +
                "'$GroupName': $($_.Exception.Message)"
            )
        }
    }
}

function Get-ServerMode {
    $ComputerSystem = Get-CimInstance `
        -ClassName Win32_ComputerSystem

    if ($ComputerSystem.PartOfDomain) {
        return 'Domain'
    }

    return 'Local'
}

function Test-ActiveDirectoryModule {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-DomainAdminsGroupIdentity {
    param(
        [Parameter(Mandatory)]
        $Domain
    )

    $DomainSid = [string]$Domain.DomainSID
    $DomainAdminsSid = "$DomainSid-512"

    try {
        $Group = Get-ADGroup `
            -Identity $DomainAdminsSid `
            -ErrorAction Stop

        return $Group.DistinguishedName
    }
    catch {
        throw (
            'Domain Admins group was not found by SID ' +
            "$DomainAdminsSid`: $($_.Exception.Message)"
        )
    }
}

function Resolve-OrCreateDomainOu {
    param(
        [Parameter(Mandatory)]
        [string]$DomainDN,

        [Parameter(Mandatory)]
        [string]$DefaultName
    )

    Write-Host ''
    Write-Host (
        'Current domain naming context: ' +
        $DomainDN
    ) -ForegroundColor DarkCyan

    Write-Host (
        'Enter an OU name or a full distinguishedName. ' +
        "Press Enter to use '$DefaultName'."
    ) -ForegroundColor Cyan

    $RequestedOU = Read-Host 'OU'

    if ([string]::IsNullOrWhiteSpace($RequestedOU)) {
        $RequestedOU = $DefaultName
    }

    $RequestedOU = $RequestedOU.Trim()

    if ($RequestedOU -match '(?i)^OU=') {
        try {
            $OU = Get-ADOrganizationalUnit `
                -Identity $RequestedOU `
                -ErrorAction Stop
        }
        catch {
            throw (
                "OU was not found: $RequestedOU. " +
                $_.Exception.Message
            )
        }

        if (
            -not $OU.DistinguishedName.EndsWith(
                ",$DomainDN",
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw (
                'The selected OU does not belong to the current domain: ' +
                $OU.DistinguishedName
            )
        }

        return $OU
    }

    $Matches = @(
        Get-ADOrganizationalUnit `
            -Filter * `
            -SearchBase $DomainDN `
            -SearchScope Subtree `
            -ErrorAction Stop |
        Where-Object {
            $_.Name -eq $RequestedOU
        }
    )

    if ($Matches.Count -eq 1) {
        return $Matches[0]
    }

    if ($Matches.Count -gt 1) {
        $DistinguishedNames = @(
            $Matches |
            Select-Object -ExpandProperty DistinguishedName
        ) -join "`r`n  "

        throw (
            "Several OUs named '$RequestedOU' were found. " +
            "Run the tool again and enter the full distinguishedName:`r`n  " +
            $DistinguishedNames
        )
    }

    Write-Host (
        "[INFO] OU '$RequestedOU' was not found. " +
        'Creating it in the domain root.'
    ) -ForegroundColor Yellow

    return New-ADOrganizationalUnit `
        -Name $RequestedOU `
        -Path $DomainDN `
        -PassThru `
        -ErrorAction Stop
}

function Add-DomainAdminMemberSafe {
    param(
        [Parameter(Mandatory)]
        [string]$GroupIdentity,

        [Parameter(Mandatory)]
        [string]$MemberIdentity
    )

    $Member = Get-ADUser `
        -Identity $MemberIdentity `
        -Properties SID `
        -ErrorAction Stop

    $AlreadyMember = @(
        Get-ADGroupMember `
            -Identity $GroupIdentity `
            -ErrorAction Stop |
        Where-Object {
            $_.SID -eq $Member.SID
        }
    ).Count -gt 0

    if ($AlreadyMember) {
        Write-Host (
            "[OK] Already in Domain Admins: $MemberIdentity"
        )

        return
    }

    Add-ADGroupMember `
        -Identity $GroupIdentity `
        -Members $Member `
        -ErrorAction Stop

    Write-Host (
        "[OK] Added to Domain Admins: $MemberIdentity"
    )
}

# =========================
# Main
# =========================

if (-not (Test-RunAsAdmin)) {
    throw 'Run this script from elevated PowerShell.'
}

$ServerMode = Get-ServerMode
$ADAvailable = Test-ActiveDirectoryModule

Write-Host "[INFO] Server mode: $ServerMode"
Write-Host "[INFO] ActiveDirectory module available: $ADAvailable"

if ($ServerMode -eq 'Domain' -and $ADAvailable) {
    Write-Host ''
    Write-Host '=== Domain mode: creating or updating AD users ===' `
        -ForegroundColor Cyan

    $Domain = Get-ADDomain -ErrorAction Stop
    $DomainDN = [string]$Domain.DistinguishedName
    $UPNSuffix = [string]$Domain.DNSRoot

    Write-Host "[INFO] Domain: $UPNSuffix"
    Write-Host "[INFO] Domain DN: $DomainDN"

    $OU = Resolve-OrCreateDomainOu `
        -DomainDN $DomainDN `
        -DefaultName $DefaultOUName

    $OUPath = [string]$OU.DistinguishedName
    $OUName = [string]$OU.Name

    Write-Host "[OK] Target OU: $OUPath" -ForegroundColor Green

    $DomainAdminsGroup = Get-DomainAdminsGroupIdentity `
        -Domain $Domain

    foreach ($User in $Users) {
        try {
            $PasswordPlain = New-StrongPassword -Length 15
            $SecurePass = ConvertTo-SecureString `
                $PasswordPlain `
                -AsPlainText `
                -Force

            $ExistingUser = Get-ADUser `
                -Filter "SamAccountName -eq '$($User.Login)'" `
                -ErrorAction SilentlyContinue

            if ($ExistingUser) {
                Set-ADAccountPassword `
                    -Identity $ExistingUser `
                    -Reset `
                    -NewPassword $SecurePass `
                    -ErrorAction Stop

                Enable-ADAccount `
                    -Identity $ExistingUser `
                    -ErrorAction SilentlyContinue

                Set-ADUser `
                    -Identity $ExistingUser `
                    -DisplayName $User.DisplayName `
                    -UserPrincipalName "$($User.Login)@$UPNSuffix" `
                    -Description 'System administrator' `
                    -ChangePasswordAtLogon $false `
                    -PasswordNeverExpires $true `
                    -ErrorAction Stop

                $Status = 'PasswordChanged'

                Write-Host (
                    "[OK] Updated AD user: $($User.Login) " +
                    "($($User.DisplayName))"
                )
            }
            else {
                New-ADUser `
                    -Name $User.DisplayName `
                    -DisplayName $User.DisplayName `
                    -SamAccountName $User.Login `
                    -UserPrincipalName "$($User.Login)@$UPNSuffix" `
                    -Description 'System administrator' `
                    -Path $OUPath `
                    -AccountPassword $SecurePass `
                    -Enabled $true `
                    -ChangePasswordAtLogon $false `
                    -PasswordNeverExpires $true `
                    -ErrorAction Stop

                $Status = 'Created'

                Write-Host (
                    "[OK] Created AD user: $($User.Login) " +
                    "($($User.DisplayName))"
                )
            }

            Add-DomainAdminMemberSafe `
                -GroupIdentity $DomainAdminsGroup `
                -MemberIdentity $User.Login

            $Results.Add(
                [pscustomobject]@{
                    Mode              = 'Domain'
                    Status            = $Status
                    DisplayName       = $User.DisplayName
                    Role              = 'System administrator'
                    Login             = $User.Login
                    UserPrincipalName = "$($User.Login)@$UPNSuffix"
                    Password          = $PasswordPlain
                    OU                = $OUPath
                    Group             = 'Domain Admins'
                }
            )
        }
        catch {
            Write-Warning (
                "Failed for '$($User.Login)': " +
                $_.Exception.Message
            )
        }
    }
}
else {
    Write-Host ''
    Write-Host '=== Local mode: creating or updating local users ===' `
        -ForegroundColor Cyan

    $LocalAdminsGroup = Resolve-LocalGroupNameBySid `
        -Sid 'S-1-5-32-544'

    $RdpUsersGroup = Resolve-LocalGroupNameBySid `
        -Sid 'S-1-5-32-555'

    if (-not $LocalAdminsGroup) {
        throw 'Local Administrators group was not found.'
    }

    if (-not $RdpUsersGroup) {
        Write-Warning (
            'Remote Desktop Users group was not found. ' +
            'Users will be added only to local Administrators.'
        )
    }

    foreach ($User in $Users) {
        try {
            $PasswordPlain = New-StrongPassword -Length 15
            $SecurePass = ConvertTo-SecureString `
                $PasswordPlain `
                -AsPlainText `
                -Force

            $ExistingUser = Get-LocalUser `
                -Name $User.Login `
                -ErrorAction SilentlyContinue

            if ($ExistingUser) {
                Set-LocalUser `
                    -Name $User.Login `
                    -Password $SecurePass `
                    -FullName $User.DisplayName `
                    -Description 'System administrator' `
                    -PasswordNeverExpires $true `
                    -ErrorAction Stop

                Enable-LocalUser `
                    -Name $User.Login `
                    -ErrorAction SilentlyContinue

                $Status = 'PasswordChanged'

                Write-Host (
                    "[OK] Updated local user: $($User.Login) " +
                    "($($User.DisplayName))"
                )
            }
            else {
                New-LocalUser `
                    -Name $User.Login `
                    -FullName $User.DisplayName `
                    -Description 'System administrator' `
                    -Password $SecurePass `
                    -PasswordNeverExpires `
                    -UserMayNotChangePassword:$false `
                    -ErrorAction Stop |
                Out-Null

                $Status = 'Created'

                Write-Host (
                    "[OK] Created local user: $($User.Login) " +
                    "($($User.DisplayName))"
                )
            }

            Add-LocalGroupMemberSafe `
                -GroupName $LocalAdminsGroup `
                -MemberName $User.Login

            if ($RdpUsersGroup) {
                Add-LocalGroupMemberSafe `
                    -GroupName $RdpUsersGroup `
                    -MemberName $User.Login
            }

            $GroupText = $LocalAdminsGroup

            if ($RdpUsersGroup) {
                $GroupText = "$LocalAdminsGroup; $RdpUsersGroup"
            }

            $Results.Add(
                [pscustomobject]@{
                    Mode              = 'Local'
                    Status            = $Status
                    DisplayName       = $User.DisplayName
                    Role              = 'System administrator'
                    Login             = $User.Login
                    UserPrincipalName = ''
                    Password          = $PasswordPlain
                    OU                = '-'
                    Group             = $GroupText
                }
            )
        }
        catch {
            Write-Warning (
                "Failed for '$($User.Login)': " +
                $_.Exception.Message
            )
        }
    }
}

if ($Results.Count -gt 0) {
    $Results |
        Export-Csv `
            -LiteralPath $CsvPath `
            -NoTypeInformation `
            -Encoding UTF8 `
            -Force

    Write-Host ''
    Write-Host (
        '[OK] Done. Current passwords saved to: ' +
        $CsvPath
    ) -ForegroundColor Green
}
else {
    Write-Host ''
    Write-Warning 'No accounts were processed. CSV was not updated.'
}
