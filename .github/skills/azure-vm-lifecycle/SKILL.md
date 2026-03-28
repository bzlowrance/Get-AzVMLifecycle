---
name: azure-vm-lifecycle
description: "Azure VM lifecycle management — detect retiring SKUs, get upgrade recommendations, and plan migrations using Get-AzVMLifecycle. USE FOR: which VMs are retiring, lifecycle risks, SKU retirement dates, upgrade recommendations, migration planning, compatibility-validated replacements, fleet modernization, old-gen SKU detection, VM lifecycle scan, analyze VM export. DO NOT USE FOR: general VM size recommendations without Azure login (use azure-compute), quota management via CLI (use azure-quotas), deploying VMs (use azure-prepare), raw availability scanning (use upstream Get-AzVMAvailability)."
license: MIT
metadata:
  author: Barry Lowrance
  version: "2.0.0"
---

# Azure VM Lifecycle Management

> **AUTHORITATIVE GUIDANCE** — This skill teaches you when and how to invoke
> the `Get-AzVMLifecycle.ps1` script via terminal for Azure VM lifecycle
> analysis. The script is the execution engine; this skill is the routing layer.

## When to Use This Skill

Invoke this skill when the user wants to:
- Detect **retiring or deprecated** VM SKUs in their fleet
- Get **upgrade recommendations** with compatibility validation
- Analyze a **CSV/XLSX file** of VMs for lifecycle risks
- Run a **live scan** of deployed VMs via Azure Resource Graph
- Check **pricing comparison** between current and recommended SKUs
- Identify **old-generation** SKUs that should be modernized
- Generate **XLSX reports** showing fleet lifecycle risk
- Validate that replacement SKUs meet **compatibility requirements**

### When NOT to Use This Skill

| Scenario | Use Instead |
|----------|-------------|
| General VM size recommendation (no Azure login needed) | `azure-compute` |
| Check/manage quota limits via `az quota` CLI | `azure-quotas` |
| Deploy VMs or infrastructure | `azure-prepare` → `azure-validate` → `azure-deploy` |
| Raw SKU availability scanning across regions | Upstream `Get-AzVMAvailability` |
| Verify local script is up to date | `AzVMLifecycle-release-verification-workflow` |

---

## Prerequisites

Before running, verify these requirements. **Stop and help the user fix any missing prerequisite.**

### 1. Script Must Be On The Machine

```powershell
$paths = @(
    "$env:USERPROFILE\Get-AzVMLifecycle\Get-AzVMLifecycle.ps1",
    "$env:USERPROFILE\source\repos\Get-AzVMLifecycle\Get-AzVMLifecycle.ps1"
)
$found = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($found) { Write-Host "Found: $found" } else { Write-Host "NOT FOUND" }
```

**If not found:**
```powershell
git clone https://github.com/bzlowrance/Get-AzVMLifecycle.git
cd Get-AzVMLifecycle
```

### 2. PowerShell 7+ Required

```powershell
$PSVersionTable.PSVersion  # Must be 7.0+
```

### 3. Azure Modules & Login

```powershell
Get-Module Az.Compute -ListAvailable
Get-Module Az.ResourceGraph -ListAvailable
Get-AzContext  # Must have active login
```

If not logged in: `Connect-AzAccount`

---

## Decision Tree

```
User request
    │
    ├─ "What VM should I use for X workload?"
    │   └─ Use azure-compute skill (no login needed)
    │
    ├─ "Which of my VMs are retiring?"
    │   └─ THIS SKILL → Default live scan
    │
    ├─ "Analyze this VM export for lifecycle risks"
    │   └─ THIS SKILL → -InputFile mode
    │
    ├─ "What should I replace Standard_D4s_v3 with?"
    │   └─ THIS SKILL → -InputFile with CSV containing the SKU
    │
    ├─ "Check lifecycle status of my production VMs"
    │   └─ THIS SKILL → Default scan with -Tag @{Environment='prod'}
    │
    └─ "Generate a migration report for stakeholders"
        └─ THIS SKILL → Default scan with -AutoExport -OutputFormat XLSX
```

---

## Core Workflows

### Workflow 1: Live Lifecycle Scan (Default)

**Scenario:** Detect retiring SKUs across deployed VMs.

