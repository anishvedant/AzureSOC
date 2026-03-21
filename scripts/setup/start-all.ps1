# ================================================================
# AzureSOC - Start All VMs
# ================================================================
# Run this at the start of each session to bring everything back up.
# VMs take 2-5 minutes to fully boot after starting.
# ================================================================

param([string]$ResourceGroup = "rg-azuresoc")

Write-Host "Starting all AzureSOC VMs..." -ForegroundColor Yellow
$vms = @("vm-dc01", "vm-workstation01", "vm-linux01", "vm-honeypot", "vm-splunk")
foreach ($vm in $vms) {
    Write-Host "  Starting $vm..." -ForegroundColor Gray
    az vm start -g $ResourceGroup --name $vm --no-wait 2>$null
}
Write-Host "All VMs starting (takes 2-5 min to fully boot)" -ForegroundColor Green
Write-Host ""
Write-Host "Connect via Bastion: Portal > vm-dc01 > Connect > Bastion" -ForegroundColor Gray
