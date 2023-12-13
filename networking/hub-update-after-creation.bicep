targetScope = 'resourceGroup'

/*** PARAMETERS ***/

@description('Subnet resource IDs for all AKS clusters nodepools in all attached spokes to allow necessary outbound traffic through the firewall.')
@minLength(1)
param nodepoolSubnetResourceIds array

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
param location string = 'eastus2'

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

// This holds IP addresses of known nodepool subnets in spokes.
resource ipgNodepoolSubnet 'Microsoft.Network/ipGroups@2021-05-01' = {
  name: 'ipg-${location}-AksNodepools'
  location: location
  properties: {
    ipAddresses: [for nodepoolSubnetResourceId in nodepoolSubnetResourceIds: '${reference(nodepoolSubnetResourceId, '2020-05-01').addressPrefix}']
  }
}

// Azure Firewall starter policy
resource fwPolicy 'Microsoft.Network/firewallPolicies@2021-05-01' = {
  name: 'fw-policies-${location}'
  location: location
  dependsOn: [
    ipgNodepoolSubnet
  ]
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
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'AKS-Global-Requirements'
          priority: 200
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'NetworkRule'
              name: 'pods-to-api-server-konnectivity'
              description: 'This allows pods to communicate with the API server. Ensure your API server\'s allowed IP ranges support all of this firewall\'s public IPs.'
              ipProtocols: [
                'TCP'
              ]
              sourceAddresses: []
              sourceIpGroups: [
                ipgNodepoolSubnet.id
              ]
              destinationAddresses: [
                'AzureCloud.${location}' // Ideally you'd list your AKS server endpoints in appliction rules, instead of this wide-ranged rule
              ]
              destinationIpGroups: []
              destinationFqdns: []
              destinationPorts: [
                '443'
              ]
            }
            // NOTE: This rule is only required for for clusters not yet running in konnectivity mode and can be removed once it has been fully rolled out.
            {
              ruleType: 'NetworkRule'
              name: 'pod-to-api-server_udp-1194'
              description: 'This allows pods to communicate with the API server. Only needed if your cluster is not yet using konnectivity.'
              ipProtocols: [
                'UDP'
              ]
              sourceAddresses: []
              sourceIpGroups: [
                ipgNodepoolSubnet.id
              ]
              destinationAddresses: [
                'AzureCloud.${location}' // Ideally you'd list your AKS server endpoints in appliction rules, instead of this wide-ranged rule
              ]
              destinationIpGroups: []
              destinationFqdns: []
              destinationPorts: [
                '1194'
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
      ruleCollections: [
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'AKS-Global-Requirements'
          priority: 200
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'azure-monitor-addon'
              description: 'Supports required communication for the Azure Monitor addon in AKS'
              protocols: [
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              fqdnTags: []
              webCategories: []
              targetFqdns: [
                '*.ods.opinsights.azure.com'
                '*.oms.opinsights.azure.com'
                '${location}.monitoring.azure.com'
              ]
              targetUrls: []
              destinationAddresses: []
              terminateTLS: false
              sourceAddresses: []
              sourceIpGroups: [
                ipgNodepoolSubnet.id
              ]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'azure-policy-addon'
              description: 'Supports required communication for the Azure Policy addon in AKS'
              protocols: [
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              fqdnTags: []
              webCategories: []
              targetFqdns: [
                'data.policy.${environment().suffixes.storage}'
                'store.policy.${environment().suffixes.storage}'
              ]
              targetUrls: []
              destinationAddresses: []
              terminateTLS: false
              sourceAddresses: []
              sourceIpGroups: [
                ipgNodepoolSubnet.id
              ]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'service-requirements'
              description: 'Supports required core AKS functionality. Could be replaced with individual rules if added granularity is desired.'
              protocols: [
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              fqdnTags: [
                'AzureKubernetesService'
              ]
              webCategories: []
              targetFqdns: []
              targetUrls: []
              destinationAddresses: []
              terminateTLS: false
              sourceAddresses: []
              sourceIpGroups: [
                ipgNodepoolSubnet.id
              ]
            }
          ]
        }
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'GitOps-Traffic'
          priority: 300
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'github-origin'
              description: 'Supports pulling gitops configuration from GitHub.'
              protocols: [
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              fqdnTags: []
              webCategories: []
              targetFqdns: [
                'github.com'
                'api.github.com'
              ]
              targetUrls: []
              destinationAddresses: []
              terminateTLS: false
              sourceAddresses: []
              sourceIpGroups: [
                ipgNodepoolSubnet.id
              ]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'flux-extension-runtime-requirements'
              description: 'Supports required communication for the Flux v2 extension operate and contains allowances for our applications deployed to the cluster.'
              protocols: [
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              fqdnTags: []
              webCategories: []
              targetFqdns: [
                '${location}.dp.kubernetesconfiguration.azure.com'
                'mcr.microsoft.com'
                'raw.githubusercontent.com'
                split(environment().resourceManager, '/')[2] // Prevent the linter from getting upset at management.azure.com - https://github.com/Azure/bicep/issues/3080
                split(environment().authentication.loginEndpoint, '/')[2] // Prevent the linter from getting upset at login.microsoftonline.com
                '*.blob.${environment().suffixes.storage}' // required for the extension installer to download the helm chart install flux. This storage account is not predictable, but does look like eusreplstore196 for example.
                'azurearcfork8s.azurecr.io' // required for a few of the images installed by the extension.
                '*.docker.io' // Only required if you use the default bootstrapping manifests included in this repo.
                '*.docker.com' // Only required if you use the default bootstrapping manifests included in this repo.
                'ghcr.io' // Only required if you use the default bootstrapping manifests included in this repo. Kured is sourced from here by default.
                'pkg-containers.githubusercontent.com' // Only required if you use the default bootstrapping manifests included in this repo. Kured is sourced from here by default.
              ]
              targetUrls: []
              destinationAddresses: []
              terminateTLS: false
              sourceAddresses: []
              sourceIpGroups: [
                ipgNodepoolSubnet.id
              ]
            }
          ]
        }
      ]
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
    ipgNodepoolSubnet
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
