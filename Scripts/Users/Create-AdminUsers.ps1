#requires -version 5.1
# Create-AdminUsers-Universal.ps1
# Creates admin users in two modes:
# 1) Domain mode: AD users in OU + Domain Admins
# 2) Local mode: local users + local Administrators + Remote Desktop Users
#
# Runtime module for Raccoon Admin Toolkit.
# The Toolkit downloads it from Git and executes it in the current PowerShell session.

$ErrorActionPreference = 'Stop'

# =========================
# Settings
# =========================

$DomainDN  = "DC=resurs,DC=lan"
$OUName    = "БІТ"
$UPNSuffix = "shik.local"

$CsvPath = "C:\Admin_Accounts_Passwords.csv"
$Results = @()

$Users = @(
    @{ Login = "y.koshmanenko"; DisplayName = "Koshmanenko Yaroslav" },
    @{ Login = "a.borysonok";   DisplayName = "Artem Borysonok" },
    @{ Login = "m.skorokhod";   DisplayName = "Skorokhod Mykola" },
    @{ Login = "k.lomaka";      DisplayName = "Lomaka Kateryna" },
    @{ Login = "r.ignatenko";   DisplayName = "Rodion Ignatenko" },
    @{ Login = "o.sushko";      DisplayName = "Оleksii Sushko" }
)

# =========================
# Functions
# =========================

