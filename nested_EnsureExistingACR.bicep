targetScope = 'resourceGroup'

resource acr 'Microsoft.ContainerRegistry/registries@2021-12-01-preview' existing = {
  name: 'ACRDEVEUS2' 
}
