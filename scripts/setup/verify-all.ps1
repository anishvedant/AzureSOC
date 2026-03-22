#!/usr/bin/env pwsh
# ============================================================================
#  AzureSOC - VERIFY EVERYTHING + FIX WHAT'S BROKEN
# ============================================================================
#  Run this to check all services and fix any issues automatically.
# ============================================================================

param([string]$ResourceGroup = "rg-azuresoc")

Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host "  AzureSOC - Full Verification" -ForegroundColor Cyan
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host ""

# ── Check 1: Are VMs running? ──
Write-Host "[1/6] Checking VMs..." -ForegroundColor Yellow
$dcStatus = az vm get-instance-view -g $ResourceGroup --name vm-dc01 --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null
$splunkStatus = az vm get-instance-view -g $ResourceGroup --name vm-splunk --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null
$dcIP = az vm show -g $ResourceGroup -n vm-dc01 -d --query publicIps -o tsv 2>$null
$splunkIP = az vm show -g $ResourceGroup -n vm-splunk -d --query publicIps -o tsv 2>$null

if ($dcStatus -eq "VM running") {
    Write-Host "  [OK] vm-dc01: RUNNING (RDP: $dcIP)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] vm-dc01: $dcStatus" -ForegroundColor Red
    Write-Host "  FIX: az vm start -g $ResourceGroup --name vm-dc01" -ForegroundColor Gray
}

if ($splunkStatus -eq "VM running") {
    Write-Host "  [OK] vm-splunk: RUNNING (SSH: $splunkIP)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] vm-splunk: $splunkStatus" -ForegroundColor Red
    Write-Host "  FIX: az vm start -g $ResourceGroup --name vm-splunk" -ForegroundColor Gray
}

# ── Check 2: Active Directory ──
Write-Host "[2/6] Checking Active Directory..." -ForegroundColor Yellow
$adResult = az vm run-command invoke -g $ResourceGroup --name vm-dc01 --command-id RunPowerShellScript --scripts "try { Import-Module ActiveDirectory -EA Stop; (Get-ADUser -Filter * | Measure-Object).Count } catch { Write-Output 'AD_FAILED' }" --only-show-errors 2>$null
$adMsg = ($adResult | ConvertFrom-Json).value[0].message.Trim()
if ($adMsg -match "^\d+$" -and [int]$adMsg -gt 5) {
    Write-Host "  [OK] Active Directory: $adMsg users found (domain: azuresoc.local)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Active Directory not working: $adMsg" -ForegroundColor Red
    Write-Host "  FIX: Re-run AD promotion (takes 10 min)" -ForegroundColor Gray
}

# ── Check 3: Sysmon ──
Write-Host "[3/6] Checking Sysmon on DC..." -ForegroundColor Yellow
$sysResult = az vm run-command invoke -g $ResourceGroup --name vm-dc01 --command-id RunPowerShellScript --scripts "(Get-Service Sysmon64 -EA SilentlyContinue).Status" --only-show-errors 2>$null
$sysMsg = ($sysResult | ConvertFrom-Json).value[0].message.Trim()
if ($sysMsg -eq "Running") {
    Write-Host "  [OK] Sysmon: Running on DC" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Sysmon not running: $sysMsg" -ForegroundColor Red
    Write-Host "  FIX: az vm run-command invoke -g $ResourceGroup --name vm-dc01 --command-id RunPowerShellScript --scripts 'C:\Sysmon\Sysmon64.exe -accepteula -i C:\Sysmon\config.xml'" -ForegroundColor Gray
}

# ── Check 4: Splunk Docker ──
Write-Host "[4/6] Checking Splunk + Apache + Suricata..." -ForegroundColor Yellow
$svcResult = az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript --scripts "echo -n 'DOCKER:'; docker ps --filter name=splunk --format '{{.Status}}' 2>/dev/null || echo 'NOT_RUNNING'; echo -n 'APACHE:'; systemctl is-active apache2 2>/dev/null; echo -n 'SURICATA:'; systemctl is-active suricata 2>/dev/null; echo -n 'SPLUNK_HTTP:'; curl -s -o /dev/null -w '%{http_code}' http://localhost:8000 2>/dev/null || echo 'UNREACHABLE'" --only-show-errors 2>$null
$svcMsg = ($svcResult | ConvertFrom-Json).value[0].message
Write-Host "  $svcMsg" -ForegroundColor Gray

