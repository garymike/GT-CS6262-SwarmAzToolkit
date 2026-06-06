#requires -Version 7.0
<#
.SYNOPSIS
  Guided, interactive setup for the CS6262 SWARM Azure OpenAI environment.
  Walks you from "nothing installed / no Azure account" to a validated deployment.

.DESCRIPTION
  Steps: detect tooling -> (offer install) -> az login -> pick subscription ->
  check your role -> find a region with the models -> no-cost WhatIf -> deploy.

  Safe to re-run. Nothing is created until you confirm at the WhatIf gate.

.EXAMPLE
  ./bootstrap.ps1
#>
[CmdletBinding()]
param(
  [string] $EnvOut = (Join-Path $PSScriptRoot '.env')   # override to your VM-share path if desired
)

$ErrorActionPreference = 'Stop'
$script:AZ = $null

function Write-Step($n, $t) { Write-Host "`n[$n] $t" -ForegroundColor Cyan }
function Write-Ok($t)       { Write-Host "    OK  $t" -ForegroundColor Green }
function Write-Warn2($t)    { Write-Host "    !   $t" -ForegroundColor Yellow }
function Confirm-YN($q)     { (Read-Host "$q [y/N]") -match '^(y|yes)$' }

# Re-read PATH from the registry so a just-installed tool is found without a shell restart.
function Update-PathFromEnv {
  $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path','User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Find-Az {
  Update-PathFromEnv
  $c = Get-Command az -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @(
    "$env:ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
    "${env:ProgramFiles(x86)}\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
    "$env:LOCALAPPDATA\Programs\Microsoft SDKs\Azure\CLI2\wbin\az.cmd")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}
function az { & $script:AZ @args }

# ---------------------------------------------------------------------------
Write-Host "=== SWARM Azure OpenAI bootstrap ===" -ForegroundColor Magenta

# [1] Azure CLI -------------------------------------------------------------
Write-Step 1 'Checking for Azure CLI (az)...'
$script:AZ = Find-Az
if (-not $script:AZ) {
  Write-Warn2 'Azure CLI not found.'
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    if (Confirm-YN '    Install it now via winget?') {
      winget install --exact --id Microsoft.AzureCLI --accept-source-agreements --accept-package-agreements
      $script:AZ = Find-Az
    }
  } else { Write-Warn2 'winget unavailable. Install from https://aka.ms/installazurecliwindows' }
  if (-not $script:AZ) { throw 'Azure CLI is required. Install it and re-run.' }
}
Write-Ok "az: $script:AZ"

# [2] Bicep -----------------------------------------------------------------
Write-Step 2 'Checking for Bicep...'
$bicepOk = $false
try { az bicep version --only-show-errors *> $null; $bicepOk = ($LASTEXITCODE -eq 0) } catch {}
if (-not $bicepOk) {
  Write-Warn2 'Bicep not installed.'
  if (Confirm-YN '    Install it now (az bicep install)?') { az bicep install; $bicepOk = $true }
  if (-not $bicepOk) { throw 'Bicep is required. Run: az bicep install' }
}
Write-Ok 'Bicep present.'

# [3] Login -----------------------------------------------------------------
Write-Step 3 'Checking Azure login...'
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $acct) {
  Write-Warn2 'Not logged in.'
  Write-Host '    No Azure subscription yet? Get free student credit:' -ForegroundColor Yellow
  Write-Host '      https://azure.microsoft.com/free/students' -ForegroundColor Yellow
  if (-not (Confirm-YN '    Continue to az login now?')) { throw 'Login required to proceed.' }
  az login --only-show-errors | Out-Null
  $acct = az account show --only-show-errors | ConvertFrom-Json
}
Write-Ok "Signed in as $($acct.user.name)"

# [4] Pick subscription -----------------------------------------------------
Write-Step 4 'Select a subscription...'
$subs = az account list --only-show-errors | ConvertFrom-Json | Where-Object { $_.state -eq 'Enabled' }
if (-not $subs) { throw 'No enabled subscriptions found. Create an Azure for Students subscription first.' }
for ($i=0; $i -lt $subs.Count; $i++) {
  $s = $subs[$i]
  $star = if ($s.isDefault) { '*' } else { ' ' }
  Write-Host ("    [{0}]{1} {2}  (tenant {3})" -f $i, $star, $s.name, $s.tenantId)
}
$pick = if ($subs.Count -eq 1) { 0 } else { [int](Read-Host '    Choose subscription #') }
$sub = $subs[$pick]
az account set --subscription $sub.id
Write-Ok "Using '$($sub.name)'  ($($sub.id))"

