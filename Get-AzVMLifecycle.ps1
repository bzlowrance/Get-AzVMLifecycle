<#
.SYNOPSIS
    Get-AzVMLifecycle - Azure VM lifecycle management tool.

.DESCRIPTION
    Analyzes your deployed Azure VMs for lifecycle risks and recommends migration paths.

    Two modes of operation:
    - **Default (live scan):** Queries Azure Resource Graph for deployed VMs and runs
      lifecycle analysis across all discovered regions.
    - **File-based (-InputFile):** Accepts CSV, JSON, or XLSX files (including native
      Azure portal VM exports) for offline lifecycle analysis.

    For each VM SKU, the tool:
    - Detects retirement status and dates from Microsoft's published schedule
    - Identifies old-generation SKUs that should be upgraded
    - Runs compatibility-validated recommendations (12 hard requirements)
    - Provides up to 5 alternatives: 3 from curated upgrade paths + 2 weighted
    - Shows capacity status, quota availability, and pricing comparison
    - Produces styled XLSX reports with color-coded risk levels

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to scan. If not provided, uses the current Az context.

.PARAMETER Region
    One or more Azure region codes (e.g., 'eastus', 'westus2'). Auto-detected from
    deployed VMs in live scan mode. Required for -InputFile when the file lacks Region data.

.PARAMETER InputFile
    Path to a CSV, JSON, or XLSX file listing current VM SKUs for lifecycle analysis.
    CSV: column SKU (or Size/VmSize). JSON: array of {SKU:'...'} objects.
    Qty column is optional. XLSX: supports native Azure portal VM exports.

.PARAMETER ManagementGroup
    Filter live scan to specific management group(s). Requires Az.ResourceGraph module.

.PARAMETER ResourceGroup
    Filter live scan to specific resource group(s).

.PARAMETER Tag
    Filter live scan to VMs with specific tags. Hashtable of key=value pairs,
    e.g. @{Environment='prod'}. Use '*' as value to match any VM with the tag key.

.PARAMETER SubMap
    Add a 'Subscription Map' sheet to the lifecycle XLSX export.

.PARAMETER RGMap
    Add a 'Resource Group Map' sheet to the lifecycle XLSX export.

.PARAMETER ShowPricing
    Show hourly/monthly pricing. Auto-detects negotiated rates, falls back to retail.

.PARAMETER ShowSpot
    Include Spot VM pricing when pricing is enabled.

.PARAMETER RateOptimization
    Include Savings Plan and Reserved Instance pricing columns. Requires -ShowPricing.

.PARAMETER ShowPlacement
    Show allocation likelihood scores from Azure placement API.

.PARAMETER NoQuota
    Skip quota checks (useful for analyzing exports without subscription access).

.PARAMETER Interactive
    Enable interactive wizard prompts for subscription, region, export, and feature selection.

.PARAMETER JsonOutput
    Emit structured JSON output for automation/agent consumption.

.PARAMETER ImageURN
    Check SKU compatibility with a specific VM image (Publisher:Offer:Sku:Version).

.PARAMETER TopN
    Number of alternative SKUs to return per retiring SKU. Default 5, max 25.

.PARAMETER SkuFilter
    Filter to specific SKU names. Supports wildcards (e.g., 'Standard_D*_v5').

.PARAMETER AutoExport
    Automatically export results without prompting.

.PARAMETER ExportPath
    Directory path for export. Defaults to C:\Temp\AzVMLifecycle or /home/system in Cloud Shell.

.NOTES
    Name:           Get-AzVMLifecycle
    Author:         Barry Lowrance (fork of Zachary Luz's Get-AzVMAvailability)
    Version:        2.0.0
    License:        MIT
    Repository:     https://github.com/bzlowrance/Get-AzVMLifecycle

    Requirements:   Az.Compute, Az.Resources, Az.ResourceGraph modules
                    PowerShell 7+ (required)

.EXAMPLE
    .\Get-AzVMLifecycle.ps1
    Live scan: queries Azure Resource Graph for all deployed VMs, analyzes lifecycle
    risks, and shows recommendations for retiring or old-gen SKUs.

.EXAMPLE
    .\Get-AzVMLifecycle.ps1 -SubscriptionId "xxxx-xxxx"
    Scan a specific subscription.

.EXAMPLE
    .\Get-AzVMLifecycle.ps1 -ManagementGroup "Production" -Tag @{Environment='prod'}
    Scan VMs in the Production management group tagged with Environment=prod.

.EXAMPLE
    .\Get-AzVMLifecycle.ps1 -InputFile .\my-vms.csv
    File-based analysis from a CSV with SKU, Region, and Qty columns.

.EXAMPLE
    .\Get-AzVMLifecycle.ps1 -InputFile .\azure-portal-export.xlsx -ShowPricing -RateOptimization
    Analyze an Azure portal VM export with full pricing comparison including RI/SP.

.EXAMPLE
    .\Get-AzVMLifecycle.ps1 -SubMap -RGMap -AutoExport
    Live scan with subscription and resource group deployment maps in the XLSX export.

.EXAMPLE
    .\Get-AzVMLifecycle.ps1 -JsonOutput
    Emit structured JSON for automation pipelines.

.LINK
    https://github.com/bzlowrance/Get-AzVMLifecycle
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Azure subscription ID(s) to scan")]
    [Alias("SubId", "Subscription")]
    [string[]]$SubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Azure region(s) to scan")]
    [Alias("Location")]
    [string[]]$Region,

    [Parameter(Mandatory = $false, HelpMessage = "Predefined region sets for common scenarios")]
    [ValidateSet("USEastWest", "USCentral", "USMajor", "Europe", "AsiaPacific", "Global", "USGov", "China", "ASR-EastWest", "ASR-CentralUS")]
    [string]$RegionPreset,

    [Parameter(Mandatory = $false, HelpMessage = "Directory path for export")]
    [string]$ExportPath,

    [Parameter(Mandatory = $false, HelpMessage = "Automatically export results")]
    [switch]$AutoExport,

    [Parameter(Mandatory = $false, HelpMessage = "Filter to specific SKUs (supports wildcards)")]
    [string[]]$SkuFilter,

    [Parameter(Mandatory = $false, HelpMessage = "Show hourly pricing (auto-detects negotiated rates, falls back to retail)")]
    [switch]$ShowPricing,

    [Parameter(Mandatory = $false, HelpMessage = "Include Spot VM pricing in outputs when pricing is enabled")]
    [switch]$ShowSpot,

    [Parameter(Mandatory = $false, HelpMessage = "Show allocation likelihood scores (High/Medium/Low) from Azure placement API")]
    [switch]$ShowPlacement,

    [Parameter(Mandatory = $false, HelpMessage = "Desired VM count for placement score API")]
    [ValidateRange(1, 1000)]
    [int]$DesiredCount = 1,

    [Parameter(Mandatory = $false, HelpMessage = "VM image URN to check compatibility (format: Publisher:Offer:Sku:Version)")]
    [string]$ImageURN,

    [Parameter(Mandatory = $false, HelpMessage = "Use compact output for narrow terminals")]
    [switch]$CompactOutput,

    [Parameter(Mandatory = $false, HelpMessage = "Enable interactive wizard prompts for subscription, region, and feature selection")]
    [Alias('Prompt')]
    [switch]$Interactive,

    [Parameter(Mandatory = $false, HelpMessage = "Skip quota checks (use when analyzing a customer extract without subscription access)")]
    [switch]$NoQuota,

    [Parameter(Mandatory = $false, HelpMessage = "Export format: Auto, CSV, or XLSX")]
    [ValidateSet("Auto", "CSV", "XLSX")]
    [string]$OutputFormat = "Auto",

    [Parameter(Mandatory = $false, HelpMessage = "Force ASCII icons instead of Unicode")]
    [switch]$UseAsciiIcons,

    [Parameter(Mandatory = $false, HelpMessage = "Azure cloud environment (default: auto-detect from Az context)")]
    [ValidateSet("AzureCloud", "AzureUSGovernment", "AzureChinaCloud", "AzureGermanCloud")]
    [string]$Environment,

    [Parameter(Mandatory = $false, HelpMessage = "Max retry attempts for transient API errors (429, 503, timeouts)")]
    [ValidateRange(0, 10)]
    [int]$MaxRetries = 3,

    [Parameter(Mandatory = $false, HelpMessage = "Number of alternative SKUs to return (default 5)")]
    [ValidateRange(1, 25)]
    [int]$TopN = 5,

    [Parameter(Mandatory = $false, HelpMessage = "Minimum similarity score (0-100) for recommended alternatives; set 0 to show all")]
    [ValidateRange(0, 100)]
    [int]$MinScore,

    [Parameter(Mandatory = $false, HelpMessage = "Minimum vCPU count for recommended alternatives")]
    [ValidateRange(1, 416)]
    [int]$MinvCPU,

    [Parameter(Mandatory = $false, HelpMessage = "Minimum memory in GB for recommended alternatives")]
    [ValidateRange(1, 12288)]
    [int]$MinMemoryGB,

    [Parameter(Mandatory = $false, HelpMessage = "Emit structured JSON output for automation/agent consumption")]
    [switch]$JsonOutput,

    [Parameter(Mandatory = $false, HelpMessage = "Allow mixed CPU architectures (x64/ARM64) in recommendations (default: filter to target arch)")]
    [switch]$AllowMixedArch,

    [Parameter(Mandatory = $false, HelpMessage = "Skip validation of region names against Azure metadata")]
    [switch]$SkipRegionValidation,

    [Parameter(Mandatory = $false, HelpMessage = "Include Savings Plan and Reserved Instance pricing columns in lifecycle reports. Requires -ShowPricing. Without this flag, only PAYG pricing is shown.")]
    [switch]$RateOptimization,

    [Parameter(Mandatory = $false, HelpMessage = "Path to a CSV, JSON, or XLSX file listing current VM SKUs for lifecycle analysis instead of live ARG scan. CSV: column SKU (or Size/VmSize). JSON: array of {SKU:'...'} objects. Qty column is optional. XLSX: supports native Azure portal VM exports (maps SIZE/LOCATION columns automatically).")]
    [Alias('LifecycleRecommendations')]
    [string]$InputFile,

    [Parameter(Mandatory = $false, HelpMessage = "Filter to specific management group(s). Requires Az.ResourceGraph module.")]
    [string[]]$ManagementGroup,

    [Parameter(Mandatory = $false, HelpMessage = "Filter to specific resource group(s).")]
    [string[]]$ResourceGroup,

    [Parameter(Mandatory = $false, HelpMessage = "Filter to VMs with specific tags. Hashtable of key=value pairs, e.g. @{Environment='prod'}. Use '*' as value to match any VM that has the tag key regardless of value.")]
    [Alias("Tags")]
    [hashtable]$Tag,

    [Parameter(Mandatory = $false, HelpMessage = "Add a 'Subscription Map' sheet to the lifecycle XLSX showing VM counts grouped by subscription, region, and SKU.")]
    [switch]$SubMap,

    [Parameter(Mandatory = $false, HelpMessage = "Add a 'Resource Group Map' sheet to the lifecycle XLSX showing VM counts grouped by resource group, subscription, region, and SKU.")]
    [switch]$RGMap,

    [Parameter(Mandatory = $false, HelpMessage = "Path to a log file for capturing terminal output. If a directory is specified, a timestamped log file is created. If omitted, no log is written.")]
    [string]$LogFile
)

$ProgressPreference = 'SilentlyContinue'  # Suppress progress bars for faster execution

# Transcript logging is deferred until after export path is resolved
$script:TranscriptStarted = $false


if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "PowerShell 7+ is required to run Get-AzVMLifecycle.ps1."
    Write-Host "Current host: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host "Install PowerShell 7 and rerun with: pwsh -File .\Get-AzVMLifecycle.ps1" -ForegroundColor Cyan
    throw "PowerShell 7+ is required. Current version: $($PSVersionTable.PSVersion)"
}

# Normalize string[] params — pwsh -File passes comma-delimited values as a single string
foreach ($paramName in @('SubscriptionId', 'Region', 'SkuFilter', 'ManagementGroup', 'ResourceGroup')) {
    $val = Get-Variable -Name $paramName -ValueOnly -ErrorAction SilentlyContinue
    if ($val -and $val.Count -eq 1 -and $val[0] -match ',') {
        Set-Variable -Name $paramName -Value @($val[0] -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
    }
}



# LifecycleRecommendations: load CSV/JSON/XLSX into $lifecycleEntries list (SKU + optional Region)
if ($InputFile) {
    if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) { throw "Input file not found or is not a file: $InputFile" }
    $ext = [System.IO.Path]::GetExtension($InputFile).ToLower()
    if ($ext -notin '.csv', '.json', '.xlsx') { throw "Unsupported file type '$ext'. LifecycleRecommendations must be .csv, .json, or .xlsx" }
    if ($ext -eq '.xlsx' -and -not (Get-Module -ListAvailable ImportExcel)) { throw "ImportExcel module required for .xlsx files. Install with: Install-Module ImportExcel -Scope CurrentUser" }
    $lifecycleEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
    $compositeKeys = @{}
    # When -SubMap or -RGMap is set, capture per-row subscription/RG data for the deployment map
    $captureDeploymentMap = ($SubMap -or $RGMap)
    if ($captureDeploymentMap) { $fileVMRows = [System.Collections.Generic.List[PSCustomObject]]::new() }
    $parseRow = {
        param($item)
        $skuProp = ($item.PSObject.Properties | Where-Object { $_.Name -match '^(SKU|Size|VmSize)$' } | Select-Object -First 1).Value
        if (-not $skuProp) { $skuProp = ($item.PSObject.Properties | Where-Object { $_.Name -match '^(Name|Intel\.SKU)$' } | Select-Object -First 1).Value }
        $regionProp = ($item.PSObject.Properties | Where-Object { $_.Name -match '^(Region|Location|AzureRegion)$' } | Select-Object -First 1).Value
        $qtyProp = ($item.PSObject.Properties | Where-Object { $_.Name -match '^(Qty|Quantity|Count)$' } | Select-Object -First 1).Value
        if ($skuProp) {
            $clean = $skuProp.Trim() -replace '^Standard_Standard_', 'Standard_'
            if ($clean -notmatch '^Standard_') { $clean = "Standard_$clean" }
            $regionClean = if ($regionProp) { ($regionProp.Trim() -replace '\s', '').ToLower() } else { $null }
            $qty = if ($qtyProp) { [int]$qtyProp } else { 1 }
            if ($qty -le 0) { throw "Invalid quantity '$qtyProp' for SKU '$clean'. Qty must be a positive integer." }
            $compositeKey = "$clean|$regionClean"
            if ($compositeKeys.ContainsKey($compositeKey)) {
                $existingIdx = $compositeKeys[$compositeKey]
                $existing = $lifecycleEntries[$existingIdx]
                $lifecycleEntries[$existingIdx] = [pscustomobject]@{ SKU = $clean; Region = $regionClean; Qty = $existing.Qty + $qty }
            }
            else {
                $compositeKeys[$compositeKey] = $lifecycleEntries.Count
                $lifecycleEntries.Add([pscustomobject]@{ SKU = $clean; Region = $regionClean; Qty = $qty })
            }
            # Capture per-row sub/RG data for deployment map
            if ($captureDeploymentMap) {
                $subIdProp = ($item.PSObject.Properties | Where-Object { $_.Name -match '^(SubscriptionId|Subscription_Id|SUBSCRIPTION ID)$' } | Select-Object -First 1).Value
                # Extract subscription ID from RESOURCE LINK URL if not found in a dedicated column
                if (-not $subIdProp) {
                    $linkProp = ($item.PSObject.Properties | Where-Object { $_.Name -match '^(RESOURCE LINK|ResourceLink|Resource_Link)$' } | Select-Object -First 1).Value
                    if ($linkProp -and $linkProp -match '/subscriptions/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
                        $subIdProp = $matches[1]
                    }
                }
                $subNameProp = ($item.PSObject.Properties | Where-Object { $_.Name -match '^(SubscriptionName|Subscription_Name|SUBSCRIPTION)$' } | Select-Object -First 1).Value
                $rgProp = ($item.PSObject.Properties | Where-Object { $_.Name -match '^(ResourceGroup|Resource_Group|RESOURCE GROUP)$' } | Select-Object -First 1).Value
                $fileVMRows.Add([pscustomobject]@{
                    subscriptionId   = if ($subIdProp) { $subIdProp.Trim() } else { '' }
                    subscriptionName = if ($subNameProp) { $subNameProp.Trim() } else { '' }
                    resourceGroup    = if ($rgProp) { $rgProp.Trim() } else { '' }
                    location         = $regionClean
                    vmSize           = $clean
                    qty              = $qty
                })
            }
        }
    }
    if ($ext -eq '.json') {
        $jsonData = @(Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json)
        foreach ($item in $jsonData) { & $parseRow $item }
    }
    elseif ($ext -eq '.xlsx') {
        $xlsxData = Import-Excel -Path $InputFile
        foreach ($row in $xlsxData) { & $parseRow $row }
    }
    else {
        $csvData = Import-Csv -LiteralPath $InputFile
        foreach ($row in $csvData) { & $parseRow $row }
    }
    if ($lifecycleEntries.Count -eq 0) { throw "No valid SKU rows found in $InputFile. Expected column: SKU, Size, or VmSize (falls back to Name)" }
    $SkuFilter = @($lifecycleEntries | ForEach-Object { $_.SKU })

    # Auto-merge per-SKU regions into the -Region parameter so all needed regions get scanned
    $fileRegions = @($lifecycleEntries | Where-Object { $_.Region } | ForEach-Object { $_.Region } | Select-Object -Unique)
    if (-not $script:TrustedRegions) { $script:TrustedRegions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
    foreach ($r in $fileRegions) { [void]$script:TrustedRegions.Add($r) }
    if ($fileRegions.Count -gt 0) {
        if ($Region) {
            $mergedRegions = @($Region) + @($fileRegions) | Select-Object -Unique
            $Region = @($mergedRegions)
        }
        else {
            $Region = @($fileRegions)
        }
        Write-Verbose "Lifecycle mode: merged $($fileRegions.Count) file region(s) into scan regions: $($Region -join ', ')"
    }

    $totalVMs = ($lifecycleEntries | Measure-Object -Property Qty -Sum).Sum
    if (-not $JsonOutput) { Write-Host "Lifecycle analysis: loaded $($lifecycleEntries.Count) SKU entries ($totalVMs VMs) from $InputFile" -ForegroundColor Cyan }

    #region Build Deployment Map from File Data (-SubMap / -RGMap)
    if ($captureDeploymentMap -and $fileVMRows.Count -gt 0) {
        $hasSubData = $fileVMRows | Where-Object { $_.subscriptionId -or $_.subscriptionName } | Select-Object -First 1
        $hasRGData = $fileVMRows | Where-Object { $_.resourceGroup } | Select-Object -First 1
        if ($RGMap -and -not $hasRGData) {
            Write-Warning "-RGMap: No ResourceGroup column found in file. The Resource Group Map sheet will show empty resource group values."
        }
        if (-not $hasSubData) {
            Write-Warning "$(if ($SubMap) { '-SubMap' } else { '-RGMap' }): No SubscriptionId/SubscriptionName column found in file. The map sheet will show empty subscription values."
        }
        if ($SubMap) {
            $subMapRows = [System.Collections.Generic.List[PSCustomObject]]::new()
            $grouped = $fileVMRows | Group-Object -Property subscriptionId, subscriptionName, location, vmSize
            foreach ($g in $grouped) {
                $sample = $g.Group[0]
                $subMapRows.Add([pscustomobject]@{
                    SubscriptionId   = $sample.subscriptionId
                    SubscriptionName = if ($sample.subscriptionName) { $sample.subscriptionName } else { $sample.subscriptionId }
                    Region           = $sample.location
                    SKU              = $sample.vmSize
                    Qty              = ($g.Group | Measure-Object -Property qty -Sum).Sum
                })
            }
            $subMapRows = [System.Collections.Generic.List[PSCustomObject]]@($subMapRows | Sort-Object SubscriptionName, Region, SKU)
            if (-not $JsonOutput) { Write-Host "Subscription map: $($subMapRows.Count) rows" -ForegroundColor Cyan }
        }
        if ($RGMap) {
            $rgMapRows = [System.Collections.Generic.List[PSCustomObject]]::new()
            $grouped = $fileVMRows | Group-Object -Property subscriptionId, subscriptionName, resourceGroup, location, vmSize
            foreach ($g in $grouped) {
                $sample = $g.Group[0]
                $rgMapRows.Add([pscustomobject]@{
                    SubscriptionId   = $sample.subscriptionId
                    SubscriptionName = if ($sample.subscriptionName) { $sample.subscriptionName } else { $sample.subscriptionId }
                    ResourceGroup    = $sample.resourceGroup
                    Region           = $sample.location
                    SKU              = $sample.vmSize
                    Qty              = ($g.Group | Measure-Object -Property qty -Sum).Sum
                })
            }
            $rgMapRows = [System.Collections.Generic.List[PSCustomObject]]@($rgMapRows | Sort-Object SubscriptionName, ResourceGroup, Region, SKU)
            if (-not $JsonOutput) { Write-Host "Resource Group map: $($rgMapRows.Count) rows" -ForegroundColor Cyan }
        }
    }
    #endregion Build Deployment Map from File Data
}

# Default mode: pull live VM inventory from Azure Resource Graph
if (-not $InputFile) {
    if ($ManagementGroup -and $SubscriptionId) { throw "Cannot specify both -ManagementGroup and -SubscriptionId. Use one or the other." }
    if (-not $ManagementGroup -and -not $SubscriptionId) {
        $currentCtx = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $currentCtx -or -not $currentCtx.Subscription) { throw "No Azure context found. Run Connect-AzAccount first, or specify -SubscriptionId or -ManagementGroup." }
    }
    if (-not (Get-Module -ListAvailable Az.ResourceGraph)) { throw "Az.ResourceGraph module required for live VM lifecycle analysis. Install with: Install-Module Az.ResourceGraph -Scope CurrentUser" }
    Import-Module Az.ResourceGraph -ErrorAction Stop

    # Build ARG query with optional resource group and tag filters
    $argQuery = "Resources`n| where type =~ 'microsoft.compute/virtualmachines'"
    if ($ResourceGroup) {
        $rgFilter = ($ResourceGroup | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ', '
        $argQuery += "`n| where resourceGroup in~ ($rgFilter)"
    }
    if ($Tag -and $Tag.Count -gt 0) {
        foreach ($tagKey in $Tag.Keys) {
            $safeKey = $tagKey -replace "'", "''"
            $tagVal = $Tag[$tagKey]
            if ($tagVal -eq '*') {
                $argQuery += "`n| where isnotnull(tags['$safeKey'])"
            }
            else {
                $safeVal = [string]$tagVal -replace "'", "''"
                $argQuery += "`n| where tags['$safeKey'] =~ '$safeVal'"
            }
        }
    }
    $argQuery += "`n| extend vmSize = tostring(properties.hardwareProfile.vmSize)"
    $argQuery += "`n| project vmSize, location, subscriptionId, resourceGroup"

    if (-not $JsonOutput) { Write-Host "Querying Azure Resource Graph for live VM inventory..." -ForegroundColor Cyan }

    # Execute ARG query with pagination
    $argParams = @{ Query = $argQuery; First = 1000 }
    if ($ManagementGroup) { $argParams['ManagementGroup'] = $ManagementGroup }
    elseif ($SubscriptionId) { $argParams['Subscription'] = $SubscriptionId }

    $allVMs = [System.Collections.Generic.List[PSCustomObject]]::new()
    do {
        $result = Search-AzGraph @argParams
        if ($result) {
            foreach ($vm in $result) { $allVMs.Add($vm) }
            if ($result.SkipToken) { $argParams['SkipToken'] = $result.SkipToken }
            else { break }
        }
        else { break }
    } while ($true)

    if ($allVMs.Count -eq 0) { throw "No VMs found matching the specified scope. Check your -SubscriptionId, -ManagementGroup, -ResourceGroup, or -Tag filters." }

    # Aggregate into lifecycle entries (same format as file-based input)
    $lifecycleEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
    $compositeKeys = @{}
    foreach ($vm in $allVMs) {
        $clean = $vm.vmSize.Trim() -replace '^Standard_Standard_', 'Standard_'
        if ($clean -notmatch '^Standard_') { $clean = "Standard_$clean" }
        $regionClean = $vm.location.ToLower()
        $compositeKey = "$clean|$regionClean"
        if ($compositeKeys.ContainsKey($compositeKey)) {
            $existingIdx = $compositeKeys[$compositeKey]
            $existing = $lifecycleEntries[$existingIdx]
            $lifecycleEntries[$existingIdx] = [pscustomobject]@{ SKU = $clean; Region = $regionClean; Qty = $existing.Qty + 1 }
        }
        else {
            $compositeKeys[$compositeKey] = $lifecycleEntries.Count
            $lifecycleEntries.Add([pscustomobject]@{ SKU = $clean; Region = $regionClean; Qty = 1 })
        }
    }
    $SkuFilter = @($lifecycleEntries | ForEach-Object { $_.SKU })

    # Auto-merge discovered regions into -Region parameter
    $scanRegions = @($lifecycleEntries | ForEach-Object { $_.Region } | Select-Object -Unique)
    $script:TrustedRegions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $scanRegions) { [void]$script:TrustedRegions.Add($r) }
    if ($scanRegions.Count -gt 0) {
        if ($Region) {
            $mergedRegions = @($Region) + @($scanRegions) | Select-Object -Unique
            $Region = @($mergedRegions)
        }
        else {
            $Region = @($scanRegions)
        }
    }

    $totalVMs = ($lifecycleEntries | Measure-Object -Property Qty -Sum).Sum
    $scopeDesc = if ($ManagementGroup) { "management group(s): $($ManagementGroup -join ', ')" } elseif ($SubscriptionId) { "subscription(s): $($SubscriptionId -join ', ')" } else { "current subscription" }
    if (-not $JsonOutput) { Write-Host "Lifecycle scan: found $($lifecycleEntries.Count) unique SKU+Region entries ($totalVMs VMs) across $($scanRegions.Count) region(s) from $scopeDesc" -ForegroundColor Cyan }

    #region Build Deployment Map Data (-SubMap / -RGMap)
    if ($SubMap -or $RGMap) {
        # Resolve subscription IDs to names via ARG ResourceContainers, filtered to only present subscriptions
        $subIds = @($allVMs | ForEach-Object { $_.subscriptionId } | Select-Object -Unique)
        $subNameMap = @{}
        if ($subIds.Count -gt 0) {
            $quotedSubIds = $subIds | ForEach-Object { "'$_'" }
            $subFilter = $quotedSubIds -join ','
            $subQuery = "ResourceContainers | where type =~ 'microsoft.resources/subscriptions' | where subscriptionId in~ ($subFilter) | project subscriptionId, name"
            $subParams = @{ Query = $subQuery; First = 1000 }
            if ($ManagementGroup) { $subParams['ManagementGroup'] = $ManagementGroup }
            elseif ($SubscriptionId) { $subParams['Subscription'] = $SubscriptionId }
            try {
                $subResults = Search-AzGraph @subParams
                foreach ($s in $subResults) { $subNameMap[$s.subscriptionId] = $s.name }
            }
            catch {
                Write-Verbose "Could not resolve subscription names via ARG: $_"
            }
        }

        if ($SubMap) {
            $subMapRows = [System.Collections.Generic.List[PSCustomObject]]::new()
            $grouped = $allVMs | Group-Object -Property subscriptionId, location, vmSize
            foreach ($g in $grouped) {
                $sample = $g.Group[0]
                $subId = $sample.subscriptionId
                $subMapRows.Add([pscustomobject]@{
                    SubscriptionId   = $subId
                    SubscriptionName = if ($subNameMap[$subId]) { $subNameMap[$subId] } else { $subId }
                    Region           = $sample.location
                    SKU              = $sample.vmSize
                    Qty              = $g.Count
                })
            }
            $subMapRows = [System.Collections.Generic.List[PSCustomObject]]@($subMapRows | Sort-Object SubscriptionName, Region, SKU)
            if (-not $JsonOutput) { Write-Host "Subscription map: $($subMapRows.Count) rows" -ForegroundColor Cyan }
        }
        if ($RGMap) {
            $rgMapRows = [System.Collections.Generic.List[PSCustomObject]]::new()
            $grouped = $allVMs | Group-Object -Property subscriptionId, resourceGroup, location, vmSize
            foreach ($g in $grouped) {
                $sample = $g.Group[0]
                $subId = $sample.subscriptionId
                $rgMapRows.Add([pscustomobject]@{
                    SubscriptionId   = $subId
                    SubscriptionName = if ($subNameMap[$subId]) { $subNameMap[$subId] } else { $subId }
                    ResourceGroup    = $sample.resourceGroup
                    Region           = $sample.location
                    SKU              = $sample.vmSize
                    Qty              = $g.Count
                })
            }
            $rgMapRows = [System.Collections.Generic.List[PSCustomObject]]@($rgMapRows | Sort-Object SubscriptionName, ResourceGroup, Region, SKU)
            if (-not $JsonOutput) { Write-Host "Resource Group map: $($rgMapRows.Count) rows" -ForegroundColor Cyan }
        }
    }
    #endregion Build Deployment Map Data
}

# Expand SKU filter to include upgrade path target SKUs so they get scanned
if ($lifecycleEntries -and $lifecycleEntries.Count -gt 0) {
    $upgradePathFile = Join-Path $PSScriptRoot 'data' 'UpgradePath.json'
    if (Test-Path -LiteralPath $upgradePathFile) {
        try {
            $upData = Get-Content -LiteralPath $upgradePathFile -Raw | ConvertFrom-Json
            $upgradeSkus = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $existingFilter = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($s in $SkuFilter) { [void]$existingFilter.Add($s) }

            foreach ($entry in $lifecycleEntries) {
                $skuName = $entry.SKU
                # Extract family (inline logic matching Get-SkuFamily)
                $fam = if ($skuName -match 'Standard_([A-Z]+[a-z]*)[\d]') { $Matches[1].ToUpper() } else { '' }
                # Extract version (inline logic matching Get-SkuFamilyVersion)
                $ver = if ($skuName -match '_v(\d+)$') { [int]$Matches[1] } else { 1 }
                # Normalize family: DS→D, GS→G (Premium SSD suffix, same family)
                $normFam = if ($fam -cmatch '^([A-Z]+)S$' -and $fam -notin 'NVS','NCS','NDS','HBS','HCS','HXS','FXS') { $Matches[1] } else { $fam }
                $pathKey = "${normFam}v${ver}"
                $path = $upData.upgradePaths.$pathKey
                if (-not $path) { continue }

                foreach ($pType in @('dropIn','futureProof','costOptimized')) {
                    $pe = $path.$pType
                    if (-not $pe -or -not $pe.sizeMap) { continue }
                    foreach ($prop in $pe.sizeMap.PSObject.Properties) {
                        if ($prop.Value -and -not $existingFilter.Contains($prop.Value)) {
                            [void]$upgradeSkus.Add($prop.Value)
                        }
                    }
                }
            }

            if ($upgradeSkus.Count -gt 0) {
                $SkuFilter = @($SkuFilter) + @($upgradeSkus)
                Write-Verbose "Lifecycle mode: expanded SKU filter with $($upgradeSkus.Count) upgrade path target SKUs for scanning"
            }
        }
        catch {
            Write-Verbose "Failed to expand SKU filter from UpgradePath.json: $_"
        }
    }
}

# Forward-looking version expansion: always scan newer generations of each deployed SKU family
# Generates wildcard patterns for versions current+1 through ceiling so v6/v7/v8+ candidates
# are discovered even when UpgradePath.json has no entry for the current generation.
# Non-existent versions harmlessly return no SKUs from Get-AzComputeResourceSku.
if ($lifecycleEntries -and $lifecycleEntries.Count -gt 0) {
    $forwardPatterns = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $lifecycleEntries) {
        $skuName = $entry.SKU
        $baseLetter = $null
        $vCPUStr = $null
        if ($skuName -match '^Standard_([A-Z]+)[a-z]*(\d+)') {
            $rawFamily = $Matches[1]
            $vCPUStr = $Matches[2]
            # Normalize: DS->D, GS->G (Premium SSD suffix = same family in newer gens)
            $baseLetter = if ($rawFamily -cmatch '^([A-Z]+)S$' -and $rawFamily -notin 'NVS','NCS','NDS','HBS','HCS','HXS','FXS') { $Matches[1] } else { $rawFamily }
        }
        if (-not $baseLetter -or -not $vCPUStr) { continue }
        $curVer = if ($skuName -match '_v(\d+)$') { [int]$Matches[1] } else { 1 }
        for ($v = ($curVer + 1); $v -le $ForwardVersionCeiling; $v++) {
            [void]$forwardPatterns.Add("Standard_${baseLetter}${vCPUStr}*_v${v}")
        }
    }
    if ($forwardPatterns.Count -gt 0) {
        $SkuFilter = @($SkuFilter) + @($forwardPatterns)
        Write-Verbose "Lifecycle mode: added $($forwardPatterns.Count) forward-looking version patterns for scanning"
    }
}

