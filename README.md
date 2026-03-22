# AzureSOC — Open Source Cloud Security Operations Center

A fully automated SOC lab on Microsoft Azure with Active Directory, Microsoft Sentinel SIEM, Suricata IDS, Sysmon endpoint telemetry, and real-time MITRE ATT&CK attack detection.

## Architecture

```
                    ┌──────────────────────────────┐
                    │      Microsoft Sentinel       │
                    │    (Cloud SIEM - 8 connectors)│
                    │    1000+ security events       │
                    │    KQL detection rules         │
                    └──────────┬───────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
  ┌─────┴──────┐    ┌─────────┴────────┐    ┌───────┴────────┐
  │  vm-dc01   │    │    vm-splunk     │    │  Azure         │
  │ Win Server │    │   Ubuntu 22.04   │    │  Key Vault     │
  │ AD Domain  │    │ Suricata IDS     │    │  Storage Acct  │
  │ Sysmon v15 │    │  65K rules       │    │  NSGs          │
  │ 11 AD Users│    │ Apache (target)  │    │  Data Coll.    │
  │ Audit Logs │    │ Attack target    │    │  Rules         │
  └────────────┘    └──────────────────┘    └────────────────┘
    10.0.1.0/24        10.0.2.0/24
        └──────────┬──────────┘
              VNet: 10.0.0.0/16
```

## What's Deployed

| Layer | Component | Details |
|-------|-----------|---------|
| **Network** | VNet + 3 NSGs | Hub network with subnet-level firewall rules |
| **Domain Controller** | Windows Server 2022 | AD DS, DNS, Sysmon, audit policies |
| **Active Directory** | azuresoc.local | 6 users, 2 admins, 1 Kerberoastable service account, 5 groups |
| **Endpoint Telemetry** | Sysmon v15 | SwiftOnSecurity config - process, network, registry monitoring |
| **SIEM** | Microsoft Sentinel | 8 data connectors, 1000+ events, KQL detection rules |
| **IDS/IPS** | Suricata v8 | 65,000+ Emerging Threats rules (free Azure Firewall replacement) |
| **Web Target** | Apache | Linux web server for attack simulation |
| **Secrets** | Azure Key Vault | Secure API key storage |
| **Monitoring** | Log Analytics + DCR | Windows Security Events flowing to Sentinel |

## Attack Simulation (Completed)

Successfully executed and detected in Sentinel:

| Attack | MITRE ID | What It Does |
|--------|----------|-------------|
| Account Discovery | T1087.001 | `net user /domain`, `whoami /all` |
| System Discovery | T1082 | `systeminfo`, `ipconfig /all` |
| Encoded PowerShell | T1059.001 | Base64 encoded command execution |
| Scheduled Task | T1053.005 | Persistence via `schtasks /create` |
| Kerberoasting | T1558.003 | TGS ticket request for svc.sql SPN |
| Log Clearing | T1070.001 | `wevtutil cl "Windows PowerShell"` |

## Quick Start

```powershell
az login
.\scripts\setup\master-deploy.ps1 -AdminPassword "YourStr0ngP@ss!"
```

Auto-detects available region and VM size. Deploys everything in 20-40 minutes.

## Repository Structure

```
AzureSOC/
├── infra/main.bicep                          # Infrastructure as Code
├── scripts/
│   ├── setup/
│   │   ├── master-deploy.ps1                 # One-command deployment
│   │   ├── verify-all.ps1                    # Health check all components
│   │   ├── start-all.ps1 / stop-all.ps1     # Cost management
│   ├── attack/
│   │   └── run-attack-simulation.ps1         # Atomic Red Team chains
│   └── detection/
│       └── sentinel-rules/all-detections.kql # 10 KQL detection rules
├── cspm/cspm_audit.py                        # Azure posture scanner
├── docs/
│   ├── AzureSOC-Complete-Build-Guide.docx
│   └── playbooks/T1003.001-credential-dumping.md
└── screenshots/
```

## Sentinel Detection Rules (KQL)

10 rules mapped to MITRE ATT&CK: Brute Force RDP, LSASS Credential Dump, Suspicious PowerShell, New Service, Lateral Movement, Scheduled Task, Account Discovery, Log Clearing, Kerberoasting, Honeypot Login.

## Cost

~$2-4 per 8-hour session. Stop VMs when done:
```powershell
.\scripts\setup\stop-all.ps1
```

## License
MIT
