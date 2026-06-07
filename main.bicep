// SWARM Azure OpenAI deployer - subscription-scope entrypoint.
// Creates a resource group + an Azure OpenAI account with up to two model deployments:
//   - "grading" slot (default gpt-5-nano): staff-grader parity; usually 0 quota on student subs.
//   - "dev" slot     (default gpt-5-mini): cheap local iteration; same gpt-5 family as the grader.
// deploy.ps1 runs a quota + deprecation preflight and sets the deploy flags / SKUs / versions.
//
// Deploy with deploy.ps1 / bootstrap.ps1 (recommended).

targetScope = 'subscription'

@description('Resource group to create/use.')
param resourceGroupName string = 'rg-swarm-openai'

@description('Azure region. Default eastus2.')
param location string = 'eastus2'

@description('Azure OpenAI account name (also the custom subdomain). Globally unique-ish.')
param accountName string = 'swarm-openai-${uniqueString(subscription().id, resourceGroupName)}'

// --- grading-parity model slot ---------------------------------------------
@description('Deploy the grading model. deploy.ps1 sets this from a quota preflight (often false on student subs).')
param deployGrading bool = false
@description('Grading deployment name (keep matching the project .env / grader).')
param gradingDeploymentName string = 'gpt-5-nano'
@description('Grading Azure model name.')
param gradingModelName string = 'gpt-5-nano'
@description('Grading model version. Resolved by deploy.ps1.')
param gradingModelVersion string
@allowed([ 'GlobalStandard', 'Standard', 'DataZoneStandard' ])
param gradingSku string = 'GlobalStandard'

// --- dev / iteration model slot --------------------------------------------
@description('Deploy the dev/iteration model.')
param deployDev bool = true
@description('Dev deployment name.')
param devDeploymentName string = 'gpt-5-mini'
@description('Dev Azure model name (default gpt-5-mini - gpt-5 family, parity with grader).')
param devModelName string = 'gpt-5-mini'
@description('Dev model version. Resolved by deploy.ps1.')
param devModelVersion string
@allowed([ 'GlobalStandard', 'Standard', 'DataZoneStandard' ])
param devSku string = 'GlobalStandard'

// --- embedding model slot (for the RAG) ------------------------------------
@description('Deploy an embedding model for the RAG. deploy.ps1 sets this from a quota preflight.')
param deployEmbed bool = true
@description('Embedding deployment name.')
param embedDeploymentName string = 'text-embedding-3-small'
@description('Embedding Azure model name (text-embedding-3-small or text-embedding-ada-002).')
param embedModelName string = 'text-embedding-3-small'
@description('Embedding model version. Resolved by deploy.ps1.')
param embedModelVersion string = ''
@allowed([ 'GlobalStandard', 'Standard', 'DataZoneStandard' ])
param embedSku string = 'Standard'

@description('Tokens-per-minute capacity (x1000) for each deployment.')
param capacity int = 10

@description('Tags applied to all resources.')
param tags object = {
  project: 'cs6262-swarm'
  purpose: 'student-llm-iteration'
}

// --- Cost guardrail (subscription-scope budget + email alerts) -------------
@description('Create a monthly Cost Management budget with alert thresholds.')
param enableBudget bool = true
@description('Monthly budget amount in subscription currency (USD). Project target is $10-20.')
param budgetAmount int = 20
@description('Emails to alert. deploy.ps1 fills this from your signed-in account.')
param budgetContactEmails array = []
@description('Budget start - must be the first of a month. Defaults to the current month.')
param budgetStartDate string = utcNow('yyyy-MM-01')

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module openai 'modules/openai.bicep' = {
  scope: rg
  name: 'swarm-openai-deploy'
  params: {
    location: location
    accountName: accountName
    deployGrading: deployGrading
    gradingDeploymentName: gradingDeploymentName
    gradingModelName: gradingModelName
    gradingModelVersion: gradingModelVersion
    gradingSku: gradingSku
    deployDev: deployDev
    devDeploymentName: devDeploymentName
    devModelName: devModelName
    devModelVersion: devModelVersion
    devSku: devSku
    deployEmbed: deployEmbed
    embedDeploymentName: embedDeploymentName
    embedModelName: embedModelName
    embedModelVersion: embedModelVersion
    embedSku: embedSku
    capacity: capacity
    tags: tags
  }
}

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = if (enableBudget && !empty(budgetContactEmails)) {
  name: 'swarm-monthly-budget'
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
    }
    notifications: {
      actual_50: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: budgetContactEmails
      }
      actual_80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: budgetContactEmails
      }
      actual_100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: budgetContactEmails
      }
      forecast_100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: budgetContactEmails
      }
    }
  }
}

output accountName string = openai.outputs.accountName
output endpoint string = openai.outputs.endpoint
output budgetCreated bool = enableBudget && !empty(budgetContactEmails)
output gradingDeployment string = deployGrading ? gradingDeploymentName : ''
output devDeployment string = deployDev ? devDeploymentName : ''
output embedDeployment string = deployEmbed ? embedDeploymentName : ''
output resourceGroupName string = rg.name