#region Configuration
$ScriptVersion = "2.0.0"

#region Constants
$HoursPerMonth = 730
$HoursPerYear = $HoursPerMonth * 12
$HoursPer3Years = $HoursPerMonth * 36
$ParallelThrottleLimit = 4
$OutputWidthWithPricing = 200
$OutputWidthBase = 122
$OutputWidthMin = 100
$OutputWidthMax = 220

# VM family purpose descriptions and category groupings
$FamilyInfo = @{
    'A'  = @{ Purpose = 'Entry-level/test'; Category = 'Basic' }
    'B'  = @{ Purpose = 'Burstable'; Category = 'General' }
    'D'  = @{ Purpose = 'General purpose'; Category = 'General' }
    'DC' = @{ Purpose = 'Confidential'; Category = 'General' }
    'E'  = @{ Purpose = 'Memory optimized'; Category = 'Memory' }
    'EC' = @{ Purpose = 'Confidential memory'; Category = 'Memory' }
    'F'  = @{ Purpose = 'Compute optimized'; Category = 'Compute' }
    'FX' = @{ Purpose = 'High-freq compute'; Category = 'Compute' }
    'G'  = @{ Purpose = 'Memory+storage'; Category = 'Memory' }
    'H'  = @{ Purpose = 'HPC'; Category = 'HPC' }
    'HB' = @{ Purpose = 'HPC (AMD)'; Category = 'HPC' }
    'HC' = @{ Purpose = 'HPC (Intel)'; Category = 'HPC' }
    'HX' = @{ Purpose = 'HPC (large memory)'; Category = 'HPC' }
    'L'  = @{ Purpose = 'Storage optimized'; Category = 'Storage' }
    'M'  = @{ Purpose = 'Large memory (SAP/HANA)'; Category = 'Memory' }
    'NC' = @{ Purpose = 'GPU compute'; Category = 'GPU' }
    'ND' = @{ Purpose = 'GPU training (AI/ML)'; Category = 'GPU' }
    'NG' = @{ Purpose = 'GPU graphics'; Category = 'GPU' }
    'NP' = @{ Purpose = 'GPU FPGA'; Category = 'GPU' }
    'NV' = @{ Purpose = 'GPU visualization'; Category = 'GPU' }
}
$MinRecommendationScoreDefault = 50
$ForwardVersionCeiling = 10
#endregion Constants
# Runtime context for per-run state, outputs, and reusable caches
$script:RunContext = [pscustomobject]@{
    SchemaVersion      = '1.0'
    OutputWidth        = $null
    AzureEndpoints     = $null
    ImageReqs          = $null
    RegionPricing      = @{}
    UsingActualPricing = $false
    ScanOutput         = $null
    RecommendOutput    = $null
    ShowPlacement      = $false
    DesiredCount       = 1
    Caches             = [ordered]@{
        ValidRegions       = $null
        Pricing            = @{}
        ActualPricing      = @{}
        PlacementWarned403 = $false
    }
}


if (-not $PSBoundParameters.ContainsKey('MinScore')) {
    $MinScore = $MinRecommendationScoreDefault
}

# Map parameters to internal variables
$TargetSubIds = $SubscriptionId
$Regions = $Region
$script:RunContext.ShowPlacement = $ShowPlacement.IsPresent
$script:RunContext.DesiredCount = $DesiredCount

# Region Presets - expand preset name to actual region array
# Note: All presets limited to 5 regions max for performance
$RegionPresets = @{
    'USEastWest'    = @('eastus', 'eastus2', 'westus', 'westus2')
    'USCentral'     = @('centralus', 'northcentralus', 'southcentralus', 'westcentralus')
    'USMajor'       = @('eastus', 'eastus2', 'centralus', 'westus', 'westus2')  # Top 5 US regions by usage
    'Europe'        = @('westeurope', 'northeurope', 'uksouth', 'francecentral', 'germanywestcentral')
    'AsiaPacific'   = @('eastasia', 'southeastasia', 'japaneast', 'australiaeast', 'koreacentral')
    'Global'        = @('eastus', 'westeurope', 'southeastasia', 'australiaeast', 'brazilsouth')
    'USGov'         = @('usgovvirginia', 'usgovtexas', 'usgovarizona')  # Azure Government (AzureUSGovernment)
    'China'         = @('chinaeast', 'chinanorth', 'chinaeast2', 'chinanorth2')  # Azure China / Mooncake (AzureChinaCloud)
    'ASR-EastWest'  = @('eastus', 'westus2')      # Azure Site Recovery pair
    'ASR-CentralUS' = @('centralus', 'eastus2')   # Azure Site Recovery pair
}

# If RegionPreset is specified, expand it (takes precedence over -Region if both specified)
if ($RegionPreset) {
    $Regions = $RegionPresets[$RegionPreset]
    Write-Verbose "Using region preset '$RegionPreset': $($Regions -join ', ')"

    # Auto-set environment for sovereign cloud presets
    if ($RegionPreset -eq 'USGov' -and -not $Environment) {
        $script:TargetEnvironment = 'AzureUSGovernment'
        Write-Verbose "Auto-setting environment to AzureUSGovernment for USGov preset"
    }
    elseif ($RegionPreset -eq 'China' -and -not $Environment) {
        $script:TargetEnvironment = 'AzureChinaCloud'
        Write-Verbose "Auto-setting environment to AzureChinaCloud for China preset"
    }
}

# Only override environment if explicitly specified (preserve auto-detected sovereign clouds)
if ($Environment) {
    $script:TargetEnvironment = $Environment
}

# Auto-detect environment from Az context when not explicitly set
if (-not $script:TargetEnvironment) {
    try {
        $autoCtx = Get-AzContext -ErrorAction SilentlyContinue
        if ($autoCtx -and $autoCtx.Environment -and $autoCtx.Environment.Name) {
            $script:TargetEnvironment = $autoCtx.Environment.Name
            Write-Verbose "Auto-detected environment from Az context: $($script:TargetEnvironment)"
        }
        else {
            $script:TargetEnvironment = 'AzureCloud'
        }
    }
    catch {
        $script:TargetEnvironment = 'AzureCloud'
    }
}

# Detect execution environment (Azure Cloud Shell vs local)
$isCloudShell = $env:CLOUD_SHELL -eq "true" -or (Test-Path "/home/system" -ErrorAction SilentlyContinue)
$defaultExportPath = if ($isCloudShell) { "/home/system" } else { "C:\Temp\AzVMLifecycle" }

# Auto-detect Unicode support for status icons
# Checks for modern terminals that support Unicode characters
# Can be overridden with -UseAsciiIcons parameter
$supportsUnicode = -not $UseAsciiIcons -and (
    $Host.UI.SupportsVirtualTerminal -or
    $env:WT_SESSION -or # Windows Terminal
    $env:TERM_PROGRAM -eq 'vscode' -or # VS Code integrated terminal
    ($env:TERM -and $env:TERM -match 'xterm|256color')  # Linux/macOS terminals
)

# Define icons based on terminal capability
# Shorter labels for narrow terminal support (Cloud Shell compatibility)
$Icons = if ($supportsUnicode) {
    @{
        OK       = '✓ OK'
        CAPACITY = '⚠ CONSTRAINED'
        LIMITED  = '⚠ LIMITED'
        PARTIAL  = '⚡ PARTIAL'
        BLOCKED  = '✗ BLOCKED'
        UNKNOWN  = '? N/A'
        Check    = '✓'
        Warning  = '⚠'
        Error    = '✗'
    }
}
else {
    @{
        OK       = '[OK]'
        CAPACITY = '[CONSTRAINED]'
        LIMITED  = '[LIMITED]'
        PARTIAL  = '[PARTIAL]'
        BLOCKED  = '[BLOCKED]'
        UNKNOWN  = '[N/A]'
        Check    = '[+]'
        Warning  = '[!]'
        Error    = '[-]'
    }
}

if ($AutoExport -and -not $ExportPath) {
    $ExportPath = $defaultExportPath
}

# Start transcript logging
# If -LogFile is specified, use it; otherwise auto-generate in the export directory (or current directory)
if (-not $LogFile) {
    $logDir = if ($ExportPath) { $ExportPath } else { $PWD.Path }
    $logTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ($InputFile) {
        $logBase = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
        $LogFile = Join-Path $logDir "${logBase}_Lifecycle_${logTimestamp}.log"
    }
    else {
        $LogFile = Join-Path $logDir "AzVMLifecycle_${logTimestamp}.log"
    }
}
elseif (Test-Path -LiteralPath $LogFile -PathType Container) {
    $logTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogFile = Join-Path $LogFile "AzVMLifecycle_${logTimestamp}.log"
}
try {
    $logFileDir = Split-Path -Path $LogFile -Parent
    if ($logFileDir -and -not (Test-Path -LiteralPath $logFileDir)) {
        New-Item -Path $logFileDir -ItemType Directory -Force | Out-Null
    }
    Start-Transcript -Path $LogFile -Append | Out-Null
    $script:TranscriptStarted = $true
    Write-Host "Logging to: $LogFile" -ForegroundColor DarkGray
}
catch {
    Write-Warning "Failed to start transcript logging: $($_.Exception.Message)"
}

#endregion Configuration
#region Module Import / Inline Fallback
$script:ModuleRoot = Join-Path $PSScriptRoot 'AzVMLifecycle'
$script:ModuleLoaded = $false
if (Test-Path (Join-Path $script:ModuleRoot 'AzVMLifecycle.psd1')) {
    try {
        Import-Module $script:ModuleRoot -Force -DisableNameChecking -ErrorAction Stop
        $script:ModuleLoaded = $true
        Write-Verbose "Loaded functions from AzVMLifecycle module"
    }
    catch {
        Write-Verbose "AzVMLifecycle module failed to load: $($_.Exception.Message) - using inline function definitions"
    }
}
if (-not $script:ModuleLoaded) {
    Write-Verbose "Using inline function definitions"
#region Inline Function Definitions

function Get-SafeString {
    <#
    .SYNOPSIS
        Safely converts a value to string, unwrapping arrays from parallel execution.
    .DESCRIPTION
        When using ForEach-Object -Parallel, PowerShell serializes objects which can
        wrap strings in arrays. This function recursively unwraps those arrays to
        get the underlying string value. Critical for hashtable key lookups.
    #>
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    # Recursively unwrap nested arrays (parallel execution can create multiple levels)
    while ($Value -is [array] -and $Value.Count -gt 0) {
        $Value = $Value[0]
    }
    if ($null -eq $Value) { return '' }
    return "$Value"  # String interpolation is safer than .ToString()
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Executes a script block with retry logic for transient Azure API errors.
    .DESCRIPTION
        Wraps any API call with automatic retry on:
        - HTTP 429 (Too Many Requests) — reads Retry-After header
        - HTTP 503 (Service Unavailable) — transient Azure outages
        - Network timeouts and WebExceptions
        Uses exponential backoff with jitter between retries.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3,

        [Parameter(Mandatory = $false)]
        [string]$OperationName = 'API call'
    )

    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        }
        catch {
            $attempt++
            $ex = $_.Exception
            $isRetryable = $false
            $waitSeconds = [math]::Pow(2, $attempt)  # Exponential: 2, 4, 8...

            # HTTP 429 — Too Many Requests (throttled)
            $statusCode = if ($ex.Response) { $ex.Response.StatusCode.value__ } else { $null }
            if ($statusCode -eq 429 -or $ex.Message -match '429|Too Many Requests') {
                $isRetryable = $true
                if ($ex.Response -and $ex.Response.Headers) {
                    $retryAfter = $ex.Response.Headers['Retry-After']
                    if ($retryAfter) {
                        $parsedSeconds = 0
                        $retryDate = [datetime]::MinValue
                        if ([int]::TryParse($retryAfter, [ref]$parsedSeconds)) {
                            # Clamp to ≥1 so Start-Sleep never receives 0 or negative seconds
                            $waitSeconds = [math]::Max(1, $parsedSeconds)
                        }
                        elseif ([datetime]::TryParseExact($retryAfter, 'R', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$retryDate)) {
                            # Azure can return an absolute HTTP-date (RFC 1123 'R' format) instead of integer seconds.
                            # AssumeUniversal|AdjustToUniversal ensures Kind=Utc so the subtraction is correct regardless of local timezone.
                            $waitSeconds = [int][math]::Ceiling(($retryDate - [datetime]::UtcNow).TotalSeconds)
                            if ($waitSeconds -lt 1) { $waitSeconds = 1 }
                        }
                    }
                }
            }
            # HTTP 503 — Service Unavailable
            elseif ($statusCode -eq 503 -or $ex.Message -match '503|Service Unavailable') {
                $isRetryable = $true
            }
            # Network errors — timeouts, connection failures
            elseif ($ex -is [System.Net.WebException] -or
                $ex -is [System.Net.Http.HttpRequestException] -or
                $ex.InnerException -is [System.Net.WebException] -or
                $ex.InnerException -is [System.Net.Http.HttpRequestException] -or
                $ex.Message -match 'timed?\s*out|connection.*reset|connection.*refused') {
                $isRetryable = $true
            }

            if (-not $isRetryable -or $attempt -ge $MaxRetries) {
                throw
            }

            # Add jitter (0-25%) to prevent thundering herd
            $jitter = Get-Random -Minimum 0 -Maximum ([math]::Max(1, [int]($waitSeconds * 0.25)))
            $waitSeconds += $jitter

            Write-Verbose "$OperationName failed (attempt $attempt/$MaxRetries): $($ex.Message). Retrying in ${waitSeconds}s..."
            Start-Sleep -Seconds $waitSeconds
        }
    }
}

function Get-GeoGroup {
    param([string]$LocationCode)
    $code = $LocationCode.ToLower()
    switch -regex ($code) {
        '^(eastus|eastus2|westus|westus2|westus3|centralus|northcentralus|southcentralus|westcentralus)' { return 'Americas-US' }
        '^(usgov|usdod|usnat|ussec)' { return 'Americas-USGov' }
        '^canada' { return 'Americas-Canada' }
        '^(brazil|chile|mexico)' { return 'Americas-LatAm' }
        '^(westeurope|northeurope|france|germany|switzerland|uksouth|ukwest|swedencentral|norwayeast|norwaywest|poland|italy|spain)' { return 'Europe' }
        '^(eastasia|southeastasia|japaneast|japanwest|koreacentral|koreasouth)' { return 'Asia-Pacific' }
        '^(centralindia|southindia|westindia|jioindia)' { return 'India' }
        '^(uae|qatar|israel|saudi)' { return 'Middle East' }
        '^(southafrica|egypt|kenya)' { return 'Africa' }
        '^(australia|newzealand)' { return 'Australia' }
        default { return 'Other' }
    }
}

function Get-AzureEndpoints {
    <#
    .SYNOPSIS
        Resolves Azure endpoints based on the current cloud environment.
    .DESCRIPTION
        Automatically detects the Azure environment (Commercial, Government, China, etc.)
        from the current Az context and returns the appropriate API endpoints.
        Supports sovereign clouds and air-gapped environments.
        Can be overridden with explicit environment name.
    .PARAMETER AzEnvironment
        Environment object for testing (mock).
    .PARAMETER EnvironmentName
        Explicit environment name override (AzureCloud, AzureUSGovernment, etc.).
    .OUTPUTS
        Hashtable with ResourceManagerUrl, PricingApiUrl, and EnvironmentName.
    .EXAMPLE
        $endpoints = Get-AzureEndpoints
        $endpoints.PricingApiUrl  # Returns https://prices.azure.com for Commercial
    .EXAMPLE
        $endpoints = Get-AzureEndpoints -EnvironmentName 'AzureUSGovernment'
        $endpoints.PricingApiUrl  # Returns https://prices.azure.us
    #>
    param(
        [Parameter(Mandatory = $false)]
        [object]$AzEnvironment,  # For testing - pass a mock environment object

        [Parameter(Mandatory = $false)]
        [string]$EnvironmentName  # Explicit override by name
    )

    # If explicit environment name provided, look it up
    if ($EnvironmentName) {
        try {
            $AzEnvironment = Get-AzEnvironment -Name $EnvironmentName -ErrorAction Stop
            if (-not $AzEnvironment) {
                Write-Warning "Environment '$EnvironmentName' not found. Using default Commercial cloud."
            }
            else {
                Write-Verbose "Using explicit environment: $EnvironmentName"
            }
        }
        catch {
            Write-Warning "Could not get environment '$EnvironmentName': $_. Using default Commercial cloud."
            $AzEnvironment = $null
        }
    }

    # Get the current Azure environment if not provided
    if (-not $AzEnvironment) {
        try {
            $context = Get-AzContext -ErrorAction Stop
            if (-not $context) {
                Write-Warning "No Azure context found. Using default Commercial cloud endpoints."
                $AzEnvironment = $null
            }
            else {
                $AzEnvironment = $context.Environment
            }
        }
        catch {
            Write-Warning "Could not get Azure context: $_. Using default Commercial cloud endpoints."
            $AzEnvironment = $null
        }
    }

    # Default to Commercial cloud if no environment detected
    if (-not $AzEnvironment) {
        return @{
            EnvironmentName    = 'AzureCloud'
            ResourceManagerUrl = 'https://management.azure.com'
            PricingApiUrl      = 'https://prices.azure.com/api/retail/prices'
        }
    }

    # Get the Resource Manager URL directly from the environment
    $armUrl = $AzEnvironment.ResourceManagerUrl
    if (-not $armUrl) {
        $armUrl = 'https://management.azure.com'
    }
    # Ensure no trailing slash
    $armUrl = $armUrl.TrimEnd('/')

    # Azure Retail Prices API is a single global endpoint (prices.azure.com) for all clouds.
    # It serves Commercial, Government, and China pricing data via armRegionName filter.
    # There are no sovereign-specific pricing API endpoints (prices.azure.us does not exist).
    $pricingApiUrl = 'https://prices.azure.com/api/retail/prices'

    $endpoints = @{
        EnvironmentName    = $AzEnvironment.Name
        ResourceManagerUrl = $armUrl
        PricingApiUrl      = $pricingApiUrl
    }

    Write-Verbose "Azure Environment: $($endpoints.EnvironmentName)"
    Write-Verbose "Resource Manager URL: $($endpoints.ResourceManagerUrl)"
    Write-Verbose "Pricing API URL: $($endpoints.PricingApiUrl)"

    return $endpoints
}

function Get-CapValue {
    param([object]$Sku, [string]$Name)
    $cap = $Sku.Capabilities | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($cap) { return $cap.Value }
    return $null
}

function Get-SkuFamily {
    param([string]$SkuName)
    if ($SkuName -match 'Standard_([A-Z]+)\d') {
        return $matches[1]
    }
    return 'Unknown'
}

function Get-SkuFamilyVersion {
    param([string]$SkuName)
    if ($SkuName -match '_v(\d+)') {
        return [int]$matches[1]
    }
    return 1
}

function Get-SkuRetirementInfo {
    param([string]$SkuName)

    # Azure VM series retirement data from official Microsoft announcements
    # https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/retirement/retired-sizes-list
    # Last verified: 2026-04-23
    $retirementLookup = @(
        # Already retired
        @{ Pattern = '^Standard_H\d+[a-z]*$';          Series = 'H';    RetireDate = '2024-09-28'; Status = 'Retired' }
        @{ Pattern = '^Standard_HB60rs$';              Series = 'HBv1'; RetireDate = '2024-09-28'; Status = 'Retired' }
        @{ Pattern = '^Standard_HC44rs$';              Series = 'HC';   RetireDate = '2024-09-28'; Status = 'Retired' }
        @{ Pattern = '^Standard_NC\d+r?$';             Series = 'NCv1'; RetireDate = '2023-09-06'; Status = 'Retired' }
        @{ Pattern = '^Standard_NC\d+r?s_v2$';         Series = 'NCv2'; RetireDate = '2023-09-06'; Status = 'Retired' }
        @{ Pattern = '^Standard_NC\d+r?s_v3$';         Series = 'NCv3'; RetireDate = '2025-09-30'; Status = 'Retired' }
        @{ Pattern = '^Standard_ND\d+r?s$';            Series = 'NDv1'; RetireDate = '2023-09-06'; Status = 'Retired' }
        @{ Pattern = '^Standard_NV\d+$';               Series = 'NVv1'; RetireDate = '2023-09-06'; Status = 'Retired' }
        # Scheduled for retirement (announced, planned retirement date)
        @{ Pattern = '^Standard_DS?\d+$';              Series = 'Dv1';  RetireDate = '2028-05-01'; Status = 'Retiring' }
        @{ Pattern = '^Standard_DS?\d+_v2(_Promo)?$';  Series = 'Dv2';  RetireDate = '2028-05-01'; Status = 'Retiring' }
        @{ Pattern = '^(Basic_A\d+|Standard_A\d+)$';  Series = 'Av1';  RetireDate = '2028-11-15'; Status = 'Retiring' }
        @{ Pattern = '^Standard_A\d+m?_v2$';           Series = 'Av2';  RetireDate = '2028-11-15'; Status = 'Retiring' }
        @{ Pattern = '^Standard_B\d+[a-z]*$';          Series = 'Bv1';  RetireDate = '2028-11-15'; Status = 'Retiring' }
        @{ Pattern = '^Standard_GS?\d+$';              Series = 'G/GS'; RetireDate = '2028-11-15'; Status = 'Retiring' }
        @{ Pattern = '^Standard_F\d+s?$';              Series = 'Fsv1'; RetireDate = '2028-11-15'; Status = 'Retiring' }
        @{ Pattern = '^Standard_F\d+s_v2$';            Series = 'Fsv2'; RetireDate = '2028-11-15'; Status = 'Retiring' }
        @{ Pattern = '^Standard_L\d+s$';               Series = 'Lsv1'; RetireDate = '2028-05-01'; Status = 'Retiring' }
        @{ Pattern = '^Standard_L\d+s_v2$';            Series = 'Lsv2'; RetireDate = '2028-11-15'; Status = 'Retiring' }
        @{ Pattern = '^Standard_ND\d+r?s_v2$';         Series = 'NDv2'; RetireDate = '2025-09-30'; Status = 'Retiring' }
        @{ Pattern = '^Standard_NV\d+s_v3$';           Series = 'NVv3'; RetireDate = '2026-09-30'; Status = 'Retiring' }
        @{ Pattern = '^Standard_NV\d+as_v4$';          Series = 'NVv4'; RetireDate = '2026-09-30'; Status = 'Retiring' }
        @{ Pattern = '^Standard_M192i[dm]*s_v2$';      Series = 'Mv2i'; RetireDate = '2027-03-31'; Status = 'Retiring' }
        @{ Pattern = '^Standard_M\d+(-\d+)?[a-z]*$';   Series = 'Mv1';  RetireDate = '2027-08-31'; Status = 'Retiring' }
        @{ Pattern = '^Standard_NP\d+s$';              Series = 'NP';   RetireDate = '2027-05-31'; Status = 'Retiring' }
    )

    foreach ($entry in $retirementLookup) {
        if ($SkuName -match $entry.Pattern) {
            return $entry
        }
    }
    return $null
}

function Get-ProcessorVendor {
    param([string]$SkuName)
    $body = ($SkuName -replace '^Standard_', '') -replace '_v\d+$', ''
    # 'p' suffix = ARM/Ampere; must check before 'a' since some SKUs have both (e.g., E64pds)
    if ($body -match 'p(?![\d])') { return 'ARM' }
    # 'a' suffix = AMD; exclude A-family where 'a' is the family letter not a suffix
    $family = if ($SkuName -match 'Standard_([A-Z]+)\d') { $matches[1] } else { '' }
    if ($family -ne 'A' -and $body -match 'a(?![\d])') { return 'AMD' }
    return 'Intel'
}

function Get-DiskCode {
    param(
        [bool]$HasTempDisk,
        [bool]$HasNvme
    )
    if ($HasNvme -and $HasTempDisk) { return 'NV+T' }
    if ($HasNvme) { return 'NVMe' }
    if ($HasTempDisk) { return 'SC+T' }
    return 'SCSI'
}

function Get-ValidAzureRegions {
    <#
    .SYNOPSIS
        Returns list of valid Azure region names that support Compute, with caching.
    .DESCRIPTION
        Uses REST API for speed (2-3x faster than Get-AzLocation).
        Falls back to Get-AzLocation if REST API fails.
        Caches result in the passed-in -Caches dictionary to avoid repeated calls.
    #>
    [OutputType([string[]])]
    param(
        [int]$MaxRetries = 3,
        [hashtable]$AzureEndpoints,
        [System.Collections.IDictionary]$Caches = @{}
    )

    # Return cached result if available
    $cachedRegions = $Caches.ValidRegions
    if ($cachedRegions) {
        Write-Verbose "Using cached region list ($($cachedRegions.Count) regions)"
        return $cachedRegions
    }

    Write-Verbose "Fetching valid Azure regions..."

    try {
        # Get current subscription context
        $ctx = Get-AzContext -ErrorAction Stop
        if (-not $ctx) {
            throw "No Azure context available"
        }

        $subId = $ctx.Subscription.Id

        # Use environment-aware ARM URL (supports sovereign clouds)
        $armUrl = if ($AzureEndpoints) { $AzureEndpoints.ResourceManagerUrl } else { 'https://management.azure.com' }
        $armUrl = $armUrl.TrimEnd('/')

        $token = (Get-AzAccessToken -ResourceUrl $armUrl -ErrorAction Stop).Token

        # REST API call (faster than Get-AzLocation)
        $uri = "$armUrl/subscriptions/$subId/locations?api-version=2022-12-01"
        $headers = @{
            'Authorization' = "Bearer $token"
            'Content-Type'  = 'application/json'
        }

        try {
            $response = Invoke-WithRetry -MaxRetries $MaxRetries -OperationName 'Region list API' -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
            }
        }
        finally {
            $headers['Authorization'] = $null
            $token = $null
        }

        # Filter to regions with valid names (exclude logical/paired regions)
        $validRegions = $response.value | Where-Object {
            $_.metadata.regionCategory -ne 'Other' -and
            $_.name -match '^[a-z0-9]+$'
        } | Select-Object -ExpandProperty name | ForEach-Object { $_.ToLower() }

        if ($validRegions.Count -eq 0) {
            throw "REST API returned no valid regions"
        }

        Write-Verbose "Fetched $($validRegions.Count) regions via REST API"
        $Caches.ValidRegions = @($validRegions)
        return @($validRegions)
    }
    catch {
        Write-Verbose "REST API failed: $($_.Exception.Message). Falling back to Get-AzLocation..."

        try {
            # Fallback to Get-AzLocation (slower but more reliable)
            $validRegions = Get-AzLocation -ErrorAction Stop |
            Where-Object { $_.Providers -contains 'Microsoft.Compute' } |
            Select-Object -ExpandProperty Location |
            ForEach-Object { $_.ToLower() }

            if ($validRegions.Count -eq 0) {
                throw "Get-AzLocation returned no valid regions"
            }

            Write-Verbose "Fetched $($validRegions.Count) regions via Get-AzLocation"
            $Caches.ValidRegions = @($validRegions)
            return @($validRegions)
        }
        catch {
            Write-Warning "Failed to retrieve valid Azure regions: $($_.Exception.Message)"
            Write-Warning "Region validation metadata is unavailable."
            return $null
        }
    }
}

function Get-RestrictionReason {
    param([object]$Sku)
    if ($Sku.Restrictions -and $Sku.Restrictions.Count -gt 0) {
        return $Sku.Restrictions[0].ReasonCode
    }
    return $null
}

function Get-RestrictionDetails {
    <#
    .SYNOPSIS
        Analyzes SKU restrictions and returns detailed zone-level availability status.
    .DESCRIPTION
        Examines Azure SKU restrictions to determine:
        - Which zones are fully available (OK)
        - Which zones have capacity constraints (LIMITED)
        - Which zones are completely restricted (RESTRICTED)
        Returns a hashtable with status and zone breakdowns.
    #>
    param([object]$Sku)

    # If no restrictions, SKU is fully available in all zones
    if (-not $Sku -or -not $Sku.Restrictions -or $Sku.Restrictions.Count -eq 0) {
        $zones = if ($Sku -and $Sku.LocationInfo -and $Sku.LocationInfo[0].Zones) {
            $Sku.LocationInfo[0].Zones
        }
        else { @() }
        return @{
            Status             = 'OK'
            ZonesOK            = @($zones)
            ZonesLimited       = @()
            ZonesRestricted    = @()
            RestrictionReasons = @()
        }
    }

    # Categorize zones based on restriction type
    $zonesOK = [System.Collections.Generic.List[string]]::new()
    $zonesLimited = [System.Collections.Generic.List[string]]::new()
    $zonesRestricted = [System.Collections.Generic.List[string]]::new()
    $reasonCodes = @()

    foreach ($r in $Sku.Restrictions) {
        $reasonCodes += $r.ReasonCode
        if ($r.Type -eq 'Zone' -and $r.RestrictionInfo -and $r.RestrictionInfo.Zones) {
            foreach ($zone in $r.RestrictionInfo.Zones) {
                if ($r.ReasonCode -eq 'NotAvailableForSubscription') {
                    if (-not $zonesLimited.Contains($zone)) { $zonesLimited.Add($zone) }
                }
                else {
                    if (-not $zonesRestricted.Contains($zone)) { $zonesRestricted.Add($zone) }
                }
            }
        }
    }

    if ($Sku.LocationInfo -and $Sku.LocationInfo[0].Zones) {
        foreach ($zone in $Sku.LocationInfo[0].Zones) {
            if (-not $zonesLimited.Contains($zone) -and -not $zonesRestricted.Contains($zone)) {
                if (-not $zonesOK.Contains($zone)) { $zonesOK.Add($zone) }
            }
        }
    }

    $status = if ($zonesRestricted.Count -gt 0) {
        if ($zonesOK.Count -eq 0) { 'RESTRICTED' } else { 'PARTIAL' }
    }
    elseif ($zonesLimited.Count -gt 0) {
        if ($zonesOK.Count -eq 0) { 'LIMITED' } else { 'CAPACITY-CONSTRAINED' }
    }
    else { 'OK' }

    return @{
        Status             = $status
        ZonesOK            = @($zonesOK | Sort-Object)
        ZonesLimited       = @($zonesLimited | Sort-Object)
        ZonesRestricted    = @($zonesRestricted | Sort-Object)
        RestrictionReasons = @($reasonCodes | Select-Object -Unique)
    }
}

function Format-ZoneStatus {
    param([array]$OK, [array]$Limited, [array]$Restricted)
    $parts = @()
    if ($OK.Count -gt 0) { $parts += "✓ Zones $($OK -join ',')" }
    if ($Limited.Count -gt 0) { $parts += "⚠ Zones $($Limited -join ',')" }
    if ($Restricted.Count -gt 0) { $parts += "✗ Zones $($Restricted -join ',')" }
    if ($parts.Count -eq 0) { return 'Non-zonal' }  # No zone info = regional deployment
    return $parts -join ' | '
}

function Format-RegionList {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Regions,
        [int]$MaxWidth = 75
    )

    if ($null -eq $Regions) {
        return , @('(none)')
    }

    $regionArray = @($Regions)

    if ($regionArray.Count -eq 0) {
        return , @('(none)')
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $currentLine = ""

    foreach ($region in $regionArray) {
        $regionStr = [string]$region
        $separator = if ($currentLine) { ', ' } else { '' }
        $testLine = $currentLine + $separator + $regionStr

        if ($testLine.Length -gt $MaxWidth -and $currentLine) {
            $lines.Add($currentLine)
            $currentLine = $regionStr
        }
        else {
            $currentLine = $testLine
        }
    }

    if ($currentLine) {
        $lines.Add($currentLine)
    }

    return , @($lines.ToArray())
}

