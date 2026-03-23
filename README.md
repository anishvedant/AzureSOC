# AzureSOC — Cloud Security Operations Center

Deploy a complete SOC lab on Azure in one command. Includes Active Directory, Microsoft Sentinel SIEM, Suricata IDS, Sysmon, and MITRE ATT&CK attack simulation.

---

## Deploy in 3 Steps

### Prerequisites
- Azure account ([free $200 credit](https://azure.microsoft.com/en-us/free/))
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed
- PowerShell 7+ or Windows PowerShell
- Git

### Step 1 — Clone and deploy
```powershell
git clone https://github.com/anishvedant/AzureSOC.git
cd AzureSOC
az login
.\scripts\setup\master-deploy.ps1 -AdminPassword "YourStr0ngP@ss!"
```

The script auto-scans **10 Azure regions** and **7 VM sizes** to find what's available in your subscription, then deploys everything. Takes 20–40 minutes.

### Step 2 — Connect logs to Sentinel
1. Go to **portal.azure.com** → search **Microsoft Sentinel** → select **law-azuresoc**
2. Click **Data connectors** → **Windows Security Events via AMA** → **Open connector page**
3. Click **+Create data collection rule** → name it `dcr-windows` → add **vm-dc01** → select **All Security Events** → Create

### Step 3 — Run attacks and detect them
RDP into the DC (IP shown in deploy output), open PowerShell, and run:
```powershell
# Account discovery (T1087.001)
net user /domain
net group "Domain Admins" /domain

# Kerberoasting (T1558.003)
Add-Type -AssemblyName System.IdentityModel
New-Object System.IdentityModel.Tokens.KerberosRequestorSecurityToken -ArgumentList "MSSQLSvc/dc01.azuresoc.local:1433"

# Encoded PowerShell (T1059.001)
powershell -EncodedCommand dwBoAG8AYQBtAGkA

# Persistence via scheduled task (T1053.005)
schtasks /create /tn "TestPersistence" /tr "cmd.exe /c echo test" /sc hourly /f
schtasks /delete /tn "TestPersistence" /f

# Clear event logs (T1070.001)
wevtutil cl "Windows PowerShell"
```

Then go to **Sentinel → Logs** and run:
```kql
SecurityEvent
| where TimeGenerated > ago(1h)
| where EventID in (4688, 4624, 4625, 4672, 4698, 4769, 1102)
| project TimeGenerated, EventID, Activity, Account, CommandLine
| sort by TimeGenerated desc
```

You'll see every attack detected in real time.

---

## What Gets Deployed

```
                    ┌──────────────────────────────┐
                    │      Microsoft Sentinel       │
                    │   Cloud SIEM · 8 connectors   │
                    └──────────┬───────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │     Azure VNet: 10.0.0.0/16                 │
        │                                             │
        │  ┌──────────────┐   ┌────────────────────┐  │
        │  │ snet-dc      │   │ snet-linux         │  │
        │  │ 10.0.1.0/24  │   │ 10.0.2.0/24        │  │
        │  │              │   │                    │  │
        │  │  vm-dc01     │   │  vm-splunk         │  │
        │  │  Windows     │◄──┤  Ubuntu 22.04      │  │
        │  │  AD + Sysmon │   │  Suricata + Apache │  │
        │  └──────────────┘   └────────────────────┘  │
        │                                             │
        │  ┌────────────────────────────────────────┐  │
        │  │ snet-honeypot · 10.0.3.0/24            │  │
        │  │ NSG allows ALL (ready for trap VM)      │  │
        │  └────────────────────────────────────────┘  │
        └─────────────────────────────────────────────┘
```

| Resource | Details |
|----------|---------|
| **vm-dc01** | Windows Server 2022 — AD DS, DNS, Sysmon v15 (SwiftOnSecurity config) |
| **vm-splunk** | Ubuntu 22.04 — Suricata IDS (65K+ rules), Apache honeypot |
| **Sentinel** | Log Analytics workspace + 8 data connectors |
| **VNet** | 3 subnets, each with its own NSG |
| **Key Vault** | Secure storage for API keys |
| **18 resources total** | VMs, NICs, public IPs, NSGs, storage, DCR |

## Active Directory Environment

| Account | Role | Attack Scenario |
|---------|------|----------------|
| azuresocadmin | Domain Admin | Primary admin |
| jsmith, sconnor, mjones, edavis, jwilson, lbrown | Domain Users | Password spray targets |
| admin.backup | Domain Admin | Over-privileged account target |
| svc.sql | Service Account | **Kerberoastable** — has SPN `MSSQLSvc/dc01:1433` |

## MITRE ATT&CK Coverage

| Technique | ID | Sentinel KQL Detection |
|-----------|----|----------------------|
| Network Scanning | T1046 | NSG flow logs |
| Brute Force RDP | T1110.001 | `EventID == 4625` with count threshold |
| Kerberoasting | T1558.003 | `EventID == 4769` non-machine SPN |
| Account Discovery | T1087.001 | `CommandLine has "net user"` |
| Encoded PowerShell | T1059.001 | `CommandLine has "EncodedCommand"` |
| Scheduled Task | T1053.005 | `EventID == 4698` |
| Log Clearing | T1070.001 | `EventID == 1102` |
| System Discovery | T1082 | `CommandLine has "systeminfo"` |
| SMB Enumeration | T1021.002 | `EventID in (5140, 5145)` |
| LSASS Access | T1003.001 | Sysmon Event 10 |

## Useful Commands

```powershell
.\scripts\setup\verify-all.ps1    # Check all 6 components
.\scripts\setup\stop-all.ps1      # Stop VMs ($0 compute cost)
.\scripts\setup\start-all.ps1     # Resume next session
```

## Cost

| Running | ~$0.40/hr (~$3/session) |
|---------|------------------------|
| Stopped | ~$0.10/day (storage only) |

## Repository Structure

```
├── infra/main.bicep                          # Bicep IaC template
├── scripts/
│   ├── setup/master-deploy.ps1               # One-command deployment
│   ├── setup/verify-all.ps1                  # Health check
│   ├── setup/start-all.ps1 / stop-all.ps1   # Cost management
│   ├── attack/run-attack-simulation.ps1      # Attack chains
│   └── detection/sentinel-rules/*.kql        # 10 KQL rules
├── cspm/cspm_audit.py                        # Cloud posture scanner
├── docs/
│   ├── attack-defense-guide/                 # Full attack playbook
│   └── playbooks/                            # Purple team playbooks
└── screenshots/
```

## Full Report

Complete project documentation with network topology, beginner explanations, Kerberos walkthrough, and attack-to-detection pipeline: [Notion Report](https://www.notion.so/32c021e08b218123a013fbbbccdbbbfc)

## License

MIT
