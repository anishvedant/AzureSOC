# AzureSOC — Open Source Cloud Security Operations Center

A fully automated, deployable SOC lab on Microsoft Azure with Active Directory, Microsoft Sentinel SIEM, Suricata IDS, Sysmon endpoint telemetry, and real-time MITRE ATT&CK attack detection.

**GitHub:** [github.com/anishvedant/AzureSOC](https://github.com/anishvedant/AzureSOC)

## What I Built

A production-grade Security Operations Center deployed on Azure using Infrastructure as Code. One PowerShell script deploys the entire environment in 20-40 minutes, including network infrastructure, domain controller, SIEM, IDS, and attack simulation targets.

## Architecture

```
                    ┌──────────────────────────────┐
                    │      Microsoft Sentinel       │
                    │    Cloud SIEM • 8 connectors  │
                    │    1000+ security events       │
                    └──────────┬───────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
  ┌─────┴──────┐    ┌─────────┴────────┐    ┌───────┴────────┐
  │  vm-dc01   │    │   vm-linux01     │    │  Supporting    │
  │ Win Server │    │   Ubuntu 22.04   │    │  Services      │
  │ AD Domain  │    │ Suricata IDS     │    │  Key Vault     │
  │ Sysmon v15 │    │  65K rules       │    │  Storage       │
  │ 11 AD Users│    │ Apache (target)  │    │  NSGs          │
  └────────────┘    └──────────────────┘    └────────────────┘
    10.0.1.0/24        10.0.2.0/24
              VNet: 10.0.0.0/16
```

## 18 Azure Resources Deployed

| Resource | Type | Purpose |
|----------|------|---------|
| vm-dc01 | Windows Server 2022 | Domain Controller, AD DS, Sysmon, DNS |
| vm-linux01 | Ubuntu 22.04 | Suricata IDS (65K rules), Apache web target |
| vnet-azuresoc | Virtual Network | 10.0.0.0/16, connects all VMs |
| nsg-dc | NSG | Firewall rules for DC subnet |
| nsg-splunk | NSG | Firewall rules for Linux subnet |
| nsg-honeypot | NSG | Wide-open rules (honeypot-ready) |
| law-azuresoc | Log Analytics | Stores all security logs |
| SecurityInsights | Sentinel | Cloud SIEM with 8 data connectors |
| kv-* | Key Vault | Secure API key storage |
| st*soc | Storage Account | NSG flow logs and diagnostics |
| dcr-windows | Data Collection Rule | Pipes DC logs to Sentinel |
| pip-dc01, pip-splunk | Public IPs | Remote access |
| nic-dc01, nic-splunk | NICs | VM network interfaces |

## Active Directory Configuration

- **Domain:** azuresoc.local
- **Users:** jsmith, sconnor, mjones, edavis, jwilson, lbrown
- **Admins:** admin.backup (Domain Admin), srv.admin
- **Service Account:** svc.sql (Kerberoastable — has SPN MSSQLSvc/dc01.azuresoc.local:1433)
- **Groups:** IT-Team, HR-Team, Finance-Team, SOC-Analysts, Server-Admins
- **Audit Policies:** Command-line logging, PowerShell Script Block logging enabled

## Attacks Executed and Detected

| Attack | MITRE ID | Tool | Detected In |
|--------|----------|------|-------------|
| Network Reconnaissance | T1046 | Nmap | 12 open ports found |
| Web Vulnerability Scan | T1595.002 | Nikto | 4 vulns found (ETag, X-Frame, server-status) |
| Account Discovery | T1087.001 | net user /domain | Sentinel EventID 4688 |
| System Discovery | T1082 | systeminfo, ipconfig | Sentinel EventID 4688 |
| Encoded PowerShell | T1059.001 | powershell -EncodedCommand | Sentinel EventID 4688 |
| Kerberoasting | T1558.003 | KerberosRequestorSecurityToken | Sentinel EventID 4769 |
| Scheduled Task Persistence | T1053.005 | schtasks /create | Sentinel EventID 4698 |
| Password Spray | T1110.003 | net use with multiple accounts | Sentinel EventID 4625 |
| SMB Enumeration | T1135 | net share, net view | Sentinel EventID 5140 |
| Log Clearing | T1070.001 | wevtutil cl | Sentinel EventID 1102 |

## KQL Detection Queries Used

```kql
// Failed RDP logins (brute force)
SecurityEvent | where EventID == 4625 | project TimeGenerated, TargetAccount, IpAddress

// Kerberoasting detection
SecurityEvent | where EventID == 4769 | where ServiceName !endswith "$"

// Process creation (attack commands)
SecurityEvent | where EventID == 4688 | where CommandLine != ""

// Log clearing (anti-forensics)
SecurityEvent | where EventID == 1102

// Full attack timeline
SecurityEvent | where EventID in (4688, 4624, 4625, 4672, 4698, 4769, 1102)
| project TimeGenerated, EventID, Activity, Account, CommandLine
| sort by TimeGenerated asc
```

## Sentinel Analytics Rules Created

- **Brute Force RDP Detection** — triggers on 3+ failed logins in 5 minutes
- **Kerberoasting Detection** — triggers on TGS requests with RC4 encryption

## How to Deploy (for anyone who wants to replicate)

```powershell
# 1. Clone the repo
git clone https://github.com/anishvedant/AzureSOC.git
cd AzureSOC

# 2. Login to Azure
az login

# 3. Deploy everything (auto-finds region + VM size)
.\scripts\setup\master-deploy.ps1 -AdminPassword "YourStr0ngP@ss!"

# 4. Wait 20-40 min, then verify
.\scripts\setup\verify-all.ps1

# 5. Stop VMs when done ($2-4/session)
.\scripts\setup\stop-all.ps1

# 6. Delete everything when finished
az group delete --name rg-azuresoc --yes
```

## Repository Structure

```
AzureSOC/
├── infra/main.bicep                    # Bicep IaC template
├── scripts/setup/master-deploy.ps1     # One-command deployment
├── scripts/setup/verify-all.ps1        # Health checker
├── scripts/setup/start-all.ps1         # Start VMs
├── scripts/setup/stop-all.ps1          # Stop VMs
├── scripts/attack/run-attack-simulation.ps1
├── scripts/detection/sentinel-rules/all-detections.kql
├── cspm/cspm_audit.py                  # Cloud posture scanner
├── docs/attack-defense-guide/ATTACK-DEFENSE-PLAYBOOK.md
├── docs/AzureSOC-Complete-Build-Guide.docx
└── docs/playbooks/T1003.001-credential-dumping.md
```

## Cost
~$2-4 per 8-hour session with D2s_v3 VMs. Delete resource group when done for zero ongoing charges.

## License
MIT
