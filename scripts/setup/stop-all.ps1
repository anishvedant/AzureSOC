param([string]$ResourceGroup = "rg-azuresoc")
Write-Host "Stopping all AzureSOC VMs..." -ForegroundColor Yellow
foreach ($vm in @("vm-dc01","vm-splunk")) {
    Write-Host "  Deallocating $vm..." -ForegroundColor Gray
    az vm deallocate -g $ResourceGroup --name $vm --no-wait 2>$null
}
Write-Host "VMs deallocating (1-2 min). Compute charges stopped." -ForegroundColor Green
