# ================================================================
# AzureSOC - One-Click Deployment Script
# ================================================================
# WHAT THIS SCRIPT DOES:
# 1. Registers required Azure resource providers
# 2. Creates the resource group
# 3. Deploys ALL infrastructure via the Bicep template (network, VMs, firewall, Sentinel, etc.)
# 4. Outputs key information you'll need for the next steps
#
# PREREQUISITES:
# - Azure CLI installed (https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
# - Logged in: az login
# - Subscription set: az account set --subscription "<your-sub-id>"
#
# USAGE:
# ./deploy.ps1 -AdminPassword "YourStr0ngP@ssw0rd!"
# ================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$AdminPassword,

    [string]$Location = "eastus",
    [string]$ResourceGroup = "rg-azuresoc"
)

function Register-ProviderAndWait {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Namespace,
        [int]$MaxChecks = 40
    )

    az provider register --namespace $Namespace --only-show-errors 2>$null | Out-Null
    for ($i = 0; $i -lt $MaxChecks; $i++) {
        $state = az provider show --namespace $Namespace --query "registrationState" -o tsv 2>$null
        if ($state -eq "Registered") { return $true }
        Start-Sleep -Seconds 5
    }

    return $false
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AzureSOC - Deployment Starting" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Register Resource Providers ──
# WHY: Azure doesn't activate all services by default. We need to "register"
# the services we want to use. It's like signing up for features.
Write-Host "[1/5] Registering Azure Resource Providers..." -ForegroundColor Yellow
$providers = @(
    "Microsoft.OperationalInsights",    # Log Analytics
    "Microsoft.OperationsManagement",   # Workspace solutions used by Sentinel onboarding
    "Microsoft.SecurityInsights",       # Microsoft Sentinel
    "Microsoft.Network",                # VNets, Firewall, NSGs, Bastion
    "Microsoft.Compute",                # Virtual Machines
    "Microsoft.KeyVault",               # Key Vault for secrets
    "Microsoft.Web",                    # Azure Functions
    "Microsoft.Security",               # Defender for Cloud
    "Microsoft.Storage",                # Storage Accounts
    "Microsoft.Insights"                # Diagnostics and Monitoring
)

foreach ($provider in $providers) {
    Write-Host "  Registering $provider..." -ForegroundColor Gray
    $registered = Register-ProviderAndWait -Namespace $provider
    if (-not $registered) {
        Write-Host "  [WARN] $provider did not reach Registered yet. Continuing..." -ForegroundColor Yellow
    }
}
Write-Host "  Providers registered (may take 1-2 min to activate)" -ForegroundColor Green
Write-Host ""

# ── Step 2: Create Resource Group ──
# WHY: A resource group is a container that holds all your Azure resources.
# When you're done with the project, you can delete the entire resource group
# to remove everything at once (and stop all charges).
Write-Host "[2/5] Creating Resource Group: $ResourceGroup in $Location..." -ForegroundColor Yellow
$existingLocation = az group show --name $ResourceGroup --query "location" -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $existingLocation -and ($existingLocation -ne $Location)) {
    Write-Host "  Existing resource group is in '$existingLocation', deleting so it can be recreated in '$Location'..." -ForegroundColor Yellow
    az group delete --name $ResourceGroup --yes --no-wait --only-show-errors | Out-Null
    for ($waitTry = 0; $waitTry -lt 24; $waitTry++) {
        $exists = az group exists --name $ResourceGroup -o tsv 2>$null
        if ($exists -ne "true") { break }
        Start-Sleep -Seconds 10
    }
}

az group create --name $ResourceGroup --location $Location --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Failed to create resource group in $Location" -ForegroundColor Red
    exit 1
}
Write-Host "  Resource group created" -ForegroundColor Green
Write-Host ""

# ── Step 3: Set Budget Alert ──
# WHY: This protects you from accidentally spending your entire $200 credit.
# You'll get email alerts at 50%, 75%, and 90% of $150.
Write-Host "[3/5] Creating budget alert at `$150..." -ForegroundColor Yellow
$startDate = (Get-Date -Day 1).ToString("yyyy-MM-01")
# Note: Budget creation via CLI may require the Consumption API. 
# If this fails, create it manually in Portal > Cost Management > Budgets.
try {
    az consumption budget create --budget-name "azuresoc-budget" `
        --amount 150 --time-grain Monthly `
        --start-date $startDate --category Cost `
        --resource-group $ResourceGroup `
        --only-show-errors 2>$null | Out-Null
    Write-Host "  Budget alert created" -ForegroundColor Green
} catch {
    Write-Host "  Budget creation via CLI failed - create manually in Portal > Cost Management > Budgets" -ForegroundColor Yellow
}
Write-Host ""

