# swarm-azure-toolkit

One-command Azure OpenAI provisioning for the **CS 6262 SWARM** project. Deploys an Azure OpenAI
account with two model slots — a **grading** model (`gpt-5-nano`, parity with the staff autograder)
and a **dev** model (`gpt-5-mini`, cheap local iteration in the same gpt-5 family) — runs a
**quota + deprecation preflight**, skips anything it can't deploy, creates a **cost budget with
alerts**, and writes a ready `.env`. Student-agnostic: nothing is hard-coded to one subscription/tenant.

> Shareable with classmates — the project doc explicitly permits helping with technical setup, and
> infra tooling is not a graded artifact. **Do not** put your `agents.yaml`/knowledge/training here.

## Prerequisites
- Azure CLI + Bicep: `winget install Microsoft.AzureCLI` then `az bicep install` (bootstrap can do this)
- An Azure subscription (Azure for Students gives ~$100 free credit). You need **Owner/Contributor on the subscription** — not tenant ownership.
- PowerShell 7+

## Usage

### Guided (recommended) — `bootstrap.ps1`
Interactive end-to-end setup; safe to re-run, nothing created until the WhatIf gate:
```powershell
./bootstrap.ps1
```
Steps: detect `az`+`bicep` (offer install; refresh PATH in-process so a just-installed CLI is found
without a shell restart) → `az login` (links to Azure for Students if you have none) → pick
subscription → **check your role** → pick region + **choose which models to deploy** (lists only
chat models that have quota and aren't deprecated) → opt-in **budget** → no-cost `-WhatIf` → deploy.

### Direct — `deploy.ps1`
```powershell
./deploy.ps1 -WhatIf                          # validate + preview, no changes
./deploy.ps1 -Location eastus2                # deploy (gpt-5-mini dev by default; .env beside the script)
./deploy.ps1 -EnvOut .\.env                   # or point -EnvOut anywhere (e.g. your VM-share path)
./deploy.ps1 -DevModel gpt-4.1-mini           # choose a different dev model
./deploy.ps1 -NoBudget                        # skip the budget
```
Auto-locates `az`, registers `Microsoft.CognitiveServices`, runs a **quota + deprecation preflight**
(picks a SKU with available quota, skips any model with none), deploys, retrieves the key, writes `.env`.

### Other scripts
- `status.ps1` — month-to-date spend + budget burn (via Cost Management REST; no extra extension).
- `teardown.ps1` — delete the resource group (and budget) when the project is done.

## Models, quota & SKUs (important)
- **Student subs usually have 0 quota for `gpt-5-nano`** — the toolkit detects this and **skips** it.
  That's fine: the **autograder uses the staff's Azure gpt-5-nano**, so your own is parity-only.
- **`gpt-4o-mini` is deprecated for new Azure deployments** (since 2026-03-31). The default dev model
  is therefore **`gpt-5-mini`** (gpt-5 family → closest behavior to the grader; ample quota).
- **Cheapest tier is already used:** account SKU **S0** (no idle/fixed cost), deployment SKU
  **GlobalStandard** (lowest per-token price of the data-plane SKUs). Capacity (TPM) is a rate limit,
  **not** a price multiplier — you pay strictly per token.

Check what's available + has quota in a region:
```powershell
az cognitiveservices model list -l <region> --query "[?kind=='OpenAI'].model.name" -o tsv
az cognitiveservices usage list -l <region> -o table   # quota limits per model/SKU
```

## Requesting gpt-5-nano quota (optional)
The grader doesn't require your own gpt-5-nano, but if you want local parity:
1. Portal → **Azure AI Foundry** (or **Azure OpenAI** resource) → **Quotas**.
2. Select **gpt-5-nano**, your region, and a SKU → **Request quota** (small amount, e.g. 10–50K TPM).
3. Student-sub requests may be slow or denied. If so, use **OpenAI-direct** for gpt-5-nano, or just
   develop on `gpt-5-mini` and rely on the staff grader.
After approval, re-run `deploy.ps1` — it will detect the new quota and add the gpt-5-nano deployment.

## Budgets & cost alerts
`deploy.ps1` creates a **subscription-scope** monthly budget (default $20) with email alerts at
50/80/100% actual + 100% forecast, to your signed-in email. To view it in the portal, set the scope
to your **Azure for Students subscription**: *Cost Management + Billing → (scope) → Budgets*, or
*Subscriptions → Azure for Students → Cost Management → Budgets*. (A subscription budget will NOT show
under the billing-account scope.) Alerts fire only once a threshold is crossed; the portal can lag
~10–30 min after creation. Authoritative check: `az consumption budget list`.

## Files
- `bootstrap.ps1` — guided interactive setup (tooling → login → sub → role → region + model picker → budget → WhatIf → deploy)
- `deploy.ps1` — scriptable deploy with quota/deprecation preflight → `.env`
- `status.ps1` — MTD spend + budget burn report
- `teardown.ps1` — delete RG + budget
- `main.bicep` — subscription-scope entry (RG + budget + module)
- `modules/openai.bicep` — Azure OpenAI account + grading/dev deployments (each toggleable, own SKU)
- `main.json` — compiled ARM template (for anyone without Bicep)

## Features
- Tooling detection + optional auto-install of `az`/`bicep`, with in-process PATH refresh (no shell restart needed)
- Guided login, subscription picker, and role check
- Region scan + interactive, quota- and deprecation-aware model picker
- Quota + deprecation preflight: skips models you can't deploy and picks a SKU that has quota
- Opt-in monthly cost budget with email alerts (50/80/100% actual + 100% forecast)
- Month-to-date spend report (`status.ps1`) and one-command teardown (`teardown.ps1`)
- Compiled ARM template (`main.json`) for use without Bicep
- Idempotent: re-running applies the same declarative template (safe to run repeatedly; e.g. after a quota grant)

## Cost
Per-token billing, no idle cost. Target **$10–20 total** for the whole project; run `teardown.ps1`
when done. You are responsible for spend beyond free credits.
