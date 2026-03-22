# AzureSOC - Open Source Cloud Security Operations Center

A fully automated, deployable SOC environment with attack simulation, detection engineering, and incident response automation on Microsoft Azure.

## What Is This?

AzureSOC deploys a **complete Security Operations Center** on Azure that:

- Runs **Active Directory** with realistic users, admins, and Kerberoastable service accounts
- Deploys **dual SIEMs**: Microsoft Sentinel (cloud-native) + Splunk Enterprise
- Installs **Sysmon** for deep endpoint telemetry with SwiftOnSecurity config
- Includes **MITRE ATT&CK** mapped detection rules for both Sentinel (KQL) and Splunk (SPL)
- Provides **attack simulation** scripts using Atomic Red Team
- Contains a **CSPM tool** that audits Azure misconfigurations
- Publishes **purple team playbooks** the cybersec community can use
- Runs an **Apache web server** as a Linux attack target

## Quick Start - Deploy in One Command

```powershell
az login
cd C:\Projects\files
.\scripts\setup\master-deploy.ps1 -AdminPassword "AzureS0C@2026!"
```

The script automatically finds a working Azure region and VM size, then deploys everything: VNet, NSGs, 2 VMs, Active Directory, Sysmon, Splunk, Apache, Sentinel, and Key Vault. Takes 40-60 minutes.

## Architecture

**Phase 1 (Deployed by master script):**
| Component | Details |
|-----------|---------|
| VNet | 10.0.0.0/16 with 3 subnets (DC, Splunk, Honeypot) |
| VM: DC | Windows Server 2022 - AD DS, Sysmon, Splunk Forwarder |
| VM: Splunk | Ubuntu 22.04 - Splunk Enterprise, Apache web server |
| Sentinel | Microsoft Sentinel + Log Analytics workspace |
| Key Vault | Stores API keys for automations |

**Phase 2 (Add manually later):**
| Component | Details |
|-----------|---------|
| Honeypot VM | Windows with weak creds, public IP (NSG ready) |
| Azure Firewall | Hub-spoke traffic inspection |
| Azure Bastion | Secure RDP/SSH without public IPs |
| Defender for Endpoint | EDR on all Windows VMs |
| Defender XDR | Cross-signal incident correlation |
| Entra ID Protection | Identity threat detection |
| Power Automate | SOAR playbooks |
| Logic Apps | Sentinel-native automation |

## Repository Structure

```
AzureSOC/
├── infra/main.bicep                          # Infrastructure as Code
├── scripts/
│   ├── setup/
│   │   ├── master-deploy.ps1                 # ONE SCRIPT deploys everything
│   │   ├── start-all.ps1                     # Start VMs
│   │   └── stop-all.ps1                      # Stop VMs (save money)
│   ├── attack/
│   │   └── run-attack-simulation.ps1         # Atomic Red Team attack chains
│   ├── detection/
│   │   ├── sentinel-rules/all-detections.kql # 10 Sentinel KQL rules
│   │   └── splunk-rules/all-detections.spl   # 10 Splunk SPL rules
│   └── automation/                           # SOAR playbook templates
├── cspm/cspm_audit.py                        # Cloud posture scanner
├── docs/
│   ├── AzureSOC-Complete-Build-Guide.docx    # Full build guide
│   └── playbooks/                            # Purple team playbook library
└── screenshots/
```

## MITRE ATT&CK Detection Coverage

| Technique | ID | Sentinel KQL | Splunk SPL |
|-----------|-----|:---:|:---:|
| Brute Force RDP | T1110.001 | Y | Y |
| LSASS Credential Dump | T1003.001 | Y | Y |
| Suspicious PowerShell | T1059.001 | Y | Y |
| New Service Created | T1543.003 | Y | Y |
| Lateral Movement SMB | T1021.002 | Y | Y |
| Scheduled Task | T1053.005 | Y | Y |
| Account Discovery | T1087.001 | Y | Y |
| Event Log Cleared | T1070.001 | Y | Y |
| Kerberoasting | T1558.003 | Y | Y |
| Honeypot Login | Custom | Y | Y |

## Cost

| Resource | Hourly | Per 8hr Session |
|----------|--------|----------------|
| 2x Standard_D2s_v3 VMs | ~$0.19 | ~$1.52 |
| Sentinel + Log Analytics | ~$0.10 | ~$0.80 |
| Storage + Key Vault | minimal | ~$0.05 |
| **Total** | **~$0.30** | **~$2.40** |

**Save money:** `.\scripts\setup\stop-all.ps1` when done for the day.

## License

MIT
