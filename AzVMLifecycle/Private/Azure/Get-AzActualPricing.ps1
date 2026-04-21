function Get-AzActualPricing {
    <#
    .SYNOPSIS
        Derives effective negotiated VM pricing from Cost Management usage data.
    .DESCRIPTION
        Uses the Cost Management Query API to aggregate actual VM costs and usage
        quantities, then derives the effective hourly rate (cost / hours).
        Works for ALL billing types (EA, MCA, CSP, PAYG) and sovereign clouds.
        Only requires Reader or Cost Management Reader role on the subscription.
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
    $cacheKey = "$SubscriptionId-$Region"

    if ($Caches.ActualPricing.ContainsKey($cacheKey)) {
        return $Caches.ActualPricing[$cacheKey]
    }

    $armLocation = $Region.ToLower() -replace '\s', ''
    $allPrices = @{}

    try {
        if (-not $AzureEndpoints) {
            $AzureEndpoints = Get-AzureEndpoints -EnvironmentName $TargetEnvironment
        }
        $armUrl = $AzureEndpoints.ResourceManagerUrl

        $token = (Get-AzAccessToken -ResourceUrl $armUrl -ErrorAction Stop).Token
        $headers = @{
            'Authorization' = "Bearer $token"
            'Content-Type'  = 'application/json'
        }

        # Cost Management Query API: aggregate actual VM costs by meter for this region.
        # Server-side filters to VM meters in the target region only.
        # Effective hourly rate = PreTaxCost / UsageQuantity (quantity unit = 1 Hour for VMs).
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
                    and = @(
                        @{ dimensions = @{ name = 'MeterCategory';    operator = 'In'; values = @('Virtual Machines') } }
                        @{ dimensions = @{ name = 'ResourceLocation'; operator = 'In'; values = @($armLocation) } }
                    )
                }
                grouping = @(
                    @{ type = 'Dimension'; name = 'MeterSubCategory' }
                    @{ type = 'Dimension'; name = 'MeterName' }
                )
            }
        } | ConvertTo-Json -Depth 10

        $queryUrl = "$armUrl/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

        try {
            $response = Invoke-WithRetry -MaxRetries $MaxRetries -OperationName 'Cost Management Query' -ScriptBlock {
                Invoke-RestMethod -Uri $queryUrl -Method Post -Headers $headers -Body $queryBody -ContentType 'application/json' -TimeoutSec 60
            }
        }
        finally {
            $headers['Authorization'] = $null
            $token = $null
        }

        # Build column-name to index map from response schema
        $colMap = @{}
        for ($i = 0; $i -lt $response.properties.columns.Count; $i++) {
            $colMap[$response.properties.columns[$i].name] = $i
        }

        $costIdx   = $colMap['PreTaxCost']
        $qtyIdx    = $colMap['UsageQuantity']
        $subCatIdx = $colMap['MeterSubCategory']
        $meterIdx  = $colMap['MeterName']
        $currIdx   = if ($colMap.ContainsKey('Currency')) { $colMap['Currency'] } else { $null }

        $rowCount = 0
        if ($response.properties.rows) {
            $rowCount = $response.properties.rows.Count
        }

        foreach ($row in $response.properties.rows) {
            $cost        = [double]$row[$costIdx]
            $quantity    = [double]$row[$qtyIdx]
            $subCategory = $row[$subCatIdx]
            $meterName   = $row[$meterIdx]
            $currency    = if ($null -ne $currIdx) { $row[$currIdx] } else { 'USD' }

            if ($subCategory -match 'Windows') { continue }
            if ($quantity -le 0) { continue }

            # Derive effective hourly rate from actual usage
            $hourlyRate = $cost / $quantity

            # Convert billing meter name to ARM SKU name:
            #   "D2s v3"          → "Standard_D2s_v3"
            #   "B2ms"            → "Standard_B2ms"
            #   "E8-4as v4"       → "Standard_E8-4as_v4"
            #   "NC24ads A100 v4" → "Standard_NC24ads_A100_v4"
            #   "D2s v3 Low Priority" → "Standard_D2s_v3"  (strip Spot/LP suffix)
            $cleanName = $meterName -replace '\s+(Low Priority|Spot)\s*$', ''
            $cleanName = $cleanName.Trim()
            if ($cleanName -match '^[A-Z]') {
                $vmSize = "Standard_$($cleanName -replace '\s+', '_')"
            }
            else {
                continue
            }

            if (-not $allPrices.ContainsKey($vmSize)) {
                $allPrices[$vmSize] = @{
                    Hourly       = [math]::Round($hourlyRate, 4)
                    Monthly      = [math]::Round($hourlyRate * $HoursPerMonth, 2)
                    Currency     = $currency
                    Meter        = $meterName
                    IsNegotiated = $true
                }
            }
        }

        Write-Verbose "Cost Management Query: $rowCount usage rows, $($allPrices.Count) unique VM SKU prices for region '$armLocation'."

        $Caches.ActualPricing[$cacheKey] = $allPrices
        return $allPrices
    }
    catch {
        $errorMsg = $_.Exception.Message
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if (-not $statusCode -and $errorMsg -match '(\d{3})') {
            $statusCode = [int]$Matches[1]
        }

        # Only warn once per session (avoid repeating for each region)
        if (-not $Caches.NegotiatedPricingWarned) {
            $Caches.NegotiatedPricingWarned = $true

            switch ($statusCode) {
                401 {
                    Write-Warning "Cost Management Query: authentication failed (HTTP 401).`n  Your access token may be expired. Run: Connect-AzAccount"
                }
                403 {
                    Write-Warning "Cost Management Query: access denied (HTTP 403). Required RBAC (any one):"
                    Write-Warning "  - Cost Management Reader  (scope: subscription)"
                    Write-Warning "  - Reader                   (scope: subscription)"
                    Write-Warning "  To assign:  New-AzRoleAssignment -SignInName <user@domain> -RoleDefinitionName 'Cost Management Reader' -Scope /subscriptions/$SubscriptionId"
                }
                {$_ -in 429, 503} {
                    Write-Warning "Cost Management Query: throttled/unavailable (HTTP $statusCode). Retries exhausted."
                }
                default {
                    Write-Warning "Cost Management Query failed$(if ($statusCode) { " (HTTP $statusCode)" }): $errorMsg"
                }
            }
            Write-Warning "Falling back to retail pricing (public list prices without negotiated discounts)."
        }
        return $null
    }
}
