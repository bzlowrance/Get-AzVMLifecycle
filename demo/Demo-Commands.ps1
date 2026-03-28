<#
.SYNOPSIS
    Demo command script for GET-AZVMLIFECYCLE live demonstrations.
.DESCRIPTION
    Copy-paste-ready commands organized by demo scenario.
    Run each section sequentially during the demo.
    Requires: PowerShell 7+, Az.Compute, Az.Resources, Az.ResourceGraph, active Azure login.
.NOTES
    Duration: ~30 minutes (7 scenarios + closing)
    See demo/DEMO-GUIDE.md for talking points and transitions.
#>

#region Pre-Flight
# Verify Azure login and active subscription
Get-AzContext | Select-Object Account, Subscription, Tenant

# Confirm module availability
Get-Module Az.Compute -ListAvailable | Select-Object Name, Version -First 1
Get-Module Az.ResourceGraph -ListAvailable | Select-Object Name, Version -First 1
#endregion Pre-Flight

# ============================================================
# LIFECYCLE SCAN: "What Needs Attention?"
# ============================================================

#region Scenario 1 — Live Scan (Default Mode) (~5 min)
# No parameters needed — pulls VMs from Azure and analyzes lifecycle risks.
.\GET-AZVMLIFECYCLE.ps1 -NoPrompt

# Scan a specific subscription
.\GET-AZVMLIFECYCLE.ps1 `
    -SubscriptionId "your-subscription-id" `
    -NoPrompt
#endregion Scenario 1

#region Scenario 2 — Scoped Scanning (~3 min)
# Scan a management group (all child subscriptions)
.\GET-AZVMLIFECYCLE.ps1 `
    -ManagementGroup "mg-production" `
    -NoPrompt

# Filter to tagged VMs only
.\GET-AZVMLIFECYCLE.ps1 `
    -Tag @{Environment='prod'} `
    -NoPrompt

# Specific resource groups
.\GET-AZVMLIFECYCLE.ps1 `
    -ResourceGroup "rg-app", "rg-data" `
    -NoPrompt
#endregion Scenario 2

#region Scenario 3 — Placement Scores (~3 min)
# Allocation likelihood from the Azure Placement Scores API: High / Medium / Low.
# Answers "how likely is Azure to fulfill the request?"
# Note: Requires "Compute Recommendations" RBAC role; degrades gracefully if absent.
.\GET-AZVMLIFECYCLE.ps1 `
    -ShowPlacement `
    -DesiredCount 5 `
    -NoPrompt
#endregion Scenario 3

# ============================================================
# FILE-BASED ANALYSIS: "Analyze Without Azure Access"
# ============================================================

#region Scenario 4 — CSV/XLSX Input (~4 min)
# From a CSV file
.\GET-AZVMLIFECYCLE.ps1 `
    -InputFile .\my-vms.csv `
    -Region "eastus" `
    -NoPrompt

# From an Azure portal VM export (XLSX)
.\GET-AZVMLIFECYCLE.ps1 `
    -InputFile .\AzureVirtualMachines.xlsx `
    -NoPrompt

# Offline analysis (no Azure login needed for the analysis itself)
.\GET-AZVMLIFECYCLE.ps1 `
    -InputFile .\my-vms.csv `
    -Region "eastus" `
    -NoQuota `
    -NoPrompt
#endregion Scenario 4

# ============================================================
# ENRICHMENT: "Pricing, Maps, and More"
# ============================================================

#region Scenario 5 — Pricing Comparison (~4 min)
# ShowPricing auto-detects EA/MCA negotiated rates, falls back to retail.
.\GET-AZVMLIFECYCLE.ps1 `
    -ShowPricing `
    -NoPrompt

# Full pricing with Savings Plan and Reserved Instance savings
.\GET-AZVMLIFECYCLE.ps1 `
    -ShowPricing `
    -RateOptimization `
    -NoPrompt
#endregion Scenario 5

#region Scenario 6 — Deployment Maps (~3 min)
# Subscription and resource group deployment maps in XLSX
.\GET-AZVMLIFECYCLE.ps1 `
    -SubMap `
    -RGMap `
    -AutoExport `
    -NoPrompt
#endregion Scenario 6

# ============================================================
# EXPORT & AUTOMATION
# ============================================================

#region Scenario 7A — JSON Output for Pipelines
# Structured JSON to stdout — pipe to file or parse in CI.
.\GET-AZVMLIFECYCLE.ps1 `
    -JsonOutput `
    -NoPrompt
#endregion Scenario 7A

#region Scenario 7B — Excel Export for Stakeholders
# Styled XLSX with color-coded risk levels, conditional formatting.
# Requires ImportExcel module; falls back to CSV if not installed.
.\GET-AZVMLIFECYCLE.ps1 `
    -ShowPricing `
    -RateOptimization `
    -SubMap `
    -RGMap `
    -AutoExport `
    -OutputFormat XLSX `
    -NoPrompt
#endregion Scenario 7B
