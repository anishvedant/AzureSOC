# ================================================================
# AzureSOC - Active Directory Configuration Script
# ================================================================
# WHAT THIS SCRIPT DOES:
# This script turns your Windows Server into a Domain Controller and
# creates a realistic Active Directory environment with users, groups,
# and organizational units (OUs). 
#
# WHY WE NEED THIS:
# Active Directory is the backbone of most enterprise networks. Almost
# every real-world attack involves AD in some way - credential theft,
# lateral movement, privilege escalation. A SOC analyst MUST understand
# AD logs because 80%+ of the alerts you'll investigate involve AD.
#
# WHAT GETS CREATED:
# - Domain: azuresoc.local
# - OUs: SOC-Lab-Users, SOC-Lab-Admins, SOC-Lab-Servers
# - 6 regular users (for simulating normal activity)
# - 2 admin users (targets for privilege escalation attacks)
# - Security groups (IT-Team, HR-Team, Finance-Team)
# - A service account (these are commonly targeted by Kerberoasting)
#
# RUN THIS ON: vm-dc01 (connect via Azure Bastion)
# NOTE: The VM will reboot after AD DS forest creation. Wait 5 min
#       and reconnect, then run Part 2 of this script.
# ================================================================

# ── Part 1: Install AD DS and Promote to Domain Controller ──
# The server needs the AD DS "role" installed first, then we "promote"
# it to be the first DC in a brand new forest (azuresoc.local).
# A forest is the top-level AD container. A domain is inside a forest.

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AzureSOC - AD Configuration Part 1" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check if AD DS is already installed
if (Get-WindowsFeature AD-Domain-Services | Where-Object Installed) {
    Write-Host "AD DS already installed. Checking if promoted..." -ForegroundColor Yellow
    try {
        Get-ADDomain | Out-Null
        Write-Host "Already a Domain Controller! Skip to Part 2." -ForegroundColor Green
    } catch {
        Write-Host "AD DS installed but not promoted. Promoting now..." -ForegroundColor Yellow
    }
} else {
    Write-Host "[1/2] Installing AD Domain Services role..." -ForegroundColor Yellow
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
    Write-Host "  AD DS role installed" -ForegroundColor Green
}

# Promote to Domain Controller
# SafeModeAdministratorPassword = the password for Directory Services Restore Mode
# This is used when you need to boot into AD recovery mode
Write-Host "[2/2] Promoting to Domain Controller (azuresoc.local)..." -ForegroundColor Yellow
Write-Host "  The server will REBOOT after this. Wait 5 min, reconnect via Bastion," -ForegroundColor Red
Write-Host "  then run Part 2 of this script." -ForegroundColor Red
Write-Host ""

Install-ADDSForest `
    -DomainName "azuresoc.local" `
    -DomainNetbiosName "AZURESOC" `
    -SafeModeAdministratorPassword (ConvertTo-SecureString "DSRMp@ssw0rd!" -AsPlainText -Force) `
    -InstallDns:$true `
    -DatabasePath "C:\Windows\NTDS" `
    -LogPath "C:\Windows\NTDS" `
    -SysvolPath "C:\Windows\SYSVOL" `
    -Force:$true

# ================================================================
# ═══ AFTER REBOOT - RUN PART 2 BELOW ═══
# ================================================================
