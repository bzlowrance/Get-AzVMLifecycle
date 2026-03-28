# GET-AZVMLIFECYCLE — Live Demo Guide

**Version:** 2.0.0 | **Duration:** ~30 minutes + Q&A | **Audience:** Internal Microsoft / External Customers

---

## Before You Start

### Prerequisites

- PowerShell 7+
- `Az.Compute`, `Az.Resources`, `Az.ResourceGraph` modules installed
- Logged in: `Connect-AzAccount`
- Active subscription with deployed VMs
- `ImportExcel` module (optional, for XLSX export)

### Pre-flight Checklist

```powershell
# Verify login and subscription
Get-AzContext | Select-Object Account, Subscription, Tenant

# Confirm modules are available
Get-Module Az.Compute -ListAvailable | Select-Object Name, Version -First 1
Get-Module Az.ResourceGraph -ListAvailable | Select-Object Name, Version -First 1
```

### Terminal Setup

- Use **Windows Terminal** or **VS Code integrated terminal** (Unicode icons render correctly)
- Set terminal width to **140+ characters** for best table formatting
- Have the script directory as your working directory

---

## Demo Flow

```
DISCOVER — "What Needs Attention?"   (~10 min)  Scenarios 1-2
ANALYZE  — "What Should I Migrate?"  (~10 min)  Scenarios 3-4
EXPORT   — "Report & Automate"       (~5 min)   Scenarios 5-6
Closing: Recap + Q&A                  (~5 min)
```

---

## Opening (1 minute)

### Talking Points

> "How many of you are tracking VM SKU retirements across your fleet? Microsoft retires old VM families regularly — Dv1, Dv2, Av1, NVv3 — and the migration deadlines are firm."
>
> "This tool scans your deployed VMs, identifies retiring and old-generation SKUs, and gives you compatibility-validated replacement recommendations — all from a single PowerShell command."
>
> "Let me show you."

---

## DISCOVER — "What Needs Attention?"

### Scenario 1: Live Scan (Default Mode) (~5 min, LIVE)

**The story:** You have VMs deployed across multiple subscriptions. Which ones are at risk?

```powershell
.\GET-AZVMLIFECYCLE.ps1 -NoPrompt
```

**What to do:**
1. Run the command — it queries Azure Resource Graph for all deployed VMs
2. Point out the lifecycle risk assessment as results appear
3. Highlight the High / Medium / Low risk classification

**Talking points:**
- "No file needed. The tool pulls your VM inventory directly from Azure via Resource Graph."
- "Each SKU gets a risk level: High means retiring or retired, Medium means old generation, Low means current generation."
- "You get up to 5 replacement recommendations per SKU — 3 from Microsoft's official upgrade paths, 2 from real-time scoring."
- "The summary footer shows total VM count at each risk level."

**What to highlight on screen:**
- Risk levels (High/Medium/Low) color-coded
- Upgrade path recommendations (Drop-in, Future-proof, Cost-optimized)
- Quota analysis showing whether you have capacity for the migration targets
- VM count summary (e.g., "3 SKU(s) (35 VMs) at HIGH risk")

**Transition:**
> "That scanned everything. But what if you only care about production VMs?"

---

### Scenario 2: Scoped Scanning (~3 min, LIVE)

**The story:** You have thousands of VMs but only need to assess production workloads.

```powershell
# Filter by tag
.\GET-AZVMLIFECYCLE.ps1 -Tag @{Environment='prod'} -NoPrompt

# Filter by management group
.\GET-AZVMLIFECYCLE.ps1 -ManagementGroup "mg-production" -NoPrompt

# Filter by resource group
.\GET-AZVMLIFECYCLE.ps1 -ResourceGroup "rg-app","rg-data" -NoPrompt
```

**Talking points:**
- "`-Tag` filters to VMs with specific Azure tags. Use `'*'` as the value to match any VM with a tag key."
- "`-ManagementGroup` scans all subscriptions under a management group — great for enterprise-scale environments."
- "You can combine filters: tag + resource group, or management group + tag."

**Transition:**
> "What if you have a customer VM export but no direct Azure access?"

---

## ANALYZE — "What Should I Migrate?"

### Scenario 3: File-Based Analysis (~4 min, LIVE)

**The story:** Customer sends you an Azure portal VM export. Analyze it without Azure access.

```powershell
# From an Azure portal XLSX export
.\GET-AZVMLIFECYCLE.ps1 -InputFile .\AzureVirtualMachines.xlsx -NoPrompt

# From a simple CSV (SKU, Region, Qty columns)
.\GET-AZVMLIFECYCLE.ps1 -InputFile .\my-vms.csv -Region "eastus" -NoPrompt

# Offline mode — skip quota checks
.\GET-AZVMLIFECYCLE.ps1 -InputFile .\my-vms.csv -Region "eastus" -NoQuota -NoPrompt
```

**Talking points:**
- "Azure portal VM exports work directly — the tool auto-maps SIZE → SKU, LOCATION → Region."
- "CSV files just need a SKU column. Region and Qty are optional."
- "`-NoQuota` skips quota API calls — useful when analyzing someone else's export without their subscription access."

