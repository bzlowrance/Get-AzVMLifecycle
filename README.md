# Get-AzVMLifecycle

Azure VM lifecycle management — detect retiring SKUs, get upgrade recommendations, and plan migrations.

![PowerShell](https://img.shields.io/badge/PowerShell-7.0%2B-blue)
![Azure](https://img.shields.io/badge/Azure-Az%20Modules-0078D4)
![License](https://img.shields.io/badge/License-MIT-green)
![Version](https://img.shields.io/badge/Version-2.0.0-brightgreen)

## Disclosure & Disclaimer

The author is a Microsoft employee; however, this is a **personal open-source project**. It is **not** an official Microsoft product, nor is it endorsed, sponsored, or supported by Microsoft.

- **No warranty**: Provided "as-is" under the [MIT License](LICENSE).
- **No official support**: For Azure platform issues, use [Azure Support](https://azure.microsoft.com/support/).
- **No confidential information**: This tool uses only publicly documented Azure APIs. Please do not share internal or confidential information in issues, pull requests, or discussions.
- **Trademarks**: "Microsoft" and "Azure" are trademarks of Microsoft Corporation. Their use here is for identification only and does not imply endorsement.

## Overview

Get-AzVMLifecycle analyzes your deployed Azure VMs for lifecycle risks and recommends migration paths. It identifies retiring, deprecated, and old-generation SKUs, then provides compatibility-validated replacement recommendations with capacity, quota, and pricing analysis.

**Two modes of operation:**

1. **Live scan (default)** — Queries Azure Resource Graph for deployed VMs and runs lifecycle analysis across all discovered regions. No file needed.
2. **File-based (`-InputFile`)** — Accepts CSV, JSON, or XLSX files (including native Azure portal VM exports) for offline lifecycle analysis.

## Features

- **Retirement Detection** — Identifies SKUs on Microsoft's published retirement schedule with dates
- **Upgrade Path Recommendations** — 3 curated paths (drop-in, future-proof, cost-optimized) + 2 weighted alternatives per SKU
- **Compatibility Validation** — 12 hard requirements checked before any recommendation (vCPU, memory, NICs, accelerated networking, premium IO, disk interface, ephemeral OS, Ultra SSD)
- **Quota-Aware Analysis** — Checks current usage vs. limits for both source and target SKU families, factoring in VM quantity
- **Pricing Comparison** — PAYG, Savings Plan, and Reserved Instance pricing with fleet-wide cost projection
- **Azure Portal Export Support** — Drop in an XLSX exported from the VM blade; column mapping is automatic
- **Live Azure Scanning** — Pull VM inventory directly from Resource Graph with management group, resource group, and tag scoping
- **Subscription & Resource Group Mapping** — Optional XLSX sheets showing VM deployment distribution
- **Styled XLSX Reports** — Color-coded risk levels, conditional formatting, auto-filter columns

## Quick Comparison

| Task                                 | Azure Portal              | This Script               |
| ------------------------------------ | ------------------------- | ------------------------- |
| Find retiring SKUs in your fleet     | Manual research per SKU   | Automated scan            |
| Get upgrade recommendations          | Read docs + cross-check   | Validated alternatives    |
| Check quota for migration targets    | Multiple blades           | Single view               |
| Compare pricing across replacements  | Separate calculator       | Integrated                |
| Analyze 100+ VMs across regions      | Hours of manual work      | Minutes                   |
| Export results for stakeholders      | Manual copy/paste         | One command               |

## Use Cases

- **Retirement Planning** — Identify which VMs are running retiring or deprecated SKUs and get migration paths
- **Fleet Modernization** — Find old-generation SKUs (v2, v3) and plan upgrades to current generation
- **Cost Optimization** — Compare pricing across replacement SKUs including RI/SP savings
- **Migration Validation** — Verify that target SKUs meet all compatibility requirements before migrating
- **Compliance Reporting** — Generate XLSX reports showing fleet lifecycle risk for stakeholders

## Requirements

- **PowerShell 7.0+** (required)
- **Azure PowerShell Modules**: `Az.Compute`, `Az.Resources`, `Az.ResourceGraph`
- **Optional**: `ImportExcel` module for styled XLSX export

## Supported Cloud Environments

The script automatically detects your Azure environment and uses the correct API endpoints:

| Cloud            | Environment Name    | Supported |
| ---------------- | ------------------- | --------- |
| Azure Commercial | `AzureCloud`        | ✅         |
| Azure Government | `AzureUSGovernment` | ✅         |
| Azure China      | `AzureChinaCloud`   | ✅         |
| Azure Germany    | `AzureGermanCloud`  | ✅         |

**No configuration required** — the script reads your current `Az` context and resolves endpoints automatically.

## Installation

```powershell
# Clone the repository
git clone https://github.com/bzlowrance/Get-AzVMLifecycle.git
cd Get-AzVMLifecycle

# Install required Azure modules (if needed)
Install-Module -Name Az.Compute -Scope CurrentUser
Install-Module -Name Az.Resources -Scope CurrentUser
Install-Module -Name Az.ResourceGraph -Scope CurrentUser

# Optional: Install ImportExcel for styled exports
Install-Module -Name ImportExcel -Scope CurrentUser
```

## Quick Start

```powershell
# Live scan — pull VMs from Azure and analyze lifecycle risks
.\Get-AzVMLifecycle.ps1

# Scan a specific subscription
.\Get-AzVMLifecycle.ps1 -SubscriptionId "xxxx-xxxx"

# Scan a management group with tag filter
.\Get-AzVMLifecycle.ps1 -ManagementGroup "Production" -Tag @{Environment='prod'}

# File-based analysis from a CSV
.\Get-AzVMLifecycle.ps1 -InputFile .\my-vms.csv -Region "eastus"

# Analyze an Azure portal VM export with full pricing
.\Get-AzVMLifecycle.ps1 -InputFile .\AzureVirtualMachines.xlsx -ShowPricing -RateOptimization

# Live scan with deployment maps and auto-export
.\Get-AzVMLifecycle.ps1 -SubMap -RGMap -AutoExport

# JSON output for automation
.\Get-AzVMLifecycle.ps1 -JsonOutput

# Interactive wizard — guided step-by-step setup
.\Get-AzVMLifecycle.ps1 -Interactive
```

### Interactive Wizard (`-Interactive`)

By default the script runs non-interactively: it uses your current Azure context, auto-detects regions from deployed VMs, and produces output immediately — ideal for automation, CI/CD, and AI agents.

Add `-Interactive` (alias `-Prompt`) to launch a guided wizard that walks you through every option:

```
Get-AzVMLifecycle v2.0.0

STEP 1: SELECT SUBSCRIPTION(S)
============================================================
1. My-Production-Sub
   xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
2. My-Dev-Sub
   yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy

Enter number(s) separated by commas (e.g., 1,3) or press Enter for #1:

STEP 2: SELECT REGION(S)
====================================================================================================
FAST PATH: Type region codes now to skip the long list (comma/space separated)
Examples: eastus eastus2 westus3  |  Press Enter to show full menu

Export results to file? (y/N):
Include estimated pricing? (adds ~5-10 sec) (y/N):
Show allocation likelihood scores? (High/Medium/Low per SKU) (y/N):
Include Spot VM pricing alongside regular pricing? (y/N):
Check SKU compatibility with a specific VM image? (y/N):
```

**When to use `-Interactive`:**

| Scenario | Why |
|----------|-----|
| First-time exploration | Browse subscriptions and regions you haven't used before |
| Ad-hoc investigation | Quickly toggle pricing, placement, or image checks without memorizing flags |
| Demo or training | Walk an audience through the tool's capabilities step by step |
| Customer workshop | Let a customer drive the tool on their own tenant |

## Parameters

| Parameter               | Type       | Description                                                                                                               |
| ----------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------- |
| `-SubscriptionId`       | String[]   | Azure subscription ID(s) to scan                                                                                          |
| `-Region`               | String[]   | Azure region code(s) (e.g., 'eastus', 'westus2'). Auto-detected from deployed VMs in live scan mode. Required for `-InputFile` when the file lacks Region data |
| `-RegionPreset`         | String     | Predefined region set (see table below). Auto-sets environment for sovereign clouds                                       |
| `-InputFile`            | String     | Path to CSV, JSON, or XLSX file listing VM SKUs. CSV: column SKU (or Size/VmSize). JSON: array of `{"SKU":"..."}` objects. Qty and Region columns are optional. Supports native Azure portal VM exports (XLSX) |
| `-ManagementGroup`      | String[]   | Scope live scan to specific management group(s) for cross-subscription scanning                                           |
| `-ResourceGroup`        | String[]   | Filter live scan to specific resource group(s)                                                                            |
| `-Tag`                  | Hashtable  | Filter live scan to VMs with specific tags, e.g. `@{Environment='prod'}`. Use `'*'` as value to match any VM with the tag key |
| `-SubMap`               | Switch     | Add a 'Subscription Map' sheet to the XLSX export showing VM distribution                                                 |
| `-RGMap`                | Switch     | Add a 'Resource Group Map' sheet to the XLSX export                                                                       |
| `-ShowPricing`          | Switch     | Show hourly/monthly pricing (auto-detects negotiated EA/MCA/CSP rates, falls back to retail)                              |
| `-ShowSpot`             | Switch     | Include Spot VM pricing when pricing is enabled                                                                           |
| `-RateOptimization`     | Switch     | Include Savings Plan and Reserved Instance savings columns. Requires `-ShowPricing`                                        |
| `-ShowPlacement`        | Switch     | Show allocation likelihood scores from Azure placement API                                                                |
| `-NoQuota`              | Switch     | Skip quota checks (use when analyzing a customer extract without subscription access)                                     |
| `-SkuFilter`            | String[]   | Filter to specific SKUs (supports wildcards, e.g. `Standard_D*_v5`)                                                      |
| `-ImageURN`             | String     | Check SKU compatibility with a VM image (format: Publisher:Offer:Sku:Version)                                             |
| `-TopN`                 | Int        | Number of alternative SKUs to return per SKU (default 5, max 25)                                                          |
| `-MinScore`             | Int        | Minimum similarity score (0-100) for alternatives; set 0 to show all (default 50)                                         |
| `-MinvCPU`              | Int        | Minimum vCPU count filter for alternatives                                                                                |
| `-MinMemoryGB`          | Int        | Minimum memory (GB) filter for alternatives                                                                               |
| `-ExportPath`           | String     | Directory for export files                                                                                                |
| `-AutoExport`           | Switch     | Export without prompting                                                                                                  |
| `-OutputFormat`         | String     | 'Auto', 'CSV', or 'XLSX'                                                                                                  |
| `-JsonOutput`           | Switch     | Emit structured JSON for automation                                                                                       |
| `-Interactive`          | Switch     | Enable interactive wizard prompts for subscription, region, and feature selection. Non-interactive by default              |
| `-CompactOutput`        | Switch     | Use compact output for narrow terminals                                                                                   |
| `-UseAsciiIcons`        | Switch     | Force ASCII instead of Unicode icons                                                                                      |
| `-Environment`          | String     | Azure cloud (default: auto-detect). Options: AzureCloud, AzureUSGovernment, AzureChinaCloud, AzureGermanCloud             |
| `-SkipRegionValidation` | Switch     | Skip Azure region metadata validation                                                                                    |

> **Tuning tip:** Use `-MinScore 0` to see all candidates when capacity is tight, or raise it (e.g., 70) to prioritize closer matches.

## Lifecycle Analysis

### Input Options

**Option 1: Live scan from Azure (default — no file needed)**

```powershell
# Scan current subscription
.\Get-AzVMLifecycle.ps1

# Scan specific subscriptions
.\Get-AzVMLifecycle.ps1 -SubscriptionId "sub-id-1","sub-id-2"

# Scan an entire management group (all child subscriptions)
.\Get-AzVMLifecycle.ps1 -ManagementGroup "mg-production"

# Scan specific resource groups
.\Get-AzVMLifecycle.ps1 -SubscriptionId "sub-id" -ResourceGroup "rg-app","rg-data"

# Scan only VMs tagged with Environment=prod
.\Get-AzVMLifecycle.ps1 -Tag @{Environment='prod'}

# Combine filters
.\Get-AzVMLifecycle.ps1 -SubscriptionId "sub-id" -Tag @{CostCenter='12345'; Environment='prod'}

# Scan all VMs that have a "Department" tag (any value)
.\Get-AzVMLifecycle.ps1 -Tag @{Department='*'}
```

Requires the `Az.ResourceGraph` module (`Install-Module Az.ResourceGraph -Scope CurrentUser`).

> **Scoping rules:** `-ManagementGroup` and `-SubscriptionId` are mutually exclusive. `-ResourceGroup` and `-Tag` can be combined with either. If neither is specified, the current subscription context is used.

**Option 2: From a CSV/JSON file**

```csv
SKU,Region,Qty
Standard_D4s_v3,eastus,10
Standard_E8s_v3,westus2,5
Standard_F4s_v2,eastus,3
Standard_D8s_v5,centralus,20
```

All columns except **SKU** are optional:
- **Region** — where the SKU is deployed. Regions are auto-merged into the scan.
- **Qty** — number of VMs (defaults to 1). Used for quota analysis. Duplicate SKU+Region rows are aggregated.

> **Column names are flexible:** `SKU`, `Size`, or `VmSize` (falls back to `Name`) for the SKU column; `Region`, `Location`, or `AzureRegion` for region; `Qty`, `Quantity`, or `Count` for quantity.

```powershell
.\Get-AzVMLifecycle.ps1 -InputFile .\my-vms.csv -Region "eastus"
```

**Option 3: From an Azure portal export (XLSX)**

Export from the Azure portal (Virtual Machines blade → Export to CSV/Excel) and pass the file directly:

```powershell
.\Get-AzVMLifecycle.ps1 -InputFile .\AzureVirtualMachines.xlsx
```

The parser maps `SIZE` → SKU and `LOCATION` → Region, converts display names (e.g., "West US" → `westus`), and aggregates one-VM-per-row into quantities. Requires the `ImportExcel` module.

### What You Get

For each SKU:
1. **Hybrid recommendations (3 curated + 2 weighted)** — Up to 5 alternatives per SKU:
   - **3 upgrade path recommendations** from a curated knowledge base ([`data/UpgradePath.json`](data/UpgradePath.json)) based on Microsoft's official migration guidance:
     - `Upgrade: Drop-in` — lowest risk replacement (e.g., Dsv5 for Dv2)
     - `Upgrade: Future-proof` — latest generation (e.g., Dsv6 with NVMe)
     - `Upgrade: Cost-optimized` — AMD/alternative architecture at lower cost
   - **2 weighted recommendations** from the real-time scoring engine, validated against region availability, capacity, and quota
2. **Lifecycle risk assessment** — High / Medium / Low
3. **Quota analysis** — current usage vs. limit for source and target SKU families, factoring in VM quantity
4. **Details column** — explains *why* each recommendation was selected
5. **Consolidated summary table** with VM-count-aware totals (e.g., "3 SKU(s) (35 VMs) at HIGH risk")

The upgrade path knowledge base covers 19 VM families (11 retired, 8 scheduled for retirement) with vCPU-matched size maps. See [`data/UpgradePath.md`](data/UpgradePath.md) for the full reference.

**Risk levels:**
- **High** — Retired/retiring SKU, capacity issues, quota insufficient, or no compatible alternatives
- **Medium** — Old generation (v3 or below); plan migration to current generation
- **Low** — Current generation with good availability and sufficient quota

### Compatibility Gate

Recommendations are **compatibility-validated** before scoring. A candidate SKU must meet or exceed the target on every critical dimension:

| Dimension | Rule |
|-----------|------|
| vCPU | Candidate ≥ Target (and ≤ 2× to avoid licensing risk) |
| Memory (GiB) | Candidate ≥ Target |
| Max NICs | Candidate ≥ Target (when target uses multi-NIC) |
| Accelerated networking | Required if target has it |
| Premium IO | Required if target has it |
| Disk interface | NVMe target requires NVMe candidate |
| Ephemeral OS disk | Required if target supports it |
| Ultra SSD | Required if target has it |

After passing, candidates are ranked by an 8-dimension similarity score:

| Dimension | Weight |
|-----------|--------|
| vCPU closeness | 20 pts |
| Memory closeness | 20 pts |
| Family match | 18 pts |
| Family version newness | 12 pts |
| Architecture match | 10 pts |
| Disk IOPS closeness | 8 pts |
| Data disk count closeness | 7 pts |
| Premium IO match | 5 pts |

### Pricing in Lifecycle Reports

By default, lifecycle reports include only PAYG cost columns when `-ShowPricing` is used:

```powershell
.\Get-AzVMLifecycle.ps1 -InputFile .\my-vms.csv -ShowPricing
```

Add `-RateOptimization` for Savings Plan (SP) and Reserved Instance (RI) savings columns:

```powershell
# Full pricing: PAYG + SP/RI savings
.\Get-AzVMLifecycle.ps1 -InputFile .\my-vms.csv -ShowPricing -RateOptimization

# Live scan with rate optimization
.\Get-AzVMLifecycle.ps1 -ShowPricing -RateOptimization -AutoExport

# Azure portal export with full pricing
.\Get-AzVMLifecycle.ps1 -InputFile .\AzureVirtualMachines.xlsx -ShowPricing -RateOptimization -NoQuota -AutoExport
```

With `-RateOptimization`, the XLSX report adds 4 savings columns: `SP 1-Year Savings`, `SP 3-Year Savings`, `RI 1-Year Savings`, `RI 3-Year Savings`.

## Region Presets

Use `-RegionPreset` for quick access to common region sets:

| Preset          | Regions                                                             | Use Case                                 |
| --------------- | ------------------------------------------------------------------- | ---------------------------------------- |
| `USEastWest`    | eastus, eastus2, westus, westus2                                    | US coastal regions                       |
| `USCentral`     | centralus, northcentralus, southcentralus, westcentralus            | US central regions                       |
| `USMajor`       | eastus, eastus2, centralus, westus, westus2                         | Top 5 US regions by usage                |
| `Europe`        | westeurope, northeurope, uksouth, francecentral, germanywestcentral | European regions                         |
| `AsiaPacific`   | eastasia, southeastasia, japaneast, australiaeast, koreacentral     | Asia-Pacific regions                     |
| `Global`        | eastus, westeurope, southeastasia, australiaeast, brazilsouth       | Global distribution                      |
| `USGov`         | usgovvirginia, usgovtexas, usgovarizona                             | Azure Government (auto-sets environment) |
| `China`         | chinaeast, chinanorth, chinaeast2, chinanorth2                      | Azure China / Mooncake (auto-sets env)   |
| `ASR-EastWest`  | eastus, westus2                                                     | Azure Site Recovery DR pair              |
| `ASR-CentralUS` | centralus, eastus2                                                  | Azure Site Recovery DR pair              |

> **Sovereign Clouds Note**:
> - `USGov` and `China` presets are **hardcoded** because `Get-AzLocation` only returns regions for the cloud you're logged into (commercial Azure won't show government regions)
> - `USGov` automatically sets `-Environment AzureUSGovernment` - you still need credentials for that environment
> - `China` automatically sets `-Environment AzureChinaCloud` (Mooncake) - you still need credentials for that environment
> - Azure Germany (AzureGermanCloud) was deprecated in October 2021 and is no longer available
> - There is no separate "European Government" cloud; EU data residency is handled via standard Azure regions with compliance certifications (e.g., France Central, Germany West Central)

### Examples

```powershell
# Quick US East/West lifecycle scan
.\Get-AzVMLifecycle.ps1 -RegionPreset USEastWest

# Top 5 US regions
.\Get-AzVMLifecycle.ps1 -RegionPreset USMajor

# European regions with auto-export
.\Get-AzVMLifecycle.ps1 -RegionPreset Europe -AutoExport

# Azure Government (environment auto-detected)
.\Get-AzVMLifecycle.ps1 -RegionPreset USGov

# Azure China / Mooncake (environment auto-detected)
.\Get-AzVMLifecycle.ps1 -RegionPreset China
```

> **Note**: Region presets apply when using `-Region` or `-RegionPreset`. In live scan mode (default), regions are auto-detected from deployed VMs.

### Manual Region Specification

You can still specify regions manually for custom scenarios:

| Scenario           | Region Parameter                         |
| ------------------ | ---------------------------------------- |
| **Custom regions** | `-Region "eastus","westus2","centralus"` |
| **Single region**  | `-Region "eastus"`                       |

## Image Compatibility

Use `-ImageURN` to verify SKU compatibility with a specific Azure Marketplace image (Gen1/Gen2 and x64/ARM64 requirements):

```powershell
# Check ARM64 compatibility
.\Get-AzVMLifecycle.ps1 `
    -InputFile .\my-vms.csv `
    -ImageURN "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-arm64:latest"

# Check Gen2 compatibility
.\Get-AzVMLifecycle.ps1 `
    -ImageURN "MicrosoftWindowsServer:WindowsServer:2022-datacenter-g2:latest"
```

When an image is specified, recommendations are further filtered to only include SKUs compatible with that image.

## Pricing Detection

With `-ShowPricing`, the script automatically detects the best pricing source:

1. **Negotiated pricing** (EA/MCA/CSP) — Uses Azure Cost Management API. Requires Billing Reader or Cost Management Reader role. Shows your actual discounted rates.
2. **Retail fallback** — Uses the public Azure Retail Prices API. No special permissions required. Shows Linux pay-as-you-go rates.

## Excel Export

- Color-coded risk levels (green/yellow/red)
- Filterable columns with auto-filter
- Alternating row colors with Azure-blue header styling
- Optional Subscription Map and Resource Group Map sheets (`-SubMap`, `-RGMap`)

## AI Agent Integration (Copilot Skill)

This repo includes a **Copilot skill** that teaches AI coding agents (VS Code Copilot, Claude, Copilot CLI) how to invoke Get-AzVMLifecycle for lifecycle analysis. The skill provides routing logic, parameter mapping, and JSON output schema documentation so agents can translate natural language requests into the correct CLI invocations.

**Skill file:** [.github/skills/azure-vm-lifecycle/SKILL.md](.github/skills/azure-vm-lifecycle/SKILL.md)

### What the skill enables

| User says | Agent runs |
|-----------|-----------|
| "Which of my VMs are running retiring SKUs?" | `.\Get-AzVMLifecycle.ps1 -JsonOutput` |
| "Analyze this VM export for lifecycle risks" | `.\Get-AzVMLifecycle.ps1 -InputFile .\vms.xlsx -JsonOutput` |
| "What should I replace Standard_D4s_v3 with?" | `.\Get-AzVMLifecycle.ps1 -InputFile .\vms.csv -ShowPricing -JsonOutput` |

### Installing the skill for VS Code Copilot

This skill is already referenced in `.github/copilot-instructions.md` and loads automatically when you open this repo in VS Code with GitHub Copilot enabled.

To use it in **other repositories**, copy the skill to your local skills directory and reference it in that repo's Copilot instructions:

```powershell
# Windows
Copy-Item -Recurse ".github\skills\azure-vm-lifecycle" "$env:USERPROFILE\.agents\skills\azure-vm-lifecycle"

# macOS/Linux
cp -r .github/skills/azure-vm-lifecycle ~/.agents/skills/azure-vm-lifecycle
```

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned features including:
- MCP Server integration for AI agent tooling
- Proactive monitoring with capacity alerts
- PowerShell module for PSGallery distribution

## License

This project is licensed under the MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

This project was adapted from [Get-AzVMAvailability](https://github.com/ZacharyLuz/Get-AzVMAvailability) by **Zachary Luz**, which provides Azure VM SKU availability, capacity, and quota scanning. Get-AzVMLifecycle extends the original with lifecycle management capabilities including retirement detection, upgrade path recommendations, and compatibility-validated migration planning.

## Author

**Barry Lowrance** (personal project, not an official Microsoft product)

## Support & Responsible Use

This tool queries only **public Azure APIs** (SKU availability, quota, retail pricing) against your own Azure subscriptions. It reads subscription metadata (such as subscription IDs/names, regions, quotas, and usage) and writes results locally (console output and CSV/XLSX exports); it does **not** transmit this data off your machine except as required to call Azure APIs.

- **Issues & PRs**: Welcome! Please do not include subscription IDs, tenant IDs, internal URLs, or any confidential information.
- **Azure support**: For Azure platform issues or outages, contact [Azure Support](https://azure.microsoft.com/support/) — not this repository.
- **Exported files**: Review CSV/XLSX exports before sharing externally — they may contain subscription IDs, region information, quotas, and usage details for your environment.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Troubleshooting

### Security warning when running downloaded script

If Windows warns that the script came from the internet, unblock it once:

```powershell
Unblock-File .\Get-AzVMLifecycle.ps1
```

### `AzureEndpoints` property error at startup

If you see an error like `The property 'AzureEndpoints' cannot be found on this object`, you are likely running an older script copy.

```powershell
Select-String -Path .\Get-AzVMLifecycle.ps1 -Pattern 'AzureEndpoints\s*=\s*\$null'
```

No match indicates the file is stale. Download the latest `Get-AzVMLifecycle.ps1` from the repository and re-run.

### Running in Windows PowerShell 5.1

PowerShell 5.1 is not supported. The script now warns and exits early if launched in 5.1.

Use PowerShell 7+ (`pwsh`):

```powershell
pwsh -File .\Get-AzVMLifecycle.ps1
```

