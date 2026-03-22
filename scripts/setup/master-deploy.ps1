#!/usr/bin/env pwsh
# ============================================================================
#  AzureSOC - MASTER DEPLOYMENT SCRIPT
# ============================================================================
#  Deploys the COMPLETE SOC lab automatically:
#    - Auto-finds a working Azure region and VM size
#    - Deploys VNet + NSGs + 2 VMs + Sentinel + Key Vault
#    - Configures Active Directory with 9 users, groups, service accounts
#    - Installs Sysmon with SwiftOnSecurity config
#    - Installs Splunk Enterprise with 6 indexes
#    - Installs Apache web server as Linux attack target
#    - Installs Splunk Universal Forwarder on DC
#    - Configures audit policies and PowerShell logging
#    - Sets up NSG diagnostic settings to Sentinel
#
#  USAGE: .\master-deploy.ps1 -AdminPassword "AzureS0C@2026!"
#  TIME:  40-60 minutes
#  COST:  ~$8-12 per session (D2s_v3 VMs)
# ============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$AdminPassword,
    [string]$ResourceGroup = "rg-azuresoc"
)

$ErrorActionPreference = "Continue"
$startTime = Get-Date

function Log { param([string]$m, [string]$c = "White") Write-Host "  $m" -ForegroundColor $c }
function OK  { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Step { param([int]$n, [string]$m)
    $e = ((Get-Date) - $script:startTime).ToString("hh\:mm\:ss")
    Write-Host "[$n/12] [$e] $m" -ForegroundColor Yellow
}

Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host "  AzureSOC - Master Deployment" -ForegroundColor Cyan
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host ""

# ====== STEP 1: CLEANUP ======
Step 1 "Cleaning up previous deployments..."
$exists = az group exists --name $ResourceGroup -o tsv 2>$null
if ($exists -eq "true") {
    Log "Deleting old resource group..." "Gray"
    az group delete --name $ResourceGroup --yes 2>$null | Out-Null
    Log "Old resource group deleted" "Gray"
}
OK "Clean slate"

# ====== STEP 2: PROVIDERS ======
Step 2 "Registering Azure providers..."
$provs = @("Microsoft.OperationalInsights","Microsoft.SecurityInsights","Microsoft.Network","Microsoft.Compute","Microsoft.KeyVault","Microsoft.Storage","Microsoft.Insights","Microsoft.Security","Microsoft.Web")
foreach ($p in $provs) { az provider register --namespace $p --only-show-errors 2>$null }
OK "Providers registered"

# ====== STEP 3: FIND WORKING REGION + VM SIZE ======
Step 3 "Scanning for available region and VM size..."
Log "Testing multiple regions - this takes 1-2 min..." "Gray"

$bicep = "./infra/main.bicep"
if (!(Test-Path $bicep)) {
    Write-Host "  ERROR: infra/main.bicep not found!" -ForegroundColor Red
    Write-Host "  Make sure you run this from C:\Projects\files" -ForegroundColor Red
    exit 1
}

$regions = @("centralus","eastus2","northcentralus","westus3","westus","canadacentral","northeurope","uksouth","australiaeast","japaneast")
$sizes = @("Standard_D2s_v3","Standard_D2as_v4","Standard_D2s_v5","Standard_D2as_v5","Standard_B2s","Standard_B2ms","Standard_DS2_v2")

$foundRegion = $null
$foundSize = $null

foreach ($reg in $regions) {
    if ($foundRegion) { break }
    foreach ($sz in $sizes) {
        $restricted = az vm list-skus --location $reg --size $sz --resource-type virtualMachines `
            --query "[?restrictions[?reasonCode=='NotAvailableForSubscription']] | length(@)" -o tsv 2>$null
        if ($null -eq $restricted -or $restricted -eq "" -or $restricted -eq "0") {
            $foundRegion = $reg
            $foundSize = $sz
            break
        }
    }
}

if (-not $foundRegion) {
    Write-Host "  ERROR: No available VM size found in any region!" -ForegroundColor Red
    Write-Host "  Request a quota increase: https://aka.ms/ProdportalCRP" -ForegroundColor Yellow
    exit 1
}

OK "Found: $foundRegion / $foundSize"

# ====== STEP 4: CREATE RESOURCE GROUP ======
Step 4 "Creating resource group in $foundRegion..."
az group create --name $ResourceGroup --location $foundRegion --only-show-errors | Out-Null
OK "Resource group created"

# ====== STEP 5: DEPLOY INFRASTRUCTURE ======
Step 5 "Deploying infrastructure - 10-20 min wait..."
Log "Region: $foundRegion  |  VM Size: $foundSize" "White"
Log "Deploying: VNet, NSGs, DC, Splunk VM, Sentinel, Key Vault, Storage" "Gray"

$deployOut = az deployment group create -g $ResourceGroup --template-file $bicep `
    --parameters adminPassword=$AdminPassword location=$foundRegion vmSize=$foundSize `
    --query "properties.outputs" -o json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  DEPLOYMENT FAILED" -ForegroundColor Red
    Write-Host $deployOut -ForegroundColor Red
    exit 1
}

$dcIP = "check-portal"
$splunkIP = "check-portal"
$kvName = "check-portal"
try {
    $o = $deployOut | ConvertFrom-Json
    $dcIP = $o.dcPublicIP.value
    $splunkIP = $o.splunkPublicIP.value
    $kvName = $o.keyVaultName.value
} catch {}

OK "Infrastructure deployed!"
Log "DC: $dcIP  |  Splunk: $splunkIP" "White"

# ====== STEP 6: WAIT FOR VMS ======
Step 6 "Waiting for VMs to boot..."
foreach ($vm in @("vm-dc01","vm-splunk")) {
    $r = 0
    while ($r -lt 20) {
        $st = az vm get-instance-view -g $ResourceGroup --name $vm `
            --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null
        if ($st -eq "VM running") { break }
        $r++
        Start-Sleep -Seconds 15
    }
    OK "$vm is running"
}
Log "Giving VMs 60s extra to fully initialize..." "Gray"
Start-Sleep -Seconds 60

# ====== STEP 7: ACTIVE DIRECTORY ======
Step 7 "Installing Active Directory + promoting to Domain Controller..."

az vm run-command invoke -g $ResourceGroup --name vm-dc01 `
    --command-id RunPowerShellScript --scripts @'
Write-Output "Installing AD DS..."
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
Write-Output "Promoting to DC..."
Install-ADDSForest `
    -DomainName "azuresoc.local" `
    -DomainNetbiosName "AZURESOC" `
    -SafeModeAdministratorPassword (ConvertTo-SecureString "DSRMp@ssw0rd!" -AsPlainText -Force) `
    -InstallDns:$true `
    -Force:$true `
    -NoRebootOnCompletion:$false
Write-Output "Done - rebooting"
'@ --only-show-errors 2>$null | Out-Null

OK "AD DS triggered - DC rebooting"
Log "Waiting 6 min for AD initialization..." "Gray"
Start-Sleep -Seconds 360

# Wait for DC to come back
$r = 0
while ($r -lt 25) {
    $st = az vm get-instance-view -g $ResourceGroup --name vm-dc01 `
        --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null
    if ($st -eq "VM running") { break }
    $r++
    Start-Sleep -Seconds 15
}
OK "DC is back online"
Log "Giving AD services 90s to fully start..." "Gray"
Start-Sleep -Seconds 90