```powershell
# Scan current subscription
.\Get-AzVMLifecycle.ps1 -JsonOutput

# Scan specific subscriptions
.\Get-AzVMLifecycle.ps1 -SubscriptionId "sub-id-1","sub-id-2" -JsonOutput

# Scan a management group
.\Get-AzVMLifecycle.ps1 -ManagementGroup "mg-production" -JsonOutput

# Filter by tag
.\Get-AzVMLifecycle.ps1 -Tag @{Environment='prod'} -JsonOutput
```

**Always use `-JsonOutput`** when running from Copilot to get structured output.

### Workflow 2: File-Based Analysis

**Scenario:** Analyze a CSV, JSON, or Azure portal XLSX export.

```powershell
# From a CSV file
.\Get-AzVMLifecycle.ps1 -InputFile .\my-vms.csv -Region "eastus" -JsonOutput

# From an Azure portal VM export (XLSX)
.\Get-AzVMLifecycle.ps1 -InputFile .\AzureVirtualMachines.xlsx -JsonOutput

# Offline analysis (no Azure login for quota checks)
.\Get-AzVMLifecycle.ps1 -InputFile .\my-vms.csv -Region "eastus" -NoQuota -JsonOutput
```

**CSV file format:**
```csv
SKU,Region,Qty
Standard_D4s_v3,eastus,10
Standard_E8s_v3,westus2,5
Standard_F4s_v2,eastus,3
```

Column names are flexible: `SKU`/`Size`/`VmSize` for SKU, `Region`/`Location` for region, `Qty`/`Quantity`/`Count` for quantity.

### Workflow 3: Pricing Comparison

```powershell
# PAYG pricing
.\Get-AzVMLifecycle.ps1 -ShowPricing -JsonOutput

# Full pricing with RI/SP savings
.\Get-AzVMLifecycle.ps1 -ShowPricing -RateOptimization -JsonOutput
```

### Workflow 4: Image Compatibility

```powershell
# Check ARM64 image compatibility
.\Get-AzVMLifecycle.ps1 -InputFile .\my-vms.csv -ImageURN "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-arm64:latest" -JsonOutput

# Check Gen2 Windows image
.\Get-AzVMLifecycle.ps1 -ImageURN "MicrosoftWindowsServer:WindowsServer:2022-datacenter-g2:latest" -JsonOutput
```

### Workflow 5: Placement Scores

```powershell
# Show allocation likelihood scores
.\Get-AzVMLifecycle.ps1 -ShowPlacement -JsonOutput

# With pricing enrichment
.\Get-AzVMLifecycle.ps1 -ShowPricing -ShowPlacement -JsonOutput
```

**Notes:**
- `-ShowPlacement` requires "Compute Recommendations Role" RBAC — fails gracefully if missing
- Placement API accepts max 5 SKUs x 8 regions per call

### Workflow 6: Export for Reporting

```powershell
# XLSX with deployment maps
.\Get-AzVMLifecycle.ps1 -SubMap -RGMap -AutoExport -OutputFormat XLSX

# Full enrichment: pricing + maps + export
.\Get-AzVMLifecycle.ps1 -ShowPricing -RateOptimization -SubMap -RGMap -AutoExport
```

---

## Parameter Quick Reference

| Parameter | Type | Purpose |
|-----------|------|---------|
| `-InputFile` | String | CSV, JSON, or XLSX file with VM SKUs for analysis |
| `-Region` | String[] | Azure region codes. Auto-detected in live scan mode |
| `-RegionPreset` | String | Predefined set: USEastWest, USMajor, Europe, etc. |
| `-SubscriptionId` | String[] | Target subscriptions for live scan |
| `-ManagementGroup` | String[] | Management group scope for live scan |
| `-ResourceGroup` | String[] | Resource group filter for live scan |
| `-Tag` | Hashtable | Tag filter for live scan: `@{Env='prod'}` |
| `-SkuFilter` | String[] | Filter to specific SKUs with wildcards |
| `-ShowPricing` | Switch | Include pricing comparison |
| `-RateOptimization` | Switch | Add RI/SP savings columns (requires `-ShowPricing`) |
| `-ShowPlacement` | Switch | Show allocation likelihood scores |
| `-ShowSpot` | Switch | Include Spot VM pricing |
| `-ImageURN` | String | Check image compatibility |
| `-TopN` | Int | Recommendations per SKU (default 5, max 25) |
| `-MinScore` | Int | Min similarity score 0-100 (default 50, use 0 for all) |
| `-MinvCPU` | Int | Min vCPU filter for recommendations |
| `-MinMemoryGB` | Int | Min memory filter for recommendations |
| `-SubMap` | Switch | Add Subscription Map sheet to XLSX |
| `-RGMap` | Switch | Add Resource Group Map sheet to XLSX |
| `-NoQuota` | Switch | Skip quota checks (offline analysis) |
| `-Interactive` | Switch | Enable interactive wizard (non-interactive by default) |
| `-JsonOutput` | Switch | **Always use from Copilot** — structured JSON output |
| `-AutoExport` | Switch | Export without prompting |
| `-OutputFormat` | String | Auto, CSV, or XLSX |

