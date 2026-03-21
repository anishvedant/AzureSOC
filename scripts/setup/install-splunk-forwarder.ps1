# ================================================================
# AzureSOC - Splunk Universal Forwarder Installation
# ================================================================
# WHAT IS A UNIVERSAL FORWARDER:
# Think of it as a tiny Splunk agent that runs on each machine.
# It watches specific log files and Event Logs, then ships them
# to your central Splunk server over port 9997.
# It uses very little CPU/RAM so it doesn't impact the host.
#
# WHAT WE'RE FORWARDING:
# - Windows Security Event Log (logon events, privilege changes)
# - Sysmon Operational Log (process creation, network connections)
# - PowerShell Operational Log (script execution, commands)
# - Windows System Log (service start/stop, errors)
#
# RUN THIS ON: All Windows VMs (DC, Workstation, Honeypot)
# ================================================================

param(
    [string]$SplunkServerIP = "10.0.3.4",
    [string]$SplunkReceivePort = "9997"
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AzureSOC - Splunk Forwarder Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$hostname = $env:COMPUTERNAME
$forwarderDir = "C:\SplunkUniversalForwarder"

# Determine which index to use based on hostname
$mainIndex = switch -Wildcard ($hostname) {
    "*HONEYPOT*" { "idx_honeypot" }
    default      { "idx_windows" }
}
Write-Host "  Host: $hostname -> Index: $mainIndex" -ForegroundColor White

# ── Create inputs.conf ──
# This tells the forwarder WHAT to collect.
# Each [WinEventLog://...] section monitors a specific Windows Event Log channel.
Write-Host "[1/2] Creating forwarder configuration..." -ForegroundColor Yellow

$inputsConf = @"
# ================================================================
# AzureSOC Splunk Universal Forwarder - inputs.conf
# ================================================================

# Windows Security Event Log
# Contains: Logon events (4624/4625), privilege use, policy changes,
# account management, process creation (4688)
[WinEventLog://Security]
disabled = false
index = $mainIndex
sourcetype = WinEventLog:Security
evt_resolve_ad_obj = 1
checkpointInterval = 5

# Sysmon Operational Log  
# Contains: Process creation with command line, network connections,
# file creation, registry changes, DNS queries, process access
[WinEventLog://Microsoft-Windows-Sysmon/Operational]
disabled = false
index = idx_sysmon
sourcetype = XmlWinEventLog:Microsoft-Windows-Sysmon/Operational
renderXml = true
checkpointInterval = 5

# PowerShell Operational Log
# Contains: Script block text, module loading, command execution
# CRITICAL for detecting encoded commands and malicious scripts
[WinEventLog://Microsoft-Windows-PowerShell/Operational]
disabled = false
index = $mainIndex
sourcetype = WinEventLog:Microsoft-Windows-PowerShell/Operational
checkpointInterval = 5

# Windows System Log
# Contains: Service installations (7045), driver loads, system errors
[WinEventLog://System]
disabled = false
index = $mainIndex
sourcetype = WinEventLog:System
checkpointInterval = 5

# Windows Application Log
[WinEventLog://Application]
disabled = false
index = $mainIndex
sourcetype = WinEventLog:Application
checkpointInterval = 5
"@

# ── Create outputs.conf ──
# This tells the forwarder WHERE to send collected data.
$outputsConf = @"
# ================================================================
# AzureSOC Splunk Universal Forwarder - outputs.conf
# ================================================================
[tcpout]
defaultGroup = azuresoc-splunk

[tcpout:azuresoc-splunk]
server = ${SplunkServerIP}:${SplunkReceivePort}
"@

# Write configs to the expected location
# If Splunk UF is installed, write to its etc/system/local/
# If not, save to C:\SplunkForwarder-Config for manual placement
$configDir = "$forwarderDir\etc\system\local"
if (!(Test-Path $configDir)) {
    $configDir = "C:\SplunkForwarder-Config"
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Write-Host "  Splunk UF not found. Configs saved to $configDir" -ForegroundColor Yellow
    Write-Host "  After installing the UF, copy these files to:" -ForegroundColor Yellow
    Write-Host "  C:\SplunkUniversalForwarder\etc\system\local\" -ForegroundColor Yellow
}

$inputsConf | Out-File -FilePath "$configDir\inputs.conf" -Encoding ASCII -Force
$outputsConf | Out-File -FilePath "$configDir\outputs.conf" -Encoding ASCII -Force
Write-Host "  inputs.conf created (Security, Sysmon, PowerShell, System, Application)" -ForegroundColor Green
Write-Host "  outputs.conf created (-> $SplunkServerIP`:$SplunkReceivePort)" -ForegroundColor Green

# ── Download and Install Universal Forwarder ──
Write-Host "[2/2] Downloading Splunk Universal Forwarder..." -ForegroundColor Yellow
Write-Host "  NOTE: If auto-download fails, download manually from:" -ForegroundColor Yellow
Write-Host "  https://www.splunk.com/en_us/download/universal-forwarder.html" -ForegroundColor Gray

$ufUrl = "https://download.splunk.com/products/universalforwarder/releases/9.3.1/windows/splunkforwarder-9.3.1-0b8d769cb912-x64-release.msi"
$ufPath = "C:\splunkforwarder.msi"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ufUrl -OutFile $ufPath -UseBasicParsing
    Write-Host "  Downloaded. Installing..." -ForegroundColor Green
    
    Start-Process msiexec -ArgumentList "/i `"$ufPath`" RECEIVING_INDEXER=`"${SplunkServerIP}:${SplunkReceivePort}`" SPLUNK_PASSWORD=`"Fwd@1234`" AGREETOLICENSE=yes /quiet" -Wait
    Write-Host "  Universal Forwarder installed" -ForegroundColor Green
    
    # Copy configs
    $destDir = "C:\SplunkUniversalForwarder\etc\system\local"
    if (Test-Path $destDir) {
        Copy-Item "$configDir\inputs.conf" "$destDir\inputs.conf" -Force
        Copy-Item "$configDir\outputs.conf" "$destDir\outputs.conf" -Force
        
        # Restart the forwarder to pick up new configs
        & "C:\SplunkUniversalForwarder\bin\splunk.exe" restart
        Write-Host "  Forwarder configured and restarted" -ForegroundColor Green
    }
} catch {
    Write-Host "  Auto-download failed. Please download manually." -ForegroundColor Yellow
    Write-Host "  Configs are ready in $configDir" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Forwarder Setup Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Verify in Splunk Web (http://10.0.3.4:8000):" -ForegroundColor White
Write-Host "  Search: index=idx_sysmon host=$hostname | head 10" -ForegroundColor Gray
Write-Host "  Search: index=$mainIndex host=$hostname | head 10" -ForegroundColor Gray
