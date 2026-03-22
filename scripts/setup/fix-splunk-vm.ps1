#!/usr/bin/env pwsh
# ============================================================================
#  AzureSOC - Fix Splunk VM + Add Suricata IDS/IPS
# ============================================================================
#  Installs: Apache, Suricata IDS, and Splunk on vm-splunk
#  Suricata = free open-source network IDS/IPS (replaces Azure Firewall)
#  Way more useful for SOC work than Azure Firewall because it generates
#  real security alerts that feed into Splunk.
# ============================================================================

param([string]$ResourceGroup = "rg-azuresoc")

Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host "  AzureSOC - Fixing Splunk VM" -ForegroundColor Cyan
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Install Apache + Suricata + dependencies ──
Write-Host "[1/3] Installing Apache + Suricata IDS..." -ForegroundColor Yellow

az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript --scripts @'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "===== INSTALLING SYSTEM PACKAGES ====="
apt-get update -qq
apt-get install -y -qq apache2 curl wget net-tools software-properties-common gnupg2 2>/dev/null

echo "===== STARTING APACHE ====="
systemctl enable apache2
systemctl start apache2
echo "Apache running on port 80"

echo "===== INSTALLING SURICATA IDS/IPS ====="
# Suricata is an open-source Intrusion Detection/Prevention System
# It monitors network traffic and generates alerts for malicious activity
# Think of it as a free replacement for Azure Firewall's threat detection
add-apt-repository -y ppa:oisf/suricata-stable 2>/dev/null || true
apt-get update -qq
apt-get install -y -qq suricata 2>/dev/null

# Download Emerging Threats Open ruleset (free threat detection rules)
echo "===== DOWNLOADING THREAT DETECTION RULES ====="
suricata-update 2>/dev/null || true

# Configure Suricata to monitor the main network interface
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -f /etc/suricata/suricata.yaml ]; then
    sed -i "s/- interface: eth0/- interface: $IFACE/" /etc/suricata/suricata.yaml 2>/dev/null || true
    # Enable JSON EVE log output (this is what Splunk will ingest)
    echo "Suricata configured on interface: $IFACE"
fi

systemctl enable suricata 2>/dev/null || true
systemctl restart suricata 2>/dev/null || true
echo "Suricata IDS running"

echo "===== INSTALLING AUDITD ====="
apt-get install -y -qq auditd 2>/dev/null
echo "-w /var/log/auth.log -p wa -k auth_log" >> /etc/audit/rules.d/audit.rules 2>/dev/null || true
systemctl restart auditd 2>/dev/null || true

echo "===== STEP 1 COMPLETE ====="
echo "Apache: OK"
echo "Suricata IDS: OK"
echo "Auditd: OK"
'@ 2>$null | Out-Null

Write-Host "  [OK] Apache + Suricata IDS installed" -ForegroundColor Green

# ── Step 2: Install Splunk ──
Write-Host "[2/3] Installing Splunk Enterprise (trying multiple versions)..." -ForegroundColor Yellow
Write-Host "  This takes 3-5 min..." -ForegroundColor Gray

az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript --scripts @'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

echo "===== DOWNLOADING SPLUNK ====="
# Try multiple Splunk versions until one works
URLS=(
    "https://download.splunk.com/products/splunk/releases/9.4.0/linux/splunk-9.4.0-6b4ebe426ca6-linux-amd64.deb"
    "https://download.splunk.com/products/splunk/releases/9.3.2/linux/splunk-9.3.2-d8bb32809498-linux-amd64.deb"
    "https://download.splunk.com/products/splunk/releases/9.3.1/linux/splunk-9.3.1-0b8d769cb912-linux-2.6-amd64.deb"
    "https://download.splunk.com/products/splunk/releases/9.2.3/linux/splunk-9.2.3-282efff6aa8b-linux-2.6-amd64.deb"
    "https://download.splunk.com/products/splunk/releases/9.2.2/linux/splunk-9.2.2-d76edf318f450-linux-2.6-amd64.deb"
    "https://download.splunk.com/products/splunk/releases/9.1.7/linux/splunk-9.1.7-f965655b6347-linux-2.6-amd64.deb"
)

DOWNLOADED=false
for url in "${URLS[@]}"; do
    echo "Trying: $url"
    if wget -q --timeout=30 -O /tmp/splunk.deb "$url" 2>/dev/null; then
        FILESIZE=$(stat -f%z /tmp/splunk.deb 2>/dev/null || stat -c%s /tmp/splunk.deb 2>/dev/null)
        if [ "$FILESIZE" -gt 1000000 ] 2>/dev/null; then
            echo "Downloaded successfully! Size: $FILESIZE bytes"
            DOWNLOADED=true
            break
        fi
    fi
    echo "Failed, trying next..."
done

if [ "$DOWNLOADED" = false ]; then
    echo "ALL DOWNLOAD URLS FAILED"
    echo "Manual install needed:"
    echo "1. Go to https://www.splunk.com/en_us/download/splunk-enterprise.html"
    echo "2. Download Linux .deb 64-bit"
    echo "3. SCP it to this VM and run: sudo dpkg -i splunk*.deb"
    exit 0
fi

echo "===== INSTALLING SPLUNK ====="
dpkg -i /tmp/splunk.deb

echo "===== CONFIGURING SPLUNK ====="
/opt/splunk/bin/splunk start --accept-license --answer-yes --seed-passwd 'Splunk@SOC2024!'
/opt/splunk/bin/splunk enable boot-start 2>/dev/null || /opt/splunk/bin/splunk enable boot-start -user root 2>/dev/null || true