# ── Step 4: Deploy Infrastructure via Bicep ──
# WHY: The Bicep template deploys EVERYTHING in one shot:
# - Hub-spoke network with Azure Firewall
# - 5 Virtual Machines (DC, Workstation, Linux, Honeypot, Splunk)
# - NSGs, Route Tables, Bastion
# - Log Analytics + Sentinel
# - Key Vault, Storage Account
# - Diagnostic settings (Firewall logs -> Sentinel)
# This typically takes 15-25 minutes.
Write-Host "[4/5] Deploying infrastructure via Bicep template..." -ForegroundColor Yellow
Write-Host "  This will take 15-25 minutes. Go grab coffee!" -ForegroundColor Gray
Write-Host ""

$deploymentOutput = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file "./infra/main.bicep" `
    --parameters adminPassword=$AdminPassword `
    --query "properties.outputs" `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  DEPLOYMENT FAILED!" -ForegroundColor Red
    Write-Host $deploymentOutput -ForegroundColor Red
    Write-Host ""
    Write-Host "  Common fixes:" -ForegroundColor Yellow
    Write-Host "  - Check your subscription has enough quota for 5 VMs" -ForegroundColor Gray
    Write-Host "  - Try a different region (westus2, centralus)" -ForegroundColor Gray
    Write-Host "  - Check Azure Portal > Activity Log for detailed error" -ForegroundColor Gray
    exit 1
}

Write-Host "  Infrastructure deployed successfully!" -ForegroundColor Green
Write-Host ""

# ── Step 5: Display Results ──
Write-Host "[5/5] Deployment Complete! Key Information:" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan

$outputs = $deploymentOutput | ConvertFrom-Json
Write-Host "  Firewall Private IP:  $($outputs.firewallPrivateIP.value)" -ForegroundColor White
Write-Host "  Honeypot Public IP:   $($outputs.honeypotPublicIP.value)" -ForegroundColor White
Write-Host "  Splunk Private IP:    $($outputs.splunkPrivateIP.value)" -ForegroundColor White
Write-Host "  Key Vault Name:       $($outputs.keyVaultName.value)" -ForegroundColor White
Write-Host "  Log Analytics WS:     law-azuresoc" -ForegroundColor White
Write-Host "  Bastion:              bastion-hub" -ForegroundColor White
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. Connect to vm-dc01 via Bastion and run configure-ad.ps1" -ForegroundColor White
Write-Host "  2. Connect to all Windows VMs and run install-sysmon.ps1" -ForegroundColor White
Write-Host "  3. Connect to vm-splunk via Bastion SSH and run install-splunk.sh" -ForegroundColor White
Write-Host "  4. Enable Sentinel data connectors in the Azure Portal" -ForegroundColor White
Write-Host ""
Write-Host "  COST SAVING REMINDER:" -ForegroundColor Red
Write-Host "  When done for the day, deallocate all VMs:" -ForegroundColor Gray
Write-Host "  az vm deallocate -g $ResourceGroup --name vm-dc01 --no-wait" -ForegroundColor Gray
Write-Host "  az vm deallocate -g $ResourceGroup --name vm-workstation01 --no-wait" -ForegroundColor Gray
Write-Host "  az vm deallocate -g $ResourceGroup --name vm-linux01 --no-wait" -ForegroundColor Gray
Write-Host "  az vm deallocate -g $ResourceGroup --name vm-honeypot --no-wait" -ForegroundColor Gray
Write-Host "  az vm deallocate -g $ResourceGroup --name vm-splunk --no-wait" -ForegroundColor Gray
Write-Host ""
Write-Host "  To delete Azure Firewall (saves ~`$9.50/day):" -ForegroundColor Gray
Write-Host "  az network firewall delete -g $ResourceGroup --name azfw-hub" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
