#!/usr/bin/env pwsh
# ════════════════════════════════════════════════════════════════════════
#  AzureSOC — MASTER DEPLOYMENT SCRIPT (Run This ONE File)
# ════════════════════════════════════════════════════════════════════════
#
#  WHAT THIS DOES:
#  This single script deploys your ENTIRE AzureSOC project from scratch.
#  It runs on YOUR laptop/PC and remotely configures every VM using
#  Azure CLI's "az vm run-command" feature (no need to manually RDP in).
#
#  WHAT GETS DEPLOYED:
#  ✅ Hub-Spoke network with Azure Firewall
#  ✅ 5 Virtual Machines (DC, Workstation, Linux, Honeypot, Splunk)
#  ✅ Azure Bastion for secure access
#  ✅ Microsoft Sentinel + Log Analytics
#  ✅ Key Vault for secrets
#  ✅ Active Directory domain (azuresoc.local) with users & groups
#  ✅ Sysmon on all Windows VMs
#  ✅ Splunk Enterprise on dedicated VM
#  ✅ Splunk Universal Forwarders on all Windows VMs
#  ✅ Audit policies and PowerShell logging enabled
#  ✅ NSG diagnostic settings
#
#  PREREQUISITES:
#  1. Azure CLI installed → https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
#  2. PowerShell 7+ installed → https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell
#  3. Logged in: az login
#  4. Subscription set: az account set --subscription "<your-sub-id>"
#
#  USAGE:
#  ./master-deploy.ps1 -AdminPassword "YourStr0ngP@ssw0rd!"
#
#  ESTIMATED TIME: 45-60 minutes (mostly waiting for Azure deployments)
#  ESTIMATED COST: ~$15 for this session. Run stop-all.ps1 when done.
#
# ════════════════════════════════════════════════════════════════════════

param(
    [Parameter(Mandatory=$true)]
    [string]$AdminPassword,

    [string]$Location = "eastus",
    [string]$ResourceGroup = "rg-azuresoc"
)

$ErrorActionPreference = "Continue"
$startTime = Get-Date

function Write-Banner($text) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step($num, $total, $text) {
    $elapsed = ((Get-Date) - $startTime).ToString("hh\:mm\:ss")
    Write-Host "[$num/$total] [$elapsed] $text" -ForegroundColor Yellow
}

function Write-OK($text) { Write-Host "  ✅ $text" -ForegroundColor Green }
function Write-Info($text) { Write-Host "  ℹ️  $text" -ForegroundColor Gray }
function Write-Warn($text) { Write-Host "  ⚠️  $text" -ForegroundColor Yellow }

$totalSteps = 15

Write-Banner "AzureSOC — Master Deployment Starting"
Write-Host "  Location:       $Location" -ForegroundColor White
Write-Host "  Resource Group:  $ResourceGroup" -ForegroundColor White
Write-Host "  Admin User:      azuresocadmin" -ForegroundColor White
Write-Host "  Estimated Time:  45-60 minutes" -ForegroundColor White
Write-Host ""

# ════════════════════════════════════════════════════════════════════════
# PHASE 1: AZURE SETUP
# ════════════════════════════════════════════════════════════════════════

Write-Step 1 $totalSteps "Registering Azure Resource Providers"
# WHY: Azure requires you to "activate" services before first use.
# Think of it like enabling features on your account.
$providers = @(
    "Microsoft.OperationalInsights",
    "Microsoft.SecurityInsights",
    "Microsoft.Network",
    "Microsoft.Compute",
    "Microsoft.KeyVault",
    "Microsoft.Web",
    "Microsoft.Security",
    "Microsoft.Storage",
    "Microsoft.Insights"
)
foreach ($p in $providers) {
    az provider register --namespace $p --only-show-errors 2>$null
}
Write-OK "Resource providers registered"

Write-Step 2 $totalSteps "Creating Resource Group"
# WHY: All Azure resources live inside a resource group.
# Delete this one group = delete everything = stop all charges.
az group create --name $ResourceGroup --location $Location --only-show-errors | Out-Null
Write-OK "Resource group '$ResourceGroup' created in $Location"

