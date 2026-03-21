// ================================================================
// AzureSOC - Main Deployment Template
// One-click deployment of the entire SOC infrastructure
// ================================================================
// WHAT THIS DOES:
// This is the master template that orchestrates the deployment of
// your entire SOC lab. It calls sub-modules for network, compute,
// monitoring, and security. Think of it like a blueprint for a building -
// this file says "build the foundation, then the walls, then the roof"
// and each module handles the details.
// ================================================================

targetScope = 'resourceGroup'

// ── Parameters (customize these) ──
@description('Azure region for all resources')
param location string = 'eastus'

@description('Admin username for all VMs')
param adminUsername string = 'azuresocadmin'

@description('Admin password for all VMs')
@secure()
param adminPassword string

@description('Your external IP for Bastion access (get from whatismyip.com)')
param yourPublicIP string = '*'

// ── Variables ──
var prefix = 'azuresoc'
var hubVnetName = 'vnet-hub'
var spokeWorkloadVnetName = 'vnet-spoke-workload'
var spokeHoneypotVnetName = 'vnet-spoke-honeypot'

// ================================================================
// LAYER 1: HUB VIRTUAL NETWORK
// ================================================================
// WHY: The hub VNet is the central point of your network. All traffic
// flows through here. It contains your firewall (security checkpoint),
// Bastion (secure remote access), and Splunk server.
// REAL-WORLD PARALLEL: In enterprise networks, the hub is like the
// main office building - it has security guards (firewall) at every
// entrance and a reception desk (Bastion) for visitors.
// ================================================================

resource hubVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: hubVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        // Azure Firewall REQUIRES this exact subnet name
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
        }
      }
      {
        // Bastion also REQUIRES this exact subnet name
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
      {
        name: 'snet-splunk'
        properties: {
          addressPrefix: '10.0.3.0/24'
          networkSecurityGroup: {
            id: nsgSplunk.id
          }
        }
      }
    ]
  }
}

// ================================================================
// LAYER 1: SPOKE VNETS (Workload + Honeypot)
// ================================================================
// WHY: Spoke VNets isolate different workloads from each other.
// The workload spoke has your real lab machines (DC, workstation, Linux).
// The honeypot spoke is completely separate so if an attacker compromises
// the honeypot, they can't reach your real lab machines directly.
// REAL-WORLD PARALLEL: Think of spokes like different departments in a
// company - HR, Engineering, Marketing - each in their own building
// but all connected through the main hub.
// ================================================================

resource spokeWorkloadVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: spokeWorkloadVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.1.0.0/16']
    }
    subnets: [
      {
        name: 'snet-ad'
        properties: {
          addressPrefix: '10.1.1.0/24'
          networkSecurityGroup: {
            id: nsgAD.id
          }
          routeTable: {
            id: routeTable.id
          }
        }
      }
      {
        name: 'snet-workstation'
        properties: {
          addressPrefix: '10.1.2.0/24'
          networkSecurityGroup: {
            id: nsgWorkstation.id
          }
          routeTable: {
            id: routeTable.id
          }
        }
      }
      {
        name: 'snet-linux'
        properties: {
          addressPrefix: '10.1.3.0/24'
          networkSecurityGroup: {
            id: nsgLinux.id
          }
          routeTable: {
            id: routeTable.id
          }
        }
      }
    ]
  }
}

resource spokeHoneypotVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: spokeHoneypotVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.2.0.0/16']
    }
    subnets: [
      {
        name: 'snet-honeypot'
        properties: {
          addressPrefix: '10.2.1.0/24'
          networkSecurityGroup: {
            id: nsgHoneypot.id
          }
        }
      }
    ]
  }
}

// ================================================================
// VNET PEERING
// ================================================================
// WHY: By default, VNets can't talk to each other even if they're
// in the same subscription. Peering creates a private, high-speed
// connection between them. We peer both spokes to the hub so all
// traffic flows through the firewall.
// NOTE: Peering must be created in BOTH directions (hub->spoke AND
// spoke->hub) otherwise traffic only flows one way.
// ================================================================

resource hubToWorkload 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: hubVnet
  name: 'hub-to-spoke-workload'
  properties: {
    remoteVirtualNetwork: {
      id: spokeWorkloadVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
  }
}

resource workloadToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: spokeWorkloadVnet
  name: 'spoke-workload-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: false
  }
}