# [5] Role check ------------------------------------------------------------
Write-Step 5 'Checking your role on this subscription...'
$me = az ad signed-in-user show --query id -o tsv --only-show-errors 2>$null
$roles = az role assignment list --assignee $me --scope "/subscriptions/$($sub.id)" `
           --query "[].roleDefinitionName" -o tsv --only-show-errors 2>$null
if ($roles -match 'Owner|Contributor') { Write-Ok "Role(s): $($roles -join ', ')" }
else { Write-Warn2 "You may lack deploy rights (roles: '$roles'). Owner/Contributor needed; continuing — WhatIf will confirm." }

# [6] Region + model selection (quota-aware) --------------------------------
Write-Step 6 'Selecting region + deployable models...'

# Chat base models that have quota > 0 and are not deprecated, in a region.
function Get-DeployableChat($region) {
  $models = az cognitiveservices model list -l $region --only-show-errors 2>$null | ConvertFrom-Json
  $usages = az cognitiveservices usage list -l $region --only-show-errors 2>$null | ConvertFrom-Json
  if (-not $models -or -not $usages) { return @() }
  $q = @{}
  foreach ($u in $usages) {
    if ($u.name.value -match '^OpenAI\.(GlobalStandard|Standard|DataZoneStandard)\.(?<m>.+)$' -and [double]$u.limit -gt 0) {
      $m = $Matches['m']; if (-not $q.ContainsKey($m) -or $q[$m] -lt [double]$u.limit) { $q[$m] = [double]$u.limit }
    }
  }
  $now = Get-Date; $seen = @{}; $out = @()
  foreach ($e in ($models | Where-Object { $_.kind -eq 'OpenAI' })) {
    $n = $e.model.name
    if ($seen.ContainsKey($n) -or -not $q.ContainsKey($n)) { continue }
    if ($n -match 'embedding|tts|transcribe|whisper|sora|audio|finetune|realtime|image|dall|moderation') { continue }
    $d = $e.model.deprecation.inference; if ($d) { try { if ([datetime]$d -le $now) { continue } } catch {} }
    $seen[$n] = $true; $out += [pscustomobject]@{ Name = $n; Quota = $q[$n] }
  }
  return @($out | Sort-Object Quota -Descending)
}

$candidateRegions = @('eastus2','eastus','westus3','swedencentral','northcentralus','australiaeast')
$regAns = Read-Host '    Region [eastus2] (blank = auto-scan candidates)'
$chosenRegion = $null; $deployable = @()
if ($regAns) { $chosenRegion = $regAns; $deployable = Get-DeployableChat $chosenRegion }
else {
  foreach ($r in $candidateRegions) {
    $d = Get-DeployableChat $r
    if ($d) { $chosenRegion = $r; $deployable = $d; Write-Ok "Region '$r': $($d.Count) deployable chat models."; break }
  }
}
if (-not $chosenRegion) { $chosenRegion = Read-Host '    Enter a region to use'; $deployable = Get-DeployableChat $chosenRegion }
if (-not $deployable) { throw "No deployable chat models with quota in '$chosenRegion'. Try another region or request quota." }

Write-Host "    Deployable chat models in '$chosenRegion':" -ForegroundColor Cyan
for ($i = 0; $i -lt $deployable.Count; $i++) { Write-Host ("      [{0}] {1}  (quota {2})" -f $i, $deployable[$i].Name, $deployable[$i].Quota) }
$defIdx = [array]::IndexOf(@($deployable.Name), 'gpt-5-mini'); if ($defIdx -lt 0) { $defIdx = 0 }
$pick = Read-Host "    Pick DEV (iteration) model # [$defIdx = $($deployable[$defIdx].Name)]"
$devIdx = if ($pick -match '^\d+$' -and [int]$pick -lt $deployable.Count) { [int]$pick } else { $defIdx }
$DevModel = $deployable[$devIdx].Name
Write-Ok "Dev model: $DevModel"

# Grading model: gpt-5-nano by default (deploy.ps1 auto-skips it if quota is 0).
$GradingModel = 'gpt-5-nano'
if ($deployable.Name -contains $GradingModel) { Write-Ok "Grading model '$GradingModel' has quota — will deploy." }
else { Write-Warn2 "Grading model '$GradingModel' has no quota — auto-skipped (grader uses staff's)." }

# [7] Budget guardrail (opt-in selection) -----------------------------------
Write-Step 7 'Cost guardrail (subscription budget + email alerts)...'
$budgetAmount = 20
$noBudget = $false
if (Confirm-YN '    Create a monthly Cost Management budget with email alerts?') {
  $bAns = Read-Host '    Monthly budget in USD [20]'
  if ($bAns -match '^\d+$') { $budgetAmount = [int]$bAns }
  Write-Ok "Budget `$$budgetAmount/mo (alerts at 50/80/100% actual + 100% forecast)."
} else {
  $noBudget = $true
  Write-Warn2 'Skipping budget. (You can re-run later to add one.)'
}

# [8] WhatIf gate -----------------------------------------------------------
Write-Step 8 "No-cost preview (WhatIf) in '$chosenRegion'..."
$deploy = Join-Path $PSScriptRoot 'deploy.ps1'
$common = @{ Location = $chosenRegion; EnvOut = $EnvOut; BudgetAmount = $budgetAmount; DevModel = $DevModel; GradingModel = $GradingModel; NoBudget = $noBudget }
& $deploy @common -WhatIf
if (-not (Confirm-YN "`n    Preview looks good — deploy for real now? (creates billable resources)")) {
  Write-Host 'Stopped before deployment. Re-run when ready.' -ForegroundColor Yellow
  return
}

# [9] Deploy ----------------------------------------------------------------
Write-Step 9 'Deploying...'
& $deploy @common
Write-Host "`nDone. .env written to $EnvOut" -ForegroundColor Green