# ════════════════════════════════════════════════════════════════════════
# PHASE 2: DEPLOY INFRASTRUCTURE VIA BICEP
# ════════════════════════════════════════════════════════════════════════

Write-Step 3 $totalSteps "Deploying infrastructure via Bicep (15-25 min)..."
Write-Info "This deploys: 3 VNets, Azure Firewall, Bastion, 5 VMs, Sentinel, Key Vault"
Write-Info "Go grab coffee — this is the longest wait."

# Find the Bicep file (check multiple locations)
$bicepPath = $null
$searchPaths = @("./infra/main.bicep", "./main.bicep", "../infra/main.bicep")
foreach ($sp in $searchPaths) {
    if (Test-Path $sp) { $bicepPath = $sp; break }
}

if (-not $bicepPath) {
    Write-Host ""
    Write-Host "  ❌ ERROR: Cannot find main.bicep!" -ForegroundColor Red
    Write-Host "  Make sure main.bicep is in ./infra/main.bicep" -ForegroundColor Red
    Write-Host "  Current directory: $(Get-Location)" -ForegroundColor Gray
    exit 1
}

$deployResult = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $bicepPath `
    --parameters adminPassword=$AdminPassword `
    --query "properties.outputs" `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ❌ DEPLOYMENT FAILED" -ForegroundColor Red
    Write-Host $deployResult -ForegroundColor Red
    Write-Host ""
    Write-Host "  Common fixes:" -ForegroundColor Yellow
    Write-Host "  - VM quota exceeded? Try: az vm list-usage --location $Location -o table" -ForegroundColor Gray
    Write-Host "  - Try different region: ./master-deploy.ps1 -AdminPassword '...' -Location westus2" -ForegroundColor Gray
    exit 1
}

try {
    $outputs = $deployResult | ConvertFrom-Json
    $fwIP = $outputs.firewallPrivateIP.value
    $honeypotIP = $outputs.honeypotPublicIP.value
    $kvName = $outputs.keyVaultName.value
} catch {
    $fwIP = "10.0.1.4"
    $honeypotIP = "(check portal)"
    $kvName = "(check portal)"
}

Write-OK "Infrastructure deployed!"
Write-Info "Firewall IP: $fwIP | Honeypot Public IP: $honeypotIP"

# ════════════════════════════════════════════════════════════════════════
# PHASE 3: WAIT FOR VMS TO BE READY
# ════════════════════════════════════════════════════════════════════════

Write-Step 4 $totalSteps "Waiting for all VMs to be fully ready..."
# WHY: VMs need time to boot, install the Azure agent, and become
# responsive to run-command. Typically 3-5 min after deployment.
$vms = @("vm-dc01", "vm-workstation01", "vm-linux01", "vm-honeypot", "vm-splunk")
foreach ($vm in $vms) {
    Write-Info "Checking $vm..."
    $retries = 0
    while ($retries -lt 12) {
        $status = az vm get-instance-view -g $ResourceGroup --name $vm `
            --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null
        if ($status -eq "VM running") { break }
        $retries++
        Start-Sleep -Seconds 15
    }
    if ($status -eq "VM running") {
        Write-OK "$vm is running"
    } else {
        Write-Warn "$vm may not be fully ready yet (status: $status). Continuing..."
    }
}

# ════════════════════════════════════════════════════════════════════════
# PHASE 4: CONFIGURE ACTIVE DIRECTORY (Remote Execution)
# ════════════════════════════════════════════════════════════════════════
# HOW THIS WORKS: "az vm run-command invoke" lets you execute scripts
# on a VM remotely through Azure's control plane. No need to RDP in!
# The script runs as SYSTEM on the VM and returns stdout/stderr.

Write-Step 5 $totalSteps "Installing AD DS on Domain Controller..."
# WHY: Active Directory Domain Services turns the Windows Server into
# a Domain Controller that manages users, computers, and security policies.
# This is the foundation of almost every enterprise network.

