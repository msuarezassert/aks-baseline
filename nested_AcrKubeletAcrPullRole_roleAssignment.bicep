targetScope = 'resourceGroup'

/*** PARAMETERS ***/

param name string
param roleDefinitionId string
param description string
param principalId string
param principalType string

resource acr 'Microsoft.ContainerRegistry/registries@2021-12-01-preview' existing = {
  name: 'ACRDEVEUS2' 
}

resource acrKubeletAcrPullRole_roleAssignment 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  scope: acr
  name: name
  properties: {
    roleDefinitionId: roleDefinitionId
    description: description
    principalId: principalId
    principalType: principalType
  }
}