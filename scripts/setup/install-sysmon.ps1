# ================================================================
# AzureSOC - Sysmon Installation Script
# ================================================================
# WHAT IS SYSMON:
# Sysmon (System Monitor) is a free Microsoft tool that provides
# DEEP visibility into what's happening on a Windows machine.
# Regular Windows Event Logs are like a security camera in the lobby.
# Sysmon is like having cameras in EVERY room, hallway, and closet.
#
# WHAT SYSMON LOGS THAT WINDOWS DOESN'T:
# - Process creation WITH full command line and parent process
# - Network connections made by every process
# - File creation timestamps
# - Registry key changes
# - DNS queries (which domain did this process try to reach?)
# - WMI activity (commonly abused by attackers for persistence)
# - DLL loading (detects DLL injection attacks)
# - Process access (detects credential dumping from LSASS)
#
# WHY A SOC ANALYST NEEDS THIS:
# When investigating an alert, the FIRST thing you ask is:
# "What process did this? What was its parent? What else did it do?"
# Only Sysmon gives you this level of detail. Without Sysmon, you're
# investigating blind.
#
# RUN THIS ON: ALL Windows VMs (DC, Workstation, Honeypot)
# Connect via Azure Bastion and paste this entire script.
# ================================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AzureSOC - Sysmon Installation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$sysmonDir = "C:\Sysmon"
if (!(Test-Path $sysmonDir)) { New-Item -ItemType Directory -Path $sysmonDir | Out-Null }

# ── Download Sysmon ──
Write-Host "[1/3] Downloading Sysmon..." -ForegroundColor Yellow
$sysmonUrl = "https://live.sysinternals.com/Sysmon64.exe"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $sysmonUrl -OutFile "$sysmonDir\Sysmon64.exe" -UseBasicParsing
    Write-Host "  Sysmon downloaded" -ForegroundColor Green
} catch {
    Write-Host "  Direct download failed, trying alternative..." -ForegroundColor Yellow
    # Alternative: download from Sysinternals suite
    Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile "$sysmonDir\Sysmon.zip" -UseBasicParsing
    Expand-Archive -Path "$sysmonDir\Sysmon.zip" -DestinationPath $sysmonDir -Force
    Write-Host "  Sysmon downloaded via ZIP" -ForegroundColor Green
}

# ── Download SwiftOnSecurity Sysmon Config ──
# WHY THIS CONFIG: SwiftOnSecurity's config is the industry standard.
# It filters out the noise (Windows Update, antivirus scans) and focuses
# on security-relevant events. Without a good config, Sysmon generates
# millions of useless events that overwhelm your SIEM.
Write-Host "[2/3] Downloading SwiftOnSecurity config..." -ForegroundColor Yellow
$configUrl = "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml"
try {
    Invoke-WebRequest -Uri $configUrl -OutFile "$sysmonDir\sysmonconfig.xml" -UseBasicParsing
    Write-Host "  Config downloaded" -ForegroundColor Green
} catch {
    Write-Host "  Config download failed. Creating minimal config..." -ForegroundColor Yellow
    # Minimal fallback config that captures the most important events
    @"
<Sysmon schemaversion="4.90">
  <EventFiltering>
    <ProcessCreate onmatch="exclude"/>
    <FileCreateTime onmatch="exclude"/>
    <NetworkConnect onmatch="exclude"/>
    <ProcessTerminate onmatch="exclude"/>
    <DriverLoad onmatch="exclude"/>
    <ImageLoad onmatch="exclude"/>
    <CreateRemoteThread onmatch="exclude"/>
    <RawAccessRead onmatch="exclude"/>
    <ProcessAccess onmatch="exclude"/>
    <FileCreate onmatch="exclude"/>
    <RegistryEvent onmatch="exclude"/>
    <FileCreateStreamHash onmatch="exclude"/>
    <PipeEvent onmatch="exclude"/>
    <WmiEvent onmatch="exclude"/>
    <DnsQuery onmatch="exclude"/>
    <FileDelete onmatch="exclude"/>
  </EventFiltering>
</Sysmon>
"@ | Out-File -FilePath "$sysmonDir\sysmonconfig.xml" -Encoding UTF8
    Write-Host "  Minimal config created" -ForegroundColor Green
}

# ── Install Sysmon ──
# The -accepteula flag accepts the license agreement automatically.
# The -i flag installs Sysmon as a service that starts on boot.
# The config file tells Sysmon what to log and what to ignore.
Write-Host "[3/3] Installing Sysmon..." -ForegroundColor Yellow

# Check if already installed
$sysmonService = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
if ($sysmonService) {
    Write-Host "  Sysmon already installed. Updating config..." -ForegroundColor Yellow
    & "$sysmonDir\Sysmon64.exe" -c "$sysmonDir\sysmonconfig.xml" 2>$null
    Write-Host "  Config updated" -ForegroundColor Green
} else {
    & "$sysmonDir\Sysmon64.exe" -accepteula -i "$sysmonDir\sysmonconfig.xml" 2>$null
    Write-Host "  Sysmon installed and running" -ForegroundColor Green
}

# Verify installation
$svc = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Host ""
    Write-Host "  Sysmon is RUNNING" -ForegroundColor Green
    Write-Host "  Logs: Event Viewer > Applications and Services > Microsoft > Windows > Sysmon > Operational" -ForegroundColor White
    Write-Host "  Quick test: Open notepad.exe, then check Sysmon logs for Event ID 1 (Process Create)" -ForegroundColor Gray
} else {
    Write-Host "  WARNING: Sysmon service not found or not running. Check C:\Sysmon for errors." -ForegroundColor Red
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Sysmon Key Event IDs for SOC Analysts:" -ForegroundColor Yellow
Write-Host "  1  = Process Creation (most important!)" -ForegroundColor White
Write-Host "  3  = Network Connection" -ForegroundColor White
Write-Host "  7  = Image Loaded (DLL)" -ForegroundColor White
Write-Host "  8  = CreateRemoteThread (injection)" -ForegroundColor White
Write-Host "  10 = Process Access (credential dumping)" -ForegroundColor White
Write-Host "  11 = File Created" -ForegroundColor White
Write-Host "  12 = Registry Key Changed" -ForegroundColor White
Write-Host "  13 = Registry Value Set" -ForegroundColor White
Write-Host "  22 = DNS Query" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
