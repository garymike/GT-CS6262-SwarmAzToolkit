#requires -Version 7.0
<#
.SYNOPSIS
  Report month-to-date Azure spend + budget status for the SWARM subscription.
  Uses the az CLI only (no Az PowerShell module needed).

.NOTES
  Exact remaining student-credit balance is portal-only (no supported CLI field):
  portal.azure.com -> Cost Management + Billing -> Credits. This shows SPEND + budget burn.
#>
[CmdletBinding()]
param([string] $SubscriptionId)

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
if ($SubscriptionId) { az account set --subscription $SubscriptionId; $acct = az account show --only-show-errors | ConvertFrom-Json }
$subId = $acct.id
Write-Host "Subscription: $($acct.name)  ($subId)" -ForegroundColor Cyan

# --- month-to-date actual cost (Cost Management REST; no extension needed) --
Write-Host "`n== Month-to-date spend ==" -ForegroundColor Magenta
$body = '{"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"Cost","function":"Sum"}}}}'
$bodyFile = Join-Path $env:TEMP 'swarm-cmquery.json'
Set-Content -Path $bodyFile -Value $body -Encoding ascii
$uri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
try {
  $q = az rest --method post --uri $uri --body "@$bodyFile" --only-show-errors | ConvertFrom-Json
  $rows = $q.properties.rows
  if ($rows -and $rows.Count) {
    $total = ($rows | ForEach-Object { [double]$_[0] } | Measure-Object -Sum).Sum
    $cur   = $rows[0][-1]
    Write-Host ("  MTD cost: {0:N2} {1}" -f $total, $cur) -ForegroundColor Green
  } else { Write-Host "  MTD cost: 0.00 (no charges this billing month)" -ForegroundColor Green }
} catch { Write-Host "  (cost query failed: $($_.Exception.Message))" -ForegroundColor Yellow }
finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }

# --- budgets ----------------------------------------------------------------
Write-Host "`n== Budgets ==" -ForegroundColor Magenta
try {
  $budgets = az consumption budget list --only-show-errors 2>$null | ConvertFrom-Json
  if ($budgets) {
    foreach ($b in $budgets) {
      $spent = if ($b.currentSpend) { [double]$b.currentSpend.amount } else { 0 }
      $pct = if ($b.amount) { [math]::Round(100*$spent/$b.amount,1) } else { 0 }
      Write-Host ("  {0}: {1:N2}/{2:N2} ({3}%) [{4}]" -f $b.name,$spent,$b.amount,$pct,$b.timeGrain) -ForegroundColor Green
    }
  } else { Write-Host "  (no budgets yet - deploy.ps1 creates one)" -ForegroundColor DarkGray }
} catch { Write-Host "  (budget list unavailable: $($_.Exception.Message))" -ForegroundColor Yellow }

Write-Host "`nExact remaining credit (portal): Cost Management + Billing -> Credits" -ForegroundColor Cyan
