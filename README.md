# AzureSOC — Open Source Cloud Security Operations Center

A fully automated, one-command deployable SOC lab on Microsoft Azure with Active Directory, Microsoft Sentinel SIEM, Suricata IDS, Sysmon telemetry, and real-time MITRE ATT&CK attack detection.

## What I Built

A complete Security Operations Center that deploys via a single PowerShell command and demonstrates real-world attack detection, threat hunting, and incident response capabilities.

## Architecture

```
                    ┌──────────────────────────────┐
                    │      Microsoft Sentinel       │
                    │    Cloud SIEM + 8 connectors  │
                    │    1000+ security events       │
                    │    KQL detection rules         │
                    └──────────┬───────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
  ┌─────┴──────┐    ┌─────────┴────────┐    ┌───────┴────────┐
  │  vm-dc01   │    │   vm-linux01     │    │  Supporting    │
  │ Win Server │    │   Ubuntu 22.04   │    │  Services      │
  │ AD Domain  │    │ Suricata IDS     │    │  Key Vault     │
  │ Sysmon v15 │    │  65K rules       │    │  Storage Acct  │
  │ 11 AD Users│    │ Apache (target)  │    │  NSGs          │
  │ DNS + Audit│    │ Honeypot page    │    │  DCR           │
  └────────────┘    └──────────────────┘    └────────────────┘
    10.0.1.0/24        10.0.2.0/24
        └──────────┬──────────┘
              VNet: 10.0.0.0/16
              3 subnets, 3 NSGs
```

## What Gets Deployed (One Command)

| Layer | Component | Details |
|-------|-----------|---------|
| Network | VNet + 3 NSGs | 3 subnets with subnet-level firewall rules |
| Domain Controller | Windows Server 2022 | AD DS, DNS, Sysmon v15, audit policies |
| Active Directory | azuresoc.local | 6 users, 2 admins, 1 Kerberoastable service account |
| Endpoint Telemetry | Sysmon | SwiftOnSecurity config — process, network, registry |
| SIEM | Microsoft Sentinel | 8 data connectors, KQL detection rules |
| IDS/IPS | Suricata v8 | 65,000+ Emerging Threats rules |
| Web Target | Apache | Linux honeypot with fake corporate login page |
| Secrets | Azure Key Vault | Secure API key storage |
| Monitoring | Log Analytics + DCR | Windows Security Events flowing to Sentinel |

## Attacks Executed & Detected

| Attack | MITRE ID | Tool Used | Detected By |
|--------|----------|-----------|-------------|
| Network Reconnaissance | T1046 | Nmap | Suricata IDS |
| Web Vulnerability Scan | T1595.002 | Nikto | Apache logs |
| Account Discovery | T1087.001 | net user, PowerShell | Sentinel (4688) |
| System Discovery | T1082 | systeminfo, ipconfig | Sentinel (4688) |
| Encoded PowerShell | T1059.001 | powershell -EncodedCommand | Sentinel (4688) |
| Kerberoasting | T1558.003 | KerberosRequestorSecurityToken | Sentinel (4769) |
| Scheduled Task Persistence | T1053.005 | schtasks /create | Sentinel (4698) |
| Password Spray | T1110.003 | net use | Sentinel (4625) |
| SMB Enumeration | T1135 | smbclient | Sentinel (5140) |
| Log Clearing | T1070.001 | wevtutil cl | Sentinel (1102) |

## Quick Start

```powershell
# Deploy the entire SOC lab
az login
.\scripts\setup\master-deploy.ps1 -AdminPassword "YourStr0ngP@ss!"

# Verify all components
.\scripts\setup\verify-all.ps1

# Stop VMs when done (save money)
.\scripts\setup\stop-all.ps1

# Start VMs next session
.\scripts\setup\start-all.ps1
```

Auto-detects available Azure region and VM size. Deploys everything in 20-40 minutes.

## Repository Structure

```
AzureSOC/
├── infra/main.bicep                              # Bicep IaC template
├── scripts/
│   ├── setup/
│   │   ├── master-deploy.ps1                     # One-command deployment
│   │   ├── verify-all.ps1                        # Health check all components
│   │   ├── deploy-honeypot.ps1                   # Deploy honeypot login page
│   │   ├── start-all.ps1 / stop-all.ps1          # Cost management
│   ├── attack/
│   │   ├── run-attack-simulation.ps1             # Atomic Red Team chains
│   │   └── run-portscan.ps1                      # Nmap port scanner
│   └── detection/
│       └── sentinel-rules/all-detections.kql     # 10 KQL detection rules
├── cspm/cspm_audit.py                            # Azure cloud posture scanner
├── docs/
│   ├── attack-defense-guide/ATTACK-DEFENSE-PLAYBOOK.md  # Complete attack & defense guide
│   ├── AzureSOC-Complete-Build-Guide.docx
│   └── playbooks/T1003.001-credential-dumping.md
└── screenshots/
```

## Sentinel KQL Detection Rules

10 rules mapped to MITRE ATT&CK: Brute Force RDP (T1110.001), LSASS Credential Dump (T1003.001), Suspicious PowerShell (T1059.001), New Service (T1543.003), Lateral Movement (T1021.002), Scheduled Task (T1053.005), Account Discovery (T1087.001), Log Clearing (T1070.001), Kerberoasting (T1558.003), Honeypot Login (Custom).

## Key KQL Queries

```kql
// See all attack activity
SecurityEvent
| where EventID in (4688, 4624, 4625, 4672, 4698, 4769, 1102)
| project TimeGenerated, EventID, Activity, Account, CommandLine
| sort by TimeGenerated desc

// Detect Kerberoasting
SecurityEvent
| where EventID == 4769
| where ServiceName !endswith "$"
| project TimeGenerated, Account, ServiceName, TicketEncryptionType

// Detect brute force
SecurityEvent
| where EventID == 4625
| summarize FailedAttempts=count() by TargetAccount, IpAddress, bin(TimeGenerated, 5m)
| where FailedAttempts > 3
```

## Cost

~$2-4 per 8-hour session with Standard_D2s_v3 VMs.

## Technologies Used

Azure (VMs, VNet, NSGs, Sentinel, Key Vault, Log Analytics, DCR), Windows Server 2022, Active Directory, Sysmon, Suricata IDS, Apache, KQL, Bicep IaC, PowerShell, Bash, MITRE ATT&CK Framework, Nmap, Nikto, Hydra

## License

MIT