function Get-QuotaAvailable {
    param([hashtable]$QuotaLookup, [string]$SkuFamily, [int]$RequiredvCPUs = 0)
    $quota = $QuotaLookup[$SkuFamily]
    if (-not $quota) { return @{ Available = $null; OK = $null; Limit = $null; Current = $null } }
    $available = $quota.Limit - $quota.CurrentValue
    return @{
        Available = $available
        OK        = if ($RequiredvCPUs -gt 0) { $available -ge $RequiredvCPUs } else { $available -gt 0 }
        Limit     = $quota.Limit
        Current   = $quota.CurrentValue
    }
}


function Use-SubscriptionContextSafely {
    param([Parameter(Mandatory)][string]$SubscriptionId)

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Subscription -or $ctx.Subscription.Id -ne $SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        return $true
    }

    return $false
}

function Restore-OriginalSubscriptionContext {
    param([string]$OriginalSubscriptionId)

    if (-not $OriginalSubscriptionId) {
        return $false
    }

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx -and $ctx.Subscription -and $ctx.Subscription.Id -eq $OriginalSubscriptionId) {
        return $false
    }

    try {
        Set-AzContext -SubscriptionId $OriginalSubscriptionId -ErrorAction Stop | Out-Null
        Write-Verbose "Restored Azure context to original subscription: $OriginalSubscriptionId"
        return $true
    }
    catch {
        Write-Warning "Failed to restore Azure context to original subscription '$OriginalSubscriptionId': $($_.Exception.Message)"
        return $false
    }
}

function Test-ImportExcelModule {
    try {
        $module = Get-Module ImportExcel -ListAvailable -ErrorAction SilentlyContinue
        if ($module) {
            Import-Module ImportExcel -ErrorAction Stop -WarningAction SilentlyContinue
            return $true
        }
        return $false
    }
    catch {
        Write-Verbose "Failed to load ImportExcel module: $($_.Exception.Message)"
        return $false
    }
}

function Test-SkuMatchesFilter {
    <#
    .SYNOPSIS
        Tests if a SKU name matches any of the filter patterns.
    .DESCRIPTION
        Supports exact matches and wildcard patterns (e.g., Standard_D*_v5).
        Case-insensitive matching.
    #>
    param([string]$SkuName, [string[]]$FilterPatterns)

    if (-not $FilterPatterns -or $FilterPatterns.Count -eq 0) {
        return $true  # No filter = include all
    }

    foreach ($pattern in $FilterPatterns) {
        # Convert wildcard pattern to regex
        $regexPattern = '^' + [regex]::Escape($pattern).Replace('\*', '.*').Replace('\?', '.') + '$'
        if ($SkuName -match $regexPattern) {
            return $true
        }
    }

    return $false
}

function Test-SkuCompatibility {
    <#
    .SYNOPSIS
        Tests whether a candidate SKU can fully replace a target SKU.
    .DESCRIPTION
        Performs hard compatibility checks across critical VM dimensions: vCPU, memory,
        data disks, NICs, accelerated networking, premium IO, disk interface (NVMe/SCSI),
        ephemeral OS disk, and Ultra SSD. Returns pass/fail with a list of failures.
        This is a pre-filter before similarity scoring — only candidates that pass all
        checks should be scored and recommended.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        [Parameter(Mandatory)][hashtable]$Candidate
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    # Category gate: burstable (B-series) candidates cannot replace non-burstable targets
    $targetFamily = if ($Target.Family) { $Target.Family } elseif ($Target.Name) { if ($Target.Name -match 'Standard_([A-Z]+)\d') { $matches[1] } else { '' } } else { '' }
    $candidateFamily = if ($Candidate.Family) { $Candidate.Family } elseif ($Candidate.Name) { if ($Candidate.Name -match 'Standard_([A-Z]+)\d') { $matches[1] } else { '' } } else { '' }
    if ($candidateFamily -eq 'B' -and $targetFamily -ne 'B') {
        $failures.Add("Category: burstable (B-series) cannot replace non-burstable ($targetFamily-series)")
    }

    # vCPU: candidate must meet or exceed target
    if ($Candidate.vCPU -gt 0 -and $Target.vCPU -gt 0 -and $Candidate.vCPU -lt $Target.vCPU) {
        $failures.Add("vCPU: candidate $($Candidate.vCPU) < target $($Target.vCPU)")
    }

    # vCPU ceiling: candidate must not exceed 2x target (prevents licensing-impacting core count jumps)
    if ($Candidate.vCPU -gt 0 -and $Target.vCPU -gt 0 -and $Candidate.vCPU -gt ($Target.vCPU * 2)) {
        $failures.Add("vCPU: candidate $($Candidate.vCPU) exceeds 2x target $($Target.vCPU) (licensing risk)")
    }

    # Memory: candidate must meet or exceed target
    if ($Candidate.MemoryGB -gt 0 -and $Target.MemoryGB -gt 0 -and $Candidate.MemoryGB -lt $Target.MemoryGB) {
        $failures.Add("MemoryGB: candidate $($Candidate.MemoryGB) < target $($Target.MemoryGB)")
    }

    # Max NICs: candidate must support at least as many
    if ($Target.MaxNetworkInterfaces -gt 1 -and $Candidate.MaxNetworkInterfaces -lt $Target.MaxNetworkInterfaces) {
        $failures.Add("MaxNICs: candidate $($Candidate.MaxNetworkInterfaces) < target $($Target.MaxNetworkInterfaces)")
    }

    # Accelerated networking: if target has it, candidate must too
    if ($Target.AccelNet -eq $true -and $Candidate.AccelNet -ne $true) {
        $failures.Add("AcceleratedNetworking: target requires it, candidate lacks it")
    }

    # Premium IO: if target requires premium, candidate must support it
    if ($Target.PremiumIO -eq $true -and $Candidate.PremiumIO -ne $true) {
        $failures.Add("PremiumIO: target requires it, candidate lacks it")
    }

    # Disk interface: NVMe target requires NVMe candidate
    if ($Target.DiskCode -match 'NV' -and $Candidate.DiskCode -notmatch 'NV') {
        $failures.Add("DiskInterface: target uses NVMe, candidate only has SCSI")
    }

    # Ephemeral OS disk: if target uses it, candidate must support it
    if ($Target.EphemeralOSDiskSupported -eq $true -and $Candidate.EphemeralOSDiskSupported -ne $true) {
        $failures.Add("EphemeralOSDisk: target requires it, candidate lacks it")
    }

    # Ultra SSD: if target uses it, candidate must support it
    if ($Target.UltraSSDAvailable -eq $true -and $Candidate.UltraSSDAvailable -ne $true) {
        $failures.Add("UltraSSD: target requires it, candidate lacks it")
    }

    # GPU: if target has GPUs, candidate must also have GPUs
    if ($Target.GPUCount -gt 0 -and ($Candidate.GPUCount -le 0 -or -not $Candidate.ContainsKey('GPUCount'))) {
        $failures.Add("GPU: target has $($Target.GPUCount) GPU(s), candidate has none")
    }

    return @{
        Compatible = ($failures.Count -eq 0)
        Failures   = @($failures)
    }
}

function Get-SkuSimilarityScore {
    <#
    .SYNOPSIS
        Scores how similar a candidate SKU is to a target SKU profile.
    .DESCRIPTION
        Weighted scoring across 8 dimensions: vCPU (20), memory (20), family (18),
        family version newness (15), architecture (10), premium IO (5), disk IOPS (8),
        data disk count (7). Max 100.
        Family version newness strongly rewards the latest SKU generations (_v9 > _v8 > _v7 > _v6)
        to prioritize lifecycle upgrades to the newest available hardware.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        [Parameter(Mandatory)][hashtable]$Candidate,
        [hashtable]$FamilyInfo
    )

    $score = 0

    # vCPU closeness (20 points)
    if ($Target.vCPU -gt 0 -and $Candidate.vCPU -gt 0) {
        $maxCpu = [math]::Max($Target.vCPU, $Candidate.vCPU)
        $cpuScore = 1 - ([math]::Abs($Target.vCPU - $Candidate.vCPU) / $maxCpu)
        $score += [math]::Round($cpuScore * 20)
    }

    # Memory closeness (20 points)
    if ($Target.MemoryGB -gt 0 -and $Candidate.MemoryGB -gt 0) {
        $maxMem = [math]::Max($Target.MemoryGB, $Candidate.MemoryGB)
        $memScore = 1 - ([math]::Abs($Target.MemoryGB - $Candidate.MemoryGB) / $maxMem)
        $score += [math]::Round($memScore * 20)
    }

    # Family match (18 points) — exact = 18, same category = 13, same first letter = 9
    if ($Target.Family -eq $Candidate.Family) {
        $score += 18
    }
    else {
        $targetInfo = if ($FamilyInfo) { $FamilyInfo[$Target.Family] } else { $null }
        $candidateInfo = if ($FamilyInfo) { $FamilyInfo[$Candidate.Family] } else { $null }
        $targetCat = if ($targetInfo) { $targetInfo.Category } else { 'Unknown' }
        $candidateCat = if ($candidateInfo) { $candidateInfo.Category } else { 'Unknown' }
        if ($targetCat -ne 'Unknown' -and $targetCat -eq $candidateCat) {
            $score += 13
        }
        elseif ($Target.Family.Length -gt 0 -and $Candidate.Family.Length -gt 0 -and
            $Target.Family[0] -eq $Candidate.Family[0]) {
            $score += 9
        }
    }

    # Family version newness (15 points) — strongly rewards latest SKU generations
    $targetVer = if ($Target.FamilyVersion) { [int]$Target.FamilyVersion } else { 1 }
    $candidateVer = if ($Candidate.FamilyVersion) { [int]$Candidate.FamilyVersion } else { 1 }

    if ($Target.Family -eq $Candidate.Family) {
        if ($candidateVer -gt $targetVer) {
            # Upgrade: base 8 + graduated bonus, newest generations score highest
            $verBonus = switch ($candidateVer) {
                { $_ -ge 9 } { 7; break }
                { $_ -ge 8 } { 6; break }
                { $_ -ge 7 } { 5; break }
                { $_ -ge 6 } { 4; break }
                { $_ -ge 5 } { 3; break }
                default      { 2 }
            }
            $score += [math]::Min(8 + $verBonus, 15)
        }
        elseif ($candidateVer -eq $targetVer) {
            $score += 5
        }
        else {
            $score += 1
        }
    }
    else {
        # Cross-family: graduated by candidate version
        $score += switch ($candidateVer) {
            { $_ -ge 9 } { 13; break }
            { $_ -ge 8 } { 12; break }
            { $_ -ge 7 } { 11; break }
            { $_ -ge 6 } { 9; break }
            { $_ -ge 5 } { 7; break }
            { $_ -ge 4 } { 5; break }
            { $_ -ge 3 } { 3; break }
            { $_ -ge 2 } { 1; break }
            default      { 0 }
        }
    }

    # Architecture match (10 points)
    if ($Target.Architecture -eq $Candidate.Architecture) {
        $score += 10
    }

    # Premium IO match (5 points) — if target needs premium, candidate must have it
    if ($Target.PremiumIO -eq $true -and $Candidate.PremiumIO -eq $true) {
        $score += 5
    }
    elseif ($Target.PremiumIO -ne $true) {
        $score += 5
    }

    # Disk IOPS closeness (8 points) — uncached disk IO throughput
    if ($Target.UncachedDiskIOPS -gt 0 -and $Candidate.UncachedDiskIOPS -gt 0) {
        $maxIOPS = [math]::Max($Target.UncachedDiskIOPS, $Candidate.UncachedDiskIOPS)
        $iopsScore = 1 - ([math]::Abs($Target.UncachedDiskIOPS - $Candidate.UncachedDiskIOPS) / $maxIOPS)
        $score += [math]::Round($iopsScore * 8)
    }
    elseif ($Target.UncachedDiskIOPS -le 0) {
        $score += 8
    }

    # Data disk count closeness (7 points)
    if ($Target.MaxDataDiskCount -gt 0 -and $Candidate.MaxDataDiskCount -gt 0) {
        $maxDisks = [math]::Max($Target.MaxDataDiskCount, $Candidate.MaxDataDiskCount)
        $diskScore = 1 - ([math]::Abs($Target.MaxDataDiskCount - $Candidate.MaxDataDiskCount) / $maxDisks)
        $score += [math]::Round($diskScore * 7)
    }
    elseif ($Target.MaxDataDiskCount -le 0) {
        $score += 7
    }

    return [math]::Min($score, 100)
}

function New-RecommendOutputContract {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][hashtable]$TargetProfile,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$TargetAvailability,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$RankedRecommendations,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Warnings,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$BelowMinSpec,
        [Parameter(Mandatory)][int]$MinScore,
        [Parameter(Mandatory)][int]$TopN,
        [Parameter(Mandatory)][bool]$FetchPricing,
        [Parameter(Mandatory)][bool]$ShowPlacement,
        [Parameter(Mandatory)][bool]$ShowSpot
    )

    $rankedPayload = [System.Collections.Generic.List[object]]::new()
    $rank = 1
    foreach ($item in @($RankedRecommendations)) {
        $rankedPayload.Add([pscustomobject]@{
            rank       = $rank
            sku        = $item.SKU
            region     = $item.Region
            vCPU       = $item.vCPU
            memGiB     = $item.MemGiB
            family     = $item.Family
            purpose    = $item.Purpose
            gen        = $item.Gen
            arch       = $item.Arch
            cpu        = $item.CPU
            disk       = $item.Disk
            tempDiskGB = $item.TempGB
            accelNet   = $item.AccelNet
            maxDisks   = $item.MaxDisks
            maxNICs    = $item.MaxNICs
            iops       = $item.IOPS
            score      = $item.Score
            capacity   = $item.Capacity
            allocScore = $item.AllocScore
            zonesOK    = $item.ZonesOK
            priceHr    = $item.PriceHr
            priceMo    = $item.PriceMo
            spotPriceHr = $item.SpotPriceHr
            spotPriceMo = $item.SpotPriceMo
        })
        $rank++
    }

    $belowMinSpecPayload = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($BelowMinSpec)) {
        $belowMinSpecPayload.Add([pscustomobject]@{
            sku      = $item.SKU
            region   = $item.Region
            vCPU     = $item.vCPU
            memGiB   = $item.MemGiB
            score    = $item.Score
            capacity = $item.Capacity
        })
    }

    return [pscustomobject]@{
        schemaVersion      = '1.0'
        mode               = 'recommend'
        generatedAt        = (Get-Date).ToString('o')
        minScore           = $MinScore
        topN               = $TopN
        pricingEnabled     = $FetchPricing
        placementEnabled   = $ShowPlacement
        spotPricingEnabled = ($FetchPricing -and $ShowSpot)
        target             = [pscustomobject]$TargetProfile
        targetAvailability = @($TargetAvailability)
        recommendations    = @($rankedPayload)
        warnings           = @($Warnings)
        belowMinSpec       = @($belowMinSpecPayload)
    }
}

function Write-RecommendOutputContract {
    param(
        [Parameter(Mandatory)][pscustomobject]$Contract,
        [Parameter(Mandatory)][hashtable]$Icons,
        [Parameter(Mandatory)][bool]$FetchPricing,
        [Parameter(Mandatory)][hashtable]$FamilyInfo,
        [int]$OutputWidth = 122
    )

    $targetProfile = $Contract.target
    $targetAvailability = @($Contract.targetAvailability)
    $recommendations = @($Contract.recommendations)
    $placementEnabled = [bool]$Contract.placementEnabled
    $spotPricingEnabled = [bool]$Contract.spotPricingEnabled
    $compatWarnings = @($Contract.warnings)

    Write-Host "`n" -NoNewline
    Write-Host ("=" * $OutputWidth) -ForegroundColor Gray
    Write-Host "CAPACITY RECOMMENDER" -ForegroundColor Green
    Write-Host ("=" * $OutputWidth) -ForegroundColor Gray
    Write-Host ""

    $targetPurpose = if ($FamilyInfo[$targetProfile.Family]) { $FamilyInfo[$targetProfile.Family].Purpose } else { 'Unknown' }
    $skuSuffixes = @()
    $skuBody = ($targetProfile.Name -replace '^Standard_', '') -replace '_v\d+$', ''
    if ($skuBody -match 'a(?![\d])') { $skuSuffixes += 'a = AMD processor' }
    if ($skuBody -match 'p(?![\d])') { $skuSuffixes += 'p = ARM processor (Ampere)' }
    if ($skuBody -notmatch '[ap](?![\d])') { $skuSuffixes += '(no a/p suffix) = Intel processor' }
    if ($skuBody -match 'd(?![\d])') {
        if ($targetProfile.TempDiskGB -gt 0) {
            $skuSuffixes += "d = Local temp disk ($($targetProfile.TempDiskGB) GB)"
        }
        else {
            $skuSuffixes += 'd = Local temp disk'
        }
    }
    if ($skuBody -match 's$') { $skuSuffixes += 's = Premium storage capable' }
    if ($skuBody -match 'i(?![\d])') { $skuSuffixes += 'i = Isolated (dedicated host)' }
    if ($skuBody -match 'm(?![\d])') { $skuSuffixes += 'm = High memory per vCPU' }
    if ($skuBody -match 'l(?![\d])') { $skuSuffixes += 'l = Low memory per vCPU' }
    if ($skuBody -match 't(?![\d])') { $skuSuffixes += 't = Constrained vCPU' }
    $genMatch = if ($targetProfile.Name -match '_v(\d+)$') { "v$($Matches[1]) = Generation $($Matches[1])" } else { $null }

    Write-Host "TARGET: $($targetProfile.Name)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host '  Name breakdown:' -ForegroundColor DarkGray
    Write-Host "    $($targetProfile.Family)        $targetPurpose (family)" -ForegroundColor DarkGray
    Write-Host "    $($targetProfile.vCPU)       vCPUs" -ForegroundColor DarkGray
    foreach ($suffix in $skuSuffixes) {
        Write-Host "    $suffix" -ForegroundColor DarkGray
    }
    if ($genMatch) {
        Write-Host "    $genMatch" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  $($targetProfile.vCPU) vCPU / $($targetProfile.MemoryGB) GiB / $($targetProfile.Architecture) / $($targetProfile.Processor) / $($targetProfile.DiskCode) / Premium IO: $(if ($targetProfile.PremiumIO) { 'Yes' } else { 'No' })" -ForegroundColor White
    Write-Host ""

    $availableRegions = @($targetAvailability | Where-Object { $_.Status -eq 'OK' })
    $unavailableRegions = @($targetAvailability | Where-Object { $_.Status -ne 'OK' })
    if ($availableRegions.Count -gt 0) {
        $availableRegionNames = @($availableRegions | ForEach-Object { $_.Region })
        Write-Host "  $($Icons.Check) Available in: $($availableRegionNames -join ', ')" -ForegroundColor Green
    }
    foreach ($ur in $unavailableRegions) {
        Write-Host "  $($Icons.Error) $($ur.Region): $($ur.Status)" -ForegroundColor Red
    }

    if ($recommendations.Count -eq 0) {
        Write-Host "`nNo alternatives met the minimum similarity score of $($Contract.minScore)%." -ForegroundColor Yellow
        Write-Host 'Try lowering -MinScore or adding -MinvCPU / -MinMemoryGB filters.' -ForegroundColor DarkYellow
        return
    }

    Write-Host "`nRECOMMENDED ALTERNATIVES (top $($recommendations.Count), sorted by similarity):" -ForegroundColor Green
    Write-Host ""

    if ($FetchPricing -and $placementEnabled -and $spotPricingEnabled) {
        $headerFmt = " {0,-3} {1,-28} {2,-12} {3,-5} {4,-7} {5,-6} {6,-6} {7,-5} {8,-20} {9,-12} {10,-8} {11,-5} {12,-8} {13,-8} {14,-10} {15,-10}"
        Write-Host ($headerFmt -f '#', 'SKU', 'Region', 'vCPU', 'Mem(GB)', 'Score', 'CPU', 'Disk', 'Type', 'Capacity', 'Alloc', 'Zones', '$/Hr', '$/Mo', 'Spot$/Hr', 'Spot$/Mo') -ForegroundColor White
        Write-Host (' ' + ('-' * 169)) -ForegroundColor DarkGray
    }
    elseif ($FetchPricing -and $placementEnabled) {
        $headerFmt = " {0,-3} {1,-28} {2,-12} {3,-5} {4,-7} {5,-6} {6,-6} {7,-5} {8,-20} {9,-12} {10,-8} {11,-5} {12,-8} {13,-8}"
        Write-Host ($headerFmt -f '#', 'SKU', 'Region', 'vCPU', 'Mem(GB)', 'Score', 'CPU', 'Disk', 'Type', 'Capacity', 'Alloc', 'Zones', '$/Hr', '$/Mo') -ForegroundColor White
        Write-Host (' ' + ('-' * 147)) -ForegroundColor DarkGray
    }
    elseif ($FetchPricing -and $spotPricingEnabled) {
        $headerFmt = " {0,-3} {1,-28} {2,-12} {3,-5} {4,-7} {5,-6} {6,-6} {7,-5} {8,-20} {9,-12} {10,-5} {11,-8} {12,-8} {13,-10} {14,-10}"
        Write-Host ($headerFmt -f '#', 'SKU', 'Region', 'vCPU', 'Mem(GB)', 'Score', 'CPU', 'Disk', 'Type', 'Capacity', 'Zones', '$/Hr', '$/Mo', 'Spot$/Hr', 'Spot$/Mo') -ForegroundColor White
        Write-Host (' ' + ('-' * 159)) -ForegroundColor DarkGray
    }
    elseif ($FetchPricing) {
        $headerFmt = " {0,-3} {1,-28} {2,-12} {3,-5} {4,-7} {5,-6} {6,-6} {7,-5} {8,-20} {9,-12} {10,-5} {11,-8} {12,-8}"
        Write-Host ($headerFmt -f '#', 'SKU', 'Region', 'vCPU', 'Mem(GB)', 'Score', 'CPU', 'Disk', 'Type', 'Capacity', 'Zones', '$/Hr', '$/Mo') -ForegroundColor White
        Write-Host (' ' + ('-' * 137)) -ForegroundColor DarkGray
    }
    elseif ($placementEnabled) {
        $headerFmt = " {0,-3} {1,-28} {2,-12} {3,-5} {4,-7} {5,-6} {6,-6} {7,-5} {8,-20} {9,-12} {10,-8} {11,-5}"
        Write-Host ($headerFmt -f '#', 'SKU', 'Region', 'vCPU', 'Mem(GB)', 'Score', 'CPU', 'Disk', 'Type', 'Capacity', 'Alloc', 'Zones') -ForegroundColor White
        Write-Host (' ' + ('-' * 129)) -ForegroundColor DarkGray
    }
    else {
        $headerFmt = " {0,-3} {1,-28} {2,-12} {3,-5} {4,-7} {5,-6} {6,-6} {7,-5} {8,-20} {9,-12} {10,-5}"
        Write-Host ($headerFmt -f '#', 'SKU', 'Region', 'vCPU', 'Mem(GB)', 'Score', 'CPU', 'Disk', 'Type', 'Capacity', 'Zones') -ForegroundColor White
        Write-Host (' ' + ('-' * 119)) -ForegroundColor DarkGray
    }

    foreach ($r in $recommendations) {
        $rowColor = switch ($r.capacity) {
            'OK' { 'Green' }
            'LIMITED' { 'Yellow' }
            default { 'DarkYellow' }
        }
        if ($FetchPricing) {
            $hrStr = if ($null -ne $r.priceHr) { '$' + ([double]$r.priceHr).ToString('0.00') } else { '-' }
            $moStr = if ($null -ne $r.priceMo) { '$' + ([double]$r.priceMo).ToString('0') } else { '-' }
            $spotHrStr = if ($null -ne $r.spotPriceHr) { '$' + ([double]$r.spotPriceHr).ToString('0.00') } else { '-' }
            $spotMoStr = if ($null -ne $r.spotPriceMo) { '$' + ([double]$r.spotPriceMo).ToString('0') } else { '-' }
            if ($placementEnabled -and $spotPricingEnabled) {
                $allocStr = if ($r.allocScore) { [string]$r.allocScore } else { '-' }
                $line = $headerFmt -f $r.rank, $r.sku, $r.region, $r.vCPU, $r.memGiB, ("$($r.score)%"), $r.cpu, $r.disk, $r.purpose, $r.capacity, $allocStr, $r.zonesOK, $hrStr, $moStr, $spotHrStr, $spotMoStr
            }
            elseif ($placementEnabled) {
                $allocStr = if ($r.allocScore) { [string]$r.allocScore } else { '-' }
                $line = $headerFmt -f $r.rank, $r.sku, $r.region, $r.vCPU, $r.memGiB, ("$($r.score)%"), $r.cpu, $r.disk, $r.purpose, $r.capacity, $allocStr, $r.zonesOK, $hrStr, $moStr
            }
            elseif ($spotPricingEnabled) {
                $line = $headerFmt -f $r.rank, $r.sku, $r.region, $r.vCPU, $r.memGiB, ("$($r.score)%"), $r.cpu, $r.disk, $r.purpose, $r.capacity, $r.zonesOK, $hrStr, $moStr, $spotHrStr, $spotMoStr
            }
            else {
                $line = $headerFmt -f $r.rank, $r.sku, $r.region, $r.vCPU, $r.memGiB, ("$($r.score)%"), $r.cpu, $r.disk, $r.purpose, $r.capacity, $r.zonesOK, $hrStr, $moStr
            }
        }
        else {
            if ($placementEnabled) {
                $allocStr = if ($r.allocScore) { [string]$r.allocScore } else { '-' }
                $line = $headerFmt -f $r.rank, $r.sku, $r.region, $r.vCPU, $r.memGiB, ("$($r.score)%"), $r.cpu, $r.disk, $r.purpose, $r.capacity, $allocStr, $r.zonesOK
            }
            else {
                $line = $headerFmt -f $r.rank, $r.sku, $r.region, $r.vCPU, $r.memGiB, ("$($r.score)%"), $r.cpu, $r.disk, $r.purpose, $r.capacity, $r.zonesOK
            }
        }
        Write-Host $line -ForegroundColor $rowColor
    }

    $hasOkCapacity = (@($recommendations | Where-Object { $_.capacity -eq 'OK' }).Count -gt 0)
    if (-not $hasOkCapacity -and @($Contract.belowMinSpec).Count -gt 0) {
        $smallerOK = $Contract.belowMinSpec |
        Sort-Object @{Expression = 'score'; Descending = $true } |
        Group-Object sku |
        ForEach-Object { $_.Group | Select-Object -First 1 } |
        Select-Object -First 3

        if ($smallerOK.Count -gt 0) {
            Write-Host ""
            Write-Host "  $($Icons.Warning) CONSIDER SMALLER (better availability, if your workload supports it):" -ForegroundColor Yellow
            foreach ($s in $smallerOK) {
                Write-Host "    $($s.sku) ($($s.vCPU) vCPU / $($s.memGiB) GiB) — $($s.capacity) in $($s.region)" -ForegroundColor DarkYellow
            }
        }
    }

    Write-Host ''
    Write-Host 'STATUS KEY:' -ForegroundColor DarkGray
    Write-Host '  OK                    = Ready to deploy. No restrictions.' -ForegroundColor Green
    Write-Host '  CAPACITY-CONSTRAINED  = Azure is low on hardware. Try a different zone or wait.' -ForegroundColor Yellow
    Write-Host "  LIMITED               = Your subscription can't use this. Request access via support ticket." -ForegroundColor Yellow
    Write-Host '  PARTIAL               = Some zones work, others are blocked. No zone redundancy.' -ForegroundColor Yellow
    Write-Host '  BLOCKED               = Cannot deploy. Pick a different region or SKU.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'DISK CODES:' -ForegroundColor DarkGray
    Write-Host '  NV+T = NVMe + local temp disk   NVMe = NVMe only (no temp disk)' -ForegroundColor DarkGray
    Write-Host '  SC+T = SCSI + local temp disk   SCSI = SCSI only (no temp disk)' -ForegroundColor DarkGray

    if ($compatWarnings.Count -gt 0) {
        Write-Host ''
        Write-Host 'COMPATIBILITY NOTES:' -ForegroundColor Yellow
        foreach ($warning in $compatWarnings) {
            Write-Host "  $($Icons.Warning) $warning" -ForegroundColor Yellow
        }
    }

    Write-Host ''
}

function Invoke-RecommendMode {
    param(
        [Parameter(Mandatory)]
        [string]$TargetSkuName,

        [Parameter(Mandatory)]
        [array]$SubscriptionData,

        [hashtable]$FamilyInfo = @{},

        [hashtable]$Icons = @{},

        [bool]$FetchPricing = $false,

        [bool]$ShowSpot = $false,

        [bool]$ShowPlacement = $false,

        [bool]$AllowMixedArch = $false,

        [int]$MinvCPU = 0,

        [int]$MinMemoryGB = 0,

        [Nullable[int]]$MinScore,

        [int]$TopN = 5,

        [int]$DesiredCount = 1,

        [bool]$JsonOutput = $false,

        [int]$MaxRetries = 3,

        [Parameter(Mandatory)]
        [pscustomobject]$RunContext,

        [int]$OutputWidth = 122,

        [hashtable]$SkuProfileCache = $null
    )

    $targetSku = $null
    $targetRegionStatus = @()

    foreach ($subData in $SubscriptionData) {
        foreach ($data in $subData.RegionData) {
            $region = Get-SafeString $data.Region
            if ($data.Error) { continue }
            foreach ($sku in $data.Skus) {
                if ($sku.Name -eq $TargetSkuName) {
                    $restrictions = Get-RestrictionDetails $sku
                    $targetRegionStatus += [pscustomobject]@{
                        Region  = [string]$region
                        Status  = $restrictions.Status
                        ZonesOK = $restrictions.ZonesOK.Count
                    }
                    if (-not $targetSku) { $targetSku = $sku }
                }
            }
        }
    }

    if (-not $targetSku) {
        Write-Host "`nSKU '$TargetSkuName' was not found in any scanned region." -ForegroundColor Red
        Write-Host "Check the SKU name and ensure the scanned regions support this SKU family." -ForegroundColor Yellow
        return
    }

    $targetCaps = Get-SkuCapabilities -Sku $targetSku
    $targetProcessor = Get-ProcessorVendor -SkuName $targetSku.Name
    $targetHasNvme = $targetCaps.NvmeSupport
    $targetDiskCode = Get-DiskCode -HasTempDisk ($targetCaps.TempDiskGB -gt 0) -HasNvme $targetHasNvme
    $targetProfile = @{
        Name                     = $targetSku.Name
        vCPU                     = [int](Get-CapValue $targetSku 'vCPUs')
        MemoryGB                 = [int](Get-CapValue $targetSku 'MemoryGB')
        Family                   = Get-SkuFamily $targetSku.Name
        FamilyVersion            = Get-SkuFamilyVersion $targetSku.Name
        Generation               = $targetCaps.HyperVGenerations
        Architecture             = $targetCaps.CpuArchitecture
        PremiumIO                = (Get-CapValue $targetSku 'PremiumIO') -eq 'True'
        Processor                = $targetProcessor
        TempDiskGB               = $targetCaps.TempDiskGB
        DiskCode                 = $targetDiskCode
        AccelNet                 = $targetCaps.AcceleratedNetworkingEnabled
        MaxDataDiskCount         = $targetCaps.MaxDataDiskCount
        MaxNetworkInterfaces     = $targetCaps.MaxNetworkInterfaces
        EphemeralOSDiskSupported = $targetCaps.EphemeralOSDiskSupported
        UltraSSDAvailable        = $targetCaps.UltraSSDAvailable
        UncachedDiskIOPS         = $targetCaps.UncachedDiskIOPS
        UncachedDiskBytesPerSecond = $targetCaps.UncachedDiskBytesPerSecond
        EncryptionAtHostSupported = $targetCaps.EncryptionAtHostSupported
        GPUCount                 = $targetCaps.GPUCount
    }

    # Score all candidate SKUs across all regions
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($subData in $SubscriptionData) {
        foreach ($data in $subData.RegionData) {
            $region = Get-SafeString $data.Region
            if ($data.Error) { continue }
            foreach ($sku in $data.Skus) {
                if ($sku.Name -eq $TargetSkuName) { continue }

                # Skip SKUs with retirement or retired status
                $candidateRetirement = Get-SkuRetirementInfo -SkuName $sku.Name
                if ($candidateRetirement) { continue }

                $restrictions = Get-RestrictionDetails $sku
                if ($restrictions.Status -eq 'RESTRICTED') { continue }

                # Use cached profile if available; otherwise build and cache it
                $candidateProfile = $null
                $caps = $null
                $candidateProcessor = $null
                $candidateDiskCode = $null
                if ($SkuProfileCache -and $SkuProfileCache.ContainsKey($sku.Name)) {
                    $cached = $SkuProfileCache[$sku.Name]
                    $candidateProfile = $cached.Profile
                    $caps = $cached.Caps
                    $candidateProcessor = $cached.Processor
                    $candidateDiskCode = $cached.DiskCode
                }
                else {
                    $caps = Get-SkuCapabilities -Sku $sku
                    $candidateProcessor = Get-ProcessorVendor -SkuName $sku.Name
                    $candidateHasNvme = $caps.NvmeSupport
                    $candidateDiskCode = Get-DiskCode -HasTempDisk ($caps.TempDiskGB -gt 0) -HasNvme $candidateHasNvme
                    $candidateProfile = @{
                        Name                     = $sku.Name
                        vCPU                     = [int](Get-CapValue $sku 'vCPUs')
                        MemoryGB                 = [int](Get-CapValue $sku 'MemoryGB')
                        Family                   = Get-SkuFamily $sku.Name
                        FamilyVersion            = Get-SkuFamilyVersion $sku.Name
                        Generation               = $caps.HyperVGenerations
                        Architecture             = $caps.CpuArchitecture
                        PremiumIO                = (Get-CapValue $sku 'PremiumIO') -eq 'True'
                        DiskCode                 = $candidateDiskCode
                        AccelNet                 = $caps.AcceleratedNetworkingEnabled
                        MaxDataDiskCount         = $caps.MaxDataDiskCount
                        MaxNetworkInterfaces     = $caps.MaxNetworkInterfaces
                        EphemeralOSDiskSupported = $caps.EphemeralOSDiskSupported
                        UltraSSDAvailable        = $caps.UltraSSDAvailable
                        UncachedDiskIOPS         = $caps.UncachedDiskIOPS
                        UncachedDiskBytesPerSecond = $caps.UncachedDiskBytesPerSecond
                        EncryptionAtHostSupported = $caps.EncryptionAtHostSupported
                        GPUCount                 = $caps.GPUCount
                    }
                    if ($SkuProfileCache) {
                        $SkuProfileCache[$sku.Name] = @{ Profile = $candidateProfile; Caps = $caps; Processor = $candidateProcessor; DiskCode = $candidateDiskCode }
                    }
                }

                # Architecture filtering — skip candidates that don't match target arch unless opted out
                if (-not $AllowMixedArch -and $candidateProfile.Architecture -ne $targetProfile.Architecture) {
                    continue
                }

                # Hard compatibility gate — candidate must meet or exceed target on critical dimensions
                $compat = Test-SkuCompatibility -Target $targetProfile -Candidate $candidateProfile
                if (-not $compat.Compatible) { continue }

                $simScore = Get-SkuSimilarityScore -Target $targetProfile -Candidate $candidateProfile -FamilyInfo $FamilyInfo

                $priceHr = $null
                $priceMo = $null
                $spotPriceHr = $null
                $spotPriceMo = $null
                if ($FetchPricing -and $RunContext.RegionPricing[[string]$region]) {
                    $regionPriceData = $RunContext.RegionPricing[[string]$region]
                    $regularPriceMap = Get-RegularPricingMap -PricingContainer $regionPriceData
                    $spotPriceMap = Get-SpotPricingMap -PricingContainer $regionPriceData
                    $skuPricing = $regularPriceMap[$sku.Name]
                    if ($skuPricing) {
                        $priceHr = $skuPricing.Hourly
                        $priceMo = $skuPricing.Monthly
                    }
                    if ($ShowSpot) {
                        $spotPricing = $spotPriceMap[$sku.Name]
                        if ($spotPricing) {
                            $spotPriceHr = $spotPricing.Hourly
                            $spotPriceMo = $spotPricing.Monthly
                        }
                    }
                }

                $candidates.Add([pscustomobject]@{
                        SKU      = $sku.Name
                        Region   = [string]$region
                        vCPU     = $candidateProfile.vCPU
                        MemGiB   = $candidateProfile.MemoryGB
                        Family   = $candidateProfile.Family
                        Purpose  = if ($FamilyInfo[$candidateProfile.Family]) { $FamilyInfo[$candidateProfile.Family].Purpose } else { '' }
                        Gen      = (($caps.HyperVGenerations -replace 'V', '') -replace ',', ',')
                        Arch     = $candidateProfile.Architecture
                        CPU      = $candidateProcessor
                        Disk     = $candidateDiskCode
                        TempGB   = $caps.TempDiskGB
                        AccelNet = $caps.AcceleratedNetworkingEnabled
                        MaxDisks = $caps.MaxDataDiskCount
                        MaxNICs  = $caps.MaxNetworkInterfaces
                        IOPS     = $caps.UncachedDiskIOPS
                        Score    = $simScore
                        Capacity = $restrictions.Status
                        ZonesOK  = $restrictions.ZonesOK.Count
                        PriceHr  = $priceHr
                        PriceMo  = $priceMo
                        SpotPriceHr = $spotPriceHr
                        SpotPriceMo = $spotPriceMo
                    }) | Out-Null
            }
        }
    }

    # Apply minimum spec filters and separate smaller options for callout
    $belowMinSpecDict = @{}
    $filtered = @($candidates)
    if ($MinvCPU) {
        $filtered | Where-Object { $_.vCPU -lt $MinvCPU -and $_.Capacity -eq 'OK' } | ForEach-Object {
            if (-not $belowMinSpecDict.ContainsKey($_.SKU)) { $belowMinSpecDict[$_.SKU] = $_ }
        }
        $filtered = @($filtered | Where-Object { $_.vCPU -ge $MinvCPU })
    }
    if ($MinMemoryGB) {
        $filtered | Where-Object { $_.MemGiB -lt $MinMemoryGB -and $_.Capacity -eq 'OK' } | ForEach-Object {
            if (-not $belowMinSpecDict.ContainsKey($_.SKU)) { $belowMinSpecDict[$_.SKU] = $_ }
        }
        $filtered = @($filtered | Where-Object { $_.MemGiB -ge $MinMemoryGB })
    }
    $belowMinSpec = @($belowMinSpecDict.Values)

    if ($null -ne $MinScore) {
        $filtered = @($filtered | Where-Object { $_.Score -ge $MinScore })
    }

    if (-not $filtered -or $filtered.Count -eq 0) {
        $RunContext.RecommendOutput = New-RecommendOutputContract -TargetProfile $targetProfile -TargetAvailability @($targetRegionStatus) -RankedRecommendations @() -Warnings @() -BelowMinSpec @($belowMinSpec) -MinScore $MinScore -TopN $TopN -FetchPricing ([bool]$FetchPricing) -ShowPlacement ([bool]$ShowPlacement) -ShowSpot ([bool]$ShowSpot
        )
        if ($JsonOutput) {
            $RunContext.RecommendOutput | ConvertTo-Json -Depth 6
            return
        }

        Write-RecommendOutputContract -Contract $RunContext.RecommendOutput -Icons $Icons -FetchPricing ([bool]$FetchPricing) -FamilyInfo $FamilyInfo -OutputWidth $OutputWidth
        return
    }

    $ranked = $filtered |
    Sort-Object @{Expression = 'Score'; Descending = $true },
    @{Expression = { if ($_.Capacity -eq 'OK') { 0 } elseif ($_.Capacity -eq 'LIMITED') { 1 } else { 2 } } },
    @{Expression = 'ZonesOK'; Descending = $true } |
    Group-Object SKU |
    ForEach-Object { $_.Group | Select-Object -First 1 } |
    Select-Object -First $TopN

    # Ensure a like-for-like (same vCPU count) candidate is always included
    $targetvCPU = [int]$targetProfile.vCPU
    $hasLikeForLike = $ranked | Where-Object { [int]$_.vCPU -eq $targetvCPU }
    if (-not $hasLikeForLike) {
        $likeForLikeCandidate = $filtered |
            Where-Object { [int]$_.vCPU -eq $targetvCPU } |
            Sort-Object @{Expression = 'Score'; Descending = $true } |
            Group-Object SKU |
            ForEach-Object { $_.Group | Select-Object -First 1 } |
            Select-Object -First 1
        if ($likeForLikeCandidate) {
            $ranked = @($ranked) + @($likeForLikeCandidate)
        }
    }

    # Ensure at least one candidate with IOPS >= target (no performance downgrade)
    $targetIOPS = [int]$targetProfile.UncachedDiskIOPS
    if ($targetIOPS -gt 0) {
        $hasIopsMatch = $ranked | Where-Object { [int]$_.IOPS -ge $targetIOPS }
        if (-not $hasIopsMatch) {
            $iopsCandidate = $filtered |
                Where-Object { [int]$_.IOPS -ge $targetIOPS } |
                Sort-Object @{Expression = 'Score'; Descending = $true } |
                Group-Object SKU |
                ForEach-Object { $_.Group | Select-Object -First 1 } |
                Select-Object -First 1
            if ($iopsCandidate) {
                $ranked = @($ranked) + @($iopsCandidate)
            }
        }
    }

    if ($ShowPlacement) {
        $placementScores = Get-PlacementScores -SkuNames @($ranked | Select-Object -ExpandProperty SKU) -Regions @($ranked | Select-Object -ExpandProperty Region) -DesiredCount $DesiredCount -MaxRetries $MaxRetries -Caches $RunContext.Caches
        $ranked = @($ranked | ForEach-Object {
                $item = $_
                $key = "{0}|{1}" -f $item.SKU, $item.Region.ToLower()
                $allocScore = if ($placementScores.ContainsKey($key)) { $placementScores[$key].Score } else { 'N/A' }
                [pscustomobject]@{
                    SKU       = $item.SKU
                    Region    = $item.Region
                    vCPU      = $item.vCPU
                    MemGiB    = $item.MemGiB
                    Family    = $item.Family
                    Purpose   = $item.Purpose
                    Gen       = $item.Gen
                    Arch      = $item.Arch
                    CPU       = $item.CPU
                    Disk      = $item.Disk
                    TempGB    = $item.TempGB
                    AccelNet  = $item.AccelNet
                    MaxDisks  = $item.MaxDisks
                    MaxNICs   = $item.MaxNICs
                    IOPS      = $item.IOPS
                    Score     = $item.Score
                    Capacity  = $item.Capacity
                    AllocScore = $allocScore
                    ZonesOK   = $item.ZonesOK
                    PriceHr   = $item.PriceHr
                    PriceMo   = $item.PriceMo
                    SpotPriceHr = $item.SpotPriceHr
                    SpotPriceMo = $item.SpotPriceMo
                }
            })
    }
    else {
        $ranked = @($ranked | ForEach-Object {
                $item = $_
                [pscustomobject]@{
                    SKU       = $item.SKU
                    Region    = $item.Region
                    vCPU      = $item.vCPU
                    MemGiB    = $item.MemGiB
                    Family    = $item.Family
                    Purpose   = $item.Purpose
                    Gen       = $item.Gen
                    Arch      = $item.Arch
                    CPU       = $item.CPU
                    Disk      = $item.Disk
                    TempGB    = $item.TempGB
                    AccelNet  = $item.AccelNet
                    MaxDisks  = $item.MaxDisks
                    MaxNICs   = $item.MaxNICs
                    IOPS      = $item.IOPS
                    Score     = $item.Score
                    Capacity  = $item.Capacity
                    AllocScore = $null
                    ZonesOK   = $item.ZonesOK
                    PriceHr   = $item.PriceHr
                    PriceMo   = $item.PriceMo
                    SpotPriceHr = $item.SpotPriceHr
                    SpotPriceMo = $item.SpotPriceMo
                }
            })
    }

    # Compatibility warning detection (shared by JSON and console output)
    $compatWarnings = @()
    $uniqueCPUs = @($ranked | Select-Object -ExpandProperty CPU -Unique)
    $uniqueAccelNet = @($ranked | Select-Object -ExpandProperty AccelNet -Unique)
    if ($AllowMixedArch) {
        $uniqueArchs = @($ranked | Select-Object -ExpandProperty Arch -Unique)
        if ($uniqueArchs.Count -gt 1) {
            $compatWarnings += "Mixed architectures (x64 + ARM64) — each requires a separate OS image."
        }
    }
    if ($uniqueCPUs.Count -gt 1) {
        $compatWarnings += "Mixed CPU vendors ($($uniqueCPUs -join ', ')) — performance characteristics vary."
    }
    $hasTempDisk = @($ranked | Where-Object { $_.Disk -match 'T' })
    $noTempDisk = @($ranked | Where-Object { $_.Disk -notmatch 'T' })
    if ($hasTempDisk.Count -gt 0 -and $noTempDisk.Count -gt 0) {
        $compatWarnings += "Mixed temp disk configs — some SKUs have local temp disk, others don't. Drive paths differ."
    }
    $hasNvme = @($ranked | Where-Object { $_.Disk -match 'NV' })
    $hasScsi = @($ranked | Where-Object { $_.Disk -match 'SC' })
    if ($hasNvme.Count -gt 0 -and $hasScsi.Count -gt 0) {
        $compatWarnings += "Mixed storage interfaces (NVMe vs SCSI) — disk driver and device path differences."
    }
    if ($uniqueAccelNet.Count -gt 1) {
        $compatWarnings += "Mixed accelerated networking support — network performance will vary across the inventory."
    }

    $RunContext.RecommendOutput = New-RecommendOutputContract -TargetProfile $targetProfile -TargetAvailability @($targetRegionStatus) -RankedRecommendations @($ranked) -Warnings @($compatWarnings) -BelowMinSpec @($belowMinSpec) -MinScore $MinScore -TopN $TopN -FetchPricing ([bool]$FetchPricing) -ShowPlacement ([bool]$ShowPlacement) -ShowSpot ([bool]$ShowSpot
    )

    if ($JsonOutput) {
        $RunContext.RecommendOutput | ConvertTo-Json -Depth 6
        return
    }

    Write-RecommendOutputContract -Contract $RunContext.RecommendOutput -Icons $Icons -FetchPricing ([bool]$FetchPricing) -FamilyInfo $FamilyInfo -OutputWidth $OutputWidth
}

function Get-ImageRequirements {
    <#
    .SYNOPSIS
        Parses an image URN and determines its Generation and Architecture requirements.
    .DESCRIPTION
        Analyzes the image URN (Publisher:Offer:Sku:Version) to determine if the image
        requires Gen1 or Gen2 VMs, and whether it needs x64 or ARM64 architecture.
        Uses pattern matching on SKU names for common Azure Marketplace images.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageURN
    )

    $parts = $ImageURN -split ':'
    if ($parts.Count -lt 3) {
        return @{ Gen = 'Unknown'; Arch = 'Unknown'; Valid = $false; Error = "Invalid URN format" }
    }

    $publisher = $parts[0]
    $offer = $parts[1]
    $sku = $parts[2]

    # Determine Generation from SKU name patterns
    $gen = 'Gen1'  # Default to Gen1 for compatibility
    if ($sku -match '-gen2|-g2|gen2|_gen2|arm64|aarch64') {
        $gen = 'Gen2'
    }
    elseif ($sku -match '-gen1|-g1|gen1|_gen1') {
        $gen = 'Gen1'
    }
    # Some publishers use different patterns
    elseif ($offer -match 'gen2' -or $publisher -match 'gen2') {
        $gen = 'Gen2'
    }

    # Determine Architecture from SKU name patterns
    $arch = 'x64'  # Default to x64
    if ($sku -match 'arm64|aarch64') {
        $arch = 'ARM64'
    }

    return @{
        Gen       = $gen
        Arch      = $arch
        Publisher = $publisher
        Offer     = $offer
        Sku       = $sku
        Valid     = $true
    }
}

