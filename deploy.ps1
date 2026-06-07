#requires -Version 7.0
<#
.SYNOPSIS
  Deploy an Azure OpenAI account for the CS6262 SWARM project — a "grading" model
  (gpt-5-nano, parity with the staff grader) and a "dev" model (gpt-5-mini) — then emit
  a ready .env. Runs a quota + deprecation preflight and skips any model it can't deploy.
  Student-agnostic: nothing hard-coded to one subscription.

.EXAMPLE
  ./deploy.ps1
  ./deploy.ps1 -Location eastus2 -DevModel gpt-5-mini -WhatIf   # preview, no changes
  ./deploy.ps1 -DevModel gpt-4.1-mini                           # pick a different dev model

.NOTES
  Auto-locates az if it isn't on PATH (e.g. installer ran but the shell wasn't restarted).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $SubscriptionId,
  [string] $Location      = 'eastus2',
  [string] $ResourceGroup = 'rg-swarm-openai',
  [string] $AccountName,                              # default: generated in Bicep
  [int]    $Capacity      = 10,
  [string] $GradingModel  = 'gpt-5-nano',             # staff-grader parity (often 0 quota)
  [string] $DevModel      = 'gpt-5-mini',             # cheap local iteration (gpt-5 family)
  [string] $EmbedModel    = 'text-embedding-3-small', # RAG embedder (ada-002 also works)
  [string] $GradingVersion,                            # default: latest non-deprecated, auto-discovered
  [string] $DevVersion,                                # default: latest non-deprecated, auto-discovered
  [string] $EmbedVersion,                              # default: latest, auto-discovered
  [int]    $BudgetAmount  = 20,                        # monthly USD budget for alerts
  [string[]] $BudgetEmail,                             # default: signed-in user's email
  [switch] $NoBudget,                                  # skip creating the budget
  [string] $EnvOut        = (Join-Path $PSScriptRoot '.env')
)

$ErrorActionPreference = 'Stop'

# ---- locate az -------------------------------------------------------------
function Get-AzPath {
  $c = Get-Command az -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $cands = @(
    "$env:ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
    "${env:ProgramFiles(x86)}\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
    "$env:LOCALAPPDATA\Programs\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
  )
  foreach ($p in $cands) { if (Test-Path $p) { return $p } }
  throw "Azure CLI (az) not found. Install with: winget install Microsoft.AzureCLI"
}
$script:AZ = Get-AzPath
function az { & $script:AZ @args }

Write-Host "==> Azure CLI: $script:AZ" -ForegroundColor Cyan

# ---- login / subscription --------------------------------------------------
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $acct) {
  Write-Host "==> Not logged in. Launching az login..." -ForegroundColor Yellow
  az login --only-show-errors | Out-Null
  $acct = az account show --only-show-errors | ConvertFrom-Json
}
if ($SubscriptionId) { az account set --subscription $SubscriptionId; $acct = az account show --only-show-errors | ConvertFrom-Json }
Write-Host "==> Subscription: $($acct.name) ($($acct.id))" -ForegroundColor Cyan

# ---- ensure provider registered -------------------------------------------
$prov = az provider show -n Microsoft.CognitiveServices --query registrationState -o tsv 2>$null
if ($prov -ne 'Registered') {
  Write-Host "==> Registering Microsoft.CognitiveServices provider..." -ForegroundColor Yellow
  az provider register -n Microsoft.CognitiveServices | Out-Null
}

# ---- discover models + quota in region ------------------------------------
Write-Host "==> Querying available models + quota in '$Location'..." -ForegroundColor Cyan
$models = az cognitiveservices model list -l $Location --only-show-errors | ConvertFrom-Json
$usages = az cognitiveservices usage list -l $Location --only-show-errors | ConvertFrom-Json

# Per-model SKU -> available quota (limit - current). Quota name: OpenAI.<SKU>.<model>
function Get-QuotaMap([string]$name) {
  $rx = "^OpenAI\.(?<sku>[^.]+)\.$([regex]::Escape($name))$"
  $map = @{}
  foreach ($q in $usages) { if ($q.name.value -match $rx) { $map[$Matches['sku']] = ([double]$q.limit - [double]$q.currentValue) } }
  return $map
}

# Drop versions whose inference deprecation date has already passed (Azure blocks new deploys of those).
function Get-LiveEntries($entries) {
  $now = Get-Date
  $live = foreach ($e in $entries) {
    $d = $e.model.deprecation.inference
    $ok = $true
    if ($d) { try { if ([datetime]$d -le $now) { $ok = $false } } catch {} }
    if ($ok) { $e }
  }
  return @($live)
}

