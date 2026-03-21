# ================================================================
# AzureSOC — Attack Simulation Script
# ================================================================
# WHAT THIS DOES:
# Runs a series of MITRE ATT&CK techniques using Atomic Red Team
# to generate real attack telemetry in your SIEM. After running each
# technique, check both Sentinel and Splunk to verify detections fire.
#
# PREREQUISITE: Install Atomic Red Team first:
# IEX (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/redcanaryco/invoke-atomicredteam/master/install-atomicredteam.ps1')
# Install-AtomicRedTeam -getAtomics
#
# RUN THIS ON: vm-workstation01 (domain-joined workstation)
# ================================================================

Write-Host "========================================" -ForegroundColor Red
Write-Host "  AzureSOC — ATTACK SIMULATION" -ForegroundColor Red
Write-Host "  Running MITRE ATT&CK Techniques" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""
Write-Host "  After EACH technique, check:" -ForegroundColor Yellow
Write-Host "  - Sentinel > Incidents (KQL alerts)" -ForegroundColor Gray
Write-Host "  - Splunk > Search (SPL alerts)" -ForegroundColor Gray
Write-Host ""

# Check if Atomic Red Team is installed
if (-not (Get-Module -ListAvailable -Name "Invoke-AtomicRedTeam" -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Atomic Red Team..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    IEX (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/redcanaryco/invoke-atomicredteam/master/install-atomicredteam.ps1')
    Install-AtomicRedTeam -getAtomics -Force
}
Import-Module "C:\AtomicRedTeam\invoke-atomicredteam\Invoke-AtomicRedTeam.psd1" -Force

function Run-Attack($id, $name, $desc) {
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
    Write-Host "  $id — $name" -ForegroundColor Red
    Write-Host "  $desc" -ForegroundColor Gray
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
    try {
        Invoke-AtomicTest $id -TestNumbers 1 -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  ✅ Attack executed. Check SIEM for detection." -ForegroundColor Green
    } catch {
        Write-Host "  ⚠️  Some tests may require admin or specific prereqs." -ForegroundColor Yellow
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Gray
    }
    Write-Host "  Waiting 30 seconds for logs to propagate..." -ForegroundColor Gray
    Start-Sleep -Seconds 30
}

# ── Attack Chain 1: Discovery + Credential Access ──
Write-Host "`n🔴 CHAIN 1: Discovery + Credential Access" -ForegroundColor Red

Run-Attack "T1082" "System Information Discovery" `
    "Attacker gathers system info (OS version, hostname, domain)"

Run-Attack "T1087.001" "Local Account Discovery" `
    "Attacker enumerates user accounts to find targets"

Run-Attack "T1059.001" "PowerShell Execution" `
    "Attacker uses PowerShell for post-exploitation"

Run-Attack "T1003.001" "LSASS Memory Credential Dump" `
    "Attacker dumps credentials from LSASS process memory"

# ── Attack Chain 2: Persistence + Lateral Movement ──
Write-Host "`n🔴 CHAIN 2: Persistence + Lateral Movement" -ForegroundColor Red

Run-Attack "T1053.005" "Scheduled Task Persistence" `
    "Attacker creates scheduled task to survive reboot"

Run-Attack "T1543.003" "New Service Persistence" `
    "Attacker installs malicious service for persistence"

Run-Attack "T1021.002" "SMB Lateral Movement" `
    "Attacker uses stolen creds to access other machines via SMB"

# ── Attack Chain 3: Defense Evasion ──
Write-Host "`n🔴 CHAIN 3: Defense Evasion" -ForegroundColor Red

Run-Attack "T1070.001" "Clear Event Logs" `
    "Attacker clears Windows event logs to cover tracks"

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Attack Simulation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  NOW GO CHECK:" -ForegroundColor Yellow
Write-Host "  1. Sentinel > Incidents — count the new incidents" -ForegroundColor White
Write-Host "  2. Splunk > Search 'index=idx_sysmon' — verify telemetry" -ForegroundColor White
Write-Host "  3. Defender XDR > Incidents — check for correlated alerts" -ForegroundColor White
Write-Host "  4. Screenshot EVERYTHING for your portfolio!" -ForegroundColor White
Write-Host ""

# Cleanup
Write-Host "Cleaning up attack artifacts..." -ForegroundColor Gray
try {
    Invoke-AtomicTest T1053.005 -TestNumbers 1 -Cleanup -Confirm:$false -ErrorAction SilentlyContinue
    Invoke-AtomicTest T1543.003 -TestNumbers 1 -Cleanup -Confirm:$false -ErrorAction SilentlyContinue
} catch {}
Write-Host "  Cleanup done." -ForegroundColor Green
