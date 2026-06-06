#requires -Version 7.0
<#
.SYNOPSIS
  Tear down SWARM Azure resources when the project is done — deletes the resource group
  (Azure OpenAI account + deployments) and, optionally, the subscription budget.
  Uses the az CLI only.

.EXAMPLE
  ./teardown.ps1                       # prompts before deleting
  ./teardown.ps1 -Force                # no prompt
  ./teardown.ps1 -KeepBudget           # delete RG but leave the budget alert in place
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-swarm-openai',
  [string] $BudgetName    = 'swarm-monthly-budget',
  [switch] $KeepBudget,
  [switch] $Force
)
$ErrorActionPreference = 'Stop'

function Find-Az {
  $machine=[Environment]::GetEnvironmentVariable('Path','Machine'); $user=[Environment]::GetEnvironmentVariable('Path','User')
  $env:Path=(@($machine,$user)|Where-Object{$_}) -join ';'
  $c=Get-Command az -ErrorAction SilentlyContinue; if($c){return $c.Source}
  foreach($p in @("$env:ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin\az.cmd","${env:ProgramFiles(x86)}\Microsoft SDKs\Azure\CLI2\wbin\az.cmd")){ if(Test-Path $p){return $p} }
  throw 'Azure CLI not found.'
}
$script:AZ = Find-Az
function az { & $script:AZ @args }

$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $acct) { throw 'Not logged in. Run: az login' }
Write-Host "Subscription: $($acct.name)  ($($acct.id))" -ForegroundColor Cyan

$rgExists = (az group exists -n $ResourceGroup --only-show-errors) -eq 'true'
if (-not $rgExists) { Write-Host "Resource group '$ResourceGroup' not found — nothing to delete." -ForegroundColor Yellow }
else {
  if (-not $Force) {
    $ans = Read-Host "Delete resource group '$ResourceGroup' and ALL its resources? Type the RG name to confirm"
    if ($ans -ne $ResourceGroup) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
  }
  Write-Host "Deleting resource group '$ResourceGroup'..." -ForegroundColor Yellow
  az group delete -n $ResourceGroup --yes --only-show-errors | Out-Null
  Write-Host "Deleted '$ResourceGroup'." -ForegroundColor Green
}

if (-not $KeepBudget) {
  $b = az consumption budget show --budget-name $BudgetName --only-show-errors 2>$null
  if ($b) {
    Write-Host "Deleting budget '$BudgetName'..." -ForegroundColor Yellow
    az consumption budget delete --budget-name $BudgetName --only-show-errors | Out-Null
    Write-Host "Deleted budget '$BudgetName'." -ForegroundColor Green
  }
}
Write-Host "Teardown complete." -ForegroundColor Green