# Resolve a model to {Deploy, Version, Sku} using availability INTERSECT quota, skipping deprecated versions.
function Resolve-ModelDeploy([string]$name, [string]$wantVersion, [int]$minCap) {
  $entries = $models | Where-Object { $_.kind -eq 'OpenAI' -and $_.model.name -eq $name }
  if (-not $entries) {
    Write-Host "   - ${name}: not available in '$Location' — SKIPPING." -ForegroundColor Yellow
    return [pscustomobject]@{ Deploy = $false; Version = 'na'; Sku = 'GlobalStandard' }
  }
  $pool = Get-LiveEntries $entries
  if (-not $pool) { $pool = $entries }   # all flagged: fall back so we at least try
  $version = if ($wantVersion) { $wantVersion } else { ($pool.model.version | Sort-Object -Descending | Select-Object -First 1) }
  $entry = ($pool | Where-Object { $_.model.version -eq $version } | Select-Object -First 1)
  if (-not $entry) { $entry = $pool | Select-Object -First 1; $version = $entry.model.version }
  $availSkus = @($entry.model.skus.name)
  $quota = Get-QuotaMap $name
  $chosen = $null
  foreach ($s in (@('GlobalStandard','Standard','DataZoneStandard') + $availSkus)) {
    if ($availSkus -contains $s -and $quota.ContainsKey($s) -and $quota[$s] -ge $minCap) { $chosen = $s; break }
  }
  if (-not $chosen) {
    $maxq = if ($quota.Values.Count) { ($quota.Values | Measure-Object -Maximum).Maximum } else { 0 }
    Write-Host "   - $name (v$version): no usable quota (max avail $maxq) — SKIPPING. Request quota in the portal." -ForegroundColor Yellow
    return [pscustomobject]@{ Deploy = $false; Version = $version; Sku = 'GlobalStandard' }
  }
  Write-Host "   - $name => v$version, sku $chosen (quota avail $($quota[$chosen])) — will deploy." -ForegroundColor Green
  return [pscustomobject]@{ Deploy = $true; Version = $version; Sku = $chosen }
}

$grading = Resolve-ModelDeploy $GradingModel $GradingVersion $Capacity
$dev     = Resolve-ModelDeploy $DevModel     $DevVersion     $Capacity
$embed   = Resolve-ModelDeploy $EmbedModel   $EmbedVersion   $Capacity
if (-not ($grading.Deploy -or $dev.Deploy)) { throw "No chat model has deployable quota in '$Location'. Request quota or try another region." }
if (-not $embed.Deploy) { Write-Host "   ! No embedder quota — RAG embedder will be skipped (the project's RAG needs one; request quota or use OpenAI)." -ForegroundColor Yellow }

# ---- resolve budget alert email -------------------------------------------
if (-not $NoBudget -and -not $BudgetEmail) {
  $mail = az ad signed-in-user show --query mail -o tsv --only-show-errors 2>$null
  if (-not $mail) { $mail = az ad signed-in-user show --query userPrincipalName -o tsv --only-show-errors 2>$null }
  if ($mail) { $BudgetEmail = @($mail) }
}
$enableBudget = (-not $NoBudget) -and ($BudgetEmail -and $BudgetEmail.Count -gt 0)
if ($enableBudget) { Write-Host "==> Budget: `$$BudgetAmount/mo, alerts to $($BudgetEmail -join ', ')" -ForegroundColor Cyan }
else { Write-Host "==> Budget: skipped (no email resolved or -NoBudget)." -ForegroundColor Yellow }

