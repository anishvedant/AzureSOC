# ================================================================
# AzureSOC - Active Directory Configuration Part 2
# ================================================================
# RUN THIS AFTER THE DC HAS REBOOTED FROM PART 1.
# This creates the realistic user environment for attack simulation.
#
# WHY THESE SPECIFIC USERS AND GROUPS:
# - Regular users generate "normal" login activity in your SIEM
# - Admin accounts are targets for privilege escalation attacks
# - Service accounts are targets for Kerberoasting (T1558.003)
# - Groups help you test group-based access control and lateral movement
# ================================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AzureSOC - AD Configuration Part 2" -ForegroundColor Cyan
Write-Host "  Creating Users, Groups, and OUs" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ── Create Organizational Units ──
# OUs are folders in AD that organize users/computers.
# They also let you apply Group Policies to specific sets of objects.
Write-Host "[1/5] Creating Organizational Units..." -ForegroundColor Yellow
$OUs = @("SOC-Lab-Users", "SOC-Lab-Admins", "SOC-Lab-Servers", "SOC-Lab-ServiceAccounts")
foreach ($ou in $OUs) {
    try {
        New-ADOrganizationalUnit -Name $ou -Path "DC=azuresoc,DC=local" -ErrorAction Stop
        Write-Host "  Created OU: $ou" -ForegroundColor Green
    } catch {
        Write-Host "  OU $ou already exists, skipping" -ForegroundColor Gray
    }
}

# ── Create Security Groups ──
# Groups control who can access what. In attacks, we look for
# group membership changes (an attacker adding themselves to Domain Admins).
Write-Host "[2/5] Creating Security Groups..." -ForegroundColor Yellow
$groups = @(
    @{Name="IT-Team"; Desc="IT Department staff"},
    @{Name="HR-Team"; Desc="Human Resources staff"},
    @{Name="Finance-Team"; Desc="Finance Department staff"},
    @{Name="SOC-Analysts"; Desc="Security Operations Center analysts"},
    @{Name="Server-Admins"; Desc="Server administrators with elevated access"}
)
foreach ($g in $groups) {
    try {
        New-ADGroup -Name $g.Name -GroupScope Global -GroupCategory Security `
            -Path "OU=SOC-Lab-Users,DC=azuresoc,DC=local" `
            -Description $g.Desc -ErrorAction Stop
        Write-Host "  Created group: $($g.Name)" -ForegroundColor Green
    } catch {
        Write-Host "  Group $($g.Name) already exists, skipping" -ForegroundColor Gray
    }
}

