#!/bin/bash
# ================================================================
# AzureSOC - Splunk Enterprise Installation Script
# ================================================================
# WHAT IS SPLUNK:
# Splunk is one of the two most popular SIEMs (Security Information
# and Event Management) in the industry, alongside Microsoft Sentinel.
# It collects logs from everywhere, lets you search them with SPL
# (Search Processing Language), build dashboards, and create alerts.
#
# WHY WE USE BOTH SPLUNK AND SENTINEL:
# Most enterprises use one or the other. By building detections in
# BOTH, you demonstrate proficiency in the two dominant SIEM platforms.
# In job interviews, being able to say "I can write KQL for Sentinel
# AND SPL for Splunk" sets you apart from other candidates.
#
# HOW SPLUNK WORKS:
# 1. Data comes IN via "inputs" (forwarders, HEC, file monitoring)
# 2. Splunk "indexes" the data (organizes it for fast searching)
# 3. You search with SPL queries in the Search bar
# 4. You build dashboards, alerts, and reports from those searches
#
# FREE DEV LICENSE: 500MB/day indexing limit. That's plenty for a lab.
# Get yours at: https://dev.splunk.com/enterprise/
#
# RUN THIS ON: vm-splunk (connect via Azure Bastion SSH)
# ================================================================

set -e
echo "========================================"
echo "  AzureSOC - Splunk Installation"
echo "========================================"

# ── Step 1: System Preparation ──
echo ""
echo "[1/5] Preparing system..."
sudo apt update -qq
sudo apt install -y -qq wget curl net-tools 2>/dev/null

# ── Step 2: Download Splunk ──
# NOTE: You need to get the latest download URL from splunk.com
# The URL below may be outdated. Visit:
# https://www.splunk.com/en_us/download/splunk-enterprise.html
# Select Linux > .deb > copy the wget URL
echo ""
echo "[2/5] Downloading Splunk Enterprise..."
echo "  NOTE: If this URL is outdated, download manually from splunk.com"
echo "  and upload the .deb file to this VM."

# Check if already downloaded
if [ -f /tmp/splunk.deb ]; then
    echo "  Splunk .deb already exists, using cached version"
else
    # TRY downloading - URL may need updating
    wget -q --show-progress -O /tmp/splunk.deb \
        "https://download.splunk.com/products/splunk/releases/9.3.1/linux/splunk-9.3.1-0b8d769cb912-linux-2.6-amd64.deb" 2>/dev/null || {
        echo ""
        echo "  ⚠️  Download failed! The URL may have changed."
        echo "  MANUAL STEPS:"
        echo "  1. Go to https://www.splunk.com/en_us/download/splunk-enterprise.html"
        echo "  2. Create a free account if needed"
        echo "  3. Download the Linux .deb 64-bit package"
        echo "  4. Upload it to this VM as /tmp/splunk.deb"
        echo "  5. Re-run this script"
        exit 1
    }
fi

# ── Step 3: Install Splunk ──
echo ""
echo "[3/5] Installing Splunk..."
sudo dpkg -i /tmp/splunk.deb

# ── Step 4: Start Splunk and Accept License ──
# --seed-passwd sets the admin password for the web interface
# Splunk runs on port 8000 (web UI) and 8089 (management API)
echo ""
echo "[4/5] Starting Splunk (first boot takes 1-2 minutes)..."
sudo /opt/splunk/bin/splunk start --accept-license --answer-yes \
    --seed-passwd 'Splunk@SOC2024!'

# Enable auto-start on boot
sudo /opt/splunk/bin/splunk enable boot-start -user splunk 2>/dev/null || \
    sudo /opt/splunk/bin/splunk enable boot-start

# ── Step 5: Configure Receiving and Indexes ──
# Enable receiving on port 9997 - this is where Universal Forwarders
# send their data. Think of it as opening the mailbox.
echo ""
echo "[5/5] Configuring Splunk inputs and indexes..."

# Enable receiving port for Universal Forwarders
sudo /opt/splunk/bin/splunk enable listen 9997 -auth admin:'Splunk@SOC2024!'

# Create custom indexes for organized data storage
# WHY SEPARATE INDEXES: In a real SOC, you separate data by source
# so you can apply different retention policies, access controls,
# and search permissions. It also makes searches faster.
sudo /opt/splunk/bin/splunk add index idx_windows -auth admin:'Splunk@SOC2024!'
sudo /opt/splunk/bin/splunk add index idx_sysmon -auth admin:'Splunk@SOC2024!'
sudo /opt/splunk/bin/splunk add index idx_firewall -auth admin:'Splunk@SOC2024!'
sudo /opt/splunk/bin/splunk add index idx_linux -auth admin:'Splunk@SOC2024!'
sudo /opt/splunk/bin/splunk add index idx_honeypot -auth admin:'Splunk@SOC2024!'
sudo /opt/splunk/bin/splunk add index idx_threat_intel -auth admin:'Splunk@SOC2024!'

# Enable HTTP Event Collector (HEC) on port 8088
# HEC lets you send data to Splunk over HTTP/HTTPS.
# We'll use this for Azure Firewall logs and custom scripts.
sudo /opt/splunk/bin/splunk http-event-collector enable -uri https://localhost:8089 \
    -auth admin:'Splunk@SOC2024!'

# Create an HEC token for Azure data
sudo /opt/splunk/bin/splunk http-event-collector create AzureSOC-HEC \
    -uri https://localhost:8089 -auth admin:'Splunk@SOC2024!' \
    -index idx_firewall -sourcetype azure:firewall 2>/dev/null || echo "  HEC token may already exist"

# Restart to apply all changes
sudo /opt/splunk/bin/splunk restart

echo ""
echo "========================================"
echo "  Splunk Installation Complete!"
echo "========================================"
echo ""
echo "  Web Interface: http://10.0.3.4:8000"
echo "  (Access via Bastion port forwarding or browser)"
echo "  Username: admin"
echo "  Password: Splunk@SOC2024!"
echo ""
echo "  Receiving Port: 9997 (for Universal Forwarders)"
echo "  HEC Port: 8088 (for HTTP Event Collector)"
echo ""
echo "  Indexes created:"
echo "    idx_windows     - Windows Security & System events"
echo "    idx_sysmon      - Sysmon endpoint telemetry"
echo "    idx_firewall    - Azure Firewall logs"
echo "    idx_linux       - Linux syslog"
echo "    idx_honeypot    - Honeypot attack data"
echo "    idx_threat_intel - Threat intelligence feeds"
echo ""
echo "  NEXT STEPS:"
echo "  1. Install Universal Forwarders on Windows VMs"
echo "  2. Configure forwarders to send to 10.0.3.4:9997"
echo "  3. Set up HEC input for Azure Firewall logs"
echo "========================================"