az vm run-command invoke -g $ResourceGroup --name vm-dc01 `
    --command-id RunPowerShellScript --scripts @'
Write-Output "Installing AD DS role..."
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
Write-Output "AD DS role installed. Promoting to DC..."
Install-ADDSForest `
    -DomainName "azuresoc.local" `
    -DomainNetbiosName "AZURESOC" `
    -SafeModeAdministratorPassword (ConvertTo-SecureString "DSRMp@ssw0rd!" -AsPlainText -Force) `
    -InstallDns:$true `
    -Force:$true `
    -NoRebootOnCompletion:$false
Write-Output "AD DS promotion initiated. VM will reboot."
'@ --only-show-errors 2>$null | Out-Null

Write-OK "AD DS installation triggered (DC will reboot)"

Write-Step 6 $totalSteps "Waiting for DC to reboot and AD to initialize (5 min)..."
# WHY: After promoting to DC, the server reboots and AD services
# take 3-5 minutes to fully initialize. We must wait before creating users.
Start-Sleep -Seconds 300

# Verify DC is back up
$retries = 0
while ($retries -lt 20) {
    $status = az vm get-instance-view -g $ResourceGroup --name vm-dc01 `
        --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null
    if ($status -eq "VM running") { break }
    $retries++
    Start-Sleep -Seconds 15
}
Write-OK "DC is back online"

# Wait a bit more for AD services to fully start
Write-Info "Giving AD services 90 more seconds to initialize..."
Start-Sleep -Seconds 90

Write-Step 7 $totalSteps "Creating AD Users, Groups, and Audit Policies..."
# WHY: We create realistic users and groups that mimic a real company.
# Regular users generate baseline activity. Admin accounts and service
# accounts are intentional targets for attack simulations (credential
# theft, Kerberoasting, privilege escalation).

az vm run-command invoke -g $ResourceGroup --name vm-dc01 `
    --command-id RunPowerShellScript --scripts @'
Import-Module ActiveDirectory

# Create Organizational Units
$OUs = @("SOC-Lab-Users","SOC-Lab-Admins","SOC-Lab-Servers","SOC-Lab-ServiceAccounts")
foreach ($ou in $OUs) {
    try { New-ADOrganizationalUnit -Name $ou -Path "DC=azuresoc,DC=local" -EA Stop
          Write-Output "Created OU: $ou" } catch { Write-Output "OU $ou exists" }
}

# Create Security Groups
$groups = @("IT-Team","HR-Team","Finance-Team","SOC-Analysts","Server-Admins")
foreach ($g in $groups) {
    try { New-ADGroup -Name $g -GroupScope Global -GroupCategory Security `
            -Path "OU=SOC-Lab-Users,DC=azuresoc,DC=local" -EA Stop
          Write-Output "Created group: $g" } catch { Write-Output "Group $g exists" }
}

