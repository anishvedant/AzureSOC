# 🛡️ AzureSOC — Open Source Cloud Security Operations Center

> A fully automated, deployable SOC environment with attack simulation, detection engineering, and incident response automation on Microsoft Azure.

## 🎯 What Is This?

AzureSOC is a **production-grade Security Operations Center** deployed entirely on Azure that:

1. **Deploys a full SOC environment** with every major security tool integrated
2. **Simulates real attacks** and detects them with MITRE ATT&CK-mapped rules
3. **Automatically responds to incidents** with SOAR automation
4. **Runs a live honeypot** collecting real-world attack data 24/7
5. **Uses dual SIEMs** (Microsoft Sentinel + Splunk) for maximum learning

## 🏗️ Architecture — 10 Integrated Layers

| Layer | Components | Purpose |
|-------|-----------|---------|
| **1. Network** | Hub-Spoke VNets, Azure Firewall, NSGs, Bastion | Enterprise network topology |
| **2. Compute** | 5 VMs (DC, Workstation, Linux, Honeypot, Splunk) | Target environment |
| **3. Endpoint (EDR)** | Microsoft Defender for Endpoint, Sysmon | Deep endpoint visibility |
| **4. XDR** | Microsoft Defender XDR | Cross-signal incident correlation |
| **5. Identity** | Entra ID Protection, Conditional Access, PIM | Identity threat detection |
| **6. SIEM (Dual)** | Microsoft Sentinel + Splunk Enterprise | Log analysis & alerting |
| **7. Threat Intel** | STIX/TAXII feeds, VirusTotal, AbuseIPDB | IOC enrichment |
| **8. SOAR** | Power Automate + Logic Apps playbooks | Automated incident response |
| **9. Attack Sim** | Atomic Red Team, MITRE Caldera | Purple team exercises |
| **10. CSPM** | Custom Python tool + Defender for Cloud | Cloud posture monitoring |

## 🚀 Quick Start — Deploy in 30 Minutes

### Prerequisites
- Azure account with $200 free credit
- Azure CLI installed
- PowerShell 7+

### One-Click Deploy
```powershell
# Clone the repo
git clone https://github.com/yourusername/AzureSOC.git
cd AzureSOC

# Login to Azure
az login
az account set --subscription "<your-subscription-id>"

# Deploy EVERYTHING with one command (takes 45-60 min)
./scripts/setup/master-deploy.ps1 -AdminPassword "YourStr0ngP@ssw0rd!"
```

This single script deploys the entire network, all 5 VMs, Sentinel, Key Vault, Azure Firewall, Active Directory, Sysmon, Splunk, and forwarders — all from your laptop. No manual RDP needed.

### Post-Deployment (Portal-only steps, ~15 min)
```
1. Sentinel > Data connectors > Enable: Windows Security Events via AMA, Entra ID, Defender XDR
2. security.microsoft.com > Onboard VMs to Defender for Endpoint
3. Entra ID > Security > Enable Identity Protection + Conditional Access
```

### Run Attack Simulation
```powershell
# Connect to vm-workstation01 via Bastion, then:
./scripts/attack/run-attack-simulation.ps1
```

## 💰 Cost Breakdown

| Resource | Hourly | Daily (8hr) |
|----------|--------|-------------|
| Azure Firewall (Basic) | $0.395 | $3.16 |
| 5 VMs (B2s/B2ms) | ~$0.29 | ~$2.30 |
| Bastion (Basic) | $0.19 | $1.52 |
| Sentinel + Logs | ~$0.25 | ~$2.00 |
| **Total** | **~$1.13** | **~$9.00** |

**Cost saving scripts included:**
```powershell
./scripts/stop-all.ps1    # Deallocate all VMs ($0 compute cost)
./scripts/start-all.ps1   # Start all VMs next session
```

## 📁 Repository Structure

```
AzureSOC/
├── infra/
│   └── main.bicep               # One-click infrastructure template
├── scripts/
│   ├── deploy.ps1                # Master deployment script
│   ├── configure-ad-part1.ps1    # AD forest creation
│   ├── configure-ad-part2.ps1    # Users, groups, policies
│   ├── install-sysmon.ps1        # Sysmon on Windows VMs
│   ├── install-splunk.sh         # Splunk Enterprise setup
│   ├── install-splunk-forwarder.ps1  # Splunk UF on Windows
│   ├── start-all.ps1             # Start VMs
│   └── stop-all.ps1              # Stop VMs (save money!)
├── detection/
│   ├── sentinel-rules/           # KQL analytics rules
│   └── splunk-rules/             # SPL correlation searches
├── automation/
│   ├── logic-apps/               # Sentinel SOAR playbooks
│   └── power-automate/           # Power Automate flows
├── cspm/
│   └── cspm_audit.py             # Cloud posture scanner
├── docs/
│   ├── playbooks/                # Purple team playbook library
│   └── AzureSOC-Build-Guide.docx # Complete deployment guide
└── screenshots/                  # Dashboard & detection screenshots
```

## 🗡️ MITRE ATT&CK Coverage

Detections written for both Sentinel (KQL) and Splunk (SPL):

| Technique | ID | Sentinel | Splunk |
|-----------|-----|----------|--------|
| Brute Force | T1110.001 | ✅ | ✅ |
| PowerShell Execution | T1059.001 | ✅ | ✅ |
| LSASS Credential Dump | T1003.001 | ✅ | ✅ |
| Scheduled Task | T1053.005 | ✅ | ✅ |
| New Service | T1543.003 | ✅ | ✅ |
| Lateral Movement SMB | T1021.002 | ✅ | ✅ |
| Account Discovery | T1087.001 | ✅ | ✅ |
| Log Clearing | T1070.001 | ✅ | ✅ |
| *...and 12+ more* | | | |

## 🤖 SOAR Playbooks

| Playbook | Trigger | Actions |
|----------|---------|---------|
| IOC Enrichment | Any Sentinel incident | VirusTotal + AbuseIPDB + Shodan lookup |
| Auto-Block IP | Malicious IP detected | NSG deny rule + TI indicator + Teams alert |
| Isolate Endpoint | High-severity EDR alert | Defender isolate + forensic collection + disable user |
| Daily Posture Report | Scheduled (8 AM) | Incident counts + Secure Score + email |
| Phishing Analyzer | HTTP request | URL reputation + WHOIS + SSL check + score |

## 📜 License

MIT — Use freely, contribute back.

## 🤝 Contributing

PRs welcome! Especially for:
- New MITRE ATT&CK detection rules
- Additional SOAR playbooks
- Cost optimization tips
- Documentation improvements