---

## Region Presets

| Preset | Regions | Notes |
|--------|---------|-------|
| USEastWest | eastus, eastus2, westus, westus2 | US coastal |
| USCentral | centralus, northcentralus, southcentralus, westcentralus | US central |
| USMajor | eastus, eastus2, centralus, westus, westus2 | Top 5 US |
| Europe | westeurope, northeurope, uksouth, francecentral, germanywestcentral | EU |
| AsiaPacific | eastasia, southeastasia, japaneast, australiaeast, koreacentral | APAC |
| Global | eastus, westeurope, southeastasia, australiaeast, brazilsouth | Worldwide |
| USGov | usgovvirginia, usgovtexas, usgovarizona | Auto-sets AzureUSGovernment |
| China | chinaeast, chinanorth, chinaeast2, chinanorth2 | Auto-sets AzureChinaCloud |
| ASR-EastWest | eastus, westus2 | DR pair |
| ASR-CentralUS | centralus, eastus2 | DR pair |

---

## JSON Output Schema

### Lifecycle Analysis

```json
{
  "schemaVersion": "1.0",
  "mode": "lifecycle",
  "generatedAt": "ISO8601",
  "subscriptions": ["sub-id"],
  "regions": ["eastus", "westus2"],
  "summary": {
    "totalSkus": 5,
    "totalVMs": 35,
    "highRisk": 2,
    "mediumRisk": 1,
    "lowRisk": 2
  },
  "entries": [
    {
      "sku": "Standard_D4s_v3",
      "region": "eastus",
      "qty": 10,
      "riskLevel": "Medium",
      "riskReasons": ["Old generation (v3)"],
      "recommendations": [
        {
          "rank": 1,
          "type": "Upgrade: Drop-in",
          "sku": "Standard_D4s_v5",
          "vCPU": 4,
          "memGiB": 16,
          "score": 95,
          "capacity": "OK",
          "priceHr": 0.192,
          "details": "Same family, SCSI disk — safest migration from Dv3"
        }
      ]
    }
  ]
}
```

> **Note:** The schema is additive — new fields may appear in future versions,
> but existing fields will not be removed without a `schemaVersion` change.

---

## Risk Level Meanings

| Risk | Meaning | Action |
|------|---------|--------|
| High | Retired/retiring SKU, no capacity, or no alternatives | Migrate immediately |
| Medium | Old generation (v3 or below) | Plan migration to current gen |
| Low | Current generation, good capacity | No action needed |

---

## Interpreting Results

When presenting results to the user:

1. **Live scan**: Summarize total VM count at each risk level, highlight High-risk SKUs first
2. **File analysis**: Note any SKUs with no compatible replacements, suggest expanding regions
3. **Always mention**: risk level, upgrade path type (Drop-in vs. Future-proof), quota availability
4. **Pricing**: Show cost delta between current and recommended SKUs if pricing is enabled

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Script not found | `git clone https://github.com/bzlowrance/Get-AzVMLifecycle.git` |
| PowerShell 5.1 error | Use `pwsh -File .\Get-AzVMLifecycle.ps1` |
| No Azure context | Run `Connect-AzAccount` first |
| `AzureEndpoints` error | Script is stale — pull latest from repo |
| Region validation fails | Add `-SkipRegionValidation` as last resort |
| Quota shows `?` | Quota API didn't return data for that family |
