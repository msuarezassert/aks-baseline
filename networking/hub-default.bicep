targetScope = 'resourceGroup'

/*** PARAMETERS ***/

@allowed([
  'australiaeast'
  'canadacentral'
  'centralus'
  'eastus'
  'eastus2'
  'westus2'
  'westus3'
  'francecentral'
  'germanywestcentral'
  'northeurope'
  'southafricanorth'
  'southcentralus'
  'uksouth'
  'westeurope'
  'japaneast'
  'southeastasia'
  'brazilsouth'
])
@description('The hub\'s regional affinity. All resources tied to this hub will also be homed in this region. The network team maintains this approved regional list which is a subset of zones with Availability Zone support.')
param location string

@description('Optional. A /24 to contain the regional firewall, management, and gateway subnet. Defaults to 10.200.0.0/24')
@maxLength(18)
@minLength(10)
param hubVirtualNetworkAddressSpace string = '10.200.0.0/24'

@description('Optional. A /26 under the virtual network address space for the regional Azure Firewall. Defaults to 10.200.0.0/26')
@maxLength(18)
@minLength(10)
param hubVirtualNetworkAzureFirewallSubnetAddressSpace string = '10.200.0.0/26'

@description('Optional. A /27 under the virtual network address space for our regional On-Prem Gateway. Defaults to 10.200.0.64/27')
@maxLength(18)
@minLength(10)
param hubVirtualNetworkGatewaySubnetAddressSpace string = '10.200.0.64/27'

@description('Optional. A /26 under the virtual network address space for regional Azure Bastion. Defaults to 10.200.0.128/26')
@maxLength(18)
@minLength(10)
param hubVirtualNetworkBastionSubnetAddressSpace string = '10.200.0.128/26'

/*** RESOURCES ***/
 
// The regional hub network
resource vnetHub 'Microsoft.Network/virtualNetworks@2021-05-01' = {
  name: 'vnet-${location}-hub'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        hubVirtualNetworkAddressSpace
      ]
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: hubVirtualNetworkAzureFirewallSubnetAddressSpace
        }
      }
    ]
  }

  resource azureFirewallSubnet 'subnets' existing = {
    name: 'AzureFirewallSubnet'
  }
}

// Allocate three IP addresses to the firewall
var numFirewallIpAddressesToAssign = 3
resource pipsAzureFirewall 'Microsoft.Network/publicIPAddresses@2021-05-01' = [for i in range(0, numFirewallIpAddressesToAssign): {
  name: 'pip-fw-${location}-${padLeft(i, 2, '0')}'
  location: location
  sku: {
    name: 'Standard'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  properties: {
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    publicIPAddressVersion: 'IPv4'
  }
}]

// Azure Firewall starter policy
resource fwPolicy 'Microsoft.Network/firewallPolicies@2021-05-01' = {
  name: 'fw-policies-${location}'
  location: location
  properties: {
    sku: {
      tier: 'Premium'
    }
    threatIntelMode: 'Deny'
    threatIntelWhitelist: {
      fqdns: []
      ipAddresses: []
    }
    intrusionDetection: {
      mode: 'Deny'
      configuration: {
        bypassTrafficSettings: []
        signatureOverrides: []
      }
    }
    dnsSettings: {
      servers: []
      enableProxy: true
    }
  }

  // Network hub starts out with only supporting DNS. This is only being done for
  // simplicity in this deployment and is not guidance, please ensure all firewall
  // rules are aligned with your security standards.
  resource defaultNetworkRuleCollectionGroup 'ruleCollectionGroups@2021-05-01' = {
    name: 'DefaultNetworkRuleCollectionGroup'
    properties: {
      priority: 200
      ruleCollections: [
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'org-wide-allowed'
          priority: 100
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'NetworkRule'
              name: 'DNS'
              description: 'Allow DNS outbound (for simplicity, adjust as needed)'
              ipProtocols: [
                'UDP'
              ]
              sourceAddresses: [
                '*'
              ]
              sourceIpGroups: []
              destinationAddresses: [
                '*'
              ]
              destinationIpGroups: []
              destinationFqdns: []
              destinationPorts: [
                '53'
              ]
            }
          ]
        }
      ]
    }
  }

  // Network hub starts out with no allowances for appliction rules
  resource defaultApplicationRuleCollectionGroup 'ruleCollectionGroups@2021-05-01' = {
    name: 'DefaultApplicationRuleCollectionGroup'
    dependsOn: [
      defaultNetworkRuleCollectionGroup
    ]
    properties: {
      priority: 300
      ruleCollections: []
    }
  }
}

// This is the regional Azure Firewall that all regional spoke networks can egress through.
resource hubFirewall 'Microsoft.Network/azureFirewalls@2021-05-01' = {
  name: 'fw-${location}'
  location: location
  zones: [
    '1'
    '2'
    '3'
  ]
  dependsOn: [
    // This helps prevent multiple PUT updates happening to the firewall causing a CONFLICT race condition
    // Ref: https://learn.microsoft.com/azure/firewall-manager/quick-firewall-policy
    fwPolicy::defaultApplicationRuleCollectionGroup
    fwPolicy::defaultNetworkRuleCollectionGroup
  ]
  properties: {
    sku: {
      tier: 'Premium'
      name: 'AZFW_VNet'
    }
    firewallPolicy: {
      id: fwPolicy.id
    }
    ipConfigurations: [for i in range(0, numFirewallIpAddressesToAssign): {
      name: pipsAzureFirewall[i].name
      properties: {
        subnet: (0 == i) ? {
          id: vnetHub::azureFirewallSubnet.id
        } : null
        publicIPAddress: {
          id: pipsAzureFirewall[i].id
        }
      }
    }]
  }
}


/*** OUTPUTS ***/

output hubVnetId string = vnetHub.id
