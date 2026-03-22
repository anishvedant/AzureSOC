# AzureSOC — Open Source Cloud Security Operations Center

A fully automated, deployable SOC lab on Microsoft Azure with dual SIEMs, attack simulation, IDS, and real-time threat detection.

## What Is This?

AzureSOC is a **production-grade Security Operations Center** deployed on Azure that:

- Runs **Active Directory** with realistic users, admins, and a Kerberoastable service account
- Deploys **dual SIEMs**: Microsoft Sentinel (cloud-native KQL) + Splunk Enterprise (SPL)
- Installs **Sysmon** for deep endpoint telemetry with SwiftOnSecurity config
- Runs **Suricata IDS** with 65,000+ Emerging Threats detection rules (free Azure Firewall replacement)
- Provides **MITRE ATT&CK** mapped detection rules for both SIEMs
- Includes **attack simulation** scripts for purple team exercises
- Contains a **CSPM tool** that audits Azure misconfigurations
- Deploys via **one command** with auto-region and VM size detection

## Architecture

```
                    ┌─────────────────────────────┐
                    │     Microsoft Sentinel       │
                    │   (Cloud SIEM - KQL rules)   │
                    │   8 data connectors active   │
                    └──────────┬──────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
  ┌─────┴──────┐    ┌─────────┴────────┐    ┌───────┴────────┐
  │  vm-dc01   │    │    vm-splunk     │    │  Azure Key     │
  │ Win Server │    │   Ubuntu 22.04   │    │  Vault         │
  │ AD Domain  │───►│ Splunk (Docker)  │    │  (Secrets)     │
  │ Sysmon     │    │ Apache (Target)  │    └────────────────┘
  │ 9 AD Users │    │ Suricata IDS     │
  │ Audit Logs │    │ 65K threat rules │
  └────────────┘    └──────────────────┘
    10.0.1.0/24        10.0.2.0/24
        └──────────┬──────────┘
              VNet: 10.0.0.0/16
              NSGs per subnet
```

## Quick Start

```powershell
az login
cd C:\Projects\files
.\scripts\setup\master-deploy.ps1 -AdminPassword "YourStr0ngP@ss!"
```

One command deploys everything: auto-finds available region + VM size, deploys VNet, NSGs, 2 VMs, AD with 9 users, Sysmon, Splunk (Docker), Suricata IDS, Apache, Sentinel, and Key Vault. Takes 20-40 minutes.

## What Gets Deployed

| Component | Details |
|-----------|---------|
| **Network** | VNet 10.0.0.0/16, 3 subnets, 3 NSGs |
| **Domain Controller** | Windows Server 2022, AD DS (azuresoc.local), Sysmon v15 |
| **AD Users** | 6 regular + 2 admin + 1 Kerberoastable service account |
| **Splunk SIEM** | Enterprise via Docker, 7 indexes, port 9997 receiver |
| **Suricata IDS** | v8.0, 65K+ Emerging Threats rules, replaces Azure Firewall |
| **Apache** | Linux web server (attack target) |
| **Sentinel** | Log Analytics + 8 data connectors |
| **Key Vault** | Secure secret storage |

## MITRE ATT&CK Detection Coverage

| Technique | ID | Sentinel KQL | Splunk SPL |
|-----------|-----|:---:|:---:|
| Brute Force RDP | T1110.001 | ✅ | ✅ |
| LSASS Credential Dump | T1003.001 | ✅ | ✅ |
| Suspicious PowerShell | T1059.001 | ✅ | ✅ |
| New Service | T1543.003 | ✅ | ✅ |
| Lateral Movement SMB | T1021.002 | ✅ | ✅ |
| Scheduled Task | T1053.005 | ✅ | ✅ |
| Account Discovery | T1087.001 | ✅ | ✅ |
| Event Log Cleared | T1070.001 | ✅ | ✅ |
| Kerberoasting | T1558.003 | ✅ | ✅ |
| Honeypot Login | Custom | ✅ | ✅ |

## Repository Structure

```
AzureSOC/
├── infra/main.bicep                          # Infrastructure as Code (Bicep)
├── scripts/
│   ├── setup/
│   │   ├── master-deploy.ps1                 # ONE SCRIPT deploys everything
│   │   ├── verify-all.ps1                    # Check all 6 components
│   │   ├── start-all.ps1                     # Start VMs
│   │   └── stop-all.ps1                      # Stop VMs (save money)
│   ├── attack/
│   │   └── run-attack-simulation.ps1         # Atomic Red Team attack chains
│   └── detection/
│       ├── sentinel-rules/all-detections.kql # 10 KQL detection rules
│       └── splunk-rules/all-detections.spl   # 10 SPL detection rules
├── cspm/cspm_audit.py                        # Azure cloud posture scanner
├── docs/
│   ├── AzureSOC-Complete-Build-Guide.docx    # Full build guide
│   └── playbooks/T1003.001-credential-dumping.md
├── screenshots/                              # Dashboard screenshots
└── README.md
```

## Attack Simulation

RDP into the DC and run manual MITRE ATT&CK techniques:

```powershell
# T1087.001 - Account Discovery
net user /domain
net group "Domain Admins" /domain

# T1059.001 - Encoded PowerShell
powershell -EncodedCommand UABpAG4AZwAgADEAMAAuADAALgAwAC4AMQA=

# T1053.005 - Scheduled Task Persistence
schtasks /create /tn "TestPersistence" /tr "cmd.exe /c echo test" /sc daily /f

# T1558.003 - Kerberoasting
Add-Type -AssemblyName System.IdentityModel
New-Object System.IdentityModel.Tokens.KerberosRequestorSecurityToken -ArgumentList "MSSQLSvc/dc01.azuresoc.local:1433"

# T1070.001 - Log Clearing
wevtutil cl "Windows PowerShell"
```

All attacks are detected in real-time by Microsoft Sentinel.

## Cost

~$2-4 per 8-hour session with Standard_D2s_v3 VMs. Stop VMs when done:

```powershell
.\scripts\setup\stop-all.ps1    # Stop
.\scripts\setup\start-all.ps1   # Resume next session
```

## Future Enhancements

- Honeypot VM with public IP (requires quota increase to 6+ cores)
- Splunk dashboards for attack visualization
- Power Automate SOAR playbooks for auto-response
- Azure Firewall or pfSense for hub-spoke topology
- Defender for Endpoint EDR integration
- Conditional Access + Entra ID Protection policies

## License

MIT
