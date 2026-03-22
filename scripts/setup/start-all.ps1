param([string]$ResourceGroup = "rg-azuresoc")
Write-Host "Starting all AzureSOC VMs..." -ForegroundColor Yellow
foreach ($vm in @("vm-dc01","vm-splunk")) {
    Write-Host "  Starting $vm..." -ForegroundColor Gray
    az vm start -g $ResourceGroup --name $vm --no-wait 2>$null
}
Write-Host "VMs starting (2-5 min to fully boot)." -ForegroundColor Green
Write-Host "DC RDP: az vm show -g $ResourceGroup -n vm-dc01 -d --query publicIps -o tsv" -ForegroundColor Gray
Write-Host "Splunk: az vm show -g $ResourceGroup -n vm-splunk -d --query publicIps -o tsv" -ForegroundColor Gray
