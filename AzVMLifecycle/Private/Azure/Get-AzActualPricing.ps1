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

        # Query Cost Management API for price sheet data
        # Using the consumption price sheet endpoint with environment-specific ARM URL
        # OData exact match (eq) instead of contains() to avoid forcing a full backend scan.
        # URL-encode the filter so spaces and quotes are valid across all HTTP clients/environments.
        $odataFilter = [uri]::EscapeDataString("meterCategory eq 'Virtual Machines'")
        $apiUrl = "$armUrl/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/pricesheets/default?api-version=2023-05-01&`$filter=$odataFilter"

        try {
            $response = Invoke-WithRetry -MaxRetries $MaxRetries -OperationName "Cost Management API" -ScriptBlock {
                Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers -TimeoutSec 60
            }
        }
        finally {
            $headers['Authorization'] = $null
            $token = $null
        }

        if ($response.properties.pricesheets) {
            foreach ($item in $response.properties.pricesheets) {
                # Normalize meterRegion (display name like "US Gov Virginia") to ARM format ("usgovvirginia")
                $normalizedMeterRegion = ($item.meterRegion -replace '[\s-]', '').ToLower()

                # Match VM SKUs by meter name pattern
                if ($item.meterCategory -eq 'Virtual Machines' -and
                    $normalizedMeterRegion -eq $armLocation -and
                    $item.meterSubCategory -notmatch 'Windows') {

                    # Extract VM size from meter details
                    $vmSize = $item.meterDetails.meterName -replace ' .*$', ''
                    if ($vmSize -match '^[A-Z]') {
                        $vmSize = "Standard_$vmSize"
                    }

                    if ($vmSize -and -not $allPrices.ContainsKey($vmSize)) {
                        $allPrices[$vmSize] = @{
                            Hourly       = [math]::Round($item.unitPrice, 4)
                            Monthly      = [math]::Round($item.unitPrice * $HoursPerMonth, 2)
                            Currency     = $item.currencyCode
                            Meter        = $item.meterName
                            IsNegotiated = $true
                        }
                    }
                }
            }
        }

        if ($allPrices.Count -eq 0 -and $response.properties.pricesheets.Count -gt 0) {
            Write-Verbose "Price sheet returned $($response.properties.pricesheets.Count) items but none matched region '$armLocation'. Falling back to retail pricing."
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
