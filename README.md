# AzureSOC - Cloud Security Operations Center

Deploy a full SOC lab on Azure with one command. Active Directory, Microsoft Sentinel SIEM, Suricata IDS, Sysmon, and MITRE ATT&CK attack simulation.

## Deploy

```powershell
git clone https://github.com/anishvedant/AzureSOC.git
cd AzureSOC
az login
.\scripts\setup\master-deploy.ps1 -AdminPassword "YourStr0ngP@ss!"
```

Auto-scans 10 regions and 7 VM sizes. Deploys in 20–40 minutes.

**After deploy - connect logs to Sentinel:**
Portal → Microsoft Sentinel → law-azuresoc → Data connectors → Windows Security Events via AMA → Create DCR → select vm-dc01 → All Security Events

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          INTERNET (Your laptop)                         │
└──────────────────┬──────────────────────┬───────────────────────────────┘
                   │ RDP :3389            │ SSH :22 / HTTP :80
                   │                      │
┌──────────────────┴──────────────────────┴──────────────────────────────┐
│                 Azure VNet: vnet-azuresoc (10.0.0.0/16)                │
│                                                                        │
│  ┌────────────────────────────┐     ┌─────────────────────────────┐    │
│  │ snet-dc (10.0.1.0/24)      │     │ snet-splunk (10.0.2.0/24)   │    │
│  │ NSG: RDP + AD ports        │     │ NSG: SSH + HTTP             │    │
│  │                            │     │                             │    │
│  │  vm-dc01 (10.0.1.4)        │     │  vm-splunk (10.0.2.4)       │    │
│  │  Windows Server 2022       │     │  Ubuntu 22.04 LTS           │    │
│  │  • Active Directory        │nmap │  • Suricata IDS (65K rules) │    │
│  │  • DNS + Kerberos      ◄───┼─────┤  • Apache 2.4 (honeypot)    │    │
│  │  • Sysmon v15              │hydra│  • nmap, nikto, hydra       │    │
│  │  • Azure Monitor Agent     │nikto│    (attack tools)           │    │
│  │  • 11 AD Users             │     │                             │    │
│  └────────────┬───────────────┘     └─────────────────────────────┘    │
│               │                                                        │
│               │ SecurityEvent + Sysmon via AMA                         │
│  ┌────────────┴──────────────────────────────────────────────────┐     │
│  │ snet-honeypot (10.0.3.0/24) - NSG: ALLOW ALL (future trap)    │     │
│  └───────────────────────────────────────────────────────────────┘     │
└───────────────────────────────┬────────────────────────────────────────┘
                                │
              ┌─────────────────┴──────────────────────┐
              │  Data Collection Rule → Log Analytics  │
              │  → Microsoft Sentinel (SIEM)           │
              │    • 8 Data Connectors                 │
              │    • 1000+ Security Events             │
              │    • Custom KQL Analytics Rules        │
              │    • Automated Incident Creation       │
              └────────────────────────────────────────┘

Supporting: Key Vault (secrets) • Storage Account (flow logs) • Network Watcher
```

18 resources total: 2 VMs, VNet, 3 NSGs, Sentinel, Key Vault, Storage, DCR, NICs, Public IPs, Network Watcher.

## Run Attacks

```powershell
.\scripts\attack\run-attacks.ps1 -Action all       # Scan + honeypot + web scan
.\scripts\attack\run-attacks.ps1 -Action scan       # Nmap port scan
.\scripts\attack\run-attacks.ps1 -Action bruteforce  # RDP brute force
```

AD attacks (run manually via RDP on DC):
```powershell
net user /domain                          # T1087 Account Discovery
Add-Type -AssemblyName System.IdentityModel
New-Object System.IdentityModel.Tokens.KerberosRequestorSecurityToken -ArgumentList "MSSQLSvc/dc01.azuresoc.local:1433"  # T1558.003 Kerberoasting
schtasks /create /tn "Test" /tr "cmd /c echo test" /sc hourly /f   # T1053.005 Persistence
powershell -EncodedCommand dwBoAG8AYQBtAGkA                        # T1059.001 Encoded PS
wevtutil cl "Windows PowerShell"                                    # T1070.001 Log Clearing
```

Detect in Sentinel → Logs:
```kql
SecurityEvent
| where TimeGenerated > ago(1h)
| where EventID in (4688, 4624, 4625, 4672, 4698, 4769, 1102)
| project TimeGenerated, EventID, Activity, Account, CommandLine
| sort by TimeGenerated desc
```

## MITRE ATT&CK Coverage

| Technique | ID | Detection |
|-----------|----|-----------|
| Network Scanning | T1046 | Nmap + NSG logs |
| Brute Force RDP | T1110.001 | EventID 4625 analytics rule |
| Kerberoasting | T1558.003 | EventID 4769 |
| Account Discovery | T1087.001 | CommandLine monitoring |
| Encoded PowerShell | T1059.001 | EncodedCommand detection |
| Scheduled Task | T1053.005 | EventID 4698 |
| Log Clearing | T1070.001 | EventID 1102 |
| Web Scanning | T1595.002 | Nikto + Apache logs |
| SMB Enumeration | T1021.002 | EventID 5140 |
| LSASS Access | T1003.001 | Sysmon Event 10 |

## Manage

```powershell
.\scripts\setup\verify-all.ps1    # Health check
.\scripts\setup\stop-all.ps1      # Stop VMs (~$0/hr)
.\scripts\setup\start-all.ps1     # Resume
```

Cost: ~$3 per 8-hour session. ~$0.10/day when stopped.

## Repo Structure

```
├── infra/main.bicep                      # Bicep IaC (18 resources)
├── scripts/
│   ├── setup/
│   │   ├── master-deploy.ps1             # One-command deployment
│   │   ├── verify-all.ps1               # Health check
│   │   ├── start-all.ps1 / stop-all.ps1 # Cost management
│   ├── attack/
│   │   └── run-attacks.ps1              # All attacks in one script
│   └── detection/
│       └── sentinel-rules/all-detections.kql  # 10 KQL rules
└── cspm/cspm_audit.py                   # Azure posture scanner
```

## Full Report

Complete documentation with network topology, Kerberos walkthrough, attack-to-detection pipeline, and evidence screenshots:

**[AzureSOC - Complete SOC Lab Report](https://www.notion.so/32c021e08b218123a013fbbbccdbbbfc)**

## License

MIT