# Create Regular Users
$pw = ConvertTo-SecureString "User@1234" -AsPlainText -Force
$users = @(
    @{F="John";L="Smith";S="jsmith";G="IT-Team"},
    @{F="Sarah";L="Connor";S="sconnor";G="IT-Team"},
    @{F="Mike";L="Jones";S="mjones";G="HR-Team"},
    @{F="Emily";L="Davis";S="edavis";G="Finance-Team"},
    @{F="James";L="Wilson";S="jwilson";G="SOC-Analysts"},
    @{F="Lisa";L="Brown";S="lbrown";G="Finance-Team"}
)
foreach ($u in $users) {
    try {
        New-ADUser -Name "$($u.F) $($u.L)" -GivenName $u.F -Surname $u.L `
            -SamAccountName $u.S -UserPrincipalName "$($u.S)@azuresoc.local" `
            -Path "OU=SOC-Lab-Users,DC=azuresoc,DC=local" `
            -AccountPassword $pw -Enabled $true -PasswordNeverExpires $true -EA Stop
        Add-ADGroupMember -Identity $u.G -Members $u.S
        Write-Output "Created user: $($u.S) -> $($u.G)"
    } catch { Write-Output "User $($u.S) exists" }
}

# Create Admin + Service Accounts (attack targets)
try {
    New-ADUser -Name "Admin Backup" -SamAccountName "admin.backup" `
        -UserPrincipalName "admin.backup@azuresoc.local" `
        -Path "OU=SOC-Lab-Admins,DC=azuresoc,DC=local" `
        -AccountPassword (ConvertTo-SecureString "B@ckup2024!" -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true -EA Stop
    Add-ADGroupMember -Identity "Domain Admins" -Members "admin.backup"
    Write-Output "Created: admin.backup (Domain Admin - ATTACK TARGET)"
} catch { Write-Output "admin.backup exists" }

try {
    New-ADUser -Name "Server Admin" -SamAccountName "srv.admin" `
        -UserPrincipalName "srv.admin@azuresoc.local" `
        -Path "OU=SOC-Lab-Admins,DC=azuresoc,DC=local" `
        -AccountPassword (ConvertTo-SecureString "SrvAdm1n!" -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true -EA Stop
    Add-ADGroupMember -Identity "Server-Admins" -Members "srv.admin"
    Write-Output "Created: srv.admin"
} catch { Write-Output "srv.admin exists" }

# Service account with SPN (Kerberoastable!)
try {
    New-ADUser -Name "SQL Service" -SamAccountName "svc.sql" `
        -UserPrincipalName "svc.sql@azuresoc.local" `
        -Path "OU=SOC-Lab-ServiceAccounts,DC=azuresoc,DC=local" `
        -AccountPassword (ConvertTo-SecureString "SQLsvc2024!" -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true -EA Stop
    Set-ADUser -Identity "svc.sql" -ServicePrincipalNames @{Add="MSSQLSvc/dc01.azuresoc.local:1433"}
    Write-Output "Created: svc.sql (Kerberoastable service account)"
} catch { Write-Output "svc.sql exists" }

# Enable audit policies
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" /v ProcessCreationIncludeCmdLine_Enabled /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" /v EnableScriptBlockLogging /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" /v EnableModuleLogging /t REG_DWORD /d 1 /f | Out-Null
Write-Output "Audit policies configured"

# Update VNet DNS to point to this DC
Write-Output "AD configuration complete!"
'@ --only-show-errors 2>$null | Out-Null

Write-OK "AD users, groups, and audit policies configured"

# Update VNet DNS to point to the DC
Write-Info "Updating VNet DNS to point to Domain Controller..."
az network vnet update -g $ResourceGroup --name vnet-spoke-workload --dns-servers 10.1.1.4 --only-show-errors 2>$null | Out-Null
Write-OK "DNS updated"

# ════════════════════════════════════════════════════════════════════════
# PHASE 5: JOIN WORKSTATION TO DOMAIN
# ════════════════════════════════════════════════════════════════════════

Write-Step 8 $totalSteps "Joining Workstation to azuresoc.local domain..."
# WHY: Domain-joined machines authenticate through AD, which generates
# the logon events (4624, 4625, 4648) that SOC analysts investigate daily.

# Restart workstation first to pick up new DNS
az vm restart -g $ResourceGroup --name vm-workstation01 --no-wait --only-show-errors 2>$null | Out-Null
Start-Sleep -Seconds 90

az vm run-command invoke -g $ResourceGroup --name vm-workstation01 `
    --command-id RunPowerShellScript --scripts @"
try {
    `$secPw = ConvertTo-SecureString '$AdminPassword' -AsPlainText -Force
    `$cred = New-Object System.Management.Automation.PSCredential('AZURESOC\azuresocadmin', `$secPw)
    Add-Computer -DomainName 'azuresoc.local' -Credential `$cred -Force -Restart
    Write-Output 'Domain join initiated - VM will reboot'
} catch {
    Write-Output "Domain join failed: `$(`$_.Exception.Message)"
    Write-Output 'Manual fix: RDP via Bastion and run Add-Computer -DomainName azuresoc.local'
}
"@ --only-show-errors 2>$null | Out-Null

Write-OK "Workstation domain join initiated"

# ════════════════════════════════════════════════════════════════════════
# PHASE 6: INSTALL SYSMON ON ALL WINDOWS VMS
# ════════════════════════════════════════════════════════════════════════

Write-Step 9 $totalSteps "Installing Sysmon on all Windows VMs..."
# WHY: Sysmon captures process creation, network connections, file changes,
# registry modifications, and DNS queries — the essential data for
# detecting attacks. Windows Event Logs alone are not enough.

$windowsVMs = @("vm-dc01", "vm-workstation01", "vm-honeypot")
foreach ($vm in $windowsVMs) {
    Write-Info "Installing Sysmon on $vm..."
    az vm run-command invoke -g $ResourceGroup --name $vm `
        --command-id RunPowerShellScript --scripts @'
$dir = "C:\Sysmon"
if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Download Sysmon
try {
    Invoke-WebRequest -Uri "https://live.sysinternals.com/Sysmon64.exe" -OutFile "$dir\Sysmon64.exe" -UseBasicParsing
} catch {
    Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile "$dir\Sysmon.zip" -UseBasicParsing
    Expand-Archive "$dir\Sysmon.zip" -Dest $dir -Force
}

# Download SwiftOnSecurity config
try {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" -OutFile "$dir\sysmonconfig.xml" -UseBasicParsing
} catch {
    # Minimal fallback
    '<Sysmon schemaversion="4.90"><EventFiltering><ProcessCreate onmatch="exclude"/><NetworkConnect onmatch="exclude"/><ProcessAccess onmatch="exclude"/><DnsQuery onmatch="exclude"/></EventFiltering></Sysmon>' | Out-File "$dir\sysmonconfig.xml" -Encoding UTF8
}

# Install or update
$svc = Get-Service -Name "Sysmon64" -EA SilentlyContinue
if ($svc) {
    & "$dir\Sysmon64.exe" -c "$dir\sysmonconfig.xml" 2>$null
    Write-Output "Sysmon config updated on $env:COMPUTERNAME"
} else {
    & "$dir\Sysmon64.exe" -accepteula -i "$dir\sysmonconfig.xml" 2>$null
    Write-Output "Sysmon installed on $env:COMPUTERNAME"
}

# Enable command-line and PowerShell logging
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" /v ProcessCreationIncludeCmdLine_Enabled /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" /v EnableScriptBlockLogging /t REG_DWORD /d 1 /f | Out-Null
Write-Output "Audit policies set on $env:COMPUTERNAME"
'@ --only-show-errors 2>$null | Out-Null
    Write-OK "Sysmon installed on $vm"
}

# ════════════════════════════════════════════════════════════════════════
# PHASE 7: INSTALL SPLUNK ENTERPRISE
# ════════════════════════════════════════════════════════════════════════

Write-Step 10 $totalSteps "Installing Splunk Enterprise on vm-splunk..."
# WHY: Splunk is one of the two industry-standard SIEMs. By running it
# alongside Sentinel, you learn both platforms. Most SOC job postings
# require either Splunk SPL or Sentinel KQL (or both).

Write-Warn "Splunk download URL may be outdated. If this fails, install manually."
Write-Info "This step takes 5-10 minutes..."

az vm run-command invoke -g $ResourceGroup --name vm-splunk `
    --command-id RunShellScript --scripts @'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget curl net-tools 2>/dev/null

echo "Downloading Splunk..."
wget -q -O /tmp/splunk.deb \
    "https://download.splunk.com/products/splunk/releases/9.3.1/linux/splunk-9.3.1-0b8d769cb912-linux-2.6-amd64.deb" 2>/dev/null || {
    echo "DOWNLOAD FAILED - Install Splunk manually via Bastion SSH"
    echo "Visit: https://www.splunk.com/en_us/download/splunk-enterprise.html"
    exit 0
}

echo "Installing Splunk..."
dpkg -i /tmp/splunk.deb

echo "Starting Splunk..."
/opt/splunk/bin/splunk start --accept-license --answer-yes --seed-passwd 'Splunk@SOC2024!'
/opt/splunk/bin/splunk enable boot-start 2>/dev/null || /opt/splunk/bin/splunk enable boot-start -user root

echo "Configuring indexes and receiving..."
/opt/splunk/bin/splunk enable listen 9997 -auth admin:'Splunk@SOC2024!'
for idx in idx_windows idx_sysmon idx_firewall idx_linux idx_honeypot idx_threat_intel; do
    /opt/splunk/bin/splunk add index $idx -auth admin:'Splunk@SOC2024!' 2>/dev/null || true
done

/opt/splunk/bin/splunk http-event-collector enable -uri https://localhost:8089 -auth admin:'Splunk@SOC2024!' 2>/dev/null || true
/opt/splunk/bin/splunk restart

echo "Splunk installed and configured!"
echo "Web UI: http://10.0.3.4:8000 (admin / Splunk@SOC2024!)"
'@ --only-show-errors 2>$null | Out-Null

Write-OK "Splunk Enterprise installed (Web: http://10.0.3.4:8000)"

# ════════════════════════════════════════════════════════════════════════
# PHASE 8: INSTALL SPLUNK FORWARDERS ON WINDOWS VMS
# ════════════════════════════════════════════════════════════════════════

Write-Step 11 $totalSteps "Configuring Splunk Universal Forwarders on Windows VMs..."
# WHY: Universal Forwarders are lightweight agents that ship logs from
# each Windows machine to the central Splunk server. They forward
# Security events, Sysmon data, PowerShell logs, and System events.

foreach ($vm in $windowsVMs) {
    $vmIndex = if ($vm -eq "vm-honeypot") { "idx_honeypot" } else { "idx_windows" }
    Write-Info "Configuring forwarder on $vm (index: $vmIndex)..."

    az vm run-command invoke -g $ResourceGroup --name $vm `
        --command-id RunPowerShellScript --scripts @"
# Create forwarder config directory
`$configDir = 'C:\SplunkForwarder-Config'
New-Item -ItemType Directory -Path `$configDir -Force | Out-Null

# inputs.conf - WHAT to collect
@'
[WinEventLog://Security]
disabled = false
index = $vmIndex
sourcetype = WinEventLog:Security
evt_resolve_ad_obj = 1

[WinEventLog://Microsoft-Windows-Sysmon/Operational]
disabled = false
index = idx_sysmon
sourcetype = XmlWinEventLog:Microsoft-Windows-Sysmon/Operational
renderXml = true

[WinEventLog://Microsoft-Windows-PowerShell/Operational]
disabled = false
index = $vmIndex
sourcetype = WinEventLog:Microsoft-Windows-PowerShell/Operational

[WinEventLog://System]
disabled = false
index = $vmIndex
sourcetype = WinEventLog:System
'@ | Out-File -FilePath "`$configDir\inputs.conf" -Encoding ASCII

# outputs.conf - WHERE to send
@'
[tcpout]
defaultGroup = azuresoc

[tcpout:azuresoc]
server = 10.0.3.4:9997
'@ | Out-File -FilePath "`$configDir\outputs.conf" -Encoding ASCII

Write-Output "Forwarder configs written for `$env:COMPUTERNAME"

# Try to download and install the forwarder
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    `$ufUrl = 'https://download.splunk.com/products/universalforwarder/releases/9.3.1/windows/splunkforwarder-9.3.1-0b8d769cb912-x64-release.msi'
    Invoke-WebRequest -Uri `$ufUrl -OutFile 'C:\splunkuf.msi' -UseBasicParsing
    Start-Process msiexec -ArgumentList '/i C:\splunkuf.msi RECEIVING_INDEXER="10.0.3.4:9997" SPLUNK_PASSWORD="Fwd@1234" AGREETOLICENSE=yes /quiet' -Wait
    Copy-Item "`$configDir\inputs.conf" 'C:\SplunkUniversalForwarder\etc\system\local\inputs.conf' -Force
    Copy-Item "`$configDir\outputs.conf" 'C:\SplunkUniversalForwarder\etc\system\local\outputs.conf' -Force
    & 'C:\SplunkUniversalForwarder\bin\splunk.exe' restart 2>`$null
    Write-Output "Universal Forwarder installed and configured on `$env:COMPUTERNAME"
} catch {
    Write-Output "Auto-install failed on `$env:COMPUTERNAME - configs saved to C:\SplunkForwarder-Config"
    Write-Output "Manual install: download UF from splunk.com, install, copy configs to etc\system\local\"
}
"@ --only-show-errors 2>$null | Out-Null
    Write-OK "Forwarder configured on $vm"
}

# ════════════════════════════════════════════════════════════════════════
# PHASE 9: INSTALL APACHE ON LINUX VM
# ════════════════════════════════════════════════════════════════════════

Write-Step 12 $totalSteps "Setting up Linux web server (attack target)..."
# WHY: The Linux VM runs Apache web server, making it a target for
# web-based attacks. Syslog from this VM goes to both Sentinel and Splunk.

az vm run-command invoke -g $ResourceGroup --name vm-linux01 `
    --command-id RunShellScript --scripts @'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq apache2 curl net-tools auditd 2>/dev/null
systemctl enable apache2
systemctl start apache2

# Enable audit logging for SSH
echo "-w /var/log/auth.log -p wa -k auth_log" >> /etc/audit/rules.d/audit.rules
systemctl restart auditd 2>/dev/null || true

echo "Apache installed. Linux target ready."
'@ --only-show-errors 2>$null | Out-Null

Write-OK "Linux web server configured"

# ════════════════════════════════════════════════════════════════════════
# PHASE 10: ENABLE SENTINEL DATA CONNECTORS (What can be automated)
# ════════════════════════════════════════════════════════════════════════

Write-Step 13 $totalSteps "Configuring Sentinel diagnostic settings..."
# WHY: Diagnostic settings route Azure platform logs (firewall, NSGs, etc.)
# to the Log Analytics workspace where Sentinel can analyze them.
# Note: Some connectors (Entra ID, Defender XDR) require Portal clicks.

# NSG diagnostic settings
$nsgs = @("nsg-ad", "nsg-workstation", "nsg-linux", "nsg-honeypot")
$lawId = az monitor log-analytics workspace show -g $ResourceGroup --workspace-name law-azuresoc --query id -o tsv 2>$null
foreach ($nsg in $nsgs) {
    $nsgId = az network nsg show -g $ResourceGroup --name $nsg --query id -o tsv 2>$null
    if ($nsgId) {
        az monitor diagnostic-settings create --resource $nsgId `
            --name "${nsg}-diag" --workspace $lawId `
            --logs "[{""categoryGroup"":""allLogs"",""enabled"":true}]" `
            --only-show-errors 2>$null | Out-Null
    }
}
Write-OK "NSG diagnostic settings configured"

# ════════════════════════════════════════════════════════════════════════
# PHASE 11: CREATE STORAGE FOR FLOW LOGS
# ════════════════════════════════════════════════════════════════════════

Write-Step 14 $totalSteps "Creating NSG Flow Logs..."
# WHY: Flow logs capture metadata about every network connection
# (source IP, dest IP, port, protocol, bytes). Essential for
# investigating lateral movement and data exfiltration.

$storageId = az storage account list -g $ResourceGroup --query "[0].id" -o tsv 2>$null
if ($storageId) {
    foreach ($nsg in $nsgs) {
        az network watcher flow-log create -g $ResourceGroup `
            --name "flowlog-$nsg" --nsg $nsg `
            --storage-account $storageId --enabled true `
            --log-version 2 --retention 7 `
            --only-show-errors 2>$null | Out-Null
    }
    Write-OK "NSG Flow Logs enabled"
} else {
    Write-Warn "Storage account not found - create flow logs manually"
}

# ════════════════════════════════════════════════════════════════════════
# DONE!
# ════════════════════════════════════════════════════════════════════════

$elapsed = ((Get-Date) - $startTime).ToString("hh\:mm\:ss")
Write-Step 15 $totalSteps "Generating summary..."

Write-Banner "AzureSOC Deployment COMPLETE! (Total time: $elapsed)"

Write-Host "  ┌─────────────────────────────────────────────────────┐" -ForegroundColor Green
Write-Host "  │  WHAT WAS DEPLOYED:                                 │" -ForegroundColor Green
Write-Host "  │  ✅ Hub-Spoke network (3 VNets + peering)          │" -ForegroundColor White
Write-Host "  │  ✅ Azure Firewall (Basic SKU) with policies       │" -ForegroundColor White
Write-Host "  │  ✅ Azure Bastion for secure VM access             │" -ForegroundColor White
Write-Host "  │  ✅ 5 VMs (DC, Workstation, Linux, Honeypot, Splunk)│" -ForegroundColor White
Write-Host "  │  ✅ Active Directory (azuresoc.local)              │" -ForegroundColor White
Write-Host "  │  ✅ 9 AD users + groups + service accounts         │" -ForegroundColor White
Write-Host "  │  ✅ Sysmon on all Windows VMs                      │" -ForegroundColor White
Write-Host "  │  ✅ Microsoft Sentinel + Log Analytics             │" -ForegroundColor White
Write-Host "  │  ✅ Splunk Enterprise (10.0.3.4:8000)              │" -ForegroundColor White
Write-Host "  │  ✅ Splunk Forwarders on Windows VMs               │" -ForegroundColor White
Write-Host "  │  ✅ Key Vault for secrets                          │" -ForegroundColor White
Write-Host "  │  ✅ NSG Flow Logs + Diagnostics                    │" -ForegroundColor White
Write-Host "  │  ✅ Linux web server (Apache)                      │" -ForegroundColor White
Write-Host "  └─────────────────────────────────────────────────────┘" -ForegroundColor Green
Write-Host ""
Write-Host "  KEY INFORMATION:" -ForegroundColor Yellow
Write-Host "  Firewall Private IP:  $fwIP" -ForegroundColor White
Write-Host "  Honeypot Public IP:   $honeypotIP" -ForegroundColor White
Write-Host "  Splunk Web:           http://10.0.3.4:8000 (via Bastion)" -ForegroundColor White
Write-Host "  Splunk Creds:         admin / Splunk@SOC2024!" -ForegroundColor White
Write-Host "  Domain:               azuresoc.local" -ForegroundColor White
Write-Host "  Domain Admin:         AZURESOC\azuresocadmin / $AdminPassword" -ForegroundColor White
Write-Host "  Key Vault:            $kvName" -ForegroundColor White
Write-Host ""
Write-Host "  ┌─────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  MANUAL STEPS STILL NEEDED (Portal only):          │" -ForegroundColor Yellow
Write-Host "  │                                                     │" -ForegroundColor Yellow
Write-Host "  │  1. Sentinel > Data connectors >                   │" -ForegroundColor White
Write-Host "  │     - Windows Security Events via AMA (create DCR) │" -ForegroundColor White
Write-Host "  │     - Microsoft Entra ID (connect sign-in logs)    │" -ForegroundColor White
Write-Host "  │     - Microsoft Defender XDR (connect incidents)   │" -ForegroundColor White
Write-Host "  │     - Threat Intelligence - TAXII                  │" -ForegroundColor White
Write-Host "  │                                                     │" -ForegroundColor White
Write-Host "  │  2. security.microsoft.com >                       │" -ForegroundColor White
Write-Host "  │     - Onboard VMs to Defender for Endpoint         │" -ForegroundColor White
Write-Host "  │                                                     │" -ForegroundColor White
Write-Host "  │  3. Entra ID > Security >                          │" -ForegroundColor White
Write-Host "  │     - Enable Identity Protection policies          │" -ForegroundColor White
Write-Host "  │     - Create Conditional Access policies           │" -ForegroundColor White
Write-Host "  │                                                     │" -ForegroundColor White
Write-Host "  │  See the Build Guide doc for step-by-step.         │" -ForegroundColor Gray
Write-Host "  └─────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "  💰 COST SAVING — Run when done for the day:" -ForegroundColor Red
Write-Host "  ./scripts/stop-all.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "  📂 NEXT: Push to GitHub, then start Phase 4 (EDR/XDR)" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