resource hubToHoneypot 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: hubVnet
  name: 'hub-to-spoke-honeypot'
  properties: {
    remoteVirtualNetwork: {
      id: spokeHoneypotVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
  }
}

resource honeypotToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: spokeHoneypotVnet
  name: 'spoke-honeypot-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: false
  }
}

// ================================================================
// NETWORK SECURITY GROUPS (NSGs)
// ================================================================
// WHY: NSGs are like bouncers at each subnet's door. Even though the
// firewall inspects all traffic, NSGs add a second layer of defense.
// This is "defense in depth" - if one control fails, another catches it.
// Each NSG has rules specific to what that subnet needs:
// - AD subnet: allows domain services ports (DNS 53, Kerberos 88, etc.)
// - Workstation: allows RDP from internal only
// - Linux: allows SSH from internal only
// - Honeypot: allows EVERYTHING (it's a trap!)
// ================================================================

resource nsgAD 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-ad'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'AllowADServices'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '10.1.0.0/16'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['53','88','135','389','445','636','3268','3269']
        }
      }
    ]
  }
}

resource nsgWorkstation 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-workstation'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource nsgLinux 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-linux'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
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
        // INTENTIONALLY OPEN - This is the honeypot trap!
        name: 'AllowAll'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
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
        name: 'AllowSplunkWeb'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8000'
        }
      }
      {
        name: 'AllowSplunkForwarder'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '9997'
        }
      }
      {
        name: 'AllowSplunkHEC'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8088'
        }
      }
    ]
  }
}

// ================================================================
// ROUTE TABLE (Force traffic through Firewall)
// ================================================================
// WHY: Without a route table, VMs talk to each other directly and
// to the internet without going through the firewall. The route table
// says "all traffic going to 0.0.0.0/0 (anywhere) must first pass
// through the firewall's private IP." This is called "forced tunneling"
// and it's how enterprises ensure ALL traffic gets inspected.
// ================================================================

resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-spoke-to-firewall'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'to-internet'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
      {
        name: 'to-hub'
        properties: {
          addressPrefix: '10.0.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
    ]
  }
}

// ================================================================
// AZURE FIREWALL
// ================================================================
// WHY: Azure Firewall is the central security inspection point.
// Every packet flowing between your spokes or to the internet passes
// through here. It can block malicious domains, inspect traffic,
// and log everything. In a real SOC, firewall logs are one of the
// TOP data sources analysts look at.
// COST NOTE: This is your most expensive resource (~$0.395/hr).
// Delete it when you're not working and redeploy from this template.
// ================================================================

resource firewallPIP 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-azfw'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'fwpol-azuresoc'
  location: location
  properties: {
    sku: {
      tier: 'Basic'
    }
    threatIntelMode: 'Alert'
  }
}

resource firewallPolicyRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'DefaultRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowInternal'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowSpokeToSpoke'
            ipProtocols: ['Any']
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['10.0.0.0/8']
            destinationPorts: ['*']
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowOutbound'
        priority: 200
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowDNS'
            ipProtocols: ['UDP','TCP']
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['*']
            destinationPorts: ['53']
          }
          {
            ruleType: 'NetworkRule'
            name: 'AllowHTTPS'
            ipProtocols: ['TCP']
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['*']
            destinationPorts: ['443','80']
          }
          {
            ruleType: 'NetworkRule'
            name: 'AllowNTP'
            ipProtocols: ['UDP']
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['*']
            destinationPorts: ['123']
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: 'azfw-hub'
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Basic'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          subnet: {
            id: hubVnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: firewallPIP.id
          }
        }
      }
    ]
  }
  dependsOn: [firewallPolicyRules]
}

// ================================================================
// AZURE BASTION
// ================================================================
// WHY: Bastion lets you RDP/SSH into your VMs through the Azure Portal
// without exposing any public IP addresses. It's like a secure tunnel.
// Without Bastion, you'd need public IPs on every VM (huge security risk)
// or a VPN (complex and costly). Bastion is the simplest secure option.
// ================================================================

resource bastionPIP 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-bastion'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: 'bastion-hub'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: {
            id: hubVnet.properties.subnets[1].id
          }
          publicIPAddress: {
            id: bastionPIP.id
          }
        }
      }
    ]
  }
}