**What to highlight on screen:**
- Column auto-detection (SIZE/LOCATION mapping)
- Region display name → code conversion ("West US" → `westus`)
- One-VM-per-row → quantity aggregation

**Transition:**
> "Now let's add pricing to see the cost impact of these migrations."

---

### Scenario 4: Pricing & Rate Optimization (~4 min, LIVE)

**The story:** Manager asks "what will the migration cost?"

```powershell
# PAYG pricing
.\GET-AZVMLIFECYCLE.ps1 -ShowPricing -NoPrompt

# Full pricing with Savings Plan and Reserved Instance savings
.\GET-AZVMLIFECYCLE.ps1 -ShowPricing -RateOptimization -NoPrompt
```

**Talking points:**
- "`-ShowPricing` auto-detects your pricing tier — EA, MCA, or CSP. Falls back to retail if unavailable."
- "`-RateOptimization` adds 4 columns: SP 1-Year, SP 3-Year, RI 1-Year, RI 3-Year savings."
- "You see the cost delta between your current SKU and each recommended replacement."
- "This answers 'will my migration save money or cost more?' immediately."

**What to highlight on screen:**
- Price Diff column (positive = more expensive, negative = savings)
- Total fleet-wide cost impact
- SP/RI savings compared to PAYG

**Transition:**
> "Let's export all of this for stakeholders."

---

## EXPORT — "Report & Automate"

### Scenario 5: Excel Export (~3 min, LIVE or pre-captured)

```powershell
.\GET-AZVMLIFECYCLE.ps1 `
    -ShowPricing `
    -RateOptimization `
    -SubMap `
    -RGMap `
    -AutoExport `
    -OutputFormat XLSX `
    -NoPrompt
```

**Talking points:**
- "The XLSX report has color-coded risk levels, conditional formatting, and auto-filter columns."
- "`-SubMap` adds a Subscription Map sheet showing VM distribution across subscriptions."
- "`-RGMap` adds a Resource Group Map sheet for finer granularity."
- "This is the artifact you hand to a project manager or compliance officer."
- "If `ImportExcel` isn't installed, it falls back to CSV."

### Scenario 6: JSON for Automation (~2 min, LIVE)

```powershell
.\GET-AZVMLIFECYCLE.ps1 -JsonOutput -NoPrompt
```

**Talking points:**
- "Structured JSON to stdout — pipe to a file or parse in CI/CD pipelines."
- "Every field is machine-readable: risk level, recommendations, pricing, quota."
- "Integrates with Azure DevOps, GitHub Actions, or custom tooling."

---

## Closing (5 minutes)

### Recap

| Capability | How |
|---|---|
| Live VM lifecycle scan | Just run the script (default mode) |
| Scoped scanning | `-Tag`, `-ManagementGroup`, `-ResourceGroup` |
| File-based analysis | `-InputFile .\file.csv` or `.xlsx` |
| Offline analysis | `-InputFile` + `-NoQuota` |
| Pricing comparison | `-ShowPricing` (auto-detects EA/retail) |
| RI/SP savings | `-RateOptimization` |
| Deployment maps | `-SubMap`, `-RGMap` |
| Placement scores | `-ShowPlacement` |
| JSON automation | `-JsonOutput` |
| Excel export | `-AutoExport -OutputFormat XLSX` |

### Key Differentiators

- **Lifecycle-focused:** Retirement detection + upgrade path recommendations
- **Compatibility-validated:** 12 hard requirements checked before any recommendation
- **Azure portal exports:** Drag-and-drop XLSX input
- **Flexible scoping:** Tag, management group, resource group, subscription
- **No Azure CLI dependency:** Pure Az PowerShell modules
- **Open source:** MIT licensed, contributions welcome

### Q&A Guidance

| Question | Answer |
|---|---|
| "Does this work in Cloud Shell?" | Yes, auto-detects and adjusts paths and icons. |
| "Do I need special permissions?" | Reader role is sufficient. Billing Reader adds negotiated pricing. |
| "Does it support sovereign clouds?" | Yes — USGov and China presets auto-set the environment. |
| "Is this safe to run in production?" | It's read-only — no resource modifications, only API reads. |
| "What about ARM64 migrations?" | The compatibility gate handles architecture matching automatically. |
| "How many families are covered?" | 19 VM families with curated upgrade paths. |

### Project Links

- **Repository:** [github.com/bzlowrance/Get-AzVMLifecycle](https://github.com/bzlowrance/Get-AzVMLifecycle)
- **Issues / Feature Requests:** via GitHub Issues
- **License:** MIT

---

## Appendix: Pre-Captured Output Tips

1. **Pricing (Scenario 4):** First pricing call can take 5-10 seconds. Run once before the demo to warm up.
2. **Excel (Scenario 5):** Have a pre-generated XLSX open in Excel as a backup.
3. **Placement Scores:** Requires "Compute Recommendations" RBAC role. Degrades gracefully if absent.

### Recommended Demo Order Adjustments

- **Short version (10 min):** Scenarios 1, 4, 5 — scan, pricing, export.
- **Executive version (10 min):** Scenarios 1, 5 — scan results + Excel handoff.
- **Engineer version (20 min):** Scenarios 1, 2, 3, 4 — all analysis modes.
- **Full version (30 min):** All 6 scenarios.