function Get-SkuCapabilities {
    <#
    .SYNOPSIS
        Extracts VM capabilities from a SKU object for compatibility and inventory analysis.
    .DESCRIPTION
        Parses the SKU's Capabilities array to find HyperVGenerations, CpuArchitectureType,
        temp disk size, accelerated networking, NVMe support, max data disks, max NICs,
        ephemeral OS disk support, Ultra SSD availability, uncached disk IOPS/throughput,
        encryption at host, and trusted launch status.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Sku
    )

    $capabilities = @{
        HyperVGenerations            = 'V1'
        CpuArchitecture              = 'x64'
        TempDiskGB                   = 0
        AcceleratedNetworkingEnabled = $false
        NvmeSupport                  = $false
        MaxDataDiskCount             = 0
        MaxNetworkInterfaces         = 1
        EphemeralOSDiskSupported     = $false
        UltraSSDAvailable            = $false
        UncachedDiskIOPS             = 0
        UncachedDiskBytesPerSecond   = 0
        EncryptionAtHostSupported    = $false
        TrustedLaunchDisabled        = $false
        GPUCount                     = 0
    }

    if ($Sku.Capabilities) {
        foreach ($cap in $Sku.Capabilities) {
            switch ($cap.Name) {
                'HyperVGenerations' { $capabilities.HyperVGenerations = $cap.Value }
                'CpuArchitectureType' { $capabilities.CpuArchitecture = $cap.Value }
                'MaxResourceVolumeMB' {
                    $MiBPerGiB = 1024
                    $mb = 0
                    if ([int]::TryParse($cap.Value, [ref]$mb) -and $mb -gt 0) {
                        $capabilities.TempDiskGB = [math]::Round($mb / $MiBPerGiB, 0)
                    }
                }
                'AcceleratedNetworkingEnabled' {
                    $capabilities.AcceleratedNetworkingEnabled = $cap.Value -eq 'True'
                }
                'NvmeDiskSizeInMiB' { $capabilities.NvmeSupport = $true }
                'MaxDataDiskCount' {
                    $val = 0
                    if ([int]::TryParse($cap.Value, [ref]$val)) { $capabilities.MaxDataDiskCount = $val }
                }
                'MaxNetworkInterfaces' {
                    $val = 0
                    if ([int]::TryParse($cap.Value, [ref]$val)) { $capabilities.MaxNetworkInterfaces = $val }
                }
                'EphemeralOSDiskSupported' {
                    $capabilities.EphemeralOSDiskSupported = $cap.Value -eq 'True'
                }
                'UltraSSDAvailable' {
                    $capabilities.UltraSSDAvailable = $cap.Value -eq 'True'
                }
                'UncachedDiskIOPS' {
                    $val = 0
                    if ([int]::TryParse($cap.Value, [ref]$val)) { $capabilities.UncachedDiskIOPS = $val }
                }
                'UncachedDiskBytesPerSecond' {
                    $val = 0
                    if ([long]::TryParse($cap.Value, [ref]$val)) { $capabilities.UncachedDiskBytesPerSecond = $val }
                }
                'EncryptionAtHostSupported' {
                    $capabilities.EncryptionAtHostSupported = $cap.Value -eq 'True'
                }
                'TrustedLaunchDisabled' {
                    $capabilities.TrustedLaunchDisabled = $cap.Value -eq 'True'
                }
                'GPUs' {
                    $val = 0
                    if ([int]::TryParse($cap.Value, [ref]$val)) { $capabilities.GPUCount = $val }
                }
            }
        }
    }

    return $capabilities
}

function Test-ImageSkuCompatibility {
    <#
    .SYNOPSIS
        Tests if a VM SKU is compatible with the specified image requirements.
    .DESCRIPTION
        Compares the image's Generation and Architecture requirements against
        the SKU's capabilities to determine compatibility.
    .OUTPUTS
        Hashtable with Compatible (bool), Reason (string), Gen (string), Arch (string)
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ImageReqs,

        [Parameter(Mandatory = $true)]
        [hashtable]$SkuCapabilities
    )

    $compatible = $true
    $reasons = @()

    # Check Generation compatibility
    $skuGens = $SkuCapabilities.HyperVGenerations -split ','
    $requiredGen = $ImageReqs.Gen
    if ($requiredGen -eq 'Gen2' -and $skuGens -notcontains 'V2') {
        $compatible = $false
        $reasons += "Gen2 required"
    }
    elseif ($requiredGen -eq 'Gen1' -and $skuGens -notcontains 'V1') {
        $compatible = $false
        $reasons += "Gen1 required"
    }

    # Check Architecture compatibility
    $skuArch = $SkuCapabilities.CpuArchitecture
    $requiredArch = $ImageReqs.Arch
    if ($requiredArch -eq 'ARM64' -and $skuArch -ne 'Arm64') {
        $compatible = $false
        $reasons += "ARM64 required"
    }
    elseif ($requiredArch -eq 'x64' -and $skuArch -eq 'Arm64') {
        $compatible = $false
        $reasons += "x64 required"
    }

    # Format the SKU's supported generations for display
    $genDisplay = ($skuGens | ForEach-Object { $_ -replace 'V', '' }) -join ','

    return @{
        Compatible = $compatible
        Reason     = if ($reasons.Count -gt 0) { $reasons -join '; ' } else { 'OK' }
        Gen        = $genDisplay
        Arch       = $skuArch
    }
}

function Get-AzVMPricing {
    <#
    .SYNOPSIS
        Fetches VM pricing from Azure Retail Prices API.
    .DESCRIPTION
        Retrieves pay-as-you-go Linux pricing for VM SKUs in a given region.
        Uses the public Azure Retail Prices API (no auth required).
        Implements caching to minimize API calls.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Region,

        [int]$MaxRetries = 3,

        [int]$HoursPerMonth = 730,

        [hashtable]$AzureEndpoints,

        [string]$TargetEnvironment = 'AzureCloud',

        [System.Collections.IDictionary]$Caches = @{}
    )

    if (-not $Caches.Pricing) {
        $Caches.Pricing = @{}
    }

    $armLocation = $Region.ToLower() -replace '\s', ''

    # Return cached pricing if already fetched this region
    if ($Caches.Pricing.ContainsKey($armLocation) -and $Caches.Pricing[$armLocation]) {
        return $Caches.Pricing[$armLocation]
    }

    # Get environment-specific endpoints (supports sovereign clouds)
    if (-not $AzureEndpoints) {
        $AzureEndpoints = Get-AzureEndpoints -EnvironmentName $TargetEnvironment
    }

    # Build filter for the API - get Linux consumption and reservation pricing
    $filter = "armRegionName eq '$armLocation' and serviceName eq 'Virtual Machines'"

    $regularPrices = @{}
    $spotPrices = @{}
    $savingsPlan1YrPrices = @{}
    $savingsPlan3YrPrices = @{}
    $reservation1YrPrices = @{}
    $reservation3YrPrices = @{}
    $apiUrl = "$($AzureEndpoints.PricingApiUrl)?api-version=2023-01-01-preview&`$filter=$([uri]::EscapeDataString($filter))"

    try {
        $nextLink = $apiUrl
        $pageCount = 0
        $maxPages = 20  # Fetch up to 20 pages (~20,000 price entries)

        while ($nextLink -and $pageCount -lt $maxPages) {
            $uri = $nextLink
            $response = Invoke-WithRetry -MaxRetries $MaxRetries -OperationName "Retail Pricing API (page $($pageCount + 1))" -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 30
            }
            $pageCount++

            foreach ($item in $response.Items) {
                # Filter for Linux pricing, skip Windows, Low Priority, and DevTest
                if ($item.productName -match 'Windows' -or
                    $item.skuName -match 'Low Priority' -or
                    $item.meterName -match 'Low Priority' -or
                    $item.type -eq 'DevTestConsumption') {
                    continue
                }

                # Extract the VM size from armSkuName
                $vmSize = $item.armSkuName
                if (-not $vmSize) { continue }

                if ($item.type -eq 'Reservation') {
                    if ($item.reservationTerm -eq '1 Year' -and -not $reservation1YrPrices[$vmSize]) {
                        $reservation1YrPrices[$vmSize] = @{
                            Total    = [math]::Round($item.retailPrice, 2)
                            Monthly  = [math]::Round($item.retailPrice / 12, 2)
                            Currency = $item.currencyCode
                        }
                    }
                    elseif ($item.reservationTerm -eq '3 Years' -and -not $reservation3YrPrices[$vmSize]) {
                        $reservation3YrPrices[$vmSize] = @{
                            Total    = [math]::Round($item.retailPrice, 2)
                            Monthly  = [math]::Round($item.retailPrice / 36, 2)
                            Currency = $item.currencyCode
                        }
                    }
                    continue
                }

                $isSpot = ($item.skuName -match 'Spot' -or $item.meterName -match 'Spot')
                $targetMap = if ($isSpot) { $spotPrices } else { $regularPrices }

                if (-not $targetMap[$vmSize]) {
                    $targetMap[$vmSize] = @{
                        Hourly   = [math]::Round($item.retailPrice, 4)
                        Monthly  = [math]::Round($item.retailPrice * $HoursPerMonth, 2)
                        Currency = $item.currencyCode
                        Meter    = $item.meterName
                    }
                }

                # Capture savings plan pricing from consumption items
                if (-not $isSpot -and $item.savingsPlan) {
                    foreach ($sp in $item.savingsPlan) {
                        if ($sp.term -eq '1 Year' -and -not $savingsPlan1YrPrices[$vmSize]) {
                            $savingsPlan1YrPrices[$vmSize] = @{
                                Hourly   = [math]::Round($sp.retailPrice, 4)
                                Monthly  = [math]::Round($sp.retailPrice * $HoursPerMonth, 2)
                                Total    = [math]::Round($sp.retailPrice * $HoursPerYear, 2)
                                Currency = $item.currencyCode
                            }
                        }
                        elseif ($sp.term -eq '3 Years' -and -not $savingsPlan3YrPrices[$vmSize]) {
                            $savingsPlan3YrPrices[$vmSize] = @{
                                Hourly   = [math]::Round($sp.retailPrice, 4)
                                Monthly  = [math]::Round($sp.retailPrice * $HoursPerMonth, 2)
                                Total    = [math]::Round($sp.retailPrice * $HoursPer3Years, 2)
                                Currency = $item.currencyCode
                            }
                        }
                    }
                }
            }

            $nextLink = $response.NextPageLink
        }

        $result = [ordered]@{
            Regular          = $regularPrices
            Spot             = $spotPrices
            SavingsPlan1Yr   = $savingsPlan1YrPrices
            SavingsPlan3Yr   = $savingsPlan3YrPrices
            Reservation1Yr   = $reservation1YrPrices
            Reservation3Yr   = $reservation3YrPrices
        }

        $Caches.Pricing[$armLocation] = $result

        return $result
    }
    catch {
        Write-Verbose "Failed to fetch pricing for region $Region`: $_"
        return [ordered]@{
            Regular          = @{}
            Spot             = @{}
            SavingsPlan1Yr   = @{}
            SavingsPlan3Yr   = @{}
            Reservation1Yr   = @{}
            Reservation3Yr   = @{}
        }
    }
}

function Get-RegularPricingMap {
    param(
        [Parameter(Mandatory = $false)]
        [object]$PricingContainer
    )

    if ($null -eq $PricingContainer) {
        return @{}
    }

    if ($PricingContainer -is [array]) {
        $PricingContainer = $PricingContainer[0]
    }

    if ($PricingContainer -is [System.Collections.IDictionary] -and $PricingContainer.Contains('Regular')) {
        return $PricingContainer.Regular
    }

    return $PricingContainer
}

function Get-SpotPricingMap {
    param(
        [Parameter(Mandatory = $false)]
        [object]$PricingContainer
    )

    if ($null -eq $PricingContainer) {
        return @{}
    }

    if ($PricingContainer -is [array]) {
        $PricingContainer = $PricingContainer[0]
    }

    if ($PricingContainer -is [System.Collections.IDictionary] -and $PricingContainer.Contains('Spot')) {
        return $PricingContainer.Spot
    }

    return @{}
}

function Get-SavingsPlanPricingMap {
    param(
        [Parameter(Mandatory = $false)]
        [object]$PricingContainer,
        [Parameter(Mandatory = $true)]
        [ValidateSet('1Yr','3Yr')]
        [string]$Term
    )

    if ($null -eq $PricingContainer) { return @{} }
    if ($PricingContainer -is [array]) { $PricingContainer = $PricingContainer[0] }

    $key = "SavingsPlan$Term"
    if ($PricingContainer -is [System.Collections.IDictionary] -and $PricingContainer.Contains($key)) {
        return $PricingContainer[$key]
    }
    return @{}
}

function Get-ReservationPricingMap {
    param(
        [Parameter(Mandatory = $false)]
        [object]$PricingContainer,
        [Parameter(Mandatory = $true)]
        [ValidateSet('1Yr','3Yr')]
        [string]$Term
    )

    if ($null -eq $PricingContainer) { return @{} }
    if ($PricingContainer -is [array]) { $PricingContainer = $PricingContainer[0] }

    $key = "Reservation$Term"
    if ($PricingContainer -is [System.Collections.IDictionary] -and $PricingContainer.Contains($key)) {
        return $PricingContainer[$key]
    }
    return @{}
}

function Get-PlacementScores {
    <#
    .SYNOPSIS
        Retrieves Azure VM placement likelihood scores for SKU and region combinations.
    .DESCRIPTION
        Calls Invoke-AzSpotPlacementScore (API name includes "Spot", but returned placement
        signal is broadly useful for VM allocation planning). Returns a hashtable keyed by
        "sku|region" with score metadata.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DesiredCount', Justification = 'Used inside Invoke-WithRetry scriptblock closure')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'IncludeAvailabilityZone', Justification = 'Used inside Invoke-WithRetry scriptblock closure')]
    param(
        [Parameter(Mandatory)]
        [string[]]$SkuNames,

        [Parameter(Mandatory)]
        [string[]]$Regions,

        [ValidateRange(1, 1000)]
        [int]$DesiredCount = 1,

        [switch]$IncludeAvailabilityZone,

        [int]$MaxRetries = 3,

        [System.Collections.IDictionary]$Caches = @{}
    )

    $scores = @{}
    $uniqueSkus = @($SkuNames | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $uniqueRegions = @($Regions | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ } | Select-Object -Unique)
    if ($uniqueSkus.Count -gt 5) {
        Write-Verbose "Placement score: truncating from $($uniqueSkus.Count) to 5 SKUs (API limit)."
    }
    if ($uniqueRegions.Count -gt 8) {
        Write-Verbose "Placement score: truncating from $($uniqueRegions.Count) to 8 regions (API limit)."
    }
    $normalizedSkus = @($uniqueSkus | Select-Object -First 5)
    $normalizedRegions = @($uniqueRegions | Select-Object -First 8)

    if ($normalizedSkus.Count -eq 0 -or $normalizedRegions.Count -eq 0) {
        return $scores
    }

    if (-not (Get-Command -Name 'Invoke-AzSpotPlacementScore' -ErrorAction SilentlyContinue)) {
        Write-Verbose 'Invoke-AzSpotPlacementScore is not available in the current Az.Compute module.'
        return $scores
    }

    try {
        $response = Invoke-WithRetry -MaxRetries $MaxRetries -OperationName 'Spot Placement Score API' -ScriptBlock {
            Invoke-AzSpotPlacementScore -Location $normalizedRegions -Sku $normalizedSkus -DesiredCount $DesiredCount -IsZonePlacement:$IncludeAvailabilityZone.IsPresent -ErrorAction Stop
        }
    }
    catch {
        $errorText = $_.Exception.Message
        $isForbidden = $errorText -match '403|forbidden|authorization|not authorized|insufficient privileges'
        if ($isForbidden) {
            if (-not $Caches.PlacementWarned403) {
                Write-Warning 'Placement score lookup skipped: missing permissions (Compute Recommendations Role).'
                $Caches.PlacementWarned403 = $true
            }
            return $scores
        }

        Write-Verbose "Failed to retrieve placement scores: $errorText"
        return $scores
    }

    $rows = @()
    if ($null -eq $response) {
        return $scores
    }

    if ($response -is [System.Collections.IEnumerable] -and $response -isnot [string]) {
        $rows = @($response)
    }
    else {
        $rows = @($response)
    }

    foreach ($row in $rows) {
        if ($null -eq $row) { continue }

        $sku = @($row.Sku, $row.SkuName, $row.VmSize, $row.ArmSkuName) | Where-Object { $_ } | Select-Object -First 1
        $region = @($row.Region, $row.Location, $row.ArmRegionName) | Where-Object { $_ } | Select-Object -First 1
        $score = @($row.Score, $row.PlacementScore, $row.AvailabilityScore) | Where-Object { $_ } | Select-Object -First 1

        if (-not $sku -or -not $region) { continue }

        $key = "$sku|$($region.ToString().ToLower())"
        $scores[$key] = [pscustomobject]@{
            Score        = if ($score) { $score.ToString() } else { 'N/A' }
            IsAvailable  = if ($null -ne $row.IsAvailable) { [bool]$row.IsAvailable } else { $null }
            IsRestricted = if ($null -ne $row.IsRestricted) { [bool]$row.IsRestricted } else { $null }
        }
    }

    return $scores
}

