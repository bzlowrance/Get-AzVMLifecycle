function Get-AzActualPricing {
    <#
    .SYNOPSIS
        Fetches actual negotiated pricing from Azure Cost Management API.
    .DESCRIPTION
        Retrieves your organization's actual negotiated rates including EA/MCA/CSP discounts.
        Requires Billing Reader or Cost Management Reader role on the billing scope.
    .NOTES
        This function queries the Azure Cost Management Query API to get actual meter rates.
        It requires appropriate RBAC permissions on the billing account/subscription.
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
        # Get environment-specific endpoints (supports sovereign clouds)
        if (-not $AzureEndpoints) {
            $AzureEndpoints = Get-AzureEndpoints -EnvironmentName $TargetEnvironment
        }
        $armUrl = $AzureEndpoints.ResourceManagerUrl

        # Get access token for Azure Resource Manager (uses environment-specific URL)
        $token = (Get-AzAccessToken -ResourceUrl $armUrl -ErrorAction Stop).Token
        $headers = @{
            'Authorization' = "Bearer $token"
            'Content-Type'  = 'application/json'
        }

        # Consumption price sheet endpoint — $expand=properties/meterDetails is required
        # because meterDetails (category, region, meter name) is NOT populated by default.
        # $filter is NOT supported by this API; filter client-side instead.
        $MaxPricesheetPages = 10
        $apiUrl = "$armUrl/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/pricesheets/default?api-version=2023-05-01&`$expand=properties/meterDetails&`$top=1000"

        $totalItems = 0
        $pageCount = 0
        try {
            do {
                $pageCount++
                $response = Invoke-WithRetry -MaxRetries $MaxRetries -OperationName "Cost Management API (page $pageCount)" -ScriptBlock {
                    Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers -TimeoutSec 60
                }

                if ($response.properties.pricesheets) {
                    $totalItems += $response.properties.pricesheets.Count
                    foreach ($item in $response.properties.pricesheets) {
                        $md = $item.meterDetails
                        if (-not $md) { continue }

                        # Client-side filter: VM category, matching region, Linux only
                        if ($md.meterCategory -ne 'Virtual Machines') { continue }
                        if ($md.meterSubCategory -match 'Windows') { continue }

                        # Normalize meterLocation (display name like "US Gov Virginia") to ARM format ("usgovvirginia")
                        $normalizedMeterRegion = ($md.meterLocation -replace '[\s-]', '').ToLower()
                        if ($normalizedMeterRegion -ne $armLocation) { continue }

                        # Extract VM size from meter name (e.g. "D2s v3" → "Standard_D2s")
                        $vmSize = $md.meterName -replace ' .*$', ''
                        if ($vmSize -match '^[A-Z]') {
                            $vmSize = "Standard_$vmSize"
                        }

                        if ($vmSize -and -not $allPrices.ContainsKey($vmSize)) {
                            $allPrices[$vmSize] = @{
                                Hourly       = [math]::Round($item.unitPrice, 4)
                                Monthly      = [math]::Round($item.unitPrice * $HoursPerMonth, 2)
                                Currency     = $item.currencyCode
                                Meter        = $md.meterName
                                IsNegotiated = $true
                            }
                        }
                    }
                }

                # Follow pagination via nextLink
                $apiUrl = $response.properties.nextLink
            } while ($apiUrl -and $pageCount -lt $MaxPricesheetPages)
        }
        finally {
            $headers['Authorization'] = $null
            $token = $null
        }

        Write-Verbose "Price sheet: $totalItems items across $pageCount page(s), $($allPrices.Count) VM SKU prices matched region '$armLocation'."
        if ($allPrices.Count -eq 0 -and $totalItems -gt 0) {
            Write-Verbose "No VM meters matched region '$armLocation'. Check meterLocation values in the price sheet."
        }

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
                    Write-Warning "Cost Management API: authentication failed (HTTP 401).`n  Your access token may be expired. Run: Connect-AzAccount"
                }
                403 {
                    Write-Warning "Cost Management API: access denied (HTTP 403). Required RBAC (any one):"
                    Write-Warning "  - Cost Management Reader  (scope: subscription or billing account)"
                    Write-Warning "  - Billing Reader           (scope: billing account or enrollment)"
                    Write-Warning "  - Enterprise Reader        (EA enrollments only)"
                    Write-Warning "  To assign:  New-AzRoleAssignment -SignInName <user@domain> -RoleDefinitionName 'Cost Management Reader' -Scope /subscriptions/$SubscriptionId"
                }
                404 {
                    Write-Warning "Cost Management price sheet not available for this subscription (HTTP 404)."
                    Write-Warning "  Supported billing types: EA, MCA, MPA (CSP). Not supported: Pay-As-You-Go, Free, Sponsorship, MSDN."
                }
                {$_ -in 429, 503} {
                    Write-Warning "Cost Management API throttled/unavailable (HTTP $statusCode). Retries exhausted."
                }
                default {
                    Write-Warning "Cost Management API failed$(if ($statusCode) { " (HTTP $statusCode)" }): $errorMsg"
                }
            }
            Write-Warning "Falling back to retail pricing (public list prices without negotiated discounts)."
        }
        return $null  # Return null to signal fallback needed
    }
}
