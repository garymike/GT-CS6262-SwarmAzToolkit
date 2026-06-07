// Resource-group-scoped: Azure OpenAI account + up to two model deployments.
// Two slots: "grading" (gpt-5-nano, for staff-grader parity) and "dev" (gpt-5-mini,
// for cheap local iteration). Each is independently toggleable (quota may exist for
// one but not the other) and carries its own SKU. The dev deployment dependsOn the
// grading one so that, when BOTH deploy, the Cognitive Services control plane doesn't
// get concurrent deployment writes (it rejects those). When grading is skipped, ARM
// ignores the dependsOn on the not-deployed resource.

@description('Azure region.')
param location string

@description('Azure OpenAI account name (also custom subdomain).')
param accountName string

@description('Deploy the grading-parity model (needs quota; commonly 0 on student subs).')
param deployGrading bool = false
param gradingDeploymentName string
param gradingModelName string
param gradingModelVersion string
@allowed([ 'GlobalStandard', 'Standard', 'DataZoneStandard' ])
param gradingSku string = 'GlobalStandard'

@description('Deploy the dev/iteration model.')
param deployDev bool = true
param devDeploymentName string
param devModelName string
param devModelVersion string
@allowed([ 'GlobalStandard', 'Standard', 'DataZoneStandard' ])
param devSku string = 'GlobalStandard'

@description('Deploy an embedding model for the RAG (CrewAI/ChromaDB).')
param deployEmbed bool = true
param embedDeploymentName string = 'text-embedding-3-small'
param embedModelName string = 'text-embedding-3-small'
param embedModelVersion string = ''
@allowed([ 'GlobalStandard', 'Standard', 'DataZoneStandard' ])
param embedSku string = 'Standard'

param capacity int
param tags object

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: accountName
    publicNetworkAccess: 'Enabled'
  }
}

resource grading 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployGrading) {
  parent: account
  name: gradingDeploymentName
  sku: {
    name: gradingSku
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: gradingModelName
      version: gradingModelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

resource dev 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployDev) {
  parent: account
  name: devDeploymentName
  dependsOn: [
    grading
  ]
  sku: {
    name: devSku
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: devModelName
      version: devModelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

resource embed 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployEmbed) {
  parent: account
  name: embedDeploymentName
  dependsOn: [
    dev
  ]
  sku: {
    name: embedSku
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embedModelName
      version: embedModelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

output accountName string = account.name
output endpoint string = account.properties.endpoint
