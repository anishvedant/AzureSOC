// ================================================================
// AzureSOC - Infrastructure Template
// ================================================================
// STRATEGY: 2 VMs (2 cores each = 4 cores for free accounts)
//   VM 1: Windows Server 2022 - Domain Controller + Sysmon
//   VM 2: Ubuntu 22.04 - Splunk SIEM + Apache web target
// Also: VNet, NSGs, Sentinel, Log Analytics, Key Vault
// Firewall + Bastion + Honeypot added later (Phase 2)
// ================================================================

targetScope = 'resourceGroup'

@description('Region - auto-detected by deploy script')
param location string

@description('Admin username')
param adminUsername string = 'azuresocadmin'

@description('Admin password')
@secure()
param adminPassword string

@description('VM size - auto-detected by deploy script')
param vmSize string = 'Standard_D2s_v3'

// ── Network ──
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-azuresoc'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'snet-dc'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: nsgDC.id }
        }
      }
      {
        name: 'snet-splunk'
        properties: {
          addressPrefix: '10.0.2.0/24'
          networkSecurityGroup: { id: nsgSplunk.id }
        }
      }
      {
        name: 'snet-honeypot'
        properties: {
          addressPrefix: '10.0.3.0/24'
          networkSecurityGroup: { id: nsgHoneypot.id }
        }
      }
    ]
  }
}

// ── NSGs ──
resource nsgDC 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-dc'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRDP'
        properties: { priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '3389' }
      }
      {
        name: 'AllowADServices'
        properties: { priority: 110, direction: 'Inbound', access: 'Allow', protocol: '*', sourceAddressPrefix: '10.0.0.0/16', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRanges: ['53','88','135','389','445','636'] }
      }
    ]
  }
}

resource nsgSplunk 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-splunk'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: { priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '22' }
      }
      {
        name: 'AllowSplunkWeb'
        properties: { priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '8000' }
      }
      {
        name: 'AllowSplunkForwarder'
        properties: { priority: 120, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '10.0.0.0/16', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '9997' }
      }
      {
        name: 'AllowHEC'
        properties: { priority: 130, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '10.0.0.0/16', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '8088' }
      }
      {
        name: 'AllowHTTP'
        properties: { priority: 140, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '80' }
      }
    ]
  }
}

resource nsgHoneypot 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-honeypot'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowAll'
        properties: { priority: 100, direction: 'Inbound', access: 'Allow', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '*' }
      }
    ]
  }
}

// ── VM 1: Domain Controller ──
resource pipDC 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-dc01'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nicDC 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-dc01'
  location: location
  properties: {
    ipConfigurations: [{
      name: 'ipconfig1'
      properties: {
        privateIPAddress: '10.0.1.4'
        privateIPAllocationMethod: 'Static'
        subnet: { id: vnet.properties.subnets[0].id }
        publicIPAddress: { id: pipDC.id }
      }
    }]
  }
}

resource vmDC 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-dc01'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: { publisher: 'MicrosoftWindowsServer', offer: 'WindowsServer', sku: '2022-datacenter-g2', version: 'latest' }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' } }
    }
    osProfile: { computerName: 'DC01', adminUsername: adminUsername, adminPassword: adminPassword }
    networkProfile: { networkInterfaces: [{ id: nicDC.id }] }
  }
}

// ── VM 2: Splunk + Apache ──
resource pipSplunk 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-splunk'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nicSplunk 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-splunk'
  location: location
  properties: {
    ipConfigurations: [{
      name: 'ipconfig1'
      properties: {
        privateIPAddress: '10.0.2.4'
        privateIPAllocationMethod: 'Static'
        subnet: { id: vnet.properties.subnets[1].id }
        publicIPAddress: { id: pipSplunk.id }
      }
    }]
  }
}

resource vmSplunk 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-splunk'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: { publisher: 'Canonical', offer: '0001-com-ubuntu-server-jammy', sku: '22_04-lts-gen2', version: 'latest' }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' }, diskSizeGB: 64 }
    }
    osProfile: {
      computerName: 'splunk'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: { disablePasswordAuthentication: false }
    }
    networkProfile: { networkInterfaces: [{ id: nicSplunk.id }] }
  }
}

// ── Microsoft Sentinel + Log Analytics ──
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-azuresoc'
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource sentinel 'Microsoft.SecurityInsights/onboardingStates@2024-03-01' = {
  name: 'default'
  scope: logAnalytics
  properties: {}
}

// ── Key Vault ──
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${uniqueString(resourceGroup().id)}'
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// ── Storage Account ──
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'st${uniqueString(resourceGroup().id)}soc'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: { minimumTlsVersion: 'TLS1_2' }
}

// ── Outputs ──
output dcPublicIP string = pipDC.properties.ipAddress
output splunkPublicIP string = pipSplunk.properties.ipAddress
output keyVaultName string = keyVault.name
output logAnalyticsId string = logAnalytics.id