function Test-RunAsAdmin {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-StrongPassword {
    param(
        [int]$Length = 15
    )

    if ($Length -lt 8) {
        throw "Password length must be at least 8 characters."
    }

    $Upper   = [char[]]"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    $Lower   = [char[]]"abcdefghijklmnopqrstuvwxyz"
    $Digits  = [char[]]"0123456789"
    $Special = [char[]]"!@#$%^&*-_=+?"

    # First character is not special.
    $FirstPool = @($Upper + $Lower + $Digits)
    $FirstChar = $FirstPool | Get-Random

    # Guarantee all required categories.
    $Required = @(
        ($Upper   | Get-Random),
        ($Lower   | Get-Random),
        ($Digits  | Get-Random),
        ($Special | Get-Random)
    )

    $RemainingCount = $Length - 1 - $Required.Count
    $AllPool = @($Upper + $Lower + $Digits + $Special)
    $Remaining = @()

    for ($i = 0; $i -lt $RemainingCount; $i++) {
        $Remaining += ($AllPool | Get-Random)
    }

    $Tail = @($Required + $Remaining) | Sort-Object { Get-Random }

    return (-join @($FirstChar) + ($Tail -join ""))
}

function Resolve-LocalGroupNameBySid {
    param(
        [Parameter(Mandatory)]
        [string]$Sid
    )

    try {
        $Group = Get-LocalGroup -SID $Sid -ErrorAction Stop
        return $Group.Name
    }
    catch {
        Write-Warning "Local group with SID $Sid was not found: $($_.Exception.Message)"
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
        Add-LocalGroupMember -Group $GroupName -Member $MemberName -ErrorAction Stop
        Write-Host "[OK] Added to local group '$GroupName': $MemberName"
    }
    catch {
        if ($_.Exception.Message -match 'already|уже|вже|ist bereits') {
            Write-Host "[OK] Already in local group '$GroupName': $MemberName"
        }
        else {
            Write-Warning "Failed to add '$MemberName' to local group '$GroupName': $($_.Exception.Message)"
        }
    }
}

function Get-ServerMode {
    $ComputerSystem = Get-CimInstance Win32_ComputerSystem

    if ($ComputerSystem.PartOfDomain) {
        return "Domain"
    }

    return "Local"
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
    # Prefer the localized name used in your original script.
    $Candidates = @(
        "Администраторы домена",
        "Domain Admins"
    )

    foreach ($Candidate in $Candidates) {
        try {
            $Group = Get-ADGroup -Identity $Candidate -ErrorAction Stop
            return $Group.DistinguishedName
        }
        catch {
            # Try next candidate.
        }
    }

    throw "Domain Admins group was not found by common names."
}

# =========================
# Main
# =========================

if (-not (Test-RunAsAdmin)) {
    throw "Run this script from elevated PowerShell."
}

$ServerMode = Get-ServerMode
$ADAvailable = Test-ActiveDirectoryModule

Write-Host "[INFO] Server mode: $ServerMode"
Write-Host "[INFO] ActiveDirectory module available: $ADAvailable"

if ($ServerMode -eq "Domain" -and $ADAvailable) {
    Write-Host ""
    Write-Host "=== Domain mode: creating AD users ===" -ForegroundColor Cyan

    $OUPath = "OU=$OUName,$DomainDN"

    try {
        $OUExists = Get-ADOrganizationalUnit -LDAPFilter "(ou=$OUName)" -SearchBase $DomainDN -ErrorAction SilentlyContinue

        if (-not $OUExists) {
            New-ADOrganizationalUnit -Name $OUName -Path $DomainDN
            Write-Host "[OK] OU created: $OUName"
        }
        else {
            Write-Host "[OK] OU already exists: $OUName"
        }
    }
    catch {
        throw "Failed to check or create OU '$OUName': $($_.Exception.Message)"
    }

    $DomainAdminsGroup = Get-DomainAdminsGroupIdentity

    foreach ($User in $Users) {
        try {
            $ExistingUser = Get-ADUser -Filter "SamAccountName -eq '$($User.Login)'" -ErrorAction SilentlyContinue

            if ($ExistingUser) {
                Write-Warning "AD user already exists, skipping: $($User.Login)"
                continue
            }

            $PasswordPlain = New-StrongPassword -Length 15
            $SecurePass = ConvertTo-SecureString $PasswordPlain -AsPlainText -Force

            New-ADUser `
                -Name $User.DisplayName `
                -DisplayName $User.DisplayName `
                -SamAccountName $User.Login `
                -UserPrincipalName "$($User.Login)@$UPNSuffix" `
                -Description "System administrator" `
                -Path $OUPath `
                -AccountPassword $SecurePass `
                -Enabled $true `
                -ChangePasswordAtLogon $false `
                -PasswordNeverExpires $true `
                -PassThru | Out-Null

            Add-ADGroupMember -Identity $DomainAdminsGroup -Members $User.Login -ErrorAction Stop

            $Results += [PSCustomObject]@{
                Mode        = "Domain"
                DisplayName = $User.DisplayName
                Role        = "System administrator"
                Login       = $User.Login
                Password    = $PasswordPlain
                OU          = $OUName
                Group       = "Domain Admins"
            }

            Write-Host "[OK] Created AD user: $($User.Login) ($($User.DisplayName))"
        }
        catch {
            Write-Error "Failed for '$($User.Login)': $($_.Exception.Message)"
        }
    }
}
else {
    Write-Host ""
    Write-Host "=== Local mode: creating local users ===" -ForegroundColor Cyan

    # Built-in local groups:
    # S-1-5-32-544 = Administrators
    # S-1-5-32-555 = Remote Desktop Users

    $LocalAdminsGroup = Resolve-LocalGroupNameBySid -Sid 'S-1-5-32-544'
    $RdpUsersGroup = Resolve-LocalGroupNameBySid -Sid 'S-1-5-32-555'

    if (-not $LocalAdminsGroup) {
        throw "Local Administrators group was not found."
    }

    if (-not $RdpUsersGroup) {
        Write-Warning "Remote Desktop Users group was not found. Users will be added only to local Administrators."
    }

    foreach ($User in $Users) {
        try {
            $ExistingUser = Get-LocalUser -Name $User.Login -ErrorAction SilentlyContinue

            if ($ExistingUser) {
                Write-Warning "Local user already exists, skipping: $($User.Login)"
                continue
            }

            $PasswordPlain = New-StrongPassword -Length 15
            $SecurePass = ConvertTo-SecureString $PasswordPlain -AsPlainText -Force

            New-LocalUser `
                -Name $User.Login `
                -FullName $User.DisplayName `
                -Description "System administrator" `
                -Password $SecurePass `
                -PasswordNeverExpires `
                -UserMayNotChangePassword:$false | Out-Null

            Add-LocalGroupMemberSafe -GroupName $LocalAdminsGroup -MemberName $User.Login

            if ($RdpUsersGroup) {
                Add-LocalGroupMemberSafe -GroupName $RdpUsersGroup -MemberName $User.Login
            }

            $Results += [PSCustomObject]@{
                Mode        = "Local"
                DisplayName = $User.DisplayName
                Role        = "System administrator"
                Login       = $User.Login
                Password    = $PasswordPlain
                OU          = "-"
                Group       = "$LocalAdminsGroup; $RdpUsersGroup"
            }

            Write-Host "[OK] Created local user: $($User.Login) ($($User.DisplayName))"
        }
        catch {
            Write-Error "Failed for '$($User.Login)': $($_.Exception.Message)"
        }
    }
}

if ($Results.Count -gt 0) {
    $Results | Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "[OK] Done. Passwords saved to: $CsvPath" -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Warning "No new users created. CSV was not updated."
}
