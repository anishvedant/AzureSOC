#!/usr/bin/env pwsh
# ============================================================================
#  AzureSOC - VERIFY EVERYTHING + FIX WHAT'S BROKEN
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
}

if ($splunkStatus -eq "VM running") {
    Write-Host "  [OK] vm-splunk: RUNNING (SSH: $splunkIP)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] vm-splunk: $splunkStatus" -ForegroundColor Red
}

# ── Check 2: Active Directory ──
Write-Host "[2/6] Checking Active Directory..." -ForegroundColor Yellow
$adResult = az vm run-command invoke -g $ResourceGroup --name vm-dc01 --command-id RunPowerShellScript --scripts "try { Import-Module ActiveDirectory -EA Stop; (Get-ADUser -Filter * | Measure-Object).Count } catch { Write-Output 'AD_FAILED' }" --only-show-errors 2>$null
$adMsg = ($adResult | ConvertFrom-Json).value[0].message.Trim()
if ($adMsg -match "^\d+$" -and [int]$adMsg -gt 5) {
    Write-Host "  [OK] Active Directory: $adMsg users found (domain: azuresoc.local)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Active Directory not working: $adMsg" -ForegroundColor Red
}

# ── Check 3: Sysmon ──
Write-Host "[3/6] Checking Sysmon on DC..." -ForegroundColor Yellow
$sysResult = az vm run-command invoke -g $ResourceGroup --name vm-dc01 --command-id RunPowerShellScript --scripts "(Get-Service Sysmon64 -EA SilentlyContinue).Status" --only-show-errors 2>$null
$sysMsg = ($sysResult | ConvertFrom-Json).value[0].message.Trim()
if ($sysMsg -eq "Running") {
    Write-Host "  [OK] Sysmon: Running on DC" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Sysmon not running: $sysMsg" -ForegroundColor Red
}

# ── Check 4: Apache + Suricata ──
Write-Host "[4/6] Checking Apache + Suricata..." -ForegroundColor Yellow
$svcResult = az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript --scripts "echo -n 'APACHE:'; systemctl is-active apache2 2>/dev/null; echo -n 'SURICATA:'; systemctl is-active suricata 2>/dev/null" --only-show-errors 2>$null
$svcMsg = ($svcResult | ConvertFrom-Json).value[0].message
Write-Host "  $svcMsg" -ForegroundColor Gray

# ── Check 5: Sentinel ──
Write-Host "[5/6] Checking Sentinel..." -ForegroundColor Yellow
$lawExists = az monitor log-analytics workspace show -g $ResourceGroup --workspace-name law-azuresoc --query name -o tsv 2>$null
if ($lawExists -eq "law-azuresoc") {
    Write-Host "  [OK] Sentinel: law-azuresoc workspace active" -ForegroundColor Green
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
Write-Host "  DC (RDP):     $dcIP" -ForegroundColor White
Write-Host "  Linux (SSH):  $splunkIP" -ForegroundColor White
Write-Host "  Apache:       http://${splunkIP}" -ForegroundColor White
Write-Host "  Sentinel:     portal.azure.com > Microsoft Sentinel > law-azuresoc" -ForegroundColor White
Write-Host "  GitHub:       https://github.com/anishvedant/AzureSOC" -ForegroundColor White
Write-Host ""
Write-Host "  COST SAVING:" -ForegroundColor Red
Write-Host "  .\scripts\setup\stop-all.ps1     (stop VMs)" -ForegroundColor Gray
Write-Host "  .\scripts\setup\start-all.ps1    (start VMs)" -ForegroundColor Gray
Write-Host ("=" * 55) -ForegroundColor Green