function Get-AzActualPricing {
    <#
    .SYNOPSIS
        Retrieves negotiated VM pricing using a tiered API strategy.
    .DESCRIPTION
        Tier 1: Consumption Price Sheet API — returns negotiated unitPrice AND
        retail pretaxStandardRate for ALL meters (deployed or not). Works for
        EA and MCA billing types.

        Tier 2: Cost Management Query API — derives effective hourly rate from
        actual month-to-date usage (cost / hours). Works for ALL billing types
        but only covers currently-deployed SKUs.

        Returns a hashtable keyed by ARM SKU name (e.g. Standard_D2s_v3) with
        Hourly, Monthly, Currency, Meter, and IsNegotiated fields.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$Region,

        [int]$MaxRetries = 3,

        [int]$HoursPerMonth = 730,

        [hashtable]$AzureEndpoints,

        [string]$TargetEnvironment = 'AzureCloud',

        [System.Collections.IDictionary]$Caches = @{}
    )

    if (-not $Caches.ActualPricing) {
        $Caches.ActualPricing = @{}
    }

    $armLocation = $Region.ToLower() -replace '\s', ''

    # Price Sheet meterLocation uses abbreviated names for gov/sovereign regions
    # that don't match ARM region names. This map provides fallback lookups.
    $armToMeterLocation = @{
        'usgovarizona'  = 'usgovaz'
        'usgovtexas'    = 'usgovtx'
        'usgovvirginia' = 'usgov'
        'usdodcentral'  = 'usdod'
        'usdodeast'     = 'usdod'
    }

    # ── Disk cache ──
    # EA/MCA negotiated rates are enrollment-level (tenant-scoped). Cache by
    # TenantId so all subscriptions in the same tenant share one cache file.
    $PriceSheetCacheTTLDays = 30
    $tenantId = try { (Get-AzContext -ErrorAction SilentlyContinue).Tenant.Id } catch { $null }
    $cacheKey = if ($tenantId) { $tenantId } else { $SubscriptionId }
    $cacheDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $cacheFile = Join-Path $cacheDir "AzVMLifecycle-PriceSheet-$cacheKey.json"

    # EA/MCA negotiated rates are set at the enrollment level — identical across
    # all subscriptions. Page through the Price Sheet once, group all Linux VM
    # meters by meterLocation, and serve every subsequent region from cache.
    if ($Caches.ActualPricing.ContainsKey('AllRegions')) {
        $allRegionPrices = $Caches.ActualPricing['AllRegions']
        $lookupKey = if ($allRegionPrices.ContainsKey($armLocation)) { $armLocation }
                     elseif ($armToMeterLocation.ContainsKey($armLocation)) { $armToMeterLocation[$armLocation] }
                     else { $null }
        $regionPrices = if ($lookupKey) { $allRegionPrices[$lookupKey] } else { @{} }
        if ($regionPrices.Count -gt 0) {
            Write-Host "  Tier 1 (Price Sheet): $($regionPrices.Count) negotiated SKU prices for '$Region' (cached)" -ForegroundColor DarkGray
        }
        return $regionPrices
    }

    # Check disk cache before calling the API
    if (Test-Path $cacheFile) {
        try {
            $cacheAge = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
            if ($cacheAge.TotalDays -le $PriceSheetCacheTTLDays) {
                $ageDays = [math]::Floor($cacheAge.TotalDays)
                $ageLabel = if ($ageDays -eq 0) { 'today' } elseif ($ageDays -eq 1) { '1 day old' } else { "$ageDays days old" }
                Write-Host "  Loading cached discounted pricing data ($ageLabel)..." -ForegroundColor DarkGray
                $allRegionPrices = Get-Content $cacheFile -Raw | ConvertFrom-Json -AsHashtable
                $Caches.ActualPricing['AllRegions'] = $allRegionPrices
                $totalSkus = ($allRegionPrices.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
                Write-Host "  Tier 1 (Price Sheet): $totalSkus negotiated SKU prices across $($allRegionPrices.Count) region(s) (from cache file)" -ForegroundColor DarkGray

                $lookupKey = if ($allRegionPrices.ContainsKey($armLocation)) { $armLocation }
                             elseif ($armToMeterLocation.ContainsKey($armLocation)) { $armToMeterLocation[$armLocation] }
                             else { $null }
                $regionPrices = if ($lookupKey) { $allRegionPrices[$lookupKey] } else { @{} }
                return $regionPrices
            }
            else {
                Write-Verbose "Price Sheet cache expired ($([math]::Floor($cacheAge.TotalDays)) days old, TTL=$PriceSheetCacheTTLDays days). Refreshing from API."
            }
        }
        catch {
            Write-Verbose "Price Sheet cache file unreadable, will refresh from API: $($_.Exception.Message)"
        }
    }

    if (-not $AzureEndpoints) {
        $AzureEndpoints = Get-AzureEndpoints -EnvironmentName $TargetEnvironment
    }
    $armUrl = $AzureEndpoints.ResourceManagerUrl

    $token = $null
    $headers = $null
    try {
        $token = (Get-AzAccessToken -ResourceUrl $armUrl -ErrorAction Stop).Token
        $headers = @{
            'Authorization' = "Bearer $token"
            'Content-Type'  = 'application/json'
        }
    }
    catch {
        if (-not $Caches.NegotiatedPricingWarned) {
            $Caches.NegotiatedPricingWarned = $true
            Write-Warning "Cost Management: cannot obtain access token. Run: Connect-AzAccount"
            Write-Warning "Falling back to retail pricing (public list prices without negotiated discounts)."
        }
        return $null
    }

    # ── Tier 1: Consumption Price Sheet API ──
    # Returns negotiated unitPrice for ALL meters (deployed or not).
    # pretaxStandardRate = retail listing price (for discount calculation).
    # Requires $expand=properties/meterDetails to populate category/region/meter fields.
    # Only works for EA/MCA billing; returns 404 for PAYG/Sponsorship/MSDN.
    $tier1Success = $false
    $allRegionPrices = @{}
    $MaxPricesheetPages = 500
    $EstimatedPages = 500
    try {
        $psUrl = "$armUrl/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/pricesheets/default?api-version=2023-05-01&`$expand=properties/meterDetails&`$top=1000"
        Write-Verbose "Tier 1 (Price Sheet): calling $psUrl"
        Write-Host "  Initial download of discounted pricing data (~15-20 min, one-time)..." -ForegroundColor Cyan
        Write-Host "  Subsequent runs will use cached data (valid $PriceSheetCacheTTLDays days)." -ForegroundColor DarkGray

        $totalItems = 0
        $pageCount = 0
        $totalVmMeters = 0
        $unitMeasureCounts = @{}
        $firstVmPage = 0
        $lastVmPage = 0
        $vmMetersPerPage = @{}
        $scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            $pageCount++
            $pctComplete = [math]::Min(99, [math]::Floor(($pageCount / $EstimatedPages) * 100))
            $elapsed = $scanStopwatch.Elapsed
            $elapsedStr = '{0:mm\:ss}' -f $elapsed
            if ($pageCount -gt 2) {
                $secsPerPage = $elapsed.TotalSeconds / ($pageCount - 1)
                $remainPages = [math]::Max(0, $EstimatedPages - $pageCount)
                $etaSecs = [math]::Ceiling($secsPerPage * $remainPages)
                $etaMin = [math]::Floor($etaSecs / 60)
                $etaSec = $etaSecs % 60
                $etaStr = if ($etaMin -gt 0) { "${etaMin}m ${etaSec}s remaining" } else { "${etaSec}s remaining" }
            }
            else {
                $etaStr = 'estimating...'
            }
            Write-Progress -Activity "Downloading discounted pricing data" -Status "Page $pageCount — $totalVmMeters VM SKUs found — $elapsedStr elapsed — $etaStr" -PercentComplete $pctComplete

            $psResponse = Invoke-WithRetry -MaxRetries $MaxRetries -OperationName "Consumption Price Sheet (page $pageCount)" -ScriptBlock {
                Invoke-RestMethod -Uri $psUrl -Method Get -Headers $headers -TimeoutSec 120
            }

            if ($psResponse.properties.pricesheets) {
                $totalItems += $psResponse.properties.pricesheets.Count
                $pageVmCount = 0
                foreach ($item in $psResponse.properties.pricesheets) {
                    $md = $item.meterDetails
                    if (-not $md) { continue }

                    if ($md.meterCategory -ne 'Virtual Machines') { continue }
                    if ($md.meterSubCategory -match 'Windows') { continue }

                    $meterLoc = $md.meterLocation
                    $normalizedRegion = ($meterLoc -replace '[\s-]', '').ToLower()
                    if (-not $normalizedRegion) { continue }

                    $cleanName = $md.meterName -replace '\s+(Low Priority|Spot)\s*$', ''
                    $cleanName = $cleanName.Trim() -replace '^Standard[\s_]+', ''
                    if ($cleanName -notmatch '^[A-Z]') { continue }
                    $vmSize = "Standard_$($cleanName -replace '\s+', '_')"

                    # Determine the hourly divisor from unitOfMeasure
                    $unitOfMeasure = if ($item.unitOfMeasure) { $item.unitOfMeasure }
                                     elseif ($md.unit) { $md.unit }
                                     else { '1 Hour' }
                    $unitKey = $unitOfMeasure.Trim()
                    if ($unitMeasureCounts.ContainsKey($unitKey)) { $unitMeasureCounts[$unitKey]++ } else { $unitMeasureCounts[$unitKey] = 1 }

                    $hourlyDivisor = switch -Regex ($unitKey) {
                        '^\d+\s+Hour'  { if ($unitKey -match '^(\d+)') { [double]$Matches[1] } else { 1 } }
                        'Month'        { $HoursPerMonth }
                        'Day'          { 24 }
                        default        { 1 }
                    }

                    if (-not $allRegionPrices.ContainsKey($normalizedRegion)) {
                        $allRegionPrices[$normalizedRegion] = @{}
                    }

                    if (-not $allRegionPrices[$normalizedRegion].ContainsKey($vmSize)) {
                        $rawRate = [double]$item.unitPrice
                        $negotiatedRate = $rawRate / $hourlyDivisor
                        $retailRate = if ($md.pretaxStandardRate) { [double]$md.pretaxStandardRate / $hourlyDivisor } else { $null }

                        $allRegionPrices[$normalizedRegion][$vmSize] = @{
                            Hourly       = [math]::Round($negotiatedRate, 4)
                            Monthly      = [math]::Round($negotiatedRate * $HoursPerMonth, 2)
                            Currency     = $item.currencyCode
                            Meter        = $md.meterName
                            IsNegotiated = $true
                        }
                        if ($retailRate -and $retailRate -gt 0) {
                            $allRegionPrices[$normalizedRegion][$vmSize].RetailHourly = [math]::Round($retailRate, 4)
                            $allRegionPrices[$normalizedRegion][$vmSize].DiscountPct  = [math]::Round((1 - ($negotiatedRate / $retailRate)) * 100, 1)
                        }
                        $totalVmMeters++
                        $pageVmCount++
                    }
                }
                if ($pageVmCount -gt 0) {
                    $vmMetersPerPage[$pageCount] = $pageVmCount
                    if ($firstVmPage -eq 0) { $firstVmPage = $pageCount }
                    $lastVmPage = $pageCount
                }
            }

            $psUrl = $psResponse.properties.nextLink
        } while ($psUrl -and $pageCount -lt $MaxPricesheetPages)

        if ($totalVmMeters -gt 0) {
            $tier1Success = $true
            $scanStopwatch.Stop()
            Write-Progress -Activity "Downloading discounted pricing data" -Completed
            $scanDuration = $scanStopwatch.Elapsed
            $scanDurationStr = '{0:mm\:ss}' -f $scanDuration
            $Caches.ActualPricing['AllRegions'] = $allRegionPrices

            # Persist to disk so subsequent runs skip the API entirely
            try {
                $cacheJson = ConvertTo-Json -InputObject $allRegionPrices -Depth 4 -Compress
                $tmpFile = "$cacheFile.tmp"
                [System.IO.File]::WriteAllText($tmpFile, $cacheJson, [System.Text.Encoding]::UTF8)
                Move-Item -Path $tmpFile -Destination $cacheFile -Force
                $cacheSizeMB = [math]::Round((Get-Item $cacheFile).Length / 1MB, 1)
                Write-Host "  Pricing data cached to disk (${cacheSizeMB}MB, valid $PriceSheetCacheTTLDays days): $cacheFile" -ForegroundColor DarkGray
            }
            catch {
                Write-Warning "Could not write Price Sheet cache file: $($_.Exception.Message)"
                Write-Verbose "Cache path: $cacheFile"
            }

            $locationSummary = ($allRegionPrices.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | ForEach-Object { "'$($_.Key)' ($($_.Value.Count))" }) -join ', '
            Write-Host "  Tier 1 (Price Sheet): $totalVmMeters negotiated SKU prices across $($allRegionPrices.Count) region(s) in $scanDurationStr" -ForegroundColor DarkGray
            Write-Verbose "Tier 1 (Price Sheet): $totalItems items across $pageCount page(s), $totalVmMeters VM SKU prices."
            Write-Verbose "  Regions: $locationSummary"
            $unitSummary = ($unitMeasureCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "'$($_.Key)' ($($_.Value))" }) -join ', '
            Write-Verbose "  unitOfMeasure values: $unitSummary"
            $sampleDiscount = $null
            foreach ($rp in $allRegionPrices.Values) {
                $sampleDiscount = $rp.Values | Where-Object { $_.DiscountPct } | Select-Object -First 1
                if ($sampleDiscount) { break }
            }
            if ($sampleDiscount) {
                Write-Verbose "  Sample discount: $($sampleDiscount.DiscountPct)% off retail"
            }
            Write-Verbose "  VM meter page distribution: first=$firstVmPage, last=$lastVmPage of $pageCount pages"
            if ($vmMetersPerPage.Count -gt 0) {
                $pagesWithVMs = $vmMetersPerPage.Count
                $pagesWithoutVMs = $pageCount - $pagesWithVMs
                Write-Verbose "  Pages with VM meters: $pagesWithVMs/$pageCount ($pagesWithoutVMs empty pages)"
            }
        }
        else {
            Write-Progress -Activity "Downloading discounted pricing data" -Completed
            $scanStopwatch.Stop()
            Write-Host "  Tier 1 (Price Sheet): no VM matches ($totalItems items across $pageCount pages). Trying Tier 2..." -ForegroundColor DarkGray
            Write-Verbose "Tier 1 (Price Sheet): $totalItems items across $pageCount page(s), 0 VM matches. Falling through to Tier 2."
        }
    }
    catch {
        Write-Progress -Activity "Downloading discounted pricing data" -Completed
        $psError = $_
        $psStatus = $null
        if ($psError.Exception.Response) { $psStatus = [int]$psError.Exception.Response.StatusCode }
        if (-not $psStatus -and $psError.Exception.Message -match '(\d{3})') { $psStatus = [int]$Matches[1] }
        Write-Host "  Tier 1 (Price Sheet): failed$(if ($psStatus) { " (HTTP $psStatus)" }) — trying Tier 2..." -ForegroundColor DarkGray
        Write-Verbose "Tier 1 (Price Sheet) failed$(if ($psStatus) { " (HTTP $psStatus)" }): $($psError.Exception.Message). Falling through to Tier 2."
    }

    # ── Tier 2: Cost Management Query API ──
    # Derives effective rate from actual usage. Covers deployed SKUs only.
    # Works for all billing types (EA, MCA, CSP, PAYG).
    # Tier 2 is region-specific (filters by ResourceLocation) since Cost Management
    # doesn't support unfiltered queries efficiently.
    if (-not $tier1Success) {
        try {
            $queryBody = @{
                type      = 'ActualCost'
                timeframe = 'MonthToDate'
                dataset   = @{
                    granularity = 'None'
                    aggregation = @{
                        PreTaxCost    = @{ name = 'PreTaxCost';    function = 'Sum' }
                        UsageQuantity = @{ name = 'UsageQuantity'; function = 'Sum' }
                    }
                    filter = @{
                        dimensions = @{ name = 'MeterCategory'; operator = 'In'; values = @('Virtual Machines') }
                    }
                    grouping = @(
                        @{ type = 'Dimension'; name = 'MeterSubcategory' }
                        @{ type = 'Dimension'; name = 'Meter' }
                    )
                }
            } | ConvertTo-Json -Depth 10

            $queryUrl = "$armUrl/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

            $cmResponse = Invoke-WithRetry -MaxRetries $MaxRetries -OperationName 'Cost Management Query' -ScriptBlock {
                Invoke-RestMethod -Uri $queryUrl -Method Post -Headers $headers -Body $queryBody -ContentType 'application/json' -TimeoutSec 60
            }

            $colMap = @{}
            for ($i = 0; $i -lt $cmResponse.properties.columns.Count; $i++) {
                $colMap[$cmResponse.properties.columns[$i].name] = $i
            }

            $costIdx   = $colMap['PreTaxCost']
            $qtyIdx    = $colMap['UsageQuantity']
            $subCatIdx = $colMap['MeterSubcategory']
            $meterIdx  = $colMap['Meter']
            $currIdx   = if ($colMap.ContainsKey('Currency')) { $colMap['Currency'] } else { $null }

            $rowCount = if ($cmResponse.properties.rows) { $cmResponse.properties.rows.Count } else { 0 }

            foreach ($row in $cmResponse.properties.rows) {
                $cost        = [double]$row[$costIdx]
                $quantity    = [double]$row[$qtyIdx]
                $subCategory = $row[$subCatIdx]
                $meterName   = $row[$meterIdx]
                $currency    = if ($null -ne $currIdx) { $row[$currIdx] } else { 'USD' }

                if ($subCategory -match 'Windows') { continue }
                if ($quantity -le 0 -or $cost -le 0) { continue }

                $hourlyRate = $cost / $quantity

                $cleanName = $meterName -replace '\s+(Low Priority|Spot)\s*$', ''
                $cleanName = $cleanName.Trim() -replace '^Standard[\s_]+', ''
                if ($cleanName -match '^[A-Z]') {
                    $vmSize = "Standard_$($cleanName -replace '\s+', '_')"
                }
                else { continue }

                if (-not $allRegionPrices.ContainsKey($armLocation)) {
                    $allRegionPrices[$armLocation] = @{}
                }
                if (-not $allRegionPrices[$armLocation].ContainsKey($vmSize)) {
                    $allRegionPrices[$armLocation][$vmSize] = @{
                        Hourly       = [math]::Round($hourlyRate, 4)
                        Monthly      = [math]::Round($hourlyRate * $HoursPerMonth, 2)
                        Currency     = $currency
                        Meter        = $meterName
                        IsNegotiated = $true
                    }
                }
            }

            $tier2Count = if ($allRegionPrices[$armLocation]) { $allRegionPrices[$armLocation].Count } else { 0 }
            Write-Host "  Tier 2 (Cost Query): $tier2Count SKU prices from $rowCount usage rows for '$Region'" -ForegroundColor DarkGray
            Write-Verbose "Tier 2 (Cost Query): $rowCount usage rows, $tier2Count VM SKU prices for region '$armLocation'."
        }
        catch {
            $errorMsg = $_.Exception.Message
            $statusCode = $null
            if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
            if (-not $statusCode -and $errorMsg -match '(\d{3})') { $statusCode = [int]$Matches[1] }

            if (-not $Caches.NegotiatedPricingWarned) {
                $Caches.NegotiatedPricingWarned = $true

                switch ($statusCode) {
                    401 {
                        Write-Warning "Cost Management: authentication failed (HTTP 401). Run: Connect-AzAccount"
                    }
                    403 {
                        Write-Warning "Cost Management: access denied (HTTP 403). Required RBAC (any one):"
                        Write-Warning "  - Cost Management Reader  (scope: subscription)"
                        Write-Warning "  - Reader                   (scope: subscription)"
                        Write-Warning "  To assign:  New-AzRoleAssignment -SignInName <user@domain> -RoleDefinitionName 'Cost Management Reader' -Scope /subscriptions/$SubscriptionId"
                    }
                    {$_ -in 429, 503} {
                        Write-Warning "Cost Management: throttled/unavailable (HTTP $statusCode). Retries exhausted."
                    }
                    default {
                        Write-Warning "Cost Management failed$(if ($statusCode) { " (HTTP $statusCode)" }): $errorMsg"
                    }
                }
                Write-Warning "Falling back to retail pricing (public list prices without negotiated discounts)."
            }

            $headers['Authorization'] = $null
            $token = $null
            return $null
        }
    }

    $headers['Authorization'] = $null
    $token = $null

    $lookupKey = if ($allRegionPrices.ContainsKey($armLocation)) { $armLocation }
                 elseif ($armToMeterLocation.ContainsKey($armLocation)) { $armToMeterLocation[$armLocation] }
                 else { $null }
    $regionPrices = if ($lookupKey) { $allRegionPrices[$lookupKey] } else { @{} }
    return $regionPrices
}


#endregion Inline Function Definitions
}

function ConvertTo-ExcelColumnLetter {
    param([int]$ColumnNumber)
    $letter = ''
    while ($ColumnNumber -gt 0) {
        $mod = ($ColumnNumber - 1) % 26
        $letter = [char](65 + $mod) + $letter
        $ColumnNumber = [math]::Floor(($ColumnNumber - 1) / 26)
    }
    return $letter
}

#endregion Module Import / Inline Fallback
#region Initialize Azure Endpoints
$script:AzureEndpoints = Get-AzureEndpoints -EnvironmentName $script:TargetEnvironment
if (-not $script:RunContext) {
    $script:RunContext = [pscustomobject]@{}
}
if (-not ($script:RunContext.PSObject.Properties.Name -contains 'AzureEndpoints')) {
    Add-Member -InputObject $script:RunContext -MemberType NoteProperty -Name AzureEndpoints -Value $null
}
$script:RunContext.AzureEndpoints = $script:AzureEndpoints

#endregion Initialize Azure Endpoints
#region Interactive Prompts
# Prompt user for subscription(s) if not provided via parameters

if (-not $TargetSubIds) {
    if (-not $Interactive) {
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($ctx -and $ctx.Subscription.Id) {
            $TargetSubIds = @($ctx.Subscription.Id)
            Write-Host "Using current subscription: $($ctx.Subscription.Name)" -ForegroundColor Cyan
        }
        else {
            Write-Host "ERROR: No subscription context. Run Connect-AzAccount or specify -SubscriptionId" -ForegroundColor Red
            throw "No subscription context available. Run Connect-AzAccount or specify -SubscriptionId."
        }
    }
    else {
        $allSubs = Get-AzSubscription | Select-Object Name, Id, State
        Write-Host "`nSTEP 1: SELECT SUBSCRIPTION(S)" -ForegroundColor Green
        Write-Host ("=" * 60) -ForegroundColor Gray

        for ($i = 0; $i -lt $allSubs.Count; $i++) {
            Write-Host "$($i + 1). $($allSubs[$i].Name)" -ForegroundColor Cyan
            Write-Host "   $($allSubs[$i].Id)" -ForegroundColor DarkGray
        }

        Write-Host "`nEnter number(s) separated by commas (e.g., 1,3) or press Enter for #1:" -ForegroundColor Yellow
        $selection = Read-Host "Selection"

        if ([string]::IsNullOrWhiteSpace($selection)) {
            $TargetSubIds = @($allSubs[0].Id)
        }
        else {
            $nums = $selection -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
            $TargetSubIds = @($nums | ForEach-Object { $allSubs[$_ - 1].Id })
        }

        Write-Host "`nSelected: $($TargetSubIds.Count) subscription(s)" -ForegroundColor Green
    }
}

if (-not $Regions) {
    if (-not $Interactive) {
        $Regions = @('eastus', 'eastus2', 'centralus')
        Write-Host "Using default regions: $($Regions -join ', ')" -ForegroundColor Cyan
    }
    else {
        Write-Host "`nSTEP 2: SELECT REGION(S)" -ForegroundColor Green
        Write-Host ("=" * 100) -ForegroundColor Gray
        Write-Host ""
        Write-Host "FAST PATH: Type region codes now to skip the long list (comma/space separated)" -ForegroundColor Yellow
        Write-Host "Examples: eastus eastus2 westus3  |  Press Enter to show full menu" -ForegroundColor DarkGray
        Write-Host "Press Enter for defaults: eastus, eastus2, centralus" -ForegroundColor DarkGray
        $quickRegions = Read-Host "Enter region codes or press Enter to load the menu"

        if (-not [string]::IsNullOrWhiteSpace($quickRegions)) {
            $Regions = @($quickRegions -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.ToLower() })
            Write-Host "`nSelected regions (fast path): $($Regions -join ', ')" -ForegroundColor Green
        }
        else {
            # Show full region menu with geo-grouping
            Write-Host ""
            Write-Host "Available regions (filtered for Compute):" -ForegroundColor Cyan

            $geoOrder = @('Americas-US', 'Americas-Canada', 'Americas-LatAm', 'Europe', 'Asia-Pacific', 'India', 'Middle East', 'Africa', 'Australia', 'Other')

            $locations = Get-AzLocation | Where-Object { $_.Providers -contains 'Microsoft.Compute' } |
            ForEach-Object { $_ | Add-Member -NotePropertyName GeoGroup -NotePropertyValue (Get-GeoGroup $_.Location) -PassThru } |
            Sort-Object @{e = { $idx = $geoOrder.IndexOf($_.GeoGroup); if ($idx -ge 0) { $idx } else { 999 } } }, @{e = { $_.DisplayName } }

            Write-Host ""
            for ($i = 0; $i -lt $locations.Count; $i++) {
                Write-Host "$($i + 1). [$($locations[$i].GeoGroup)] $($locations[$i].DisplayName)" -ForegroundColor Cyan
                Write-Host "   Code: $($locations[$i].Location)" -ForegroundColor DarkGray
            }

            Write-Host ""
            Write-Host "INSTRUCTIONS:" -ForegroundColor Yellow
            Write-Host "  - Enter number(s) separated by commas (e.g., '1,5,10')" -ForegroundColor White
            Write-Host "  - Or use spaces (e.g., '1 5 10')" -ForegroundColor White
            Write-Host "  - Press Enter for defaults: eastus, eastus2, centralus" -ForegroundColor White
            Write-Host ""
            $regionsInput = Read-Host "Select region(s)"

            if ([string]::IsNullOrWhiteSpace($regionsInput)) {
                $Regions = @('eastus', 'eastus2', 'centralus')
                Write-Host "`nSelected regions (default): $($Regions -join ', ')" -ForegroundColor Green
            }
            else {
                $selectedNumbers = $regionsInput -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }

                if ($selectedNumbers.Count -eq 0) {
                    Write-Host "ERROR: No valid selections entered" -ForegroundColor Red
                    throw "No valid region selections entered."
                }

                $invalidNumbers = $selectedNumbers | Where-Object { $_ -lt 1 -or $_ -gt $locations.Count }
                if ($invalidNumbers.Count -gt 0) {
                    Write-Host "ERROR: Invalid selection(s): $($invalidNumbers -join ', '). Valid range is 1-$($locations.Count)" -ForegroundColor Red
                    throw "Invalid region selection(s): $($invalidNumbers -join ', '). Valid range is 1-$($locations.Count)."
                }

                $selectedNumbers = @($selectedNumbers | Sort-Object -Unique)
                $Regions = @()
                foreach ($num in $selectedNumbers) {
                    $Regions += $locations[$num - 1].Location
                }

                Write-Host "`nSelected regions:" -ForegroundColor Green
                foreach ($num in $selectedNumbers) {
                    Write-Host "  $($Icons.Check) $($locations[$num - 1].DisplayName) ($($locations[$num - 1].Location))" -ForegroundColor Green
                }
            }
        }
    }
}
else {
    $Regions = @($Regions | ForEach-Object { $_.ToLower() })
}

# Validate regions against Azure's available regions
$validRegions = if ($SkipRegionValidation) { $null } else { Get-ValidAzureRegions -MaxRetries $MaxRetries -AzureEndpoints $script:AzureEndpoints -Caches $script:RunContext.Caches }

$invalidRegions = @()
$validatedRegions = @()

# If region validation is skipped or failed entirely
if ($SkipRegionValidation) {
    Write-Warning "Region validation explicitly skipped via -SkipRegionValidation."
    $validatedRegions = $Regions
}
elseif ($null -eq $validRegions -or $validRegions.Count -eq 0) {
    if (-not $Interactive) {
        Write-Host "`nERROR: Region validation is unavailable." -ForegroundColor Red
        Write-Host "Use valid regions when connectivity is restored, or explicitly set -SkipRegionValidation to override." -ForegroundColor Yellow
        throw "Region validation unavailable. Use -SkipRegionValidation to override."
    }

    Write-Warning "Region validation unavailable — proceeding with user-provided regions in interactive mode."
    $validatedRegions = $Regions
}
else {
    foreach ($region in $Regions) {
        if ($validRegions -contains $region) {
            $validatedRegions += $region
        }
        elseif ($script:TrustedRegions -and $script:TrustedRegions.Contains($region)) {
            # Region discovered from ARG or input file — VMs are deployed there, trust it
            Write-Verbose "Region '$region' not in locations API but trusted (discovered from deployed VMs)"
            $validatedRegions += $region
        }
        else {
            $invalidRegions += $region
        }
    }
}

if ($invalidRegions.Count -gt 0) {
    Write-Host "`nWARNING: Invalid or unsupported region(s) detected:" -ForegroundColor Yellow
    foreach ($invalid in $invalidRegions) {
        Write-Host "  $($Icons.Error) $invalid (not found or does not support Compute)" -ForegroundColor Red
    }
    Write-Host "`nValid regions have been retained. To see all available regions, run:" -ForegroundColor Gray
    Write-Host "  Get-AzLocation | Where-Object { `$_.Providers -contains 'Microsoft.Compute' } | Select-Object Location, DisplayName" -ForegroundColor DarkGray
}

if ($validatedRegions.Count -eq 0) {
    Write-Host "`nERROR: No valid regions to scan. Please specify valid Azure region names." -ForegroundColor Red
    Write-Host "Example valid regions: eastus, westus2, centralus, westeurope, eastasia" -ForegroundColor Gray
    throw "No valid regions to scan. Specify valid Azure region names."
}

$Regions = $validatedRegions

# Validate region count limit (skip for lifecycle scans — all deployed regions need pricing)
$maxRegions = 5
if ($Regions.Count -gt $maxRegions -and -not $lifecycleEntries) {
    if (-not $Interactive) {
        # Auto-truncate with warning (don't hang on Read-Host)
        Write-Host "`nWARNING: " -ForegroundColor Yellow -NoNewline
        Write-Host "Specified $($Regions.Count) regions exceeds maximum of $maxRegions. Auto-truncating." -ForegroundColor White
        $Regions = @($Regions[0..($maxRegions - 1)])
        Write-Host "Proceeding with: $($Regions -join ', ')" -ForegroundColor Green
    }
    else {
        Write-Host "`n" -NoNewline
        Write-Host "WARNING: " -ForegroundColor Yellow -NoNewline
        Write-Host "You've specified $($Regions.Count) regions. For optimal performance and readability," -ForegroundColor White
        Write-Host "         the maximum recommended is $maxRegions regions per scan." -ForegroundColor White
        Write-Host "`nOptions:" -ForegroundColor Cyan
        Write-Host "  1. Continue with first $maxRegions regions: $($Regions[0..($maxRegions-1)] -join ', ')" -ForegroundColor Gray
        Write-Host "  2. Cancel and re-run with fewer regions" -ForegroundColor Gray
        Write-Host "`nContinue with first $maxRegions regions? (y/N): " -ForegroundColor Yellow -NoNewline
        $limitInput = Read-Host
        if ($limitInput -match '^y(es)?$') {
            $Regions = @($Regions[0..($maxRegions - 1)])
            Write-Host "Proceeding with: $($Regions -join ', ')" -ForegroundColor Green
        }
        else {
            Write-Host "Scan cancelled. Please re-run with $maxRegions or fewer regions." -ForegroundColor Yellow
            return
        }
    }
}

