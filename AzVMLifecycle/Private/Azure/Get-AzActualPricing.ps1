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
    $cacheKey = "$SubscriptionId-$Region"

    if ($Caches.ActualPricing.ContainsKey($cacheKey)) {
        return $Caches.ActualPricing[$cacheKey]
    }

    $armLocation = $Region.ToLower() -replace '\s', ''
    $allPrices = @{}

    if (-not $AzureEndpoints) {
        $AzureEndpoints = Get-AzureEndpoints -EnvironmentName $TargetEnvironment
    }
    $armUrl = $AzureEndpoints.ResourceManagerUrl

    # Gov cloud EA/MCA enrollments often map gov meters to commercial region
    # display names in the Price Sheet. Build a set of acceptable normalized
    # region names so Tier 1 can match either the real or mapped name.
    $govToCommercialMap = @{
        'usgovarizona'  = 'ussouthcentral'
        'usgovtexas'    = 'usnorthcentral'
        'usgovvirginia' = 'useast'
        'usdodcentral'  = 'uscentraleuap'
        'usdodeast'     = 'useast2euap'
    }
    $acceptedRegions = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$acceptedRegions.Add($armLocation)
    if ($govToCommercialMap.ContainsKey($armLocation)) {
        [void]$acceptedRegions.Add($govToCommercialMap[$armLocation])
    }

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
    $MaxPricesheetPages = 20
    try {
        $psUrl = "$armUrl/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/pricesheets/default?api-version=2023-05-01&`$expand=properties/meterDetails&`$top=1000"
        Write-Verbose "Tier 1 (Price Sheet): calling $psUrl"

        $totalItems = 0
        $pageCount = 0
        $loggedMismatch = $false
        do {
            $pageCount++
            $psResponse = Invoke-WithRetry -MaxRetries $MaxRetries -OperationName "Consumption Price Sheet (page $pageCount)" -ScriptBlock {
                Invoke-RestMethod -Uri $psUrl -Method Get -Headers $headers -TimeoutSec 120
            }

            if ($psResponse.properties.pricesheets) {
                $totalItems += $psResponse.properties.pricesheets.Count
                foreach ($item in $psResponse.properties.pricesheets) {
                    $md = $item.meterDetails
                    if (-not $md) { continue }

                    if ($md.meterCategory -ne 'Virtual Machines') { continue }
                    if ($md.meterSubCategory -match 'Windows') { continue }

                    # Normalize meterLocation display name to ARM format
                    $meterLoc = $md.meterLocation
                    $normalizedRegion = ($meterLoc -replace '[\s-]', '').ToLower()
                    if (-not $acceptedRegions.Contains($normalizedRegion)) {
                        if (-not $loggedMismatch) {
                            Write-Verbose "  Tier 1 region filter: meterLocation='$meterLoc' normalized='$normalizedRegion' not in accepted set ($($acceptedRegions -join ', '))"
                            $loggedMismatch = $true
                        }
                        continue
                    }

                    # Convert billing meter name to ARM SKU name
                    $cleanName = $md.meterName -replace '\s+(Low Priority|Spot)\s*$', ''
                    $cleanName = $cleanName.Trim() -replace '^Standard[\s_]+', ''
                    if ($cleanName -match '^[A-Z]') {
                        $vmSize = "Standard_$($cleanName -replace '\s+', '_')"
                    }
                    else { continue }

                    if (-not $allPrices.ContainsKey($vmSize)) {
                        $negotiatedRate = [double]$item.unitPrice
                        $retailRate = if ($md.pretaxStandardRate) { [double]$md.pretaxStandardRate } else { $null }

                        $allPrices[$vmSize] = @{
                            Hourly       = [math]::Round($negotiatedRate, 4)
                            Monthly      = [math]::Round($negotiatedRate * $HoursPerMonth, 2)
                            Currency     = $item.currencyCode
                            Meter        = $md.meterName
                            IsNegotiated = $true
                        }
                        if ($retailRate -and $retailRate -gt 0) {
                            $allPrices[$vmSize].RetailHourly = [math]::Round($retailRate, 4)
                            $allPrices[$vmSize].DiscountPct  = [math]::Round((1 - ($negotiatedRate / $retailRate)) * 100, 1)
                        }
                    }
                }
            }

            $psUrl = $psResponse.properties.nextLink
        } while ($psUrl -and $pageCount -lt $MaxPricesheetPages)

        if ($allPrices.Count -gt 0) {
            $tier1Success = $true
            Write-Host "  Tier 1 (Price Sheet): $($allPrices.Count) negotiated SKU prices for '$Region'" -ForegroundColor DarkGray
            Write-Verbose "Tier 1 (Price Sheet): $totalItems items across $pageCount page(s), $($allPrices.Count) VM SKU prices for region '$armLocation'."
            $sampleKeys = @($allPrices.Keys | Select-Object -First 5) -join ', '
            Write-Verbose "  Sample SKU keys: $sampleKeys"
            $sampleDiscount = ($allPrices.Values | Where-Object { $_.DiscountPct } | Select-Object -First 1)
            if ($sampleDiscount) {
                Write-Verbose "  Sample discount: $($sampleDiscount.DiscountPct)% off retail"
            }
        }
        else {
            Write-Host "  Tier 1 (Price Sheet): no matches for '$Region' ($totalItems items scanned). Trying Tier 2..." -ForegroundColor DarkGray
            Write-Verbose "Tier 1 (Price Sheet): $totalItems items across $pageCount page(s), 0 VM matches for region '$armLocation'. Falling through to Tier 2."
        }
    }
    catch {
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
    if (-not $tier1Success) {
        try {
            # Include all accepted region name variants in the location filter
            # so gov cloud subscriptions match regardless of how Cost Management
            # stores the location (ARM name vs mapped commercial name).
            $locationValues = @($acceptedRegions | ForEach-Object { $_ })

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
                            @{ dimensions = @{ name = 'ResourceLocation'; operator = 'In'; values = $locationValues } }
                        )
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

            Write-Host "  Tier 2 (Cost Query): $($allPrices.Count) SKU prices from $rowCount usage rows for '$Region'" -ForegroundColor DarkGray
            Write-Verbose "Tier 2 (Cost Query): $rowCount usage rows, $($allPrices.Count) VM SKU prices for region '$armLocation'."
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

    $Caches.ActualPricing[$cacheKey] = $allPrices
    return $allPrices
}