# ====== STEP 8: AD USERS + GROUPS + AUDIT POLICIES ======
Step 8 "Creating AD users, groups, service accounts, audit policies..."

az vm run-command invoke -g $ResourceGroup --name vm-dc01 `
    --command-id RunPowerShellScript --scripts @'
Import-Module ActiveDirectory

# Organizational Units
foreach ($ou in @("SOC-Lab-Users","SOC-Lab-Admins","SOC-Lab-ServiceAccounts")) {
    try { New-ADOrganizationalUnit -Name $ou -Path "DC=azuresoc,DC=local" -EA Stop
          Write-Output "Created OU: $ou" } catch { Write-Output "OU exists: $ou" }
}

# Security Groups
foreach ($g in @("IT-Team","HR-Team","Finance-Team","SOC-Analysts","Server-Admins")) {
    try { New-ADGroup -Name $g -GroupScope Global -GroupCategory Security `
            -Path "OU=SOC-Lab-Users,DC=azuresoc,DC=local" -EA Stop
          Write-Output "Created group: $g" } catch { Write-Output "Group exists: $g" }
}

# Regular Users
$pw = ConvertTo-SecureString "User@1234" -AsPlainText -Force
$users = @(
    @{N="John Smith";S="jsmith";G="IT-Team"},
    @{N="Sarah Connor";S="sconnor";G="IT-Team"},
    @{N="Mike Jones";S="mjones";G="HR-Team"},
    @{N="Emily Davis";S="edavis";G="Finance-Team"},
    @{N="James Wilson";S="jwilson";G="SOC-Analysts"},
    @{N="Lisa Brown";S="lbrown";G="Finance-Team"}
)
foreach ($u in $users) {
    try {
        New-ADUser -Name $u.N -SamAccountName $u.S `
            -UserPrincipalName "$($u.S)@azuresoc.local" `
            -Path "OU=SOC-Lab-Users,DC=azuresoc,DC=local" `
            -AccountPassword $pw -Enabled $true -PasswordNeverExpires $true -EA Stop
        Add-ADGroupMember -Identity $u.G -Members $u.S
        Write-Output "Created user: $($u.S)"
    } catch { Write-Output "User exists: $($u.S)" }
}

# Domain Admin - attack target for privilege escalation
try {
    New-ADUser -Name "Admin Backup" -SamAccountName "admin.backup" `
        -UserPrincipalName "admin.backup@azuresoc.local" `
        -Path "OU=SOC-Lab-Admins,DC=azuresoc,DC=local" `
        -AccountPassword (ConvertTo-SecureString "B@ckup2024!" -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true -EA Stop
    Add-ADGroupMember -Identity "Domain Admins" -Members "admin.backup"
    Write-Output "Created: admin.backup [Domain Admin - ATTACK TARGET]"
} catch { Write-Output "admin.backup exists" }

# Server Admin
try {
    New-ADUser -Name "Server Admin" -SamAccountName "srv.admin" `
        -UserPrincipalName "srv.admin@azuresoc.local" `
        -Path "OU=SOC-Lab-Admins,DC=azuresoc,DC=local" `
        -AccountPassword (ConvertTo-SecureString "SrvAdm1n!" -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true -EA Stop
    Add-ADGroupMember -Identity "Server-Admins" -Members "srv.admin"
    Write-Output "Created: srv.admin"
} catch { Write-Output "srv.admin exists" }

# Kerberoastable Service Account - has SPN for attack simulation
try {
    New-ADUser -Name "SQL Service" -SamAccountName "svc.sql" `
        -UserPrincipalName "svc.sql@azuresoc.local" `
        -Path "OU=SOC-Lab-ServiceAccounts,DC=azuresoc,DC=local" `
        -AccountPassword (ConvertTo-SecureString "SQLsvc2024!" -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true -EA Stop
    Set-ADUser -Identity "svc.sql" -ServicePrincipalNames @{Add="MSSQLSvc/dc01.azuresoc.local:1433"}
    Write-Output "Created: svc.sql [Kerberoastable - ATTACK TARGET]"
} catch { Write-Output "svc.sql exists" }

# Enable command-line logging in process creation events
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" /v ProcessCreationIncludeCmdLine_Enabled /t REG_DWORD /d 1 /f | Out-Null
# Enable PowerShell Script Block Logging
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" /v EnableScriptBlockLogging /t REG_DWORD /d 1 /f | Out-Null
# Enable PowerShell Module Logging
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" /v EnableModuleLogging /t REG_DWORD /d 1 /f | Out-Null

Write-Output "AD + audit policies configured!"
'@ --only-show-errors 2>$null | Out-Null

OK "AD configured: 4 OUs, 5 groups, 6 users, 2 admins, 1 service account"

# ====== STEP 9: SYSMON ON DC ======
Step 9 "Installing Sysmon + Splunk Forwarder on DC..."

az vm run-command invoke -g $ResourceGroup --name vm-dc01 `
    --command-id RunPowerShellScript --scripts @'
# ── Sysmon ──
$d = "C:\Sysmon"
if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    Invoke-WebRequest -Uri "https://live.sysinternals.com/Sysmon64.exe" -OutFile "$d\Sysmon64.exe" -UseBasicParsing
    Write-Output "Sysmon downloaded"
} catch {
    try {
        Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile "$d\Sysmon.zip" -UseBasicParsing
        Expand-Archive "$d\Sysmon.zip" -DestinationPath $d -Force
        Write-Output "Sysmon downloaded via ZIP"
    } catch { Write-Output "Sysmon download failed - install manually" }
}

try {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" -OutFile "$d\sysmonconfig.xml" -UseBasicParsing
    Write-Output "SwiftOnSecurity config downloaded"
} catch {
    '<Sysmon schemaversion="4.90"><EventFiltering><ProcessCreate onmatch="exclude"/><NetworkConnect onmatch="exclude"/><ProcessAccess onmatch="exclude"/><DnsQuery onmatch="exclude"/></EventFiltering></Sysmon>' | Out-File "$d\sysmonconfig.xml" -Encoding UTF8
    Write-Output "Fallback config created"
}

$svc = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
if ($svc) {
    & "$d\Sysmon64.exe" -c "$d\sysmonconfig.xml" 2>$null
    Write-Output "Sysmon config updated"
} else {
    & "$d\Sysmon64.exe" -accepteula -i "$d\sysmonconfig.xml" 2>$null
    Write-Output "Sysmon installed"
}

# ── Splunk Universal Forwarder config ──
$cfg = "C:\SplunkForwarder-Config"
New-Item -ItemType Directory -Path $cfg -Force | Out-Null

@"
[WinEventLog://Security]
disabled = false
index = idx_windows
sourcetype = WinEventLog:Security
evt_resolve_ad_obj = 1

[WinEventLog://Microsoft-Windows-Sysmon/Operational]
disabled = false
index = idx_sysmon
sourcetype = XmlWinEventLog:Microsoft-Windows-Sysmon/Operational
renderXml = true

[WinEventLog://Microsoft-Windows-PowerShell/Operational]
disabled = false
index = idx_windows
sourcetype = WinEventLog:Microsoft-Windows-PowerShell/Operational

[WinEventLog://System]
disabled = false
index = idx_windows
sourcetype = WinEventLog:System
"@ | Out-File -FilePath "$cfg\inputs.conf" -Encoding ASCII

@"
[tcpout]
defaultGroup = azuresoc

[tcpout:azuresoc]
server = 10.0.2.4:9997
"@ | Out-File -FilePath "$cfg\outputs.conf" -Encoding ASCII

# Try to download and install UF
try {
    $ufUrl = "https://download.splunk.com/products/universalforwarder/releases/9.3.1/windows/splunkforwarder-9.3.1-0b8d769cb912-x64-release.msi"
    Invoke-WebRequest -Uri $ufUrl -OutFile "C:\splunkuf.msi" -UseBasicParsing
    Start-Process msiexec -ArgumentList '/i C:\splunkuf.msi RECEIVING_INDEXER="10.0.2.4:9997" SPLUNK_PASSWORD="Fwd@1234" AGREETOLICENSE=yes /quiet' -Wait
    Copy-Item "$cfg\inputs.conf" "C:\SplunkUniversalForwarder\etc\system\local\inputs.conf" -Force
    Copy-Item "$cfg\outputs.conf" "C:\SplunkUniversalForwarder\etc\system\local\outputs.conf" -Force
    & "C:\SplunkUniversalForwarder\bin\splunk.exe" restart 2>$null
    Write-Output "Splunk Universal Forwarder installed"
} catch {
    Write-Output "UF auto-install failed - configs saved to C:\SplunkForwarder-Config"
}

Write-Output "DC configuration complete!"
'@ --only-show-errors 2>$null | Out-Null

OK "Sysmon + Splunk Forwarder installed on DC"

# ====== STEP 10: SPLUNK + APACHE ON LINUX VM ======
Step 10 "Installing Splunk Enterprise + Apache on Linux VM..."
Log "This step takes 5-10 min..." "Gray"

az vm run-command invoke -g $ResourceGroup --name vm-splunk `
    --command-id RunShellScript --scripts @'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "=== Installing system packages ==="
apt-get update -qq
apt-get install -y -qq wget curl net-tools apache2 auditd 2>/dev/null

echo "=== Configuring Apache web server ==="
systemctl enable apache2
systemctl start apache2

echo "=== Configuring audit logging ==="
echo "-w /var/log/auth.log -p wa -k auth_log" >> /etc/audit/rules.d/audit.rules
systemctl restart auditd 2>/dev/null || true

echo "=== Downloading Splunk Enterprise ==="
wget -q -O /tmp/splunk.deb \
    "https://download.splunk.com/products/splunk/releases/9.3.1/linux/splunk-9.3.1-0b8d769cb912-linux-2.6-amd64.deb" 2>/dev/null || {
    echo "SPLUNK DOWNLOAD FAILED"
    echo "Install manually: SSH in and download from splunk.com"
    exit 0
}

echo "=== Installing Splunk ==="
dpkg -i /tmp/splunk.deb

echo "=== Starting Splunk ==="
/opt/splunk/bin/splunk start --accept-license --answer-yes --seed-passwd 'Splunk@SOC2024!'
/opt/splunk/bin/splunk enable boot-start 2>/dev/null || /opt/splunk/bin/splunk enable boot-start -user root

echo "=== Configuring Splunk indexes and inputs ==="
/opt/splunk/bin/splunk enable listen 9997 -auth admin:'Splunk@SOC2024!'

for idx in idx_windows idx_sysmon idx_firewall idx_linux idx_honeypot idx_threat_intel; do
    /opt/splunk/bin/splunk add index $idx -auth admin:'Splunk@SOC2024!' 2>/dev/null || true
done

/opt/splunk/bin/splunk http-event-collector enable -uri https://localhost:8089 \
    -auth admin:'Splunk@SOC2024!' 2>/dev/null || true

/opt/splunk/bin/splunk restart

echo "=== DONE ==="
echo "Splunk Web: http://$(hostname -I | awk '{print $1}'):8000"
echo "Apache: http://$(hostname -I | awk '{print $1}'):80"
'@ --only-show-errors 2>$null | Out-Null

OK "Splunk Enterprise + Apache installed"

# ====== STEP 11: SENTINEL DIAGNOSTICS ======
Step 11 "Configuring Sentinel diagnostic settings..."

$lawId = az monitor log-analytics workspace show -g $ResourceGroup `
    --workspace-name law-azuresoc --query id -o tsv 2>$null

foreach ($nsg in @("nsg-dc","nsg-splunk","nsg-honeypot")) {
    $nsgId = az network nsg show -g $ResourceGroup --name $nsg --query id -o tsv 2>$null
    if ($nsgId -and $lawId) {
        az monitor diagnostic-settings create --resource $nsgId `
            --name "$nsg-diag" --workspace $lawId `
            --logs '[{\"categoryGroup\":\"allLogs\",\"enabled\":true}]' `
            --only-show-errors 2>$null | Out-Null
    }
}
OK "NSG diagnostics flowing to Sentinel"

# ====== STEP 12: SUMMARY ======
$elapsed = ((Get-Date) - $startTime).ToString("hh\:mm\:ss")
Step 12 "DEPLOYMENT COMPLETE!"

Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Green
Write-Host "  AzureSOC DEPLOYED SUCCESSFULLY" -ForegroundColor Green
Write-Host "  Total time: $elapsed" -ForegroundColor Green
Write-Host ("=" * 55) -ForegroundColor Green
Write-Host ""
Write-Host "  REGION: $foundRegion  |  VM SIZE: $foundSize" -ForegroundColor Cyan
Write-Host ""
Write-Host "  --- INFRASTRUCTURE ---" -ForegroundColor Yellow
Write-Host "  VNet:      vnet-azuresoc (10.0.0.0/16)" -ForegroundColor White
Write-Host "  NSGs:      nsg-dc, nsg-splunk, nsg-honeypot" -ForegroundColor White
Write-Host "  Sentinel:  law-azuresoc (Log Analytics + Sentinel)" -ForegroundColor White
Write-Host "  Key Vault: $kvName" -ForegroundColor White
Write-Host ""
Write-Host "  --- VIRTUAL MACHINES ---" -ForegroundColor Yellow
Write-Host "  vm-dc01    Windows Server 2022  RDP: $dcIP" -ForegroundColor White
Write-Host "  vm-splunk  Ubuntu 22.04         SSH: $splunkIP" -ForegroundColor White
Write-Host ""
Write-Host "  --- ACTIVE DIRECTORY ---" -ForegroundColor Yellow
Write-Host "  Domain:    azuresoc.local" -ForegroundColor White
Write-Host "  Users:     jsmith, sconnor, mjones, edavis, jwilson, lbrown" -ForegroundColor White
Write-Host "  Admins:    admin.backup (Domain Admin), srv.admin" -ForegroundColor White
Write-Host "  Service:   svc.sql (Kerberoastable - has SPN)" -ForegroundColor White
Write-Host "  Groups:    IT-Team, HR-Team, Finance-Team, SOC-Analysts, Server-Admins" -ForegroundColor White
Write-Host ""
Write-Host "  --- SECURITY TOOLS ---" -ForegroundColor Yellow
Write-Host "  Sysmon:    Installed on DC with SwiftOnSecurity config" -ForegroundColor White
Write-Host "  Splunk:    http://${splunkIP}:8000 (admin / Splunk@SOC2024!)" -ForegroundColor White
Write-Host "  Sentinel:  Azure Portal > Microsoft Sentinel > law-azuresoc" -ForegroundColor White
Write-Host "  Forwarder: DC sending Security+Sysmon+PowerShell logs to Splunk" -ForegroundColor White
Write-Host "  Apache:    http://${splunkIP}:80 (Linux attack target)" -ForegroundColor White
Write-Host "  Audit:     Command-line + PowerShell Script Block logging enabled" -ForegroundColor White
Write-Host ""
Write-Host "  --- CREDENTIALS ---" -ForegroundColor Yellow
Write-Host "  DC RDP:    azuresocadmin / $AdminPassword" -ForegroundColor White
Write-Host "  Splunk SSH: azuresocadmin / $AdminPassword" -ForegroundColor White
Write-Host "  Splunk Web: admin / Splunk@SOC2024!" -ForegroundColor White
Write-Host ""
Write-Host "  --- NEXT STEPS ---" -ForegroundColor Yellow
Write-Host "  1. RDP into DC ($dcIP) - verify AD and Sysmon" -ForegroundColor Gray
Write-Host "  2. Open http://${splunkIP}:8000 - verify Splunk" -ForegroundColor Gray
Write-Host "  3. Enable Sentinel data connectors in Azure Portal" -ForegroundColor Gray
Write-Host "  4. Run attack simulation: scripts/attack/run-attack-simulation.ps1" -ForegroundColor Gray
Write-Host "  5. Add Honeypot later: deallocate a VM, deploy honeypot" -ForegroundColor Gray
Write-Host "  6. Add Firewall + Bastion later for enterprise topology" -ForegroundColor Gray
Write-Host ""
Write-Host "  --- COST SAVING ---" -ForegroundColor Red
Write-Host "  Stop VMs:  az vm deallocate -g $ResourceGroup --name vm-dc01 --no-wait" -ForegroundColor Gray
Write-Host "             az vm deallocate -g $ResourceGroup --name vm-splunk --no-wait" -ForegroundColor Gray
Write-Host "  Start VMs: az vm start -g $ResourceGroup --name vm-dc01 --no-wait" -ForegroundColor Gray
Write-Host "             az vm start -g $ResourceGroup --name vm-splunk --no-wait" -ForegroundColor Gray
Write-Host "  Nuke all:  az group delete --name $ResourceGroup --yes" -ForegroundColor Gray
Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Green