# Export prompt
if (-not $ExportPath -and $Interactive -and -not $AutoExport) {
    Write-Host "`nExport results to file? (y/N): " -ForegroundColor Yellow -NoNewline
    $exportInput = Read-Host
    if ($exportInput -match '^y(es)?$') {
        Write-Host "Export path (Enter for default: $defaultExportPath): " -ForegroundColor Yellow -NoNewline
        $pathInput = Read-Host
        $ExportPath = if ([string]::IsNullOrWhiteSpace($pathInput)) { $defaultExportPath } else { $pathInput }
    }
}

# Pricing prompt
$FetchPricing = $ShowPricing.IsPresent
if (-not $ShowPricing -and $Interactive) {
    Write-Host "`nInclude estimated pricing? (adds ~5-10 sec) (y/N): " -ForegroundColor Yellow -NoNewline
    $pricingInput = Read-Host
    if ($pricingInput -match '^y(es)?$') { $FetchPricing = $true }
}

# Placement score prompt — fires independently (useful without pricing)
if (-not $ShowPlacement -and $Interactive) {
    Write-Host "`nShow allocation likelihood scores? (High/Medium/Low per SKU) (y/N): " -ForegroundColor Yellow -NoNewline
    $placementInput = Read-Host
    if ($placementInput -match '^y(es)?$') { $ShowPlacement = [switch]::new($true) }
}
$script:RunContext.ShowPlacement = $ShowPlacement.IsPresent

# Spot pricing prompt — only useful if pricing is enabled
if (-not $ShowSpot -and $Interactive -and $FetchPricing) {
    Write-Host "`nInclude Spot VM pricing alongside regular pricing? (y/N): " -ForegroundColor Yellow -NoNewline
    $spotInput = Read-Host
    if ($spotInput -match '^y(es)?$') { $ShowSpot = [switch]::new($true) }
}