# ---- build parameters FILE (avoids az.cmd inline-JSON quote stripping) -----
$tmpl = Join-Path $PSScriptRoot 'main.bicep'
$depName = "swarm-openai-$($acct.id.Substring(0,8))"
$pv = [ordered]@{
  resourceGroupName     = $ResourceGroup
  location              = $Location
  gradingModelName      = $GradingModel
  gradingModelVersion   = $grading.Version
  devModelName          = $DevModel
  devModelVersion       = $dev.Version
  deployGrading         = $grading.Deploy
  deployDev             = $dev.Deploy
  gradingSku            = $grading.Sku
  devSku                = $dev.Sku
  gradingDeploymentName = $GradingModel
  devDeploymentName     = $DevModel
  deployEmbed           = $embed.Deploy
  embedModelName        = $EmbedModel
  embedModelVersion     = $embed.Version
  embedSku              = $embed.Sku
  embedDeploymentName   = $EmbedModel
  capacity              = $Capacity
  enableBudget          = $enableBudget
  budgetAmount          = $BudgetAmount
  budgetContactEmails   = @($BudgetEmail)
}
if ($AccountName) { $pv['accountName'] = $AccountName }
$armParams = [ordered]@{
  '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
  contentVersion = '1.0.0.0'
  parameters     = [ordered]@{}
}
foreach ($k in $pv.Keys) { $armParams.parameters[$k] = @{ value = $pv[$k] } }
$paramFile = Join-Path ([System.IO.Path]::GetTempPath()) 'swarm-deploy.params.json'
# .NET write (NOT Set-Content) so -WhatIf/ShouldProcess doesn't suppress the file write.
[System.IO.File]::WriteAllText($paramFile, ($armParams | ConvertTo-Json -Depth 6))

if ($WhatIfPreference) {
  Write-Host "==> WhatIf: validating + previewing (no changes)..." -ForegroundColor Yellow
  az deployment sub validate -l $Location -f $tmpl -p "@$paramFile" --only-show-errors | Out-Null
  az deployment sub what-if -l $Location -f $tmpl -p "@$paramFile" --only-show-errors
  Write-Host "==> Preview complete. No resources created." -ForegroundColor Green
  return
}

# ---- deploy ----------------------------------------------------------------
Write-Host "==> Deploying (RG '$ResourceGroup', region '$Location')..." -ForegroundColor Cyan
$out = az deployment sub create -l $Location -n $depName -f $tmpl -p "@$paramFile" --only-show-errors | ConvertFrom-Json
$o = $out.properties.outputs
$endpoint   = $o.endpoint.value
$account    = $o.accountName.value
$depGrading = $o.gradingDeployment.value
$depDev     = $o.devDeployment.value
$depEmbed   = $o.embedDeployment.value
$rg         = $o.resourceGroupName.value
Write-Host "==> Deployed account '$account' @ $endpoint" -ForegroundColor Green

# ---- retrieve key + write .env --------------------------------------------
$key = az cognitiveservices account keys list -n $account -g $rg --query key1 -o tsv --only-show-errors
$apiVersion = '2024-10-21'   # adjust to match the VM's provided .env if it differs
$lines = @(
  '# Generated by swarm-azure-toolkit/deploy.ps1 — DO NOT COMMIT (contains a secret).',
  '# Reconcile these variable NAMES against the VM-provided .env before use.',
  '',
  '# --- Azure OpenAI (litellm / CrewAI convention) ---',
  "AZURE_API_KEY=$key",
  "AZURE_API_BASE=$endpoint",
  "AZURE_API_VERSION=$apiVersion",
  ''
)
if ($depDev)     { $lines += "# cheap dev model ($DevModel)";        $lines += "SWARM_DEV_MODEL=azure/$depDev" }
if ($depGrading) { $lines += "# grading-parity model ($GradingModel)"; $lines += "SWARM_GRADING_MODEL=azure/$depGrading" }
else {
  $lines += "# $GradingModel NOT deployed (no quota). Request quota in the portal, or use OpenAI-direct"
  $lines += '# for parity. The autograder uses STAFF Azure gpt-5-nano regardless of this.'
  $lines += "# SWARM_GRADING_MODEL=azure/$GradingModel"
}
if ($depEmbed) {
  $lines += ''
  $lines += "# RAG embedder ($EmbedModel) — reconcile var names with the VM's provided .env"
  $lines += "AZURE_EMBEDDING_DEPLOYMENT=$depEmbed"
  $lines += "SWARM_EMBED_MODEL=azure/$depEmbed"
} else {
  $lines += ''
  $lines += "# Embedder NOT deployed (no quota). The RAG needs one — request quota or use an OpenAI embedder."
}
[System.IO.File]::WriteAllText($EnvOut, ($lines -join "`n") + "`n")

Write-Host "==> Wrote $EnvOut" -ForegroundColor Green
if (-not $depGrading) { Write-Host "==> NOTE: $GradingModel skipped (no quota). See README 'Requesting gpt-5-nano quota'." -ForegroundColor Yellow }
Write-Host ""
Write-Host "Next: copy $EnvOut into the VM's ~/swarm-files/.env (reconcile var names first)," -ForegroundColor Cyan
Write-Host "then smoke-test a crew run. Costs accrue per token — target `$10-20 total." -ForegroundColor Cyan