# ── Create Regular Users ──
# These simulate real employees. Their login patterns create
# baseline "normal" activity that makes malicious activity detectable.
Write-Host "[3/5] Creating Regular Users..." -ForegroundColor Yellow
$userPassword = ConvertTo-SecureString "User@1234" -AsPlainText -Force
$users = @(
    @{First="John"; Last="Smith"; Sam="jsmith"; Group="IT-Team"},
    @{First="Sarah"; Last="Connor"; Sam="sconnor"; Group="IT-Team"},
    @{First="Mike"; Last="Jones"; Sam="mjones"; Group="HR-Team"},
    @{First="Emily"; Last="Davis"; Sam="edavis"; Group="Finance-Team"},
    @{First="James"; Last="Wilson"; Sam="jwilson"; Group="SOC-Analysts"},
    @{First="Lisa"; Last="Brown"; Sam="lbrown"; Group="Finance-Team"}
)
foreach ($u in $users) {
    try {
        New-ADUser `
            -Name "$($u.First) $($u.Last)" `
            -GivenName $u.First `
            -Surname $u.Last `
            -SamAccountName $u.Sam `
            -UserPrincipalName "$($u.Sam)@azuresoc.local" `
            -Path "OU=SOC-Lab-Users,DC=azuresoc,DC=local" `
            -AccountPassword $userPassword `
            -Enabled $true `
            -ChangePasswordAtLogon $false `
            -PasswordNeverExpires $true `
            -ErrorAction Stop
        Add-ADGroupMember -Identity $u.Group -Members $u.Sam
        Write-Host "  Created user: $($u.Sam) -> $($u.Group)" -ForegroundColor Green
    } catch {
        Write-Host "  User $($u.Sam) already exists, skipping" -ForegroundColor Gray
    }
}

# ── Create Admin Users ──
# These are high-value targets. In a real attack:
# - admin.backup is the "low-hanging fruit" domain admin
# - svc.sql is a Kerberoastable service account (has an SPN)
Write-Host "[4/5] Creating Admin and Service Accounts..." -ForegroundColor Yellow

# Domain Admin (target for credential theft)
try {
    New-ADUser -Name "Admin Backup" -SamAccountName "admin.backup" `
        -UserPrincipalName "admin.backup@azuresoc.local" `
        -Path "OU=SOC-Lab-Admins,DC=azuresoc,DC=local" `
        -AccountPassword (ConvertTo-SecureString "B@ckup2024!" -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true -ErrorAction Stop
    Add-ADGroupMember -Identity "Domain Admins" -Members "admin.backup"
    Add-ADGroupMember -Identity "Server-Admins" -Members "admin.backup"
    Write-Host "  Created: admin.backup (Domain Admin) - TARGET for attacks!" -ForegroundColor Red
} catch { Write-Host "  admin.backup already exists" -ForegroundColor Gray }

# Server Admin (secondary target)
try {
    New-ADUser -Name "Server Admin" -SamAccountName "srv.admin" `
        -UserPrincipalName "srv.admin@azuresoc.local" `
        -Path "OU=SOC-Lab-Admins,DC=azuresoc,DC=local" `
        -AccountPassword (ConvertTo-SecureString "SrvAdm1n!" -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true -ErrorAction Stop
    Add-ADGroupMember -Identity "Server-Admins" -Members "srv.admin"
    Write-Host "  Created: srv.admin (Server Admin)" -ForegroundColor Green
} catch { Write-Host "  srv.admin already exists" -ForegroundColor Gray }

# Service Account with SPN (Kerberoastable!)
# WHY: Service accounts with SPNs are targets for Kerberoasting.
# An attacker can request a Kerberos ticket for this SPN and crack
# the password offline. This is one of the most common AD attacks.
try {
    New-ADUser -Name "SQL Service" -SamAccountName "svc.sql" `
        -UserPrincipalName "svc.sql@azuresoc.local" `
        -Path "OU=SOC-Lab-ServiceAccounts,DC=azuresoc,DC=local" `
        -AccountPassword (ConvertTo-SecureString "SQLsvc2024!" -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true -ErrorAction Stop
    # Set SPN - this makes it Kerberoastable
    Set-ADUser -Identity "svc.sql" -ServicePrincipalNames @{Add="MSSQLSvc/dc01.azuresoc.local:1433"}
    Write-Host "  Created: svc.sql (Service Account with SPN - Kerberoastable!)" -ForegroundColor Red
} catch { Write-Host "  svc.sql already exists" -ForegroundColor Gray }

# ── Enable Auditing via Group Policy ──
# WHY: Windows doesn't log everything by default. We need to enable
# "Advanced Audit Policies" so that actions like logon events, process
# creation, and privilege use are captured in the Security Event Log.
# Without this, your SIEM has nothing useful to analyze.
Write-Host "[5/5] Configuring Audit Policies..." -ForegroundColor Yellow

# Enable command-line logging in process creation events
# This is CRITICAL - without it, you can't see what commands attackers run
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" /v ProcessCreationIncludeCmdLine_Enabled /t REG_DWORD /d 1 /f

# Enable PowerShell Script Block Logging
# This captures the FULL text of every PowerShell command/script
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" /v EnableScriptBlockLogging /t REG_DWORD /d 1 /f

# Enable PowerShell Module Logging
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" /v EnableModuleLogging /t REG_DWORD /d 1 /f

Write-Host "  Audit policies configured" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AD Configuration Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Domain: azuresoc.local" -ForegroundColor White
Write-Host "  Users:  6 regular + 2 admin + 1 service" -ForegroundColor White
Write-Host "  Groups: IT-Team, HR-Team, Finance-Team, SOC-Analysts, Server-Admins" -ForegroundColor White
Write-Host ""
Write-Host "  NEXT: Join vm-workstation01 to the domain:" -ForegroundColor Yellow
Write-Host "  Add-Computer -DomainName 'azuresoc.local' -Credential (Get-Credential) -Restart" -ForegroundColor Gray
Write-Host "  Use: AZURESOC\azuresocadmin when prompted" -ForegroundColor Gray