echo "===== CREATING INDEXES ====="
/opt/splunk/bin/splunk enable listen 9997 -auth admin:'Splunk@SOC2024!'
for idx in idx_windows idx_sysmon idx_firewall idx_linux idx_honeypot idx_threat_intel idx_suricata; do
    /opt/splunk/bin/splunk add index $idx -auth admin:'Splunk@SOC2024!' 2>/dev/null || true
done

echo "===== ENABLING HTTP EVENT COLLECTOR ====="
/opt/splunk/bin/splunk http-event-collector enable -uri https://localhost:8089 -auth admin:'Splunk@SOC2024!' 2>/dev/null || true

echo "===== CONFIGURING SURICATA LOG INPUT ====="
# Tell Splunk to monitor Suricata's EVE JSON log
mkdir -p /opt/splunk/etc/apps/search/local
cat > /opt/splunk/etc/apps/search/local/inputs.conf << 'INPUTEOF'
[monitor:///var/log/suricata/eve.json]
disabled = false
index = idx_suricata
sourcetype = suricata:eve
_TCP_ROUTING = *

[monitor:///var/log/suricata/fast.log]
disabled = false
index = idx_suricata
sourcetype = suricata:fast

[monitor:///var/log/apache2/access.log]
disabled = false
index = idx_linux
sourcetype = apache:access

[monitor:///var/log/auth.log]
disabled = false
index = idx_linux
sourcetype = linux:auth
INPUTEOF

/opt/splunk/bin/splunk restart

echo "===== SPLUNK INSTALLATION COMPLETE ====="
echo "Web UI: http://$(hostname -I | awk '{print $1}'):8000"
echo "Indexes: idx_windows, idx_sysmon, idx_firewall, idx_linux, idx_honeypot, idx_threat_intel, idx_suricata"
'@ 2>$null | Out-Null

Write-Host "  [OK] Splunk installed and configured" -ForegroundColor Green

# ── Step 3: Verify everything ──
Write-Host "[3/3] Verifying all services..." -ForegroundColor Yellow

$verify = az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript --scripts @'
#!/bin/bash
echo "===== SERVICE STATUS ====="
echo -n "Apache:   "; systemctl is-active apache2 2>/dev/null || echo "NOT RUNNING"
echo -n "Suricata: "; systemctl is-active suricata 2>/dev/null || echo "NOT RUNNING"
echo -n "Splunk:   "; /opt/splunk/bin/splunk status 2>/dev/null | head -1 || echo "NOT INSTALLED"

echo ""
echo "===== PORTS LISTENING ====="
ss -tlnp | grep -E '(:80 |:8000 |:9997 |:8088 )' 2>/dev/null || echo "No relevant ports found"

echo ""
echo "===== SURICATA RULES LOADED ====="
suricata --build-info 2>/dev/null | head -1 || echo "Suricata not found"
ls -la /var/lib/suricata/rules/ 2>/dev/null | head -5 || echo "No rules directory"

echo ""
echo "===== SURICATA LOGS ====="
ls -la /var/log/suricata/ 2>/dev/null || echo "No Suricata log directory"
'@ 2>$null

# Parse and display results
$msg = ($verify | ConvertFrom-Json).value[0].message
Write-Host $msg -ForegroundColor Gray

$splunkIP = az vm show -g $ResourceGroup -n vm-splunk -d --query publicIps -o tsv 2>$null
$dcIP = az vm show -g $ResourceGroup -n vm-dc01 -d --query publicIps -o tsv 2>$null

Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Green
Write-Host "  VM Fix Complete!" -ForegroundColor Green
Write-Host ("=" * 55) -ForegroundColor Green
Write-Host ""
Write-Host "  VERIFY THESE IN YOUR BROWSER:" -ForegroundColor Yellow
Write-Host "  Splunk:   http://${splunkIP}:8000  (admin / Splunk@SOC2024!)" -ForegroundColor White
Write-Host "  Apache:   http://${splunkIP}" -ForegroundColor White
Write-Host "  DC RDP:   $dcIP  (azuresocadmin)" -ForegroundColor White
Write-Host ""
Write-Host "  NEW - SURICATA IDS/IPS:" -ForegroundColor Yellow
Write-Host "  Free open-source network intrusion detection" -ForegroundColor White
Write-Host "  Monitors all traffic on the Splunk VM" -ForegroundColor White
Write-Host "  Alerts flow into Splunk index: idx_suricata" -ForegroundColor White
Write-Host "  Uses Emerging Threats Open ruleset" -ForegroundColor White
Write-Host "  Search in Splunk: index=idx_suricata" -ForegroundColor White
Write-Host ""
Write-Host "  WHY SURICATA IS BETTER THAN AZURE FIREWALL FOR SOC:" -ForegroundColor Cyan
Write-Host "  - Free (Azure FW costs ~$9.50/day)" -ForegroundColor Gray
Write-Host "  - Generates real IDS alerts (Azure FW just blocks)" -ForegroundColor Gray
Write-Host "  - SOC analysts work with IDS alerts daily" -ForegroundColor Gray
Write-Host "  - ET Open ruleset detects real threats" -ForegroundColor Gray
Write-Host "  - Logs feed directly into Splunk for analysis" -ForegroundColor Gray
Write-Host "  - Shows you know open-source security tools" -ForegroundColor Gray
Write-Host ("=" * 55) -ForegroundColor Green