// ================================================================
// VIRTUAL MACHINES
// ================================================================
// We deploy 5 VMs total:
// 1. Domain Controller (Windows Server 2022) - runs Active Directory
// 2. Workstation (Windows 11) - simulates an employee machine
// 3. Linux Server (Ubuntu 22.04) - runs web services as a target
// 4. Honeypot (Windows Server) - deliberately vulnerable, public-facing
// 5. Splunk Server (Ubuntu 22.04) - runs Splunk Enterprise SIEM
// ================================================================

// ── Domain Controller ──
resource nicDC 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-dc01'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAddress: '10.1.1.4'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: spokeWorkloadVnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

resource vmDC 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-dc01'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2ms'
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'DC01'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    networkProfile: {
      networkInterfaces: [{ id: nicDC.id }]
    }
  }
}

// ── Workstation ──
resource nicWS 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-workstation01'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAddress: '10.1.2.4'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: spokeWorkloadVnet.properties.subnets[1].id
          }
        }
      }
    ]
  }
}

resource vmWS 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-workstation01'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'WS01'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    networkProfile: {
      networkInterfaces: [{ id: nicWS.id }]
    }
  }
}

// ── Linux Server ──
resource nicLinux 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-linux01'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAddress: '10.1.3.4'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: spokeWorkloadVnet.properties.subnets[2].id
          }
        }
      }
    ]
  }
}

resource vmLinux 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-linux01'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'linux01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nicLinux.id }]
    }
  }
}

// ── Honeypot (PUBLIC IP - intentionally exposed) ──
resource honeypotPIP 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-honeypot'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nicHoneypot 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-honeypot'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAddress: '10.2.1.4'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: spokeHoneypotVnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: honeypotPIP.id
          }
        }
      }
    ]
  }
}

resource vmHoneypot 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-honeypot'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'HONEYPOT'
      adminUsername: 'administrator'
      adminPassword: 'Password123!'
    }
    networkProfile: {
      networkInterfaces: [{ id: nicHoneypot.id }]
    }
  }
}

// ── Splunk Server ──
resource nicSplunk 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-splunk'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAddress: '10.0.3.4'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: hubVnet.properties.subnets[2].id
          }
        }
      }
    ]
  }
}

resource vmSplunk 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-splunk'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2ms'
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
        diskSizeGB: 64
      }
    }
    osProfile: {
      computerName: 'splunk'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nicSplunk.id }]
    }
  }
}

// ================================================================
// LOG ANALYTICS WORKSPACE + MICROSOFT SENTINEL
// ================================================================
// WHY: Log Analytics Workspace is Microsoft's cloud-native log database.
// All your Azure logs, VM logs, firewall logs land here. Sentinel sits
// ON TOP of Log Analytics and adds SIEM capabilities: alerts, incidents,
// dashboards, threat hunting, and automation.
// Think of Log Analytics as the filing cabinet and Sentinel as the
// detective who reads the files and connects the dots.
// ================================================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-azuresoc'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource sentinel 'Microsoft.SecurityInsights/onboardingStates@2024-03-01' = {
  name: 'default'
  scope: logAnalytics
  properties: {}
}

// ================================================================
// STORAGE ACCOUNT (for NSG Flow Logs and diagnostics)
// ================================================================
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'st${uniqueString(resourceGroup().id)}soc'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
  }
}

// ================================================================
// KEY VAULT
// ================================================================
// WHY: Key Vault securely stores your API keys (VirusTotal, AbuseIPDB,
// Shodan) and other secrets. Your Azure Functions and Logic Apps pull
// credentials from here instead of hardcoding them in code.
// This is a security best practice - never put secrets in source code.
// ================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${uniqueString(resourceGroup().id)}'
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// ================================================================
// DIAGNOSTIC SETTINGS (Send Firewall Logs to Sentinel)
// ================================================================
resource fwDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'fw-to-sentinel'
  scope: firewall
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource kvDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'kv-to-sentinel'
  scope: keyVault
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// ================================================================
// OUTPUTS
// ================================================================
output firewallPrivateIP string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output honeypotPublicIP string = honeypotPIP.properties.ipAddress
output logAnalyticsWorkspaceId string = logAnalytics.id
output keyVaultName string = keyVault.name
output bastionName string = bastion.name
output splunkPrivateIP string = '10.0.3.4'
