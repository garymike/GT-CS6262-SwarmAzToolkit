# swarm-azure-toolkit

Scripts to set up an Azure OpenAI environment for the CS 6262 SWARM project. One command creates a
resource group, an Azure OpenAI account, the model deployments your subscription has quota for, and
a monthly cost budget, then writes a `.env`.

As of June 2026 the course staff recommend OpenAI over Azure. Microsoft changed their quota policy,
so `gpt-5-nano` and `ada-002` quota requests are often denied on Azure for Students accounts,
especially ones created with a GaTech email (that puts the account in the GaTech tenant, whose policy
blocks the request). This toolkit covers the Azure path: it deploys whatever models you do have quota
for (for example `gpt-5-mini` and `text-embedding-3-small`) and skips the rest. If you want the
simpler route, use OpenAI directly with `gpt-5-nano` and `text-embedding-ada-002` for about $5.

This is setup tooling only. There is no `agents.yaml`, knowledge base, or training data here, so it
contains no graded work. Keep your own out of this repo.

## Prerequisites
- Azure CLI and Bicep (`winget install Microsoft.AzureCLI`, then `az bicep install`). `bootstrap.ps1` can install these for you.
- An Azure subscription with Owner or Contributor access. Tenant ownership is not required. Azure for Students includes about $100 in credit.
- PowerShell 7 or later.

## Usage

`bootstrap.ps1` is the guided path. It is safe to re-run and creates nothing until you confirm at the preview step.
```powershell
./bootstrap.ps1
```
It checks for `az` and `bicep`, runs `az login`, lets you pick a subscription and region, lists the
chat and embedding models that have quota, lets you set a budget, shows a no-cost preview, and deploys.

`deploy.ps1` is the scriptable path.
```powershell
./deploy.ps1 -WhatIf                 # preview only, no changes
./deploy.ps1 -Location eastus2       # deploy; writes .env next to the script
./deploy.ps1 -EnvOut .\.env          # write .env somewhere else
./deploy.ps1 -DevModel gpt-4.1-mini  # use a different dev model
./deploy.ps1 -NoBudget               # do not create a budget
```
It finds `az`, registers the Cognitive Services provider, checks model availability and quota,
deploys the models it can, retrieves the key, and writes the `.env`.

`status.ps1` reports month-to-date spend and budget usage. `teardown.ps1` deletes the resource group
and budget when you are done.

## What it deploys
The template has three model slots, each optional:
- grading: `gpt-5-nano`, to match the autograder
- dev: `gpt-5-mini`, for local iteration
- embedding: `text-embedding-3-small`, for the RAG

Notes:
- Student subscriptions usually have no quota for `gpt-5-nano`, so the script skips it. The autograder runs on the staff's own `gpt-5-nano`, so you do not strictly need your own.
- `gpt-4o-mini` can no longer be deployed on Azure (deprecated for new deployments on 2026-03-31), which is why the default dev model is `gpt-5-mini`.
- Embedding models do have quota, so the embedder deploys without a quota request.
- The account uses the S0 tier (no fixed cost) and GlobalStandard deployments (lowest per-token price). Capacity sets the rate limit, not the price; you pay per token.

To see what a region offers:
```powershell
az cognitiveservices model list -l <region> --query "[?kind=='OpenAI'].model.name" -o tsv
az cognitiveservices usage list -l <region> -o table
```

## Requesting gpt-5-nano quota
You do not need your own `gpt-5-nano` to finish the project, but if you want it for local testing:
1. In the portal, open Azure AI Foundry (or the Azure OpenAI resource) and go to Quotas.
2. Select `gpt-5-nano`, your region, and a SKU, then request a small amount (10-50K TPM).
3. Student requests are often slow or denied. If yours is denied, use OpenAI for `gpt-5-nano`, or work on `gpt-5-mini`.

Re-run `deploy.ps1` after approval and it will add the deployment.

## Budget and cost alerts
`deploy.ps1` creates a monthly budget (default $20) on the subscription, with email alerts at 50, 80,
and 100 percent of actual spend plus a 100 percent forecast alert, sent to your signed-in email. It
is a subscription-scope budget, so find it under Cost Management + Billing with the subscription
selected as the scope, or under Subscriptions, your subscription, Cost Management, Budgets. It will
not appear under the billing-account scope. Alerts only fire after a threshold is crossed, and the
portal can take 10 to 30 minutes to show a new budget. To check from the CLI, run
`az consumption budget list`.

## Files
- `bootstrap.ps1`: guided setup
- `deploy.ps1`: scriptable deploy, writes `.env`
- `status.ps1`: spend and budget report
- `teardown.ps1`: delete the resource group and budget
- `main.bicep`: subscription-scope template (resource group, budget, module)
- `modules/openai.bicep`: the OpenAI account and model deployments
- `main.json`: the compiled ARM template, for use without Bicep

## Cost
Billing is per token with no fixed cost. Aim for $10-20 total for the project and run `teardown.ps1`
when finished. You are responsible for any spend beyond your free credits.

## License
MIT, see [LICENSE](LICENSE).
