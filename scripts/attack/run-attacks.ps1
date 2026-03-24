#!/usr/bin/env pwsh
# ============================================================================
#  AzureSOC - Attack Simulation Toolkit
# ============================================================================
#  Consolidated script: port scanning, honeypot deployment, and all
#  MITRE ATT&CK attack simulations from a single file.
#
#  USAGE:
#    .\run-attacks.ps1 -Action scan        # Nmap port scan DC from Linux VM
#    .\run-attacks.ps1 -Action honeypot    # Deploy fake login page on Apache
#    .\run-attacks.ps1 -Action webscan     # Nikto web vulnerability scan
#    .\run-attacks.ps1 -Action bruteforce  # Hydra RDP brute force
#    .\run-attacks.ps1 -Action all         # Run scan + webscan + honeypot
#
#  NOTE: AD attacks (Kerberoasting, enumeration, persistence, log clearing)
#  must be run manually via RDP on the DC. See the Notion report for commands.
# ============================================================================

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("scan","honeypot","webscan","bruteforce","all")]
    [string]$Action,
    [string]$ResourceGroup = "rg-azuresoc"
)

function Run-PortScan {
    Write-Host "[ATTACK] Nmap port scan against DC (T1046)..." -ForegroundColor Red

    $script = @'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
add-apt-repository -y universe 2>/dev/null
apt-get update -qq
apt-get install -y nmap nikto hydra smbclient 2>/dev/null

echo "=== PORT SCAN of DC (10.0.1.4) ==="
if command -v nmap &> /dev/null; then
    nmap -sV -sC 10.0.1.4 2>&1 | head -50
else
    echo "nmap not available, using bash scanner..."
    for port in 22 53 80 88 135 139 389 443 445 636 3389 5985 9389; do
        (echo >/dev/tcp/10.0.1.4/${port}) 2>/dev/null && echo "OPEN: port ${port}" || echo "CLOSED: port ${port}"
    done
fi
echo "=== SCAN COMPLETE ==="
'@

    az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript --scripts $script
}

function Deploy-Honeypot {
    Write-Host "[SETUP] Deploying honeypot login page (Apache)..." -ForegroundColor Yellow

    $html = @"
<html>
<head><title>AZURESOC Corp - Employee Portal</title></head>
<body style="font-family:Arial;max-width:420px;margin:100px auto;text-align:center;">
<div style="border:1px solid #ddd;padding:30px;border-radius:8px;">
<h2 style="color:#0078D4;">AZURESOC Corp</h2>
<h3>Employee Portal Login</h3>
<form method="POST" action="/login.php">
<input type="text" name="user" placeholder="Username" style="width:90%;padding:10px;margin:8px 0;border:1px solid #ccc;border-radius:4px;"><br>
<input type="password" name="pass" placeholder="Password" style="width:90%;padding:10px;margin:8px 0;border:1px solid #ccc;border-radius:4px;"><br>
<button type="submit" style="width:94%;padding:12px;background:#0078D4;color:white;border:none;border-radius:4px;font-size:16px;">Sign In</button>
</form>
<p style="color:gray;font-size:11px;">WARNING: All login attempts are logged by the SOC.</p>
</div></body></html>
"@

    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($html))
    $splunkIP = az vm show -g $ResourceGroup -n vm-splunk -d --query publicIps -o tsv 2>$null

    az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript `
        --scripts "systemctl start apache2; echo $b64 | base64 -d > /var/www/html/index.html; systemctl restart apache2; echo DEPLOYED" `
        --only-show-errors

    Write-Host "[OK] Honeypot at http://${splunkIP}" -ForegroundColor Green
}

function Run-WebScan {
    Write-Host "[ATTACK] Nikto web vulnerability scan (T1595.002)..." -ForegroundColor Red

    $script = @'
#!/bin/bash
if command -v nikto &> /dev/null; then
    nikto -h http://localhost 2>&1 | head -20
else
    echo "nikto not installed. Run with -Action scan first."
fi
'@

    az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript --scripts $script
}

function Run-BruteForce {
    Write-Host "[ATTACK] Hydra RDP brute force (T1110.001)..." -ForegroundColor Red

    $script = @'
#!/bin/bash
if ! command -v hydra &> /dev/null; then echo "hydra not installed. Run with -Action scan first."; exit 0; fi
echo -e "admin\nazuresocadmin\njsmith\nadmin.backup\nsvc.sql" > /tmp/users.txt
echo -e "password\nP@ssw0rd\nWinter2026\nadmin123\nletmein\nUser@1234" > /tmp/passwords.txt
hydra -L /tmp/users.txt -P /tmp/passwords.txt 10.0.1.4 rdp -t 4 -V 2>&1 | tail -30
'@

    az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript --scripts $script
}

# Main
Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Red
Write-Host "  AzureSOC Attack Toolkit" -ForegroundColor Red
Write-Host ("=" * 50) -ForegroundColor Red
Write-Host ""

switch ($Action) {
    "scan"       { Run-PortScan }
    "honeypot"   { Deploy-Honeypot }
    "webscan"    { Run-WebScan }
    "bruteforce" { Run-BruteForce }
    "all"        { Run-PortScan; Deploy-Honeypot; Run-WebScan }
}

Write-Host ""
Write-Host "  NEXT: Check Sentinel for detections:" -ForegroundColor Yellow
Write-Host "  SecurityEvent | where TimeGenerated > ago(1h) | where EventID in (4625,4688,4769,1102)" -ForegroundColor Gray
Write-Host ""
Write-Host "  AD attacks (run manually via RDP on DC):" -ForegroundColor Yellow
Write-Host "  - net user /domain                    (T1087 Account Discovery)" -ForegroundColor Gray
Write-Host "  - Kerberoasting svc.sql SPN           (T1558.003)" -ForegroundColor Gray
Write-Host "  - schtasks /create                    (T1053.005 Persistence)" -ForegroundColor Gray
Write-Host "  - powershell -EncodedCommand          (T1059.001)" -ForegroundColor Gray
Write-Host "  - wevtutil cl                         (T1070.001 Log Clearing)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Full attack guide: https://www.notion.so/32c021e08b218123a013fbbbccdbbbfc" -ForegroundColor Cyan
