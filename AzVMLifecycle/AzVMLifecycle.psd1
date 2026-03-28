@{
    RootModule        = 'AzVMLifecycle.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = 'a7f3b2c1-4d5e-6f78-9a0b-1c2d3e4f5a6b'
    Author            = 'Zachary Luz'
    CompanyName       = 'Community'
    Copyright         = '(c) Zachary Luz. All rights reserved. MIT License.'
    Description       = 'Azure VM lifecycle management: retirement detection, upgrade path recommendations, compatibility analysis, pricing comparison, and deployment mapping.'
    PowerShellVersion = '7.0'
    RequiredModules   = @(
        @{ ModuleName = 'Az.Accounts'; ModuleVersion = '2.0.0' }
        @{ ModuleName = 'Az.Compute'; ModuleVersion = '4.0.0' }
        @{ ModuleName = 'Az.Resources'; ModuleVersion = '4.0.0' }
    )
    FunctionsToExport = @(
        # Azure API
        'Get-AzureEndpoints'
        'Get-AzVMPricing'
        'Get-AzActualPricing'
        'Get-PlacementScores'
        'Get-ValidAzureRegions'
        'Invoke-WithRetry'
        # SKU analysis
        'Get-CapValue'
        'Get-SkuFamily'
        'Get-SkuFamilyVersion'
        'Get-ProcessorVendor'
        'Get-DiskCode'
        'Get-SkuCapabilities'
        'Get-SkuSimilarityScore'
        'Get-RestrictionReason'
        'Get-RestrictionDetails'
        'Test-SkuMatchesFilter'
        # Image
        'Get-ImageRequirements'
        'Test-ImageSkuCompatibility'
        # Format / Output
        'Format-ZoneStatus'
        'Format-RegionList'
        'New-RecommendOutputContract'
        'Write-RecommendOutputContract'
        'Invoke-RecommendMode'
        # Utility
        'Get-SafeString'
        'Get-GeoGroup'
        'Get-QuotaAvailable'
        'ConvertTo-ExcelColumnLetter'
        'Use-SubscriptionContextSafely'
        'Restore-OriginalSubscriptionContext'
        'Test-ImportExcelModule'
        'Get-RegularPricingMap'
        'Get-SpotPricingMap'
        'Get-SavingsPlanPricingMap'
        'Get-ReservationPricingMap'
        'Get-SkuRetirementInfo'
        'Test-SkuCompatibility'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Azure', 'VM', 'SKU', 'Lifecycle', 'Retirement', 'Migration', 'Pricing', 'Recommendations')
            LicenseUri   = 'https://github.com/bzlowrance/Get-AzVMLifecycle/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/bzlowrance/Get-AzVMLifecycle'
            ReleaseNotes = 'v2.0.0: Rebranded to Get-AzVMLifecycle. Simplified to 2-mode design (live ARG scan default, -InputFile for file-based). Removed availability scan, recommend, and inventory modes.'
        }
    }
}