# Image compatibility prompt
if (-not $ImageURN -and $Interactive) {
    Write-Host "`nCheck SKU compatibility with a specific VM image? (y/N): " -ForegroundColor Yellow -NoNewline
    $imageInput = Read-Host
    if ($imageInput -match '^y(es)?$') {
        # Common images list for easy selection - organized by category
        $commonImages = @(
            # Linux - General Purpose
            @{ Num = 1; Name = "Ubuntu 22.04 LTS (Gen2)"; URN = "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Linux" }
            @{ Num = 2; Name = "Ubuntu 24.04 LTS (Gen2)"; URN = "Canonical:ubuntu-24_04-lts:server-gen2:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Linux" }
            @{ Num = 3; Name = "Ubuntu 22.04 ARM64"; URN = "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-arm64:latest"; Gen = "Gen2"; Arch = "ARM64"; Cat = "Linux" }
            @{ Num = 4; Name = "RHEL 9 (Gen2)"; URN = "RedHat:RHEL:9-lvm-gen2:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Linux" }
            @{ Num = 5; Name = "Debian 12 (Gen2)"; URN = "Debian:debian-12:12-gen2:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Linux" }
            @{ Num = 6; Name = "Azure Linux (Mariner)"; URN = "MicrosoftCBLMariner:cbl-mariner:cbl-mariner-2-gen2:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Linux" }
            # Windows
            @{ Num = 7; Name = "Windows Server 2022 (Gen2)"; URN = "MicrosoftWindowsServer:WindowsServer:2022-datacenter-g2:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Windows" }
            @{ Num = 8; Name = "Windows Server 2019 (Gen2)"; URN = "MicrosoftWindowsServer:WindowsServer:2019-datacenter-gensecond:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Windows" }
            @{ Num = 9; Name = "Windows 11 Enterprise (Gen2)"; URN = "MicrosoftWindowsDesktop:windows-11:win11-22h2-ent:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Windows" }
            # Data Science & ML
            @{ Num = 10; Name = "Data Science VM Ubuntu 22.04"; URN = "microsoft-dsvm:ubuntu-2204:2204-gen2:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Data Science" }
            @{ Num = 11; Name = "Data Science VM Windows 2022"; URN = "microsoft-dsvm:dsvm-win-2022:winserver-2022:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Data Science" }
            @{ Num = 12; Name = "Azure ML Workstation Ubuntu"; URN = "microsoft-dsvm:aml-workstation:ubuntu22:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "Data Science" }
            # HPC & GPU Optimized
            @{ Num = 13; Name = "Ubuntu HPC 22.04"; URN = "microsoft-dsvm:ubuntu-hpc:2204:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "HPC" }
            @{ Num = 14; Name = "AlmaLinux HPC"; URN = "almalinux:almalinux-hpc:8_7-hpc-gen2:latest"; Gen = "Gen2"; Arch = "x64"; Cat = "HPC" }
            # Legacy/Gen1 (for older SKUs)
            @{ Num = 15; Name = "Ubuntu 22.04 LTS (Gen1)"; URN = "Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest"; Gen = "Gen1"; Arch = "x64"; Cat = "Gen1" }
            @{ Num = 16; Name = "Windows Server 2022 (Gen1)"; URN = "MicrosoftWindowsServer:WindowsServer:2022-datacenter:latest"; Gen = "Gen1"; Arch = "x64"; Cat = "Gen1" }
        )

        Write-Host ""
        Write-Host "COMMON VM IMAGES:" -ForegroundColor Cyan
        Write-Host ("-" * 85) -ForegroundColor Gray
        Write-Host ("{0,-4} {1,-40} {2,-6} {3,-7} {4}" -f "#", "Image Name", "Gen", "Arch", "Category") -ForegroundColor White
        Write-Host ("-" * 85) -ForegroundColor Gray
        foreach ($img in $commonImages) {
            $catColor = switch ($img.Cat) { "Linux" { "Cyan" } "Windows" { "Blue" } "Data Science" { "Magenta" } "HPC" { "Yellow" } "Gen1" { "DarkGray" } default { "Gray" } }
            Write-Host ("{0,-4} {1,-40} {2,-6} {3,-7} {4}" -f $img.Num, $img.Name, $img.Gen, $img.Arch, $img.Cat) -ForegroundColor $catColor
        }
        Write-Host ("-" * 85) -ForegroundColor Gray
        Write-Host "Or type: 'custom' for manual URN | 'search' to browse Azure Marketplace | Enter to skip" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "Select image (1-16, custom, search, or Enter to skip): " -ForegroundColor Yellow -NoNewline
        $imageSelection = Read-Host

        if ($imageSelection -match '^\d+$' -and [int]$imageSelection -ge 1 -and [int]$imageSelection -le $commonImages.Count) {
            $selectedImage = $commonImages[[int]$imageSelection - 1]
            $ImageURN = $selectedImage.URN
            Write-Host "Selected: $($selectedImage.Name)" -ForegroundColor Green
            Write-Host "URN: $ImageURN" -ForegroundColor DarkGray
        }
        elseif ($imageSelection -match '^custom$') {
            Write-Host "Enter image URN (Publisher:Offer:Sku:Version): " -ForegroundColor Yellow -NoNewline
            $customURN = Read-Host
            if (-not [string]::IsNullOrWhiteSpace($customURN)) {
                $ImageURN = $customURN
                Write-Host "Using custom URN: $ImageURN" -ForegroundColor Green
            }
            else {
                $ImageURN = $null
                Write-Host "No image specified - skipping compatibility check" -ForegroundColor DarkGray
            }
        }
        elseif ($imageSelection -match '^search$') {
            Write-Host ""
            Write-Host "Enter search term (e.g., 'ubuntu', 'data science', 'windows', 'dsvm'): " -ForegroundColor Yellow -NoNewline
            $searchTerm = Read-Host
            if (-not [string]::IsNullOrWhiteSpace($searchTerm) -and $Regions.Count -gt 0) {
                Write-Host "Searching Azure Marketplace..." -ForegroundColor DarkGray
                try {
                    # Search publishers first
                    $publishers = Get-AzVMImagePublisher -Location $Regions[0] -ErrorAction SilentlyContinue |
                    Where-Object { $_.PublisherName -match $searchTerm }

                    # Also search common publishers for offers matching the term
                    $offerResults = [System.Collections.Generic.List[object]]::new()
                    $searchPublishers = @('Canonical', 'MicrosoftWindowsServer', 'RedHat', 'microsoft-dsvm', 'MicrosoftCBLMariner', 'Debian', 'SUSE', 'Oracle', 'OpenLogic')
                    foreach ($pub in $searchPublishers) {
                        try {
                            $offers = Get-AzVMImageOffer -Location $Regions[0] -PublisherName $pub -ErrorAction SilentlyContinue |
                            Where-Object { $_.Offer -match $searchTerm }
                            foreach ($offer in $offers) {
                                $offerResults.Add(@{ Publisher = $pub; Offer = $offer.Offer }) | Out-Null
                            }
                        }
                        catch { Write-Verbose "Image search failed for publisher '$pub': $_" }
                    }

                    if ($publishers -or $offerResults.Count -gt 0) {
                        $allResults = [System.Collections.Generic.List[object]]::new()
                        $idx = 1

                        # Add publisher matches
                        if ($publishers) {
                            $publishers | Select-Object -First 5 | ForEach-Object {
                                $allResults.Add(@{ Num = $idx; Type = "Publisher"; Name = $_.PublisherName; Publisher = $_.PublisherName; Offer = $null }) | Out-Null
                                $idx++
                            }
                        }

                        # Add offer matches
                        $offerResults | Select-Object -First 5 | ForEach-Object {
                            $allResults.Add(@{ Num = $idx; Type = "Offer"; Name = "$($_.Publisher) > $($_.Offer)"; Publisher = $_.Publisher; Offer = $_.Offer }) | Out-Null
                            $idx++
                        }

                        Write-Host ""
                        Write-Host "Results matching '$searchTerm':" -ForegroundColor Cyan
                        Write-Host ("-" * 60) -ForegroundColor Gray
                        foreach ($result in $allResults) {
                            $color = if ($result.Type -eq "Offer") { "White" } else { "Gray" }
                            Write-Host ("  {0,2}. [{1,-9}] {2}" -f $result.Num, $result.Type, $result.Name) -ForegroundColor $color
                        }
                        Write-Host ""
                        Write-Host "Select (1-$($allResults.Count)) or Enter to skip: " -ForegroundColor Yellow -NoNewline
                        $resultSelect = Read-Host

                        if ($resultSelect -match '^\d+$' -and [int]$resultSelect -le $allResults.Count) {
                            $selected = $allResults[[int]$resultSelect - 1]

                            if ($selected.Type -eq "Offer") {
                                # Already have publisher and offer, just need SKU
                                $skus = Get-AzVMImageSku -Location $Regions[0] -PublisherName $selected.Publisher -Offer $selected.Offer -ErrorAction SilentlyContinue |
                                Select-Object -First 15

                                if ($skus) {
                                    Write-Host ""
                                    Write-Host "SKUs for $($selected.Offer):" -ForegroundColor Cyan
                                    for ($i = 0; $i -lt $skus.Count; $i++) {
                                        Write-Host "  $($i + 1). $($skus[$i].Skus)" -ForegroundColor White
                                    }
                                    Write-Host ""
                                    Write-Host "Select SKU (1-$($skus.Count)) or Enter to skip: " -ForegroundColor Yellow -NoNewline
                                    $skuSelect = Read-Host

                                    if ($skuSelect -match '^\d+$' -and [int]$skuSelect -le $skus.Count) {
                                        $selectedSku = $skus[[int]$skuSelect - 1]
                                        $ImageURN = "$($selected.Publisher):$($selected.Offer):$($selectedSku.Skus):latest"
                                        Write-Host "Selected: $ImageURN" -ForegroundColor Green
                                    }
                                }
                            }
                            else {
                                # Publisher selected - show offers
                                $offers = Get-AzVMImageOffer -Location $Regions[0] -PublisherName $selected.Publisher -ErrorAction SilentlyContinue |
                                Select-Object -First 10

                                if ($offers) {
                                    Write-Host ""
                                    Write-Host "Offers from $($selected.Publisher):" -ForegroundColor Cyan
                                    for ($i = 0; $i -lt $offers.Count; $i++) {
                                        Write-Host "  $($i + 1). $($offers[$i].Offer)" -ForegroundColor White
                                    }
                                    Write-Host ""
                                    Write-Host "Select offer (1-$($offers.Count)) or Enter to skip: " -ForegroundColor Yellow -NoNewline
                                    $offerSelect = Read-Host

                                    if ($offerSelect -match '^\d+$' -and [int]$offerSelect -le $offers.Count) {
                                        $selectedOffer = $offers[[int]$offerSelect - 1]
                                        $skus = Get-AzVMImageSku -Location $Regions[0] -PublisherName $selected.Publisher -Offer $selectedOffer.Offer -ErrorAction SilentlyContinue |
                                        Select-Object -First 15

                                        if ($skus) {
                                            Write-Host ""
                                            Write-Host "SKUs for $($selectedOffer.Offer):" -ForegroundColor Cyan
                                            for ($i = 0; $i -lt $skus.Count; $i++) {
                                                Write-Host "  $($i + 1). $($skus[$i].Skus)" -ForegroundColor White
                                            }
                                            Write-Host ""
                                            Write-Host "Select SKU (1-$($skus.Count)) or Enter to skip: " -ForegroundColor Yellow -NoNewline
                                            $skuSelect = Read-Host

                                            if ($skuSelect -match '^\d+$' -and [int]$skuSelect -le $skus.Count) {
                                                $selectedSku = $skus[[int]$skuSelect - 1]
                                                $ImageURN = "$($selected.Publisher):$($selectedOffer.Offer):$($selectedSku.Skus):latest"
                                                Write-Host "Selected: $ImageURN" -ForegroundColor Green
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    else {
                        Write-Host "No results found matching '$searchTerm'" -ForegroundColor DarkYellow
                        Write-Host "Try: 'ubuntu', 'windows', 'rhel', 'dsvm', 'mariner', 'debian', 'suse'" -ForegroundColor DarkGray
                    }
                }
                catch {
                    Write-Host "Search failed: $_" -ForegroundColor Red
                }

                if (-not $ImageURN) {
                    Write-Host "No image selected - skipping compatibility check" -ForegroundColor DarkGray
                }
            }
        }
        else {
            # Assume they entered a URN directly or pressed Enter to skip
            if (-not [string]::IsNullOrWhiteSpace($imageSelection)) {
                $ImageURN = $imageSelection
                Write-Host "Using: $ImageURN" -ForegroundColor Green
            }
        }
    }
}

# Parse image requirements if an image was specified
$script:RunContext.ImageReqs = $null
if ($ImageURN) {
    $script:RunContext.ImageReqs = Get-ImageRequirements -ImageURN $ImageURN
    if (-not $script:RunContext.ImageReqs.Valid) {
        Write-Host "Warning: Could not parse image URN - $($script:RunContext.ImageReqs.Error)" -ForegroundColor DarkYellow
        $script:RunContext.ImageReqs = $null
    }
}

if ($ExportPath -and -not (Test-Path $ExportPath)) {
    New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null
    Write-Host "Created: $ExportPath" -ForegroundColor Green
}

#endregion Interactive Prompts
#region Data Collection

# Calculate consistent output width based on table columns
# Base columns: Family(12) + SKUs(6) + OK(5) + Largest(18) + Zones(28) + Status(22) + Quota(10) = 101
# Plus spacing and CPU/Disk columns = 122 base
# With pricing: +18 (two price columns) = 140
$script:OutputWidth = if ($FetchPricing) { $OutputWidthWithPricing } else { $OutputWidthBase }
if ($CompactOutput) {
    $script:OutputWidth = $OutputWidthMin
}
$script:OutputWidth = [Math]::Max($script:OutputWidth, $OutputWidthMin)
$script:OutputWidth = [Math]::Min($script:OutputWidth, $OutputWidthMax)
$script:RunContext.OutputWidth = $script:OutputWidth

Write-Host "`n" -NoNewline
Write-Host ("=" * $script:OutputWidth) -ForegroundColor Gray
Write-Host "Get-AzVMLifecycle v$ScriptVersion" -ForegroundColor Green
Write-Host "Personal project — not an official Microsoft product. Provided AS IS." -ForegroundColor DarkGray
Write-Host ("=" * $script:OutputWidth) -ForegroundColor Gray
Write-Host "Subscriptions: $($TargetSubIds.Count) | Regions: $($Regions -join ', ')" -ForegroundColor Cyan
if ($SkuFilter -and $SkuFilter.Count -gt 0) {
    Write-Host "SKU Filter: $($SkuFilter -join ', ')" -ForegroundColor Yellow
}
Write-Host "Icons: $(if ($supportsUnicode) { 'Unicode' } else { 'ASCII' }) | Pricing: $(if ($FetchPricing) { 'Enabled' } else { 'Disabled' })" -ForegroundColor DarkGray
if ($script:RunContext.ImageReqs) {
    Write-Host "Image: $ImageURN" -ForegroundColor Cyan
    Write-Host "Requirements: $($script:RunContext.ImageReqs.Gen) | $($script:RunContext.ImageReqs.Arch)" -ForegroundColor DarkCyan
}
Write-Host ("=" * $script:OutputWidth) -ForegroundColor Gray
Write-Host ""

# Fetch pricing data if enabled
$script:RunContext.RegionPricing = @{}
$script:RunContext.UsingActualPricing = $false

if ($FetchPricing) {
    # Auto-detect: Try negotiated pricing first, fall back to retail
    Write-Host "Checking for negotiated pricing (EA/MCA/CSP)..." -ForegroundColor DarkGray

    $actualPricingSuccess = $true
    $verboseFlag = ($VerbosePreference -eq 'Continue')
    foreach ($regionCode in $Regions) {
        $actualPrices = Get-AzActualPricing -SubscriptionId $TargetSubIds[0] -Region $regionCode -MaxRetries $MaxRetries -HoursPerMonth $HoursPerMonth -AzureEndpoints $script:AzureEndpoints -TargetEnvironment $script:TargetEnvironment -Caches $script:RunContext.Caches -Verbose:$verboseFlag
        if ($actualPrices -and $actualPrices.Count -gt 0) {
            if ($actualPrices -is [array]) { $actualPrices = $actualPrices[0] }
            $script:RunContext.RegionPricing[$regionCode] = $actualPrices
        }
        else {
            $actualPricingSuccess = $false
            break
        }
    }

    if ($actualPricingSuccess -and $script:RunContext.RegionPricing.Count -gt 0) {
        $script:RunContext.UsingActualPricing = $true
        # Merge negotiated pricing into the retail structure so reservation/SP/spot data is preserved.
        # Negotiated rates override retail Regular entries; all other pricing tiers come from retail.
        foreach ($regionCode in $Regions) {
            $retailResult = Get-AzVMPricing -Region $regionCode -MaxRetries $MaxRetries -HoursPerMonth $HoursPerMonth -AzureEndpoints $script:AzureEndpoints -TargetEnvironment $script:TargetEnvironment -Caches $script:RunContext.Caches
            if ($retailResult -is [array]) { $retailResult = $retailResult[0] }
            $retailMap = Get-RegularPricingMap -PricingContainer $retailResult
            $negotiatedMap = $script:RunContext.RegionPricing[$regionCode]
            # Start with retail Regular map, overlay negotiated prices on top
            $mergedRegular = @{}
            foreach ($skuName in $retailMap.Keys) {
                $mergedRegular[$skuName] = $retailMap[$skuName]
            }
            $negotiatedCount = 0
            foreach ($skuName in $negotiatedMap.Keys) {
                $mergedRegular[$skuName] = $negotiatedMap[$skuName]
                $negotiatedCount++
            }
            # Store as structured container so Spot/Reservation/SavingsPlan maps work
            $script:RunContext.RegionPricing[$regionCode] = [ordered]@{
                Regular        = $mergedRegular
                Spot           = if ($retailResult.Spot) { $retailResult.Spot } else { @{} }
                SavingsPlan1Yr = if ($retailResult.SavingsPlan1Yr) { $retailResult.SavingsPlan1Yr } else { @{} }
                SavingsPlan3Yr = if ($retailResult.SavingsPlan3Yr) { $retailResult.SavingsPlan3Yr } else { @{} }
                Reservation1Yr = if ($retailResult.Reservation1Yr) { $retailResult.Reservation1Yr } else { @{} }
                Reservation3Yr = if ($retailResult.Reservation3Yr) { $retailResult.Reservation3Yr } else { @{} }
            }
            Write-Verbose "Pricing merge for '$regionCode': $negotiatedCount negotiated + $($mergedRegular.Count - $negotiatedCount) retail Regular, $($retailResult.Reservation1Yr.Count) RI-1yr, $($retailResult.Reservation3Yr.Count) RI-3yr"
        }
        Write-Host "$($Icons.Check) Using negotiated pricing (EA/MCA/CSP rates detected)" -ForegroundColor Green
    }
    else {
        # Fall back to retail pricing
        Write-Host "No negotiated rates found, using retail pricing. (Run with -Verbose for details)" -ForegroundColor DarkGray
        Write-Verbose "Retail pricing API: $($script:AzureEndpoints.PricingApiUrl)"
        $script:RunContext.RegionPricing = @{}
        foreach ($regionCode in $Regions) {
            $pricingResult = Get-AzVMPricing -Region $regionCode -MaxRetries $MaxRetries -HoursPerMonth $HoursPerMonth -AzureEndpoints $script:AzureEndpoints -TargetEnvironment $script:TargetEnvironment -Caches $script:RunContext.Caches
            if ($pricingResult -is [array]) { $pricingResult = $pricingResult[0] }
            $script:RunContext.RegionPricing[$regionCode] = $pricingResult
            $regularMap = Get-RegularPricingMap -PricingContainer $pricingResult
            Write-Verbose "Retail pricing for '$regionCode': $($regularMap.Count) VM SKUs loaded"
        }
        Write-Host "$($Icons.Check) Using retail pricing (Linux pay-as-you-go)" -ForegroundColor DarkGray
    }
}

$allSubscriptionData = @()

$initialAzContext = Get-AzContext -ErrorAction SilentlyContinue
$initialSubscriptionId = if ($initialAzContext -and $initialAzContext.Subscription) { [string]$initialAzContext.Subscription.Id } else { $null }

# Outer try/finally ensures Az context is restored even if Ctrl+C or PipelineStoppedException
# interrupts parallel scanning, results processing, or export
try {
    try {
        foreach ($subId in $TargetSubIds) {
        $scanStartTime = Get-Date
        try {
            Use-SubscriptionContextSafely -SubscriptionId $subId | Out-Null
        }
        catch {
            Write-Warning "Failed to switch Azure context to subscription '$subId': $($_.Exception.Message)"
            continue
        }

        $subName = (Get-AzSubscription -SubscriptionId $subId | Select-Object -First 1).Name
        Write-Host "[$subName] Scanning $($Regions.Count) region(s)..." -ForegroundColor Yellow

        # Progress indicator for parallel scanning
        $regionCount = $Regions.Count
        Write-Progress -Activity "Scanning Azure Regions" -Status "Querying $regionCount region(s) in parallel..." -PercentComplete 0

        $scanRegionScript = {
            param($region, $skuFilterCopy, $maxRetries, $skipQuota)

            # Inline retry — parallel runspaces cannot see script-scope functions
            $retryCall = {
                param([scriptblock]$Action, [int]$Retries)
                $attempt = 0
                while ($true) {
                    try {
                        return (& $Action)
                    }
                    catch {
                        $attempt++
                        $msg = $_.Exception.Message
                        $isThrottle = $msg -match '429' -or $msg -match 'Too Many Requests' -or
                        $msg -match '503' -or $msg -match 'ServiceUnavailable'
                        if ($isThrottle -and $attempt -le $Retries) {
                            $baseDelay = [math]::Pow(2, $attempt)
                            $jitter = $baseDelay * (Get-Random -Minimum 0.0 -Maximum 0.25)
                            Start-Sleep -Milliseconds (($baseDelay + $jitter) * 1000)
                            continue
                        }
                        throw
                    }
                }
            }

            try {
                $allSkus = & $retryCall -Action {
                    Get-AzComputeResourceSku -Location $region -ErrorAction Stop |
                    Where-Object { $_.ResourceType -eq 'virtualMachines' }
                } -Retries $maxRetries

                # Apply SKU filter if specified
                if ($skuFilterCopy -and $skuFilterCopy.Count -gt 0) {
                    $allSkus = $allSkus | Where-Object {
                        $skuName = $_.Name
                        $isMatch = $false
                        foreach ($pattern in $skuFilterCopy) {
                            $regexPattern = '^' + [regex]::Escape($pattern).Replace('\*', '.*').Replace('\?', '.') + '$'
                            if ($skuName -match $regexPattern) {
                                $isMatch = $true
                                break
                            }
                        }
                        $isMatch
                    }
                }

                $quotas = @()
                $quotaError = $null
                if (-not $skipQuota) {
                    try {
                        $quotas = & $retryCall -Action {
                            Get-AzVMUsage -Location $region -ErrorAction Stop
                        } -Retries $maxRetries
                    }
                    catch {
                        $quotaError = $_.Exception.Message
                    }
                }

                @{ Region = [string]$region; Skus = $allSkus; Quotas = $quotas; QuotaError = $quotaError; Error = $null }
            }
            catch {
                @{ Region = [string]$region; Skus = @(); Quotas = @(); QuotaError = $null; Error = $_.Exception.Message }
            }
        }

        $canUseParallel = $PSVersionTable.PSVersion.Major -ge 7
        if ($canUseParallel) {
            try {
                $regionData = $Regions | ForEach-Object -Parallel {
                    $region = [string]$_
                    $skuFilterCopy = $using:SkuFilter
                    $maxRetries = $using:MaxRetries
                    $skipQuota = $using:NoQuota

                    # Inline retry — parallel runspaces cannot see script-scope functions or external scriptblocks
                    $retryCall = {
                        param([scriptblock]$Action, [int]$Retries)
                        $attempt = 0
                        while ($true) {
                            try {
                                return (& $Action)
                            }
                            catch {
                                $attempt++
                                $msg = $_.Exception.Message
                                $isThrottle = $msg -match '429' -or $msg -match 'Too Many Requests' -or
                                $msg -match '503' -or $msg -match 'ServiceUnavailable' -or $msg -match 'Service Unavailable'
                                if ($isThrottle -and $attempt -le $Retries) {
                                    $baseDelay = [math]::Pow(2, $attempt)
                                    $jitter = $baseDelay * (Get-Random -Minimum 0.0 -Maximum 0.25)
                                    Start-Sleep -Milliseconds (($baseDelay + $jitter) * 1000)
                                    continue
                                }
                                throw
                            }
                        }
                    }

                    try {
                        $allSkus = & $retryCall -Action {
                            Get-AzComputeResourceSku -Location $region -ErrorAction Stop |
                            Where-Object { $_.ResourceType -eq 'virtualMachines' }
                        } -Retries $maxRetries

                        if ($skuFilterCopy -and $skuFilterCopy.Count -gt 0) {
                            $allSkus = $allSkus | Where-Object {
                                $skuName = $_.Name
                                $isMatch = $false
                                foreach ($pattern in $skuFilterCopy) {
                                    $regexPattern = '^' + [regex]::Escape($pattern).Replace('\*', '.*').Replace('\?', '.') + '$'
                                    if ($skuName -match $regexPattern) {
                                        $isMatch = $true
                                        break
                                    }
                                }
                                $isMatch
                            }
                        }

                        $quotas = @()
                        $quotaError = $null
                        if (-not $skipQuota) {
                            try {
                                $quotas = & $retryCall -Action {
                                    Get-AzVMUsage -Location $region -ErrorAction Stop
                                } -Retries $maxRetries
                            }
                            catch {
                                $quotaError = $_.Exception.Message
                            }
                        }

                        @{ Region = [string]$region; Skus = $allSkus; Quotas = $quotas; QuotaError = $quotaError; Error = $null }
                    }
                    catch {
                        @{ Region = [string]$region; Skus = @(); Quotas = @(); QuotaError = $null; Error = $_.Exception.Message }
                    }
                } -ThrottleLimit $ParallelThrottleLimit
            }
            catch {
                Write-Warning "Parallel region scan failed: $($_.Exception.Message)"
                Write-Warning "Falling back to sequential scan mode for compatibility."
                $canUseParallel = $false
            }
        }

        if (-not $canUseParallel) {
            $regionData = foreach ($region in $Regions) {
                & $scanRegionScript -region ([string]$region) -skuFilterCopy $SkuFilter -maxRetries $MaxRetries -skipQuota $NoQuota.IsPresent
            }
        }

        Write-Progress -Activity "Scanning Azure Regions" -Completed

        # Retry failed regions sequentially (parallel pressure may have caused throttling)
        $failedRegions = @($regionData | Where-Object { $_.Error })
        if ($failedRegions.Count -gt 0) {
            $regionNames = @($failedRegions | ForEach-Object { $_.Region }) -join ', '
            Write-Warning "Retrying $($failedRegions.Count) failed region(s) sequentially: $regionNames"
            $successfulData = [System.Collections.Generic.List[object]]::new()
            foreach ($rd in $regionData) {
                if (-not $rd.Error) { $successfulData.Add($rd) }
            }
            foreach ($failedRd in $failedRegions) {
                Write-Verbose "Retry: $($failedRd.Region) (original error: $($failedRd.Error))"
                $retryResult = & $scanRegionScript -region ([string]$failedRd.Region) -skuFilterCopy $SkuFilter -maxRetries $MaxRetries -skipQuota $NoQuota.IsPresent
                if ($retryResult.Error) {
                    Write-Warning "Region '$($failedRd.Region)' failed after retry: $($retryResult.Error) — data excluded from analysis"
                }
                else {
                    Write-Host "  Retry succeeded: $($failedRd.Region) ($($retryResult.Skus.Count) SKUs, $($retryResult.Quotas.Count) quotas)" -ForegroundColor Green
                }
                $successfulData.Add($retryResult)
            }
            $regionData = $successfulData.ToArray()
        }

        # Sequential retry for quota data that failed during parallel scan (common in GOV due to tighter throttle limits)
        if (-not $NoQuota) {
            $quotaRetryRegions = @($regionData | Where-Object { -not $_.Error -and $_.QuotaError })
            if ($quotaRetryRegions.Count -gt 0) {
                Write-Verbose "Retrying quota fetch sequentially for $($quotaRetryRegions.Count) region(s) that failed during parallel scan..."
                foreach ($rd in $quotaRetryRegions) {
                    try {
                        $retryQuotas = Invoke-WithRetry -MaxRetries $MaxRetries -OperationName "Get-AzVMUsage ($($rd.Region) retry)" -ScriptBlock {
                            Get-AzVMUsage -Location $rd.Region -ErrorAction Stop
                        }
                        $rd.Quotas = if ($retryQuotas) { @($retryQuotas) } else { @() }
                        $rd.QuotaError = $null
                        Write-Verbose "Quota retry succeeded for $($rd.Region): $($rd.Quotas.Count) families"
                    }
                    catch {
                        Write-Verbose "Quota retry failed for $($rd.Region): $($_.Exception.Message)"
                    }
                }
            }
        }

        $scanElapsed = (Get-Date) - $scanStartTime
        Write-Host "[$subName] Scan complete in $([math]::Round($scanElapsed.TotalSeconds, 1))s" -ForegroundColor Green

        $allSubscriptionData += @{
            SubscriptionId   = $subId
            SubscriptionName = $subName
            RegionData       = $regionData
        }
    }
}
catch {
    Write-Verbose "Scan loop interrupted: $($_.Exception.Message)"
    throw
}

#endregion Data Collection
#region Lifecycle Recommendations

if ($lifecycleEntries.Count -gt 0) {
    $lifecycleResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $skuIndex = 0

    # Pre-build indexes for O(1) lookups during the lifecycle loop
    $lcSkuIndex = @{}       # "SKUName|region" → raw SKU object (for .Family quota key)
    $lcQuotaIndex = @{}     # "region" → hashtable of quota name → quota object
    foreach ($subData in $allSubscriptionData) {
        foreach ($rd in $subData.RegionData) {
            if ($rd.Error) { continue }
            $regionKey = [string]$rd.Region
            if ($rd.QuotaError) {
                Write-Warning "Quota data unavailable for region '$regionKey': $($rd.QuotaError)"
            }
            elseif (-not $rd.Quotas -or @($rd.Quotas).Count -eq 0) {
                Write-Warning "Quota API returned no data for region '$regionKey'. Quota columns will show '-' for VMs deployed here."
            }
            if (-not $lcQuotaIndex.ContainsKey($regionKey)) {
                $qLookup = @{}
                foreach ($q in $rd.Quotas) { $qLookup[$q.Name.Value] = $q }
                $lcQuotaIndex[$regionKey] = $qLookup
                Write-Verbose "Quota index for '$regionKey': $($qLookup.Count) families loaded"
            }
            foreach ($sku in $rd.Skus) {
                $skuRegionKey = "$($sku.Name)|$regionKey"
                if (-not $lcSkuIndex.ContainsKey($skuRegionKey)) {
                    $lcSkuIndex[$skuRegionKey] = $sku
                }
            }
        }
    }

    # Candidate profile cache — populated on first Invoke-RecommendMode call, reused for all subsequent
    $lcProfileCache = @{}

    # Load upgrade path knowledge base for AI-curated recommendations
    $upgradePathData = $null
    $upgradePathFile = Join-Path $PSScriptRoot 'data' 'UpgradePath.json'
    if (Test-Path -LiteralPath $upgradePathFile) {
        try {
            $upgradePathData = Get-Content -LiteralPath $upgradePathFile -Raw | ConvertFrom-Json
            Write-Verbose "Loaded upgrade path knowledge base v$($upgradePathData._metadata.version) ($($upgradePathData._metadata.lastUpdated))"
        }
        catch {
            Write-Verbose "Failed to load UpgradePath.json: $_"
        }
    }

    foreach ($entry in $lifecycleEntries) {
        $targetSku = $entry.SKU
        $deployedRegion = $entry.Region
        $entryQty = $entry.Qty
        $skuIndex++
        $regionLabel = if ($deployedRegion) { " (deployed: $deployedRegion)" } else { '' }
        $qtyLabel = if ($entryQty -gt 1) { " x$entryQty" } else { '' }
        if (-not $JsonOutput) {
            Write-Host ""
            Write-Host ("=" * $script:OutputWidth) -ForegroundColor Gray
            Write-Host "LIFECYCLE ANALYSIS [$skuIndex/$($lifecycleEntries.Count)]: $targetSku$qtyLabel$regionLabel" -ForegroundColor Cyan
            Write-Host ("=" * $script:OutputWidth) -ForegroundColor Gray
        }

        Invoke-RecommendMode -TargetSkuName $targetSku -SubscriptionData $allSubscriptionData `
            -FamilyInfo $FamilyInfo -Icons $Icons -FetchPricing ([bool]$FetchPricing) `
            -ShowSpot $ShowSpot.IsPresent -ShowPlacement $ShowPlacement.IsPresent `
            -AllowMixedArch $AllowMixedArch.IsPresent -MinvCPU $MinvCPU -MinMemoryGB $MinMemoryGB `
            -MinScore $MinScore -TopN $TopN -DesiredCount $DesiredCount `
            -JsonOutput $false -MaxRetries $MaxRetries `
            -RunContext $script:RunContext -OutputWidth $script:OutputWidth `
            -SkuProfileCache $lcProfileCache

        # Capture lifecycle risk signals from the recommend output
        $recOutput = $script:RunContext.RecommendOutput
        if ($recOutput) {
            $target = $recOutput.target
            $allRecs = @($recOutput.recommendations)

            # Look up target SKU monthly price for cost-diff calculation
            $targetPriceMo = $null
            if ($FetchPricing -and $deployedRegion -and $script:RunContext.RegionPricing[$deployedRegion]) {
                $tgtPriceMap = Get-RegularPricingMap -PricingContainer $script:RunContext.RegionPricing[$deployedRegion]
                $tgtPriceEntry = $tgtPriceMap[$target.Name]
                if ($tgtPriceEntry) { $targetPriceMo = [double]$tgtPriceEntry.Monthly }
            }

            # Detect lifecycle risk: old generation, capacity issues, no alternatives
            $generation = if ($target.Name -match '_v(\d+)$') { [int]$Matches[1] } else { 1 }
            $targetAvail = $recOutput.targetAvailability

            # If a deployed region was specified, check availability specifically in that region
            $hasCapacityIssues = $false
            if ($deployedRegion) {
                $deployedStatus = $targetAvail | Where-Object { $_.Region -eq $deployedRegion } | Select-Object -First 1
                if ($deployedStatus -and $deployedStatus.Status -notin 'OK','LIMITED') {
                    $hasCapacityIssues = $true
                }
                elseif (-not $deployedStatus) {
                    $hasCapacityIssues = $true
                }
            }
            else {
                $hasCapacityIssues = @($targetAvail | Where-Object { $_.Status -notin 'OK','LIMITED' }).Count -gt 0
            }

            # Quota analysis for target SKU: use pre-built indexes for O(1) lookup
            $targetQuotaStatus = '-'
            $targetQuotaAvail = $null
            $quotaInsufficient = $false
            if (-not $NoQuota) {
                $lookupRegions = if ($deployedRegion) { @($deployedRegion) } else { @($lcQuotaIndex.Keys) }
                foreach ($qRegion in $lookupRegions) {
                    if ($targetQuotaAvail) { break }
                    $regionQuotas = $lcQuotaIndex[$qRegion]
                    if (-not $regionQuotas) { continue }
                    $rawSku = $lcSkuIndex["$($target.Name)|$qRegion"]
                    if ($rawSku) {
                        $requiredvCPUs = $entryQty * [int]$target.vCPU
                        $qi = Get-QuotaAvailable -QuotaLookup $regionQuotas -SkuFamily $rawSku.Family -RequiredvCPUs $requiredvCPUs
                        if ($null -ne $qi.Available) {
                            $targetQuotaAvail = $qi
                            $targetQuotaStatus = "$($qi.Current)/$($qi.Limit) (avail: $($qi.Available))"
                            if (-not $qi.OK) { $quotaInsufficient = $true }
                        }
                    }
                }
            }

            $isOldGen = $generation -le 3
            $noAlternatives = $allRecs.Count -eq 0

            $riskLevel = 'Low'
            $riskReasons = [System.Collections.Generic.List[string]]::new()
            if ($isOldGen) { $riskReasons.Add("Gen v$generation"); $riskLevel = 'Medium' }
            $retirementInfo = Get-SkuRetirementInfo -SkuName $target.Name
            if ($retirementInfo) {
                $retireLabel = if ($retirementInfo.Status -eq 'Retired') { "Retired $($retirementInfo.RetireDate)" } else { "Retiring $($retirementInfo.RetireDate)" }
                $riskReasons.Add($retireLabel)
                $riskLevel = 'High'
            }
            if ($hasCapacityIssues) { $riskReasons.Add("Capacity$(if ($deployedRegion) { " ($deployedRegion)" } else { '' })"); $riskLevel = 'High' }
            if ($quotaInsufficient) { $riskReasons.Add("Quota: need $($entryQty)x$($target.vCPU)vCPU"); $riskLevel = 'High' }
            if ($noAlternatives -and ($isOldGen -or $hasCapacityIssues -or $retirementInfo)) { $riskReasons.Add("No alternatives"); $riskLevel = 'High' }

            # Current-gen (v4+) SKUs with quota as the only risk → recommend quota increase, not SKU change
            $isQuotaOnlyCurrentGen = (-not $isOldGen) -and (-not $hasCapacityIssues) -and (-not $retirementInfo) -and $quotaInsufficient

            # Select up to 3 weighted recommendations: like-for-like, best fit, alternative
            $ScoreCloseThreshold = 10
            $MaxWeightedRecs = 3
            $selectedRecs = [System.Collections.Generic.List[pscustomobject]]::new()
            $usedSkus = [System.Collections.Generic.HashSet[string]]::new()

            # Inject upgrade path recommendations from knowledge base FIRST (up to 3)
            # Upgrade paths get priority so weighted recs fill remaining slots with different SKUs
            if ($upgradePathData -and $riskLevel -ne 'Low' -and (-not $isQuotaOnlyCurrentGen)) {
                $targetFamily = $target.Family
                $targetVersion = [int]$target.FamilyVersion
                $targetvCPU = [string][int]$target.vCPU
                # Normalize family: DS→D, GS→G (the S suffix indicates Premium SSD, same family)
                $normalizedFamily = if ($targetFamily -cmatch '^([A-Z]+)S$' -and $targetFamily -notin 'NVS','NCS','NDS','HBS','HCS','HXS','FXS') { $Matches[1] } else { $targetFamily }
                $pathKey = "${normalizedFamily}v${targetVersion}"
                $upgradePath = $upgradePathData.upgradePaths.$pathKey

                if ($upgradePath) {
                    $upgradeRecs = [System.Collections.Generic.List[pscustomobject]]::new()
                    $pathLabels = @(
                        @{ Key = 'dropIn'; Label = 'Upgrade: Drop-in' }
                        @{ Key = 'futureProof'; Label = 'Upgrade: Future-proof' }
                        @{ Key = 'costOptimized'; Label = 'Upgrade: Cost-optimized' }
                    )

                    foreach ($pl in $pathLabels) {
                        $pathEntry = $upgradePath.$($pl.Key)
                        if (-not $pathEntry) { continue }

                        # Look up the size-matched SKU from the sizeMap
                        $mappedSku = $pathEntry.sizeMap.$targetvCPU
                        if (-not $mappedSku) {
                            # Find nearest vCPU match (next size up)
                            $availSizes = @($pathEntry.sizeMap.PSObject.Properties.Name | ForEach-Object { [int]$_ } | Sort-Object)
                            $nearestSize = $availSizes | Where-Object { $_ -ge [int]$targetvCPU } | Select-Object -First 1
                            if ($nearestSize) { $mappedSku = $pathEntry.sizeMap."$nearestSize" }
                            elseif ($availSizes.Count -gt 0) { $mappedSku = $pathEntry.sizeMap."$($availSizes[-1])" }
                        }
                        if (-not $mappedSku) { continue }

                        # Skip if already used by a prior upgrade path entry
                        if ($usedSkus.Contains($mappedSku)) { continue }

                        # Check if this SKU exists in the scored candidates
                        $scoredMatch = $allRecs | Where-Object { $_.sku -eq $mappedSku } | Select-Object -First 1
                        if ($scoredMatch) {
                            $upgradeRecs.Add([pscustomobject]@{ Rec = $scoredMatch; MatchType = $pl.Label })
                            $usedSkus.Add($mappedSku) | Out-Null
                        }
                        else {
                            # SKU not in scored candidates — check raw scan data (may have failed compat gate)
                            $rawUpgradeSku = $null
                            $rawSkuRegion = $deployedRegion
                            if ($deployedRegion) {
                                $rawUpgradeSku = $lcSkuIndex["$mappedSku|$deployedRegion"]
                            }
                            if (-not $rawUpgradeSku) {
                                foreach ($rk in $lcSkuIndex.Keys) {
                                    if ($rk.StartsWith("$mappedSku|")) {
                                        $rawUpgradeSku = $lcSkuIndex[$rk]
                                        $rawSkuRegion = $rk.Substring($mappedSku.Length + 1)
                                        break
                                    }
                                }
                            }

                            if ($rawUpgradeSku) {
                                # Build rec from actual scan data and profile cache
                                $upRestrictions = Get-RestrictionDetails $rawUpgradeSku
                                $cached = if ($lcProfileCache.ContainsKey($mappedSku)) { $lcProfileCache[$mappedSku] } else { $null }
                                if ($cached) {
                                    $upVcpu = $cached.Profile.vCPU
                                    $upMemGiB = $cached.Profile.MemoryGB
                                    $upIOPS = $cached.Caps.UncachedDiskIOPS
                                    $upMaxDisks = $cached.Caps.MaxDataDiskCount
                                    $upCandidateProfile = $cached.Profile
                                }
                                else {
                                    $upCaps = Get-SkuCapabilities -Sku $rawUpgradeSku
                                    $upVcpu = [int](Get-CapValue $rawUpgradeSku 'vCPUs')
                                    $upMemGiB = [int](Get-CapValue $rawUpgradeSku 'MemoryGB')
                                    $upIOPS = $upCaps.UncachedDiskIOPS
                                    $upMaxDisks = $upCaps.MaxDataDiskCount
                                    $upCandidateProfile = @{
                                        Name     = $mappedSku
                                        vCPU     = $upVcpu
                                        MemoryGB = $upMemGiB
                                        Family   = Get-SkuFamily $mappedSku
                                        Generation               = $upCaps.HyperVGenerations
                                        Architecture             = $upCaps.CpuArchitecture
                                        PremiumIO                = (Get-CapValue $rawUpgradeSku 'PremiumIO') -eq 'True'
                                        DiskCode                 = Get-DiskCode -HasTempDisk ($upCaps.TempDiskGB -gt 0) -HasNvme $upCaps.NvmeSupport
                                        AccelNet                 = $upCaps.AcceleratedNetworkingEnabled
                                        MaxDataDiskCount         = $upCaps.MaxDataDiskCount
                                        MaxNetworkInterfaces     = $upCaps.MaxNetworkInterfaces
                                        EphemeralOSDiskSupported  = $upCaps.EphemeralOSDiskSupported
                                        UltraSSDAvailable        = $upCaps.UltraSSDAvailable
                                        UncachedDiskIOPS         = $upCaps.UncachedDiskIOPS
                                        UncachedDiskBytesPerSecond = $upCaps.UncachedDiskBytesPerSecond
                                        EncryptionAtHostSupported = $upCaps.EncryptionAtHostSupported
                                    }
                                }
                                # Compute similarity score against the target profile
                                $targetProfileHt = @{}
                                foreach ($p in $target.PSObject.Properties) { $targetProfileHt[$p.Name] = $p.Value }
                                $upScore = Get-SkuSimilarityScore -Target $targetProfileHt -Candidate $upCandidateProfile -FamilyInfo $FamilyInfo
                                $upPriceMo = $null
                                if ($FetchPricing -and $rawSkuRegion -and $script:RunContext.RegionPricing[$rawSkuRegion]) {
                                    $prMap = Get-RegularPricingMap -PricingContainer $script:RunContext.RegionPricing[$rawSkuRegion]
                                    $prEntry = $prMap[$mappedSku]
                                    if ($prEntry) { $upPriceMo = $prEntry.Monthly }
                                }
                                $upgradeRecs.Add([pscustomobject]@{
                                    Rec = [pscustomobject]@{
                                        sku      = $mappedSku
                                        vCPU     = $upVcpu
                                        memGiB   = $upMemGiB
                                        family   = Get-SkuFamily $mappedSku
                                        score    = $upScore
                                        capacity = $upRestrictions.Status
                                        IOPS     = $upIOPS
                                        MaxDisks = $upMaxDisks
                                        priceMo  = $upPriceMo
                                    }
                                    MatchType = $pl.Label
                                })
                                $usedSkus.Add($mappedSku) | Out-Null
                            }
                            else {
                                # SKU not in any scanned region — skip (no data to compare)
                                continue
                            }
                        }
                    }

                    # Add upgrade recs to selectedRecs (weighted recs will be appended after)
                    foreach ($ur in $upgradeRecs) { $selectedRecs.Add($ur) }
                }
            }

            # Build weighted recommendations from scored candidates (excluding upgrade path SKUs)
            if ($riskLevel -ne 'Low' -and (-not $isQuotaOnlyCurrentGen) -and $allRecs.Count -gt 0) {
                $filteredRecs = if ($usedSkus.Count -gt 0) {
                    @($allRecs | Where-Object { -not $usedSkus.Contains($_.sku) })
                } else { $allRecs }

                if ($filteredRecs.Count -gt 0) {
                    $bestFit = $filteredRecs | Sort-Object -Property score -Descending | Select-Object -First 1
                    $likeForLike = $filteredRecs | Where-Object { $_.vCPU -eq [int]$target.vCPU } | Sort-Object -Property score -Descending | Select-Object -First 1

                    $weightedRecs = [System.Collections.Generic.List[pscustomobject]]::new()
                    if ($likeForLike -and $likeForLike.sku -ne $bestFit.sku) {
                        $weightedRecs.Add([pscustomobject]@{ Rec = $likeForLike; MatchType = 'Like-for-like' })
                        $weightedRecs.Add([pscustomobject]@{ Rec = $bestFit; MatchType = 'Best fit' })
                    }
                    else {
                        $matchLabel = if ($likeForLike -and $likeForLike.sku -eq $bestFit.sku) { 'Like-for-like' } else { 'Best fit' }
                        $weightedRecs.Add([pscustomobject]@{ Rec = $bestFit; MatchType = $matchLabel })
                    }

                    foreach ($s in $weightedRecs) { $usedSkus.Add($s.Rec.sku) | Out-Null }

                    foreach ($altRec in $filteredRecs) {
                        if ($weightedRecs.Count -ge $MaxWeightedRecs) { break }
                        if ($usedSkus.Contains($altRec.sku)) { continue }
                        if ($altRec.score -ge ($bestFit.score - $ScoreCloseThreshold)) {
                            $weightedRecs.Add([pscustomobject]@{ Rec = $altRec; MatchType = 'Alternative' })
                            $usedSkus.Add($altRec.sku) | Out-Null
                        }
                    }

                    # Guarantee at least one rec with IOPS >= target (no performance downgrade)
                    $targetIOPS = [int]$target.UncachedDiskIOPS
                    if ($targetIOPS -gt 0) {
                        $hasIopsMatch = $selectedRecs + @($weightedRecs) | Where-Object { [int]$_.Rec.IOPS -ge $targetIOPS }
                        if (-not $hasIopsMatch) {
                            $iopsCandidate = $allRecs |
                                Where-Object { [int]$_.IOPS -ge $targetIOPS -and -not $usedSkus.Contains($_.sku) } |
                                Sort-Object -Property score -Descending |
                                Select-Object -First 1
                            if ($iopsCandidate) {
                                $weightedRecs.Add([pscustomobject]@{ Rec = $iopsCandidate; MatchType = 'IOPS match' })
                                $usedSkus.Add($iopsCandidate.sku) | Out-Null
                            }
                        }
                    }

                    # Append weighted recs after upgrade path recs
                    foreach ($wr in $weightedRecs) { $selectedRecs.Add($wr) }
                }
            }

            # Detect sovereign/GOV regions where Savings Plans are not supported
            $isSovereignRegion = $script:TargetEnvironment -in @('AzureUSGovernment', 'AzureChinaCloud', 'AzureGermanCloud') -or
                ($deployedRegion -and $deployedRegion -match '^(usgov|usdod|usnat|ussec|china|germany)')

            # Look up savings plan and reservation pricing maps for this region
            $sp1YrMap = @{}; $sp3YrMap = @{}; $ri1YrMap = @{}; $ri3YrMap = @{}
            if ($RateOptimization -and $FetchPricing -and $deployedRegion -and $script:RunContext.RegionPricing[$deployedRegion]) {
                $regionContainer = $script:RunContext.RegionPricing[$deployedRegion]
                if (-not $isSovereignRegion) {
                    $sp1YrMap = Get-SavingsPlanPricingMap -PricingContainer $regionContainer -Term '1Yr'
                    $sp3YrMap = Get-SavingsPlanPricingMap -PricingContainer $regionContainer -Term '3Yr'
                }
                $ri1YrMap = Get-ReservationPricingMap -PricingContainer $regionContainer -Term '1Yr'
                $ri3YrMap = Get-ReservationPricingMap -PricingContainer $regionContainer -Term '3Yr'
            }

            # Build lifecycle result rows — one per selected recommendation (or one summary row)
            if ($selectedRecs.Count -eq 0) {
                $lifecycleResults.Add([pscustomobject]@{
                    SKU              = $target.Name
                    DeployedRegion   = if ($deployedRegion) { $deployedRegion } else { '-' }
                    Qty              = $entryQty
                    vCPU             = $target.vCPU
                    MemoryGB         = $target.MemoryGB
                    Generation       = "v$generation"
                    RiskLevel        = $riskLevel
                    RiskReasons      = ($riskReasons -join '; ')
                    QuotaStatus      = $targetQuotaStatus
                    MatchType        = '-'
                    TopAlternative   = if ($riskLevel -eq 'Low') { 'N/A' } elseif ($isQuotaOnlyCurrentGen) { 'Request quota increase' } else { '-' }
                    AltScore         = ''
                    CpuDelta         = '-'
                    MemDelta         = '-'
                    DiskDelta        = '-'
                    IopsDelta        = '-'
                    AltCapacity      = '-'
                    AltQuotaStatus   = '-'
                    PriceDiff        = '-'
                    TotalPriceDiff   = '-'
                    PAYG1Yr          = '-'
                    PAYG3Yr          = '-'
                    SP1YrSavings     = if ($isSovereignRegion) { 'N/A' } else { '-' }
                    SP3YrSavings     = if ($isSovereignRegion) { 'N/A' } else { '-' }
                    RI1YrSavings     = '-'
                    RI3YrSavings     = '-'
                    AlternativeCount = 0
                    Details          = if ($riskLevel -eq 'Low') { '-' } elseif ($isQuotaOnlyCurrentGen) { 'Current gen; quota increase recommended' } else { 'No suitable alternatives found in scanned regions' }
                })
            }
            else {
                $isFirstRow = $true
                foreach ($sel in $selectedRecs) {
                    $rec = $sel.Rec
                    # Quota lookup for this specific alternative
                    $thisAltQuota = '-'
                    if (-not $NoQuota) {
                        $lookupRegions = if ($deployedRegion) { @($deployedRegion) } else { @($lcQuotaIndex.Keys) }
                        foreach ($qRegion in $lookupRegions) {
                            $altRawSku = $lcSkuIndex["$($rec.sku)|$qRegion"]
                            if ($altRawSku) {
                                $regionQuotas = $lcQuotaIndex[$qRegion]
                                if ($regionQuotas) {
                                    $altRequiredvCPUs = $entryQty * [int]$rec.vCPU
                                    $altQi = Get-QuotaAvailable -QuotaLookup $regionQuotas -SkuFamily $altRawSku.Family -RequiredvCPUs $altRequiredvCPUs
                                    if ($null -ne $altQi.Available) {
                                        $thisAltQuota = "$($altQi.Current)/$($altQi.Limit) (avail: $($altQi.Available))"
                                        break
                                    }
                                }
                            }
                        }
                    }

                    # Calculate price difference for this alternative
                    $priceDiffStr = '-'
                    $totalDiffStr = '-'
                    $payg1YrStr = '-'
                    $payg3YrStr = '-'
                    if ($null -ne $targetPriceMo -and $null -ne $rec.priceMo) {
                        $diff = [double]$rec.priceMo - $targetPriceMo
                        $priceDiffStr = if ($diff -ge 0) { '+$' + $diff.ToString('0') } else { '-$' + ([Math]::Abs($diff)).ToString('0') }
                        $totalDiff = $diff * $entryQty
                        $totalDiffStr = if ($totalDiff -ge 0) { '+$' + $totalDiff.ToString('N0') } else { '-$' + ([Math]::Abs($totalDiff)).ToString('N0') }
                        $payg1Yr = [double]$rec.priceMo * 12 * $entryQty
                        $payg1YrStr = '$' + $payg1Yr.ToString('N0')
                        $payg3Yr = [double]$rec.priceMo * 36 * $entryQty
                        $payg3YrStr = '$' + $payg3Yr.ToString('N0')
                    }

                    # Look up savings plan and reservation savings vs PAYG fleet total
                    $sp1YrSavingsStr = if ($isSovereignRegion) { 'N/A' } else { '-' }
                    $sp3YrSavingsStr = if ($isSovereignRegion) { 'N/A' } else { '-' }
                    $ri1YrSavingsStr = '-'; $ri3YrSavingsStr = '-'
                    if ($RateOptimization -and $FetchPricing -and $null -ne $rec.priceMo) {
                        $recPaygFleet1Yr = [double]$rec.priceMo * 12 * $entryQty
                        $recPaygFleet3Yr = [double]$rec.priceMo * 36 * $entryQty
                        if (-not $isSovereignRegion) {
                            $sp1Entry = $sp1YrMap[$rec.sku]
                            if ($sp1Entry) { $sp1Fleet = [double]$sp1Entry.Monthly * 12 * $entryQty; $sp1Savings = $recPaygFleet1Yr - $sp1Fleet; $sp1YrSavingsStr = '$' + $sp1Savings.ToString('N0') }
                            $sp3Entry = $sp3YrMap[$rec.sku]
                            if ($sp3Entry) { $sp3Fleet = [double]$sp3Entry.Monthly * 36 * $entryQty; $sp3Savings = $recPaygFleet3Yr - $sp3Fleet; $sp3YrSavingsStr = '$' + $sp3Savings.ToString('N0') }
                        }
                        $ri1Entry = $ri1YrMap[$rec.sku]
                        if ($ri1Entry) { $ri1Fleet = [double]$ri1Entry.Total * $entryQty; $ri1Savings = $recPaygFleet1Yr - $ri1Fleet; $ri1YrSavingsStr = '$' + $ri1Savings.ToString('N0') }
                        $ri3Entry = $ri3YrMap[$rec.sku]
                        if ($ri3Entry) { $ri3Fleet = [double]$ri3Entry.Total * $entryQty; $ri3Savings = $recPaygFleet3Yr - $ri3Fleet; $ri3YrSavingsStr = '$' + $ri3Savings.ToString('N0') }
                    }

                    # Compute CPU, memory, and disk deltas
                    $isUnscannedUpgrade = ($rec.capacity -eq 'Not scanned')
                    if ($isUnscannedUpgrade) {
                        $cpuDiff = 0; $cpuDeltaStr = '-'
                        $memDiff = 0; $memDeltaStr = '-'
                        $diskDeltaStr = '-'
                        $iopsDiff = 0; $iopsDeltaStr = '-'
                    }
                    else {
                        $cpuDiff = [int]$rec.vCPU - [int]$target.vCPU
                        $cpuDeltaStr = if ($cpuDiff -eq 0) { '=' } elseif ($cpuDiff -gt 0) { "+$cpuDiff" } else { "$cpuDiff" }
                        $memDiff = [double]$rec.memGiB - [double]$target.MemoryGB
                        $memDeltaStr = if ($memDiff -eq 0) { '=' } elseif ($memDiff -gt 0) { "+$memDiff" } else { "$memDiff" }
                        $diskDiff = [int]$rec.MaxDisks - [int]$target.MaxDataDiskCount
                        $diskDeltaStr = if ($diskDiff -eq 0) { '=' } elseif ($diskDiff -gt 0) { "+$diskDiff" } else { "$diskDiff" }
                        $iopsDiff = [int]$rec.IOPS - [int]$target.UncachedDiskIOPS
                        $iopsDeltaStr = if ($iopsDiff -eq 0) { '=' } elseif ($iopsDiff -gt 0) { "+$iopsDiff" } else { "$iopsDiff" }
                    }

                    # Build Details string explaining why this recommendation was selected
                    $targetFamily = $target.Family
                    $targetVersion = [int]$target.FamilyVersion
                    $recFamily = Get-SkuFamily $rec.sku
                    $recVersion = if ($rec.sku -match '_v(\d+)$') { [int]$Matches[1] } else { 1 }

                    $detailParts = [System.Collections.Generic.List[string]]::new()

                    # Upgrade path recommendations get their reason from the knowledge base
                    if ($sel.MatchType -like 'Upgrade:*' -and $upgradePathData) {
                        $detailNormFamily = if ($targetFamily -cmatch '^([A-Z]+)S$' -and $targetFamily -notin 'NVS','NCS','NDS','HBS','HCS','HXS','FXS') { $Matches[1] } else { $targetFamily }
                        $pathKey = "${detailNormFamily}v${targetVersion}"
                        $upgradePath = $upgradePathData.upgradePaths.$pathKey
                        if ($upgradePath) {
                            $pathTypeKey = switch -Wildcard ($sel.MatchType) {
                                '*Drop-in'        { 'dropIn' }
                                '*Future-proof'    { 'futureProof' }
                                '*Cost-optimized'  { 'costOptimized' }
                            }
                            $pathEntry = if ($pathTypeKey) { $upgradePath.$pathTypeKey } else { $null }
                            if ($pathEntry -and $pathEntry.reason) {
                                $detailParts.Add($pathEntry.reason)
                            }
                            if ($pathEntry -and $pathEntry.requirements -and $pathEntry.requirements.Count -gt 0) {
                                $detailParts.Add("Requires: $($pathEntry.requirements -join ', ')")
                            }
                        }
                        if ($rec.capacity -eq 'Not scanned') {
                            $detailParts.Add("availability not verified (region not scanned)")
                        }
                    }
                    else {
                        # Weighted recommendation — existing family/version analysis
                        if ($recFamily -eq $targetFamily) {
                            if ($recVersion -gt $targetVersion) {
                                $detailParts.Add("$targetFamily-family v$targetVersion→v$recVersion upgrade")
                            }
                            elseif ($recVersion -eq $targetVersion) {
                                $detailParts.Add("Same $targetFamily-family v$recVersion")
                            }
                            else {
                                $detailParts.Add("$targetFamily-family v$recVersion (older generation)")
                            }
                        }
                        else {
                            $hasSameFamily = $allRecs | Where-Object { (Get-SkuFamily $_.sku) -eq $targetFamily } | Select-Object -First 1
                            if ($hasSameFamily) {
                                $detailParts.Add("Cross-family: $recFamily-family v$recVersion selected (same-family options scored lower)")
                            }
                            else {
                                $detailParts.Add("Cross-family: $recFamily-family v$recVersion (no $targetFamily-family v${targetVersion}+ available)")
                            }
                        }

                        if ($sel.MatchType -eq 'Like-for-like') {
                            $detailParts.Add("same vCPU count ($($rec.vCPU))")
                        }
                        elseif ($sel.MatchType -eq 'IOPS match') {
                            $detailParts.Add("IOPS guarantee: maintains ≥$($target.UncachedDiskIOPS) IOPS")
                        }
                    }

                    if ($cpuDiff -ne 0 -or $memDiff -ne 0) {
                        $resizeParts = @()
                        if ($cpuDiff -gt 0) { $resizeParts += "+$cpuDiff vCPU" }
                        elseif ($cpuDiff -lt 0) { $resizeParts += "$cpuDiff vCPU" }
                        if ($memDiff -gt 0) { $resizeParts += "+$memDiff GB RAM" }
                        elseif ($memDiff -lt 0) { $resizeParts += "$memDiff GB RAM" }
                        if ($resizeParts.Count -gt 0) { $detailParts.Add("resize: $($resizeParts -join ', ')") }
                    }

                    $detailsStr = $detailParts -join '; '

                    $lifecycleResults.Add([pscustomobject]@{
                        SKU              = if ($isFirstRow) { $target.Name } else { '' }
                        DeployedRegion   = if ($isFirstRow) { if ($deployedRegion) { $deployedRegion } else { '-' } } else { '' }
                        Qty              = if ($isFirstRow) { $entryQty } else { '' }
                        vCPU             = if ($isFirstRow) { $target.vCPU } else { '' }
                        MemoryGB         = if ($isFirstRow) { $target.MemoryGB } else { '' }
                        Generation       = if ($isFirstRow) { "v$generation" } else { '' }
                        RiskLevel        = if ($isFirstRow) { $riskLevel } else { '' }
                        RiskReasons      = if ($isFirstRow) { ($riskReasons -join '; ') } else { '' }
                        QuotaStatus      = if ($isFirstRow) { $targetQuotaStatus } else { '' }
                        MatchType        = $sel.MatchType
                        TopAlternative   = $rec.sku
                        AltScore         = if ($rec.score -is [ValueType] -and $rec.score -isnot [bool]) { "$([int]$rec.score)%" } else { '' }
                        CpuDelta         = $cpuDeltaStr
                        MemDelta         = $memDeltaStr
                        DiskDelta        = $diskDeltaStr
                        IopsDelta        = $iopsDeltaStr
                        AltCapacity      = $rec.capacity
                        AltQuotaStatus   = $thisAltQuota
                        PriceDiff        = $priceDiffStr
                        TotalPriceDiff   = $totalDiffStr
                        PAYG1Yr          = $payg1YrStr
                        PAYG3Yr          = $payg3YrStr
                        SP1YrSavings     = $sp1YrSavingsStr
                        SP3YrSavings     = $sp3YrSavingsStr
                        RI1YrSavings     = $ri1YrSavingsStr
                        RI3YrSavings     = $ri3YrSavingsStr
                        AlternativeCount = if ($isFirstRow) { $allRecs.Count } else { '' }
                        Details          = $detailsStr
                    })

                    $isFirstRow = $false
                }
            }
        }
    }

    # Print lifecycle summary
    $uniqueSkuCount = @($lifecycleResults | Where-Object { $_.SKU -ne '' }).Count
    $totalVMCount = ($lifecycleResults | Where-Object { $_.Qty -ne '' } | Measure-Object -Property Qty -Sum).Sum
    if (-not $JsonOutput) {
        Write-Host ""
        Write-Host ("=" * $script:OutputWidth) -ForegroundColor Gray
        Write-Host "LIFECYCLE RECOMMENDATIONS SUMMARY  ($uniqueSkuCount SKUs, $totalVMCount VMs)" -ForegroundColor Green
        Write-Host ("=" * $script:OutputWidth) -ForegroundColor Gray
        Write-Host ""

        if ($NoQuota) {
            if ($FetchPricing) {
                $sumFmt = " {0,-26} {1,-13} {2,-4} {3,-5} {4,-7} {5,-4} {6,-7} {7,-33} {8,-24} {9,-26} {10,-6} {11,-5} {12,-5} {13,-7} {14,-8} {15,-10} {16,-12}"
                Write-Host ($sumFmt -f 'Current SKU', 'Region', 'Qty', 'vCPU', 'Mem(GB)', 'Gen', 'Risk', 'Risk Reasons', 'Match Type', 'Alternative', 'Score', 'CPU+/-', 'Mem+/-', 'Disk+/-', 'IOPS+/-', 'Price Diff', 'Total') -ForegroundColor White
            }
            else {
                $sumFmt = " {0,-26} {1,-13} {2,-4} {3,-5} {4,-7} {5,-4} {6,-7} {7,-33} {8,-24} {9,-26} {10,-6} {11,-5} {12,-5} {13,-7} {14,-8}"
                Write-Host ($sumFmt -f 'Current SKU', 'Region', 'Qty', 'vCPU', 'Mem(GB)', 'Gen', 'Risk', 'Risk Reasons', 'Match Type', 'Alternative', 'Score', 'CPU+/-', 'Mem+/-', 'Disk+/-', 'IOPS+/-') -ForegroundColor White
            }
        }
        else {
            if ($FetchPricing) {
                $sumFmt = " {0,-26} {1,-13} {2,-4} {3,-5} {4,-7} {5,-4} {6,-7} {7,-22} {8,-33} {9,-24} {10,-26} {11,-6} {12,-5} {13,-5} {14,-7} {15,-8} {16,-10} {17,-10} {18,-12}"
                Write-Host ($sumFmt -f 'Current SKU', 'Region', 'Qty', 'vCPU', 'Mem(GB)', 'Gen', 'Risk', 'Quota (used/limit)', 'Risk Reasons', 'Match Type', 'Alternative', 'Score', 'CPU+/-', 'Mem+/-', 'Disk+/-', 'IOPS+/-', 'Alt Quota', 'Price Diff', 'Total') -ForegroundColor White
            }
            else {
                $sumFmt = " {0,-26} {1,-13} {2,-4} {3,-5} {4,-7} {5,-4} {6,-7} {7,-22} {8,-33} {9,-24} {10,-26} {11,-6} {12,-5} {13,-5} {14,-7} {15,-8} {16,-10}"
                Write-Host ($sumFmt -f 'Current SKU', 'Region', 'Qty', 'vCPU', 'Mem(GB)', 'Gen', 'Risk', 'Quota (used/limit)', 'Risk Reasons', 'Match Type', 'Alternative', 'Score', 'CPU+/-', 'Mem+/-', 'Disk+/-', 'IOPS+/-', 'Alt Quota') -ForegroundColor White
            }
        }
        Write-Host (' ' + ('-' * ($script:OutputWidth - 2))) -ForegroundColor DarkGray

        $lastSeenRiskColor = 'Gray'
        foreach ($r in $lifecycleResults) {
            if ($r.RiskLevel -and $r.RiskLevel -ne '') {
                $riskColor = switch ($r.RiskLevel) {
                    'High'   { 'Red' }
                    'Medium' { 'Yellow' }
                    'Low'    { 'Green' }
                    default  { 'Gray' }
                }
                $lastSeenRiskColor = $riskColor
            }
            else {
                $riskColor = $lastSeenRiskColor
            }
            if ($NoQuota) {
                [object[]]$fmtArgs = @($r.SKU, $r.DeployedRegion, $r.Qty, $r.vCPU, $r.MemoryGB, $r.Generation, $r.RiskLevel, $r.RiskReasons, $r.MatchType, $r.TopAlternative, $r.AltScore, $r.CpuDelta, $r.MemDelta, $r.DiskDelta, $r.IopsDelta)
            }
            else {
                [object[]]$fmtArgs = @($r.SKU, $r.DeployedRegion, $r.Qty, $r.vCPU, $r.MemoryGB, $r.Generation, $r.RiskLevel, $r.QuotaStatus, $r.RiskReasons, $r.MatchType, $r.TopAlternative, $r.AltScore, $r.CpuDelta, $r.MemDelta, $r.DiskDelta, $r.IopsDelta, $r.AltQuotaStatus)
            }
            if ($FetchPricing) { $fmtArgs += @($r.PriceDiff, $r.TotalPriceDiff) }
            $line = $sumFmt -f $fmtArgs
            Write-Host $line -ForegroundColor $riskColor
        }

        $highRisk = @($lifecycleResults | Where-Object { $_.RiskLevel -eq 'High' })
        $medRisk = @($lifecycleResults | Where-Object { $_.RiskLevel -eq 'Medium' })
        $highVMs = ($highRisk | Measure-Object -Property Qty -Sum).Sum
        $medVMs = ($medRisk | Measure-Object -Property Qty -Sum).Sum
        Write-Host ""
        if ($highRisk.Count -gt 0) {
            Write-Host "  $($highRisk.Count) SKU(s) ($highVMs VMs) at HIGH risk — immediate action recommended" -ForegroundColor Red
        }
        if ($medRisk.Count -gt 0) {
            Write-Host "  $($medRisk.Count) SKU(s) ($medVMs VMs) at MEDIUM risk — plan migration to current generation" -ForegroundColor Yellow
        }
        if ($highRisk.Count -eq 0 -and $medRisk.Count -eq 0) {
            Write-Host "  All SKUs are current generation with good availability" -ForegroundColor Green
        }
        Write-Host ("=" * $script:OutputWidth) -ForegroundColor Gray
    }

    # XLSX Export — auto-export lifecycle results
    if (-not $JsonOutput -and (Test-ImportExcelModule)) {
        $lcTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        if ($InputFile) {
            $sourceDir = [System.IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $InputFile).Path)
            $sourceBase = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
        }
        else {
            $sourceDir = $PWD.Path
            $sourceBase = 'AzVMLifecycle'
        }
        $lcXlsxFile = Join-Path $sourceDir "${sourceBase}_Lifecycle_Recommendations_${lcTimestamp}.xlsx"

        try {
            $greenFill = [System.Drawing.Color]::FromArgb(198, 239, 206)
            $greenText = [System.Drawing.Color]::FromArgb(0, 97, 0)
            $yellowFill = [System.Drawing.Color]::FromArgb(255, 235, 156)
            $yellowText = [System.Drawing.Color]::FromArgb(156, 101, 0)
            $redFill = [System.Drawing.Color]::FromArgb(255, 199, 206)
            $redText = [System.Drawing.Color]::FromArgb(156, 0, 6)
            $headerBlue = [System.Drawing.Color]::FromArgb(0, 120, 212)
            $lightGray = [System.Drawing.Color]::FromArgb(242, 242, 242)
            $naGray = [System.Drawing.Color]::FromArgb(191, 191, 191)

            #region Lifecycle Summary Sheet
            # Tag continuation rows with parent's risk level, SKU, and group sequence for sorting
            $lastParentRisk = 'Low'
            $lastParentSKU = ''
            $groupSeq = 0
            $rowSeq = 0
            foreach ($lr in $lifecycleResults) {
                if ($lr.SKU -and $lr.SKU -ne '') {
                    $lastParentRisk = $lr.RiskLevel
                    $lastParentSKU = $lr.SKU
                    $groupSeq++
                    $rowSeq = 0
                }
                $lr | Add-Member -NotePropertyName '_ParentRisk' -NotePropertyValue $lastParentRisk -Force
                $lr | Add-Member -NotePropertyName '_ParentSKU' -NotePropertyValue $lastParentSKU -Force
                $lr | Add-Member -NotePropertyName '_GroupSeq' -NotePropertyValue $groupSeq -Force
                $lr | Add-Member -NotePropertyName '_RowSeq' -NotePropertyValue $rowSeq -Force
                $rowSeq++
            }

            $lcSortedResults = $lifecycleResults | Sort-Object @{e={switch($_._ParentRisk){'High'{0}'Medium'{1}'Low'{2}default{3}}}}, _ParentSKU, _GroupSeq, _RowSeq

            # Detect sovereign/GOV tenant — all SP values are N/A, so omit those columns entirely
            $isSovereignTenant = $script:TargetEnvironment -in @('AzureUSGovernment', 'AzureChinaCloud', 'AzureGermanCloud')

            # SP/RI columns included only with -RateOptimization flag (SP columns excluded for sovereign tenants)
            $rateOptCols = if ($RateOptimization) {
                $cols = @()
                if (-not $isSovereignTenant) {
                    $cols += @{N='SP 1-Year Savings';E={$_.SP1YrSavings}}
                    $cols += @{N='SP 3-Year Savings';E={$_.SP3YrSavings}}
                }
                $cols += @{N='RI 1-Year Savings';E={$_.RI1YrSavings}}
                $cols += @{N='RI 3-Year Savings';E={$_.RI3YrSavings}}
                $cols
            } else { @() }

            # PAYG pricing columns included only with -ShowPricing
            $pricingCols = if ($FetchPricing) {
                @(
                    @{N='Price Diff';E={$_.PriceDiff}}, @{N='Total';E={$_.TotalPriceDiff}},
                    @{N='1-Year Cost';E={$_.PAYG1Yr}}, @{N='3-Year Cost';E={$_.PAYG3Yr}}
                ) + $rateOptCols
            } else { @() }

            if ($NoQuota) {
                $lcProps = @(
                    @{N='SKU';E={$_.SKU}}, @{N='Region';E={$_.DeployedRegion}}, @{N='Qty';E={$_.Qty}},
                    @{N='vCPU';E={$_.vCPU}}, @{N='Memory (GB)';E={$_.MemoryGB}}, @{N='Generation';E={$_.Generation}},
                    @{N='Risk Level';E={$_.RiskLevel}}, @{N='Risk Reasons';E={$_.RiskReasons}},
                    @{N='Match Type';E={$_.MatchType}}, @{N='Alternative';E={$_.TopAlternative}}, @{N='Alt Score';E={$_.AltScore}},
                    @{N='CPU +/-';E={$_.CpuDelta}}, @{N='Mem +/-';E={$_.MemDelta}},
                    @{N='Disk +/-';E={$_.DiskDelta}}, @{N='IOPS +/-';E={$_.IopsDelta}}
                ) + $pricingCols + @(@{N='Details';E={$_.Details}})
                $lcExportRows = $lcSortedResults | Select-Object -Property $lcProps
                $riskColLetter = 'G'
                $altColLetter = 'J'
                $riskReasonsColNum = 8
            }
            else {
                $lcProps = @(
                    @{N='SKU';E={$_.SKU}}, @{N='Region';E={$_.DeployedRegion}}, @{N='Qty';E={$_.Qty}},
                    @{N='vCPU';E={$_.vCPU}}, @{N='Memory (GB)';E={$_.MemoryGB}}, @{N='Generation';E={$_.Generation}},
                    @{N='Risk Level';E={$_.RiskLevel}}, @{N='Risk Reasons';E={$_.RiskReasons}},
                    @{N='Quota (Used/Limit)';E={$_.QuotaStatus}},
                    @{N='Match Type';E={$_.MatchType}}, @{N='Alternative';E={$_.TopAlternative}}, @{N='Alt Score';E={$_.AltScore}},
                    @{N='CPU +/-';E={$_.CpuDelta}}, @{N='Mem +/-';E={$_.MemDelta}},
                    @{N='Disk +/-';E={$_.DiskDelta}}, @{N='IOPS +/-';E={$_.IopsDelta}},
                    @{N='Alt Quota';E={$_.AltQuotaStatus}}
                ) + $pricingCols + @(@{N='Details';E={$_.Details}})
                $lcExportRows = $lcSortedResults | Select-Object -Property $lcProps
                $riskColLetter = 'G'
                $altColLetter = 'K'
                $riskReasonsColNum = 8
            }

            $excel = $lcExportRows | Export-Excel -Path $lcXlsxFile -WorksheetName "Lifecycle Summary" -AutoSize -AutoFilter -FreezeTopRow -PassThru

            $ws = $excel.Workbook.Worksheets["Lifecycle Summary"]
            $lastRow = $ws.Dimension.End.Row
            $lastCol = $ws.Dimension.End.Column

            # Azure-blue header row
            $headerRange = $ws.Cells["A1:$(ConvertTo-ExcelColumnLetter $lastCol)1"]
            $headerRange.Style.Font.Bold = $true
            $headerRange.Style.Font.Color.SetColor([System.Drawing.Color]::White)
            $headerRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $headerRange.Style.Fill.BackgroundColor.SetColor($headerBlue)
            $headerRange.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center

            # Alternating row colors
            for ($row = 2; $row -le $lastRow; $row++) {
                if ($row % 2 -eq 0) {
                    $rowRange = $ws.Cells["A$row`:$(ConvertTo-ExcelColumnLetter $lastCol)$row"]
                    $rowRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                    $rowRange.Style.Fill.BackgroundColor.SetColor($lightGray)
                }
            }

            # Risk Level column — conditional formatting
            $riskRange = "${riskColLetter}2:${riskColLetter}$lastRow"
            Add-ConditionalFormatting -Worksheet $ws -Range $riskRange -RuleType ContainsText -ConditionValue "High" -BackgroundColor $redFill -ForegroundColor $redText
            Add-ConditionalFormatting -Worksheet $ws -Range $riskRange -RuleType ContainsText -ConditionValue "Medium" -BackgroundColor $yellowFill -ForegroundColor $yellowText
            Add-ConditionalFormatting -Worksheet $ws -Range $riskRange -RuleType ContainsText -ConditionValue "Low" -BackgroundColor $greenFill -ForegroundColor $greenText

            # Alternative column — highlight N/A
            $altRange = "${altColLetter}2:${altColLetter}$lastRow"
            Add-ConditionalFormatting -Worksheet $ws -Range $altRange -RuleType Equal -ConditionValue "N/A" -BackgroundColor $lightGray -ForegroundColor $naGray
            Add-ConditionalFormatting -Worksheet $ws -Range $altRange -RuleType Equal -ConditionValue "-" -BackgroundColor $redFill -ForegroundColor $redText

            # Thin borders on all data cells
            $dataRange = $ws.Cells["A1:$(ConvertTo-ExcelColumnLetter $lastCol)$lastRow"]
            $dataRange.Style.Border.Top.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
            $dataRange.Style.Border.Bottom.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
            $dataRange.Style.Border.Left.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
            $dataRange.Style.Border.Right.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin

            # Center-align numeric and short columns
            $ws.Cells["C2:F$lastRow"].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
            $ws.Cells["${riskColLetter}2:${riskColLetter}$lastRow"].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center

            # Widen Risk Reasons column
            $ws.Column($riskReasonsColNum).Width = 50

            # Summary footer rows
            $footerStart = $lastRow + 2
            $highRisk = @($lifecycleResults | Where-Object { $_.RiskLevel -eq 'High' })
            $medRisk = @($lifecycleResults | Where-Object { $_.RiskLevel -eq 'Medium' })
            $lowRisk = @($lifecycleResults | Where-Object { $_.RiskLevel -eq 'Low' })
            $highVMs = ($highRisk | Measure-Object -Property Qty -Sum).Sum
            $medVMs = ($medRisk | Measure-Object -Property Qty -Sum).Sum
            $lowVMs = ($lowRisk | Measure-Object -Property Qty -Sum).Sum

            $ws.Cells["A$footerStart"].Value = "SUMMARY"
            $ws.Cells["A$footerStart`:F$footerStart"].Merge = $true
            $ws.Cells["A$footerStart"].Style.Font.Bold = $true
            $ws.Cells["A$footerStart"].Style.Font.Size = 11
            $ws.Cells["A$footerStart`:F$footerStart"].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $ws.Cells["A$footerStart`:F$footerStart"].Style.Fill.BackgroundColor.SetColor($headerBlue)
            $ws.Cells["A$footerStart`:F$footerStart"].Style.Font.Color.SetColor([System.Drawing.Color]::White)

            $summaryItems = @(
                @{ Label = "Total SKUs"; Value = "$uniqueSkuCount"; VMs = "$totalVMCount VMs" }
                @{ Label = "HIGH Risk"; Value = "$($highRisk.Count) SKUs"; VMs = "$highVMs VMs — immediate action" }
                @{ Label = "MEDIUM Risk"; Value = "$($medRisk.Count) SKUs"; VMs = "$medVMs VMs — plan migration" }
                @{ Label = "LOW Risk"; Value = "$($lowRisk.Count) SKUs"; VMs = "$lowVMs VMs — no action needed" }
            )

            $sRow = $footerStart + 1
            foreach ($si in $summaryItems) {
                $ws.Cells["A$sRow"].Value = $si.Label
                $ws.Cells["A$sRow"].Style.Font.Bold = $true
                $ws.Cells["B$sRow"].Value = $si.Value
                $ws.Cells["C$sRow`:F$sRow"].Merge = $true
                $ws.Cells["C$sRow"].Value = $si.VMs

                $ws.Cells["A$sRow`:F$sRow"].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                switch ($si.Label) {
                    "HIGH Risk" { $ws.Cells["A$sRow`:F$sRow"].Style.Fill.BackgroundColor.SetColor($redFill); $ws.Cells["A$sRow`:F$sRow"].Style.Font.Color.SetColor($redText) }
                    "MEDIUM Risk" { $ws.Cells["A$sRow`:F$sRow"].Style.Fill.BackgroundColor.SetColor($yellowFill); $ws.Cells["A$sRow`:F$sRow"].Style.Font.Color.SetColor($yellowText) }
                    "LOW Risk" { $ws.Cells["A$sRow`:F$sRow"].Style.Fill.BackgroundColor.SetColor($greenFill); $ws.Cells["A$sRow`:F$sRow"].Style.Font.Color.SetColor($greenText) }
                    default { $ws.Cells["A$sRow`:F$sRow"].Style.Fill.BackgroundColor.SetColor($lightGray) }
                }
                $sRow++
            }
            #endregion Lifecycle Summary Sheet

            #region Risk Breakdown Sheet
            $highBase = @($lifecycleResults | Where-Object { $_._ParentRisk -eq 'High' })
            if ($NoQuota) {
                $hrProps = @(
                    @{N='SKU';E={$_.SKU}}, @{N='Region';E={$_.DeployedRegion}}, @{N='Qty';E={$_.Qty}},
                    @{N='vCPU';E={$_.vCPU}}, @{N='Memory (GB)';E={$_.MemoryGB}}, @{N='Generation';E={$_.Generation}},
                    @{N='Risk Reasons';E={$_.RiskReasons}},
                    @{N='Match Type';E={$_.MatchType}}, @{N='Alternative';E={$_.TopAlternative}}, @{N='Alt Score';E={$_.AltScore}},
                    @{N='CPU +/-';E={$_.CpuDelta}}, @{N='Mem +/-';E={$_.MemDelta}},
                    @{N='Disk +/-';E={$_.DiskDelta}}, @{N='IOPS +/-';E={$_.IopsDelta}}
                ) + $pricingCols + @(@{N='Details';E={$_.Details}})
                $highRows = @($highBase | Select-Object -Property $hrProps)
            }
            else {
                $hrProps = @(
                    @{N='SKU';E={$_.SKU}}, @{N='Region';E={$_.DeployedRegion}}, @{N='Qty';E={$_.Qty}},
                    @{N='vCPU';E={$_.vCPU}}, @{N='Memory (GB)';E={$_.MemoryGB}}, @{N='Generation';E={$_.Generation}},
                    @{N='Risk Reasons';E={$_.RiskReasons}},
                    @{N='Quota (Used/Limit)';E={$_.QuotaStatus}},
                    @{N='Match Type';E={$_.MatchType}}, @{N='Alternative';E={$_.TopAlternative}}, @{N='Alt Score';E={$_.AltScore}},
                    @{N='CPU +/-';E={$_.CpuDelta}}, @{N='Mem +/-';E={$_.MemDelta}},
                    @{N='Disk +/-';E={$_.DiskDelta}}, @{N='IOPS +/-';E={$_.IopsDelta}},
                    @{N='Alt Quota';E={$_.AltQuotaStatus}}
                ) + $pricingCols + @(@{N='Details';E={$_.Details}})
                $highRows = @($highBase | Select-Object -Property $hrProps)
            }

            if ($highRows.Count -gt 0) {
                $excel = $highRows | Export-Excel -ExcelPackage $excel -WorksheetName "High Risk" -AutoSize -AutoFilter -FreezeTopRow -PassThru
                $wsH = $excel.Workbook.Worksheets["High Risk"]
                $hLastRow = $wsH.Dimension.End.Row
                $hLastCol = $wsH.Dimension.End.Column

                $hHeader = $wsH.Cells["A1:$(ConvertTo-ExcelColumnLetter $hLastCol)1"]
                $hHeader.Style.Font.Bold = $true
                $hHeader.Style.Font.Color.SetColor([System.Drawing.Color]::White)
                $hHeader.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                $hHeader.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb(156, 0, 6))

                for ($row = 2; $row -le $hLastRow; $row++) {
                    $rowRange = $wsH.Cells["A$row`:$(ConvertTo-ExcelColumnLetter $hLastCol)$row"]
                    $rowRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                    $rowRange.Style.Fill.BackgroundColor.SetColor($(if ($row % 2 -eq 0) { $redFill } else { [System.Drawing.Color]::White }))
                }
            }

            $medBase = @($lifecycleResults | Where-Object { $_._ParentRisk -eq 'Medium' })
            if ($NoQuota) {
                $mrProps = @(
                    @{N='SKU';E={$_.SKU}}, @{N='Region';E={$_.DeployedRegion}}, @{N='Qty';E={$_.Qty}},
                    @{N='vCPU';E={$_.vCPU}}, @{N='Memory (GB)';E={$_.MemoryGB}}, @{N='Generation';E={$_.Generation}},
                    @{N='Risk Reasons';E={$_.RiskReasons}},
                    @{N='Match Type';E={$_.MatchType}}, @{N='Alternative';E={$_.TopAlternative}}, @{N='Alt Score';E={$_.AltScore}},
                    @{N='CPU +/-';E={$_.CpuDelta}}, @{N='Mem +/-';E={$_.MemDelta}},
                    @{N='Disk +/-';E={$_.DiskDelta}}, @{N='IOPS +/-';E={$_.IopsDelta}}
                ) + $pricingCols + @(@{N='Details';E={$_.Details}})
                $medRows = @($medBase | Select-Object -Property $mrProps)
            }
            else {
                $mrProps = @(
                    @{N='SKU';E={$_.SKU}}, @{N='Region';E={$_.DeployedRegion}}, @{N='Qty';E={$_.Qty}},
                    @{N='vCPU';E={$_.vCPU}}, @{N='Memory (GB)';E={$_.MemoryGB}}, @{N='Generation';E={$_.Generation}},
                    @{N='Risk Reasons';E={$_.RiskReasons}},
                    @{N='Quota (Used/Limit)';E={$_.QuotaStatus}},
                    @{N='Match Type';E={$_.MatchType}}, @{N='Alternative';E={$_.TopAlternative}}, @{N='Alt Score';E={$_.AltScore}},
                    @{N='CPU +/-';E={$_.CpuDelta}}, @{N='Mem +/-';E={$_.MemDelta}},
                    @{N='Disk +/-';E={$_.DiskDelta}}, @{N='IOPS +/-';E={$_.IopsDelta}},
                    @{N='Alt Quota';E={$_.AltQuotaStatus}}
                ) + $pricingCols + @(@{N='Details';E={$_.Details}})
                $medRows = @($medBase | Select-Object -Property $mrProps)
            }

            if ($medRows.Count -gt 0) {
                $excel = $medRows | Export-Excel -ExcelPackage $excel -WorksheetName "Medium Risk" -AutoSize -AutoFilter -FreezeTopRow -PassThru
                $wsM = $excel.Workbook.Worksheets["Medium Risk"]
                $mLastRow = $wsM.Dimension.End.Row
                $mLastCol = $wsM.Dimension.End.Column

                $mHeader = $wsM.Cells["A1:$(ConvertTo-ExcelColumnLetter $mLastCol)1"]
                $mHeader.Style.Font.Bold = $true
                $mHeader.Style.Font.Color.SetColor([System.Drawing.Color]::White)
                $mHeader.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                $mHeader.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb(156, 101, 0))

                for ($row = 2; $row -le $mLastRow; $row++) {
                    $rowRange = $wsM.Cells["A$row`:$(ConvertTo-ExcelColumnLetter $mLastCol)$row"]
                    $rowRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                    $rowRange.Style.Fill.BackgroundColor.SetColor($(if ($row % 2 -eq 0) { $yellowFill } else { [System.Drawing.Color]::White }))
                }
            }
            #endregion Risk Breakdown Sheet

            #region Deployment Map Sheets (-SubMap / -RGMap)
            # Build risk lookup once for all map sheets
            $riskLookup = @{}
            if ($SubMap -or $RGMap) {
                foreach ($lr in $lifecycleResults) {
                    $riskKey = "$($lr.SKU)|$($lr.DeployedRegion)"
                    if (-not $riskLookup.ContainsKey($riskKey)) {
                        $riskLookup[$riskKey] = @{ RiskLevel = $lr.RiskLevel; RiskReasons = $lr.RiskReasons }
                    }
                }
            }

            # Helper scriptblock to enrich, export, and style a deployment map sheet
            $exportMapSheet = {
                param($mapRows, $sheetName, $hasRG)
                $enriched = [System.Collections.Generic.List[PSCustomObject]]::new()
                foreach ($mapRow in $mapRows) {
                    $rKey = "$($mapRow.SKU)|$($mapRow.Region)"
                    $risk = $riskLookup[$rKey]
                    $props = [ordered]@{
                        SubscriptionId   = $mapRow.SubscriptionId
                        SubscriptionName = $mapRow.SubscriptionName
                    }
                    if ($hasRG) { $props['ResourceGroup'] = $mapRow.ResourceGroup }
                    $props['Region']      = $mapRow.Region
                    $props['SKU']         = $mapRow.SKU
                    $props['Qty']         = $mapRow.Qty
                    $props['RiskLevel']   = if ($risk) { $risk.RiskLevel } else { 'Low' }
                    $props['RiskReasons'] = if ($risk) { $risk.RiskReasons } else { '' }
                    $enriched.Add([pscustomobject]$props)
                }
                $excel = $enriched | Export-Excel -ExcelPackage $excel -WorksheetName $sheetName -AutoSize -AutoFilter -FreezeTopRow -PassThru
                $wsMap = $excel.Workbook.Worksheets[$sheetName]
                $mapLastRow = $wsMap.Dimension.End.Row
                $mapLastCol = $wsMap.Dimension.End.Column
                $mapHeader = $wsMap.Cells["A1:$(ConvertTo-ExcelColumnLetter $mapLastCol)1"]
                $mapHeader.Style.Font.Bold = $true
                $mapHeader.Style.Font.Color.SetColor([System.Drawing.Color]::White)
                $mapHeader.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                $mapHeader.Style.Fill.BackgroundColor.SetColor($headerBlue)
                $riskColNum = if ($hasRG) { 7 } else { 6 }
                $riskColLtr = ConvertTo-ExcelColumnLetter $riskColNum
                for ($row = 2; $row -le $mapLastRow; $row++) {
                    $rowRange = $wsMap.Cells["A$row`:$(ConvertTo-ExcelColumnLetter $mapLastCol)$row"]
                    $rowRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                    $rowRange.Style.Fill.BackgroundColor.SetColor($(if ($row % 2 -eq 0) { $lightGray } else { [System.Drawing.Color]::White }))
                    $riskCell = $wsMap.Cells["$riskColLtr$row"]
                    $riskVal = $riskCell.Value
                    if ($riskVal -eq 'High') {
                        $riskCell.Style.Font.Color.SetColor($redText)
                        $riskCell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                        $riskCell.Style.Fill.BackgroundColor.SetColor($redFill)
                    }
                    elseif ($riskVal -eq 'Medium') {
                        $riskCell.Style.Font.Color.SetColor($yellowText)
                        $riskCell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                        $riskCell.Style.Fill.BackgroundColor.SetColor($yellowFill)
                    }
                    elseif ($riskVal -eq 'Low') {
                        $riskCell.Style.Font.Color.SetColor($greenText)
                        $riskCell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                        $riskCell.Style.Fill.BackgroundColor.SetColor($greenFill)
                    }
                }
                return $excel
            }

            if ($SubMap -and $subMapRows -and $subMapRows.Count -gt 0) {
                $excel = & $exportMapSheet $subMapRows "Subscription Map" $false
            }
            if ($RGMap -and $rgMapRows -and $rgMapRows.Count -gt 0) {
                $excel = & $exportMapSheet $rgMapRows "Resource Group Map" $true
            }
            #endregion Deployment Map Sheets

            Close-ExcelPackage $excel

            Write-Host ""
            Write-Host "Lifecycle report exported: $lcXlsxFile" -ForegroundColor Green
            $sheetList = "Lifecycle Summary"
            if ($highRows.Count -gt 0) { $sheetList += ", High Risk" }
            if ($medRows.Count -gt 0) { $sheetList += ", Medium Risk" }
            if ($SubMap -and $subMapRows -and $subMapRows.Count -gt 0) {
                $sheetList += ", Subscription Map"
            }
            if ($RGMap -and $rgMapRows -and $rgMapRows.Count -gt 0) {
                $sheetList += ", Resource Group Map"
            }
            Write-Host "  Sheets: $sheetList" -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Failed to export lifecycle XLSX: $_"
        }
    }
    elseif (-not $JsonOutput -and -not (Test-ImportExcelModule)) {
        Write-Host ""
        Write-Host "Tip: Install ImportExcel for styled XLSX export: Install-Module ImportExcel -Scope CurrentUser" -ForegroundColor DarkGray
    }

    if ($JsonOutput) {
        $jsonResult = @{
            schemaVersion = '1.0'
            mode          = 'lifecycle'
            skuCount      = $lifecycleEntries.Count
            totalVMs      = $totalVMCount
            results       = @($lifecycleResults)
        }
        if ($SubMap -and $subMapRows -and $subMapRows.Count -gt 0) {
            $jsonResult['subscriptionMap'] = @{
                groupBy = 'Subscription'
                rows    = @($subMapRows)
            }
        }
        if ($RGMap -and $rgMapRows -and $rgMapRows.Count -gt 0) {
            $jsonResult['resourceGroupMap'] = @{
                groupBy = 'ResourceGroup'
                rows    = @($rgMapRows)
            }
        }
        $jsonResult | ConvertTo-Json -Depth 5
    }

    return
}

#endregion Lifecycle Recommendations
}
finally {
    [void](Restore-OriginalSubscriptionContext -OriginalSubscriptionId $initialSubscriptionId)
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose "Transcript already stopped: $($_.Exception.Message)" }
    }
}