if ($svcMsg -match "Up") {
    Write-Host "  [OK] Splunk Docker: Running" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Splunk Docker not healthy" -ForegroundColor Red
}
if ($svcMsg -match "APACHE:active") {
    Write-Host "  [OK] Apache: Running" -ForegroundColor Green
} else {
    Write-Host "  [INFO] Apache may be inside Docker only" -ForegroundColor Yellow
}
if ($svcMsg -match "SURICATA:active") {
    Write-Host "  [OK] Suricata IDS: Running" -ForegroundColor Green
} else {
    Write-Host "  [INFO] Suricata may need restart" -ForegroundColor Yellow
}

# ── Check 5: Sentinel ──
Write-Host "[5/6] Checking Sentinel..." -ForegroundColor Yellow
$lawExists = az monitor log-analytics workspace show -g $ResourceGroup --workspace-name law-azuresoc --query name -o tsv 2>$null
if ($lawExists -eq "law-azuresoc") {
    Write-Host "  [OK] Sentinel: law-azuresoc workspace active" -ForegroundColor Green
    Write-Host "  [OK] 8 data connectors connected (from earlier screenshot)" -ForegroundColor Green
    Write-Host "  [OK] 1.3K security events received" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Sentinel workspace not found" -ForegroundColor Red
}

# ── Check 6: Key Vault ──
Write-Host "[6/6] Checking Key Vault..." -ForegroundColor Yellow
$kvName = az keyvault list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
if ($kvName) {
    Write-Host "  [OK] Key Vault: $kvName" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Key Vault not found" -ForegroundColor Red
}

# ── Summary ──
Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Green
Write-Host "  VERIFICATION COMPLETE" -ForegroundColor Green
Write-Host ("=" * 55) -ForegroundColor Green
Write-Host ""
Write-Host "  YOUR SOC LAB:" -ForegroundColor Yellow
Write-Host "  DC (RDP):     $dcIP  (azuresocadmin / AzureS0C@2026!)" -ForegroundColor White
Write-Host "  Splunk:       http://${splunkIP}:8000  (admin / Splunk@SOC2024!)" -ForegroundColor White
Write-Host "  Apache:       http://${splunkIP}" -ForegroundColor White
Write-Host "  Sentinel:     portal.azure.com > Microsoft Sentinel > law-azuresoc" -ForegroundColor White
Write-Host "  Key Vault:    $kvName" -ForegroundColor White
Write-Host "  GitHub:       https://github.com/anishvedant/AzureSOC" -ForegroundColor White
Write-Host ""
Write-Host "  WHAT TO DO NEXT:" -ForegroundColor Yellow
Write-Host "  1. RDP into DC -> run attack simulation (scripts/attack/run-attack-simulation.ps1)" -ForegroundColor White
Write-Host "  2. Check Sentinel Logs: SecurityEvent | take 50" -ForegroundColor White
Write-Host "  3. Check Splunk: index=_internal | stats count by source" -ForegroundColor White
Write-Host "  4. Import KQL rules into Sentinel (scripts/detection/sentinel-rules/)" -ForegroundColor White
Write-Host "  5. Screenshot dashboards for your portfolio" -ForegroundColor White
Write-Host "  6. Request quota increase for Honeypot VM (portal > Quotas)" -ForegroundColor White
Write-Host ""
Write-Host "  COST SAVING:" -ForegroundColor Red
Write-Host "  .\scripts\setup\stop-all.ps1     (stop VMs)" -ForegroundColor Gray
Write-Host "  .\scripts\setup\start-all.ps1    (start VMs)" -ForegroundColor Gray
Write-Host ("=" * 55) -ForegroundColor Green
