# ================================================================
# AzureSOC - Stop All VMs (Cost Saving)
# ================================================================
# Run this at the end of every session to stop the billing clock.
# Deallocated VMs cost $0. Only storage charges continue (~pennies/day).
# ================================================================

param([string]$ResourceGroup = "rg-azuresoc")

Write-Host "Stopping all AzureSOC VMs..." -ForegroundColor Yellow
$vms = @("vm-dc01", "vm-workstation01", "vm-linux01", "vm-honeypot", "vm-splunk")
foreach ($vm in $vms) {
    Write-Host "  Deallocating $vm..." -ForegroundColor Gray
    az vm deallocate -g $ResourceGroup --name $vm --no-wait 2>$null
}
Write-Host "All VMs deallocating (takes 1-2 min to fully stop)" -ForegroundColor Green
Write-Host ""
Write-Host "To also delete Azure Firewall (saves ~`$9.50/day):" -ForegroundColor Yellow
Write-Host "az network firewall delete -g $ResourceGroup --name azfw-hub" -ForegroundColor Gray
