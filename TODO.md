# Get-AzVMLifecycle — Parity TODO

This TODO captures fixes, features, and capabilities currently shipped in
[`Get-AzVMAvailability`](https://github.com/bzlowrance/Get-AzVMAvailability)
that are **not yet present** in `Get-AzVMLifecycle`. Each item links to the
exact file/line in Availability where the working pattern can be cribbed from
verbatim.

**Source repo path used for cross-references:** `C:\coderepo\Get-AzVMAvailability\Get-AzVMAvailability\`
**This repo path:** `C:\coderepo\Get-AzVMLifecycle\`

Last reviewed: 2026-04-28 against Availability branch `GOV_Price_fix` @ `87c8e6b` (post v2.2.0 release prep — retail-vs-retail SP/RI percent, advisory recs, paired-meter split, legend UX).

---

## P0 — Pricing correctness (recent fixes in Availability — port now)

### 0a. Spot/Low-Priority meter exclusion + cache schema v2 bump
**Availability ref:** commit `bff7bb3` "fix(pricing): exclude Spot/Low-Priority meters from negotiated PAYG cache". File: `AzVMAvailability/Private/Azure/Get-AzActualPricing.ps1`.

**Bug:** v1 cache logic stripped a `" Spot"` / `" Low Priority"` suffix off `meterName` before bucketing, then accepted those rows as `Regular` PAYG meters. With first-write-wins semantics the Spot rate (≈1/8 the on-demand rate) overwrote the legitimate on-demand rate for SKUs whose Spot meter happened to be paged first. Real-world impact: `Standard_B16as_v2` showed ~$858/yr 1Y cost and a -$2,772 RI savings (negative savings impossible).

**Fix in Availability:**
1. Hard-skip any meter whose `meterName` or `meterSubCategory` matches `\b(Spot|Low Priority)\b` — no suffix-stripping, full discard with skip-reason counter.
2. Cache filename bumped: `AzVMLifecycle-PriceSheet-<tenant>.json` → `AzVMLifecycle-PriceSheet-v2-<tenant>.json`. Old v1 file is auto-deleted on first run because v1 caches are poisoned.
3. New skip-reason counters: `NoMeterDetails`, `NotVirtualMachine`, `WindowsSubcategory`, `SpotOrLowPriority`, `EmptyMeterLocation`, `UnparsableMeterName`, `ZeroOrNegativeUnitPrice` — emitted via `Write-Verbose` so `-Verbose` runs can audit Tier 1 hygiene.

**Lifecycle status:** Same disk-cache convention is shared with Lifecycle (see "Items already at parity" below). If Lifecycle's parser also strips the Spot/Low-Priority suffix, **Lifecycle caches are equally poisoned and any user with a v1 cache file will keep getting wrong rates until invalidated.**

**Action — port:**
1. Audit Lifecycle's price-sheet parser (`Get-AzVMLifecycle.ps1:2549–2683`) for any `meterName -replace ...Spot.*` pattern. Replace with hard `continue` skip.
2. Bump Lifecycle's cache filename to `…-v2-…` and add the same v1-cleanup `Get-ChildItem | Remove-Item` line.
3. Optional: port the skip-reason counter dictionary for parity with Availability's verbose output.

**Acceptance:** PAYG rates for any SKU with both Regular and Spot meters in the price sheet match Azure portal Cost Management within rounding; RI savings columns are non-negative.

---

### 0b. Retail-fallback price marker (`*` prefix)
**Availability ref:** commit `bca90c6` "feat(pricing): mark retail-fallback prices with '*' + Tier 1 skip diagnostics". Files: `AzVMAvailability/Public/Get-AzVMAvailability.ps1`, `AzVMAvailability/Private/Format/Invoke-RecommendMode.ps1`, `AzVMAvailability/Private/Format/New-RecommendOutputContract.ps1`.

**Behavior:** When a region's negotiated rates are not in the price sheet (sovereign Gov regions sometimes omit rates), the row falls back to the public retail Cost Management API. Those cells are now prefixed with `*` so users can see at a glance which prices are negotiated vs retail, and a header comment legend documents the marker.

**Lifecycle status:** Not implemented. Lifecycle silently mixes negotiated and retail rates with no visual distinction.

**Action — port:**
1. Add a per-row `PriceIsNegotiated` boolean threaded through the candidate emit and ranked re-projections.
2. Track which regions fell back via a `$script:RunContext.RetailFallbackRegions` list (or equivalent) populated by the Tier 1 region-resolve branch.
3. In the export property arrays, prefix `*` on each price column when `-not $row.PriceIsNegotiated`.
4. Add a header-comment legend to the Lifecycle Summary tab: `* = retail rate (negotiated rate not found in price sheet for this region)`.
5. If Lifecycle emits a JSON contract, add `priceIsNegotiated` as a sibling field on each price object.

---

### 0c. Tier 1 disk-load logging symmetry
**Availability ref:** commit `fed02f6` "fix(pricing): log Tier 1 success on first (disk-load) region call too".

**Bug:** The cache-hit branch only logged `Tier 1 (Price Sheet): N negotiated SKU prices for '<region>' (cached)` after the *second* call (when in-memory `$Caches.ActualPricing['AllRegions']` was already populated). The first call — which loaded from disk — silently returned without any per-region count. Diagnostic asymmetry made it look like the first region got zero prices.

**Fix:** Same `resolvePriceSheetKey` lookup + log line is now run in the disk-load branch too.

**Lifecycle status:** Verify Lifecycle's disk-cache load path emits the same per-region count log on first hit.

**Action — port:** Mirror the symmetric log line. Trivial 5-line diff.

---

## P1 — Output correctness (recent fixes in Availability — port now)

### 0d. Per-sub quota deficit double-counting
**Availability ref:** commit `f253a25` "fix(quota+lifecycle): drop quota-only current-gen rows from Summary/HighRisk/MediumRisk; flag deficit only when family is over its limit". File: `AzVMAvailability/Public/Get-AzVMAvailability.ps1` ~L2370–2400, L2516–2520.

**Bug:** The per-sub quota check called `Get-QuotaAvailable -RequiredvCPUs ($qty * $sourceVcpu)` and flagged a deficit when `Available < required`. But `$qty * $sourceVcpu` is the running fleet's existing usage, **already counted in `$qi.Current`**. The check was effectively asking "can I deploy 100% of my running fleet again on top of itself?" — a guaranteed false positive whenever fleet size approached half the quota. Real-world example: `Standard_NV48s_v3` Qty=17, family quota 876/1000 (avail 124). The check computed `17 × 48 = 816` needed against `124` available → flagged deficit, even though the fleet is operating fine.

**Fix:** Per-sub deficit now flags only when `Current > Limit` (the family is genuinely over its cap *right now*). Migration headroom for the *target* SKU is a separate concern that depends on the chosen recommendation and is not surfaced as a Quota deficit on the map. Reason text reworded:
- **Old:** `Quota: insufficient in N of M deploying sub(s) (need NvCPU/VM)`
- **New:** `Quota: family over limit in N of M deploying sub(s)`

**Lifecycle status:** Verify whether Lifecycle's per-sub quota check has the same double-counting pattern. Search for `Get-QuotaAvailable` invocations that pass `qty * vCPU`.

**Action — port:** Pass `RequiredvCPUs=0` to the quota check; flag deficit only when `[int]$qi.Current -gt [int]$qi.Limit`. Update reason text.

---

### 0e. Quota-only current-gen rows excluded from Summary / High Risk / Medium Risk
**Availability ref:** same commit `f253a25`.

**Bug:** Current-generation SKUs with no retirement, no capacity issue, and no "not available for new" signal were being emitted to the Lifecycle Summary, High Risk, and Medium Risk sheets purely because of a per-sub quota signal. Real-world example: `Standard_D16as_v4`, `Standard_D16ds_v5` rows polluting the Summary with risk reasons that were already proven false-positive by the fix above.

**Fix:** Such rows are flagged with `_QuotaOnlyCurrentGen = $true` and:
- Excluded from `$lcSortedResults`, `$highBase`, `$medBase` (Summary / High / Medium sheets).
- Excluded from console + workbook box risk counters.
- **Retained** for SubMap / RGMap propagation so the affected sub(s) still see the quota signal in context.

**Lifecycle status:** Likely affected — Lifecycle's row-emission logic doesn't have a current-gen-only-quota filter today.

**Action — port:** Add the `_QuotaOnlyCurrentGen` flag at row emission time; filter it out of the three summary-style sheets while keeping it in SubMap/RGMap.

---

### 0f. Paired meter-name split (`D3 v2/DS3 v2` → both ARM SKUs)
**Availability ref:** commits `0fa4a89` and `b87f60c` (corrected regex). File: `AzVMAvailability/Private/Azure/Get-AzActualPricing.ps1`.

**Bug:** Some Price Sheet rows describe a single meter that maps to two ARM SKUs in the form `D3 v2/DS3 v2` (one premium-storage variant + one standard-storage variant). The parser previously consumed the row whole, producing prices for one ARM SKU and `-` for the other. Real-world impact: every D-series v2 paired meter (D2/DS2 v2, D3/DS3 v2, D4/DS4 v2, D5/DS5 v2, etc.) had the `S`-variant or non-`S`-variant blank.

**Fix:** Parser now splits on `/` and emits both ARM SKUs (e.g. `Standard_D3_v2` AND `Standard_DS3_v2`) with the same hourly/monthly rate. Cache schema bumped (`-v3-` → `-v4-` filename) so v2 paired-meter-incomplete caches are invalidated automatically.

**Action — port:** Apply the same split + schema bump to Lifecycle's price-sheet parser. Pair this with **#0a's v2 cache bump** (Lifecycle should jump straight to `-v4-` to align cache schema with Availability and force a one-time refresh).

**Acceptance:** `Standard_D3_v2` and `Standard_DS3_v2` both populate with PAYG rates after a fresh scan; same for the other v2 paired families.

---

### 0g. Strip `" Expired"` meter suffix
**Availability ref:** commit `b87f60c` (combined with #0f).

**Bug:** Price Sheet rows for retired-but-still-billable meters carry an `" Expired"` suffix on `meterName` that prevented SKU resolution. Parser silently dropped the row.

**Fix:** Suffix stripped before normalization so the meter still resolves to its ARM SKU and is bucketed correctly.

**Action — port:** One-line addition in Lifecycle's parser before the meter-name regex.

---

### 0h. Advisory upgrade-path recommendations
**Availability ref:** commits `bd128d3` (initial advisory injection + deferred No-alt risk) and `a1ed7ad` (numeric-field hardening). Files: `AzVMAvailability/Public/Get-AzVMAvailability.ps1` (recommendation loop ~L2776–2796 advisory injection; L2624 deferred `$shouldFlagNoAlternatives` boolean).

**Behavior:** When a Microsoft-documented successor SKU (`data/UpgradePath.json`) is not deployable in any scanned region, an *advisory* recommendation row is emitted with `Capacity = Advisory` so the migration target is still visible in the report. Numeric capability fields (`vCPU`, `ACU`, `memGiB`, `IOPS`, `MaxDisks`, `score`) default to `0`; the existing `-le 0` guards in the delta formatter render `0` as `-` for display. `priceMo = $null`. `MatchType = "<label> (Advisory)"`. The `"No alternatives"` risk is **no longer** flagged just because the documented successor isn't in scanned regions; it is reserved for the genuinely high-risk case where neither a same-family/compatible-profile match nor a documented successor is available.

**Lifecycle status:** Likely affected — same recommendation engine pattern. Lifecycle currently emits `"No alternatives"` for any SKU whose Microsoft-documented successor is region-locked (e.g., M-series v2/v3, NVads_A10_v5 niche regions), inflating high-risk counts.

**Action — port:**
1. Add the advisory rec injection block in the recommendation emit loop. Numeric fields **MUST** be `0` (not the string `'-'`) — string sentinels crash downstream `[int]` casts in any IOPS-match guard or capability-delta extractor (this is the bug that motivated `a1ed7ad`).
2. Replace the immediate `"No alternatives"` emit with a deferred `$shouldFlagNoAlternatives` boolean evaluated *after* advisory injection, so advisory presence suppresses the high-risk flag.
3. Add `Advisory`, `No alternatives`, and `No alternatives in scanned regions (advisory only)` rows to whatever legend Lifecycle ships (or add a legend if it doesn't have one — see #0j below).

**Acceptance:** SAP/HANA M-series v2/v3 successors visible as advisory rows in the Best-fit recommendation column when the scanned regions don't offer them; `"No alternatives"` count drops to true zero-successor cases only.

---

### 0i. Reservation / Savings-Plan savings as retail-vs-retail percentage
**Availability ref:** commits `9c3035c` (RI percent), `f0a190d` (SP percent), `87c8e6b` (retail-vs-retail correction). File: `AzVMAvailability/Public/Get-AzVMAvailability.ps1` ~L1700 (`RegularRetail` map preservation), ~L2895 (consumer pulls `retailRegularMap`), ~L2965–2998 (cell formatting).

**Behavior:**
- **Display format:** `<marker><amount> (<pct>%)`, e.g. `*4,810 (37%)` for retail-fallback rates and `4,810 (37%)` for negotiated SP rates from the Price Sheet.
- **Critical correctness rule:** the `(pct%)` denominator is the **retail PAYG fleet total**, not the negotiated/merged PAYG. Earlier development used negotiated PAYG, which compressed against the customer's already-discounted bill and made the figure non-stackable with their EA discount. Container preserves an **unmerged** retail PAYG map (`RegularRetail` key) alongside the merged `Regular` map; SP/RI denominator pulls from `RegularRetail`, falls back to `priceMo` when no retail entry exists for the SKU/region (sovereign edge case).
- Result: a `70% RI` cell + customer's 20% EA discount yields roughly 50% realized incremental discount on top of their existing PAYG bill. Apples-to-apples against list.

**Lifecycle status:** Lifecycle currently emits raw dollar savings for SP/RI columns with no percentage. If Lifecycle ports #1 (RI/SP harvesting) it must adopt the same retail-vs-retail rule from day one — otherwise the percent will be silently inflated.

**Action — port:**
1. When constructing the per-region pricing container, store the **unmerged** retail PAYG map under a `RegularRetail` key (alongside the existing merged `Regular` overlay).
2. In the cell-format scriptblock for SP 1Yr/3Yr and RI 1Yr/3Yr, compute the denominator from `RegularRetail[$rec.sku].Monthly * (12 or 36) * $entryQty`. Fall back to negotiated `priceMo` only when no retail entry exists.
3. Cell format: `'<marker>' + $savings.ToString('N0') + ' (' + [math]::Round(($savings / $denom) * 100, 0) + '%)'`. Marker `'*'` when retail-fallback, `''` when negotiated. Skip percent (or use 0) when denom ≤ 0.
4. Update legend / RI tooltip to call out the retail-vs-retail basis with the worked stacking example.

**Acceptance:** RI 3-Year cell on a M16ms-class SKU shows e.g. `*8,815 (62%)`; `8,815 / (62/100) ≈ 14,218` ≈ retail 3Y PAYG fleet total for that SKU+qty (verify by hand against the Azure pricing calculator).

---

### 0j. Lifecycle Summary legend block
**Availability ref:** commits `bc8c07f` (initial legend), `36114ea` (widen to col J + zebra stripes). File: `AzVMAvailability/Public/Get-AzVMAvailability.ps1` ~L3473–3530.

**Behavior:** A dedicated `LEGEND` section at the bottom of the Lifecycle Summary sheet documents every marker used across the lifecycle report family (`*`, `* (RI)`, `+N`, `-N`, `0`, `-`, `✓ Zones N`, `⚠ Zones N`, `✗ Zones N`, `Non-zonal`, `No alternatives`, `Advisory`, etc.). Banner spans `A:J`; marker cell merged `A:B` (centered, bold, wraps); meaning cell merged `C:J` (wrapped, vertically centered). Zebra-striped rows (alternating light-gray / white) with thin gray bottom borders for clarity. Per-row heights tuned to fit explanations on 1–2 lines at the wider width.

**Lifecycle status:** Existing `docs/Excel-Legend-Reference.md` documents the markers but the workbook itself does not embed an inline legend.

**Action — port:** Lift the entire `LEGEND` block (the 60-line `$legendItems` array + the styled write loop). Place it at the bottom of the Lifecycle Summary sheet immediately after the SUMMARY footer rows. Use the same `$headerBlue` / `$lightGray` palette already present in Lifecycle's styling helpers.

**Acceptance:** Open a fresh lifecycle XLSX, scroll to the bottom of the Summary tab, and see a banner + table of marker meanings with zebra striping.

---

### 0k. Cosmetic price-cell cleanup (`+0` → `0`, drop `$`, force text format)
**Availability ref:** commits `8b888e9` (`+0` / `±0` → plain `0`), `e5bee88` (equality-delta sentinel `=` → `0` to dodge Excel formula parser), `e55f010` (drop dollar signs), `3854b07` (force price columns to text via `-NoNumberConversion`).

**Bug catalog:**
- Capability-delta cells used `±0` for equality, which Excel sometimes interpreted oddly; price-diff used `+0`. Both replaced with plain `0`.
- An older equality sentinel was `=`, which Excel treated as the start of a formula and corrupted the cell.
- Some cells leaked `$` into the value, breaking column alignment with non-currency deltas.
- Price columns occasionally rendered as numbers (stripping the `*` / `+` / `-` markers); `-NoNumberConversion` on `Export-Excel` forces them to text.

**Action — port:** Verify Lifecycle's delta formatter and Export-Excel call. Replace any `±0` / `+0` / `=` sentinel with `'0'`; drop any `$` literal; pass `-NoNumberConversion @('Price Diff','Total','3-Year Cost','SP 3-Year Savings','RI 3-Year Savings')` (mirror Availability's `$priceColNames` array).

---

## P0 — Pricing correctness (active investigation in Availability)

### 1. Negotiated RI / Savings Plan parsing from Consumption Price Sheet
**Status in Availability (updated 2026-04-27):** Issue 4 was *partially* resolved on `GOV_Price_fix` by changing the pricing container to an ordered hashtable that **overlays** negotiated PAYG on `Regular` while preserving the retail `Reservation1Yr` / `Reservation3Yr` / `SavingsPlan1Yr` / `SavingsPlan3Yr` / `Spot` maps from Tier 2. RI / SP / Spot columns now populate in both commercial and sovereign clouds *as long as the retail Cost Management API returns data for the region*. True negotiated (EA/MCA) RI / SP rate harvesting from the price sheet is still pending — `tools\Probe-PriceSheetRI.ps1` was committed for that investigation.

**Status in Lifecycle:** unchanged. `Get-AzActualPricing` block at `Get-AzVMLifecycle.ps1:2549–2683` still captures only PAYG `Regular`; RI rates come exclusively from retail merge at L3866. Two gaps:

- Sovereign-cloud regions where retail RI / SP / Spot data is sparse will still show blanks. The Availability fix doesn't help here \u2014 it preserves whatever retail returns, but if retail is empty the columns are still empty.
- EA/MCA-negotiated RI / SP rates are never surfaced; users see retail RI rates instead of their contract rates.

**What to port now (low-risk, immediate):**
1. **Mirror the container shape fix.** Audit how Lifecycle's negotiated price sheet path constructs its pricing container; if it overwrites the retail container instead of overlaying, switch to an ordered-hashtable overlay so RI / SP / Spot maps survive even when Tier 1 succeeds. Reference: `Get-AzVMAvailability/Public/Get-AzVMAvailability.ps1` \u2014 search for the negotiated/retail merge that builds `[ordered]@{ Regular = $merged; Spot; SavingsPlan1Yr; SavingsPlan3Yr; Reservation1Yr; Reservation3Yr }`.
2. **Add `tools\Probe-PriceSheetRI.ps1`** verbatim from Availability so users can dump their own price-sheet schema for support tickets.

**What to port later (after Availability finishes the price-sheet investigation):**
1. Extend the price-sheet parser in `Get-AzVMLifecycle.ps1:2549\u20132683` to bucket items by `priceType` (`Consumption` \u2192 Regular, `Reservation` \u2192 RI, `SavingsPlan` \u2192 SP, `Spot` \u2192 Spot) and populate `$reservation1YrPrices` / `$reservation3YrPrices` / `$savingsPlan1YrPrices` / `$savingsPlan3YrPrices` directly.
2. In the Tier-1/Tier-2 merge at L3843\u2013L3869, prefer negotiated RI / SP from the price sheet, falling back to retail RI / SP only when negotiated is absent.

**Acceptance:** RI / SP savings columns populate in Gov tenants whenever retail returns data (immediate goal); negotiated RI rates surfaced when EA/MCA contract data is in the price sheet (deferred goal).

---

## P1 — Lifecycle output quality

### 2. Strip `Quota: need NxNvCPU` from generalized Risk Reasons on Summary tabs
**Availability ref:** `AzVMAvailability/Public/Get-AzVMAvailability.ps1:2925–2935`
(stripping logic) and L2356 (the line that adds the per-sub quota text).

**Lifecycle status:** Lifecycle does **not** emit `Quota: need ...` strings into
`RiskReasons` at all today (search for `Quota: need` returned 0 matches). So
no strip is needed.

**Action:** **No port required.** This item exists only as a "do not regress
into Availability's old behavior" guardrail — if quota emission is ever added
to Lifecycle's recommendation loop, ensure it is scoped to per-sub tabs
(SubMap/RGMap), not the generalized Lifecycle Summary.

---

### 3. Auto-detect `$script:TargetEnvironment` from `Get-AzContext`
**Availability ref:** `AzVMAvailability/Public/Get-AzVMAvailability.ps1:1000–1015`.

**Lifecycle status:** Already implemented at `Get-AzVMLifecycle.ps1:745–757`.
Availability ported this block FROM Lifecycle.

**Action:** **No port required.** Verified 2026-04-27.

---

### 4. Cross-region ACU fallback for upgrade-path candidates
**Availability ref:** `AzVMAvailability/Public/Get-AzVMAvailability.ps1:2655–2665`
— when the candidate SKU isn't in `$lcSkuIndex` keyed by deployed region, walk
all keys for the SKU (ACU is a region-invariant capability).

**Lifecycle status:** Already implemented at `Get-AzVMLifecycle.ps1:4310`
(`foreach ($rk in $lcSkuIndex.Keys)` cross-region walk).

**Action:** **No port required.** Verified 2026-04-27.

---

### 4b. Availability Zone columns in lifecycle XLSX (`-AZ`)
**Availability ref:**
- Parameter declared in `AzVMAvailability/Public/Get-AzVMAvailability.ps1` (search `[switch]$AZ`) and auto-enabled in lifecycle mode (search `if (-not $AZ)` near the lifecycle defaults block).
- ARG projection extended with `zones` so deployed-zone aggregation works in live mode (search `project vmSize, location, subscriptionId, resourceGroup, zones`).
- File-mode reader extracts `Zone` / `Zones` / `AvailabilityZone` columns and normalizes to single-digit zone IDs.
- SubMap / RGMap groups compute a `Zones` field as the union of distinct deployed zones; export emits a `Zones (Deployed)` column.
- Lifecycle result rows compute `AltZones` via `Get-RestrictionDetails` + `Format-ZoneStatus` against `$lcSkuIndex["$($rec.sku)|$deployedRegion"]` (with cross-region fallback). `Lifecycle Summary`, `High Risk`, and `Medium Risk` Select-Object property arrays insert a `Zones (Supported)` column between `Alt Score` and `CPU +/-`, gated on `$AZ`.

**Lifecycle status:** Not implemented. No zone columns on SubMap / RGMap or risk sheets today.

**Action — port:**
1. Add `[switch]$AZ` parameter; auto-enable in the lifecycle defaults block (mirror the Availability pattern: `if (-not $AZ) { $AZ = [switch]::new($true) }` next to the existing `ShowPricing` / `AutoExport` / `RateOptimization` defaults).
2. Extend the ARG `Resources` projection with `zones`.
3. Add a file-mode zone-column detector + normalizer (split on `,;\s`, keep single-digit zone IDs only).
4. In the SubMap / RGMap aggregation, compute `$deployedZones = @($g.Group | %{ $_.zones } | ?{ $_ } | Select-Object -Unique | Sort-Object)` and store it on each map row; the export scriptblock emits `Zones (Deployed)` (or `Non-zonal` when empty).
5. In the recommendation result emitter, compute `$altZonesStr` via `Get-RestrictionDetails` + `Format-ZoneStatus` with cross-region fallback; add `AltZones` to the result PSCustomObject.
6. In the three property-array definitions (`$lcProps`, `$hrProps`, `$mrProps`), insert `@{N='Zones (Supported)';E={$_.AltZones}}` between `Alt Score` and `CPU +/-`, gated by an `$altZonesCol = if ($AZ) { @(...) } else { @() }` splat to keep the diff minimal.

**Notes:** This is a pure additive change; no schema migration. Skill-test on a tenant with at least one zonal and one non-zonal SKU per scanned region.

---

## P1 — Performance

### 5. Dedupe candidate pool in lifecycle recommendation loop (~100x speedup)
**Availability ref:** commit `10a329b` "Lifecycle Fix #1: dedupe candidate pool
(~100x speedup at scale)". Reduces the lifecycle phase from ~7 hr to ~3–5 min
on the 196-sub × 224-SKU test fleet.

**Lifecycle status:** Search for `dedupe`, `dedup`, `candidate.pool`,
`candidatePool` returned 0 matches. **Likely affected.** Lifecycle iterates
`lifecycleResults` per-subscription against the same candidate set without
deduping; at scale (multi-region × multi-sub) this redoes identical work many
times.

**Action:** Port the dedup pattern. Open `Get-AzVMAvailability.ps1` at
`AzVMAvailability/Public/Get-AzVMAvailability.ps1:2076–2090` and read commit
`10a329b` for the diff. Apply the equivalent transformation to Lifecycle's
recommendation loop (search for the `lifecycleResults` accumulator).

**Risk:** Low — pure dedup, output unchanged.

---

## P2 — Detection signals

### 6. `NotAvailableForNewDeployments` lifecycle signal
**Availability ref:** commit `ae3c6dc` "Wire Advisor retirement into risk loop,
add NotAvailableForNewDeployments signal, region-level retry". Search
`AzVMAvailability/Public/Get-AzVMAvailability.ps1` for `NotAvailableForNewDeployments`
to see how the signal is derived from SKU restrictions and surfaced in
`RiskReasons`.

**Lifecycle status:** 0 matches for `NotAvailableForNewDeployments`. SKUs that
have been silently deprecated for new deployments (still running for existing
customers but not orderable) are not flagged.

**Action:** Port the detection. Adds a new Risk Reason token `Not available for
new deployments (region)` when the SKU's restrictions include the deployed
region's location-level "NotAvailableForSubscription" reason without an
explicit retirement date.

---

### 7. Tenant-wide ARG query for Advisor retirement (vs per-sub REST)
**Availability ref:** commit `31ad3e7` "Refactor Advisor retirement to single
tenant-wide ARG query instead of per-subscription REST calls". File:
`AzVMAvailability/Public/Get-AzVMAvailability.ps1` — search for
`Microsoft.Advisor/recommendations` and `Search-AzGraph`.

**Lifecycle status:**
- `Search-AzGraph` is used (2 matches at L457, L519) — but for VM/SKU inventory.
- `Microsoft.Advisor/recommendations` returned 0 matches — Advisor retirement
  data is **not** queried at all.

**Action:** Port the tenant-wide ARG advisor query. Single call at module start
populates a `$advisorRetirementsByVmId` lookup that is then joined into the
recommendation risk loop. Massive perf win (1 query instead of N-subs API
calls) and adds Advisor retirement signals that Lifecycle currently lacks.

---

## P2 — Tooling

### 8. Discovery / diagnostic tools
| Tool | Availability path | Purpose | Port? |
|---|---|---|---|
| `Probe-PriceSheetRI.ps1` | `tools\` | Dump price sheet schema for RI/SP/Spot bucketing | **Yes** — couple with item #1 |
| `Update-RetirementData.ps1` | `tools\` | Refresh `data\RetirementData.json` from Microsoft sources | **Yes** if Lifecycle uses the same data file format |
| `Validate-Script.ps1` | `tools\` | Already in Lifecycle | — |
| `Run-ModuleTests.ps1` | `tools\` | Module-only (Lifecycle is single-script) | **No** |
| `Test-Parity.ps1` | `tools\` | Module-only | **No** |
| `Build-PublicFunction.ps1` | `tools\` | Module-only | **No** |
| `Audit-AllPRComments.ps1` | `tools\` | Repo PR automation | Optional |
| `Check-PRReadyToMerge.ps1` | `tools\` | Repo PR automation | Optional |
| `Reply-StaleThreads.ps1` | `tools\` | Repo PR automation | Optional |
| `Sync-TrafficInfra.ps1` | `tools\` | Companion to `Generate-TrafficDashboard-Premium-v2.ps1` | **Yes** — Lifecycle has the generator but not the sync tool |
| `dashboard.js` | `tools\` | Static dashboard JS used by `Generate-TrafficDashboard-Premium-v2.ps1` | **Yes** if Lifecycle's dashboard generator references it (currently 0 refs in repo — verify) |

---

## P3 — Documentation

### 9. Extended `docs/` set
**Availability `docs/`** (15 files): `agent-integration.md`, `cloud-environments.md`,
`codespaces.md`, `Excel-Legend-Reference.md`, `image-compatibility.md`,
`inventory-planning.md`, `lifecycle-recommendations.md`,
`LifecycleRecommendationCoreDifferences.md`, `local-installation.md`,
`MULTI-MODEL-CODE-REVIEW.md`, `output-and-pricing.md`, `parameters.md`,
`region-presets.md`, `usage-examples.md`, `VERIFY-RELEASE.md`.

**Lifecycle `docs/`** (2 files): `Excel-Legend-Reference.md`, `VERIFY-RELEASE.md`.

**Action — port the relevant subset:**
- **High value (port verbatim, content applies to Lifecycle):**
  - `cloud-environments.md` — sovereign cloud usage notes
  - `parameters.md` — full parameter reference
  - `region-presets.md` — `-RegionPreset` documentation
  - `output-and-pricing.md` — pricing tier behavior
  - `usage-examples.md` — common invocations
- **Conditional:**
  - `LifecycleRecommendationCoreDifferences.md` — created in Availability to
    document where its lifecycle output differs from Lifecycle's. **Inverse
    version belongs here** describing differences in the other direction.
  - `image-compatibility.md` — only if Lifecycle has image compatibility
    detection (verify).
- **Skip (Availability-specific):**
  - `agent-integration.md`, `codespaces.md`, `local-installation.md`,
    `MULTI-MODEL-CODE-REVIEW.md`, `inventory-planning.md`, `lifecycle-recommendations.md`
    (the latter is a docs file describing Lifecycle from Availability's side).

---

## P3 — Repo / module structure

### 10. Pester test suite
**Availability:** 24 test files in `tests/` (Pester) covering helpers, parameter
parity, JSON contracts, retirement data, SKU compatibility, etc.

**Lifecycle:** No `tests/` directory; relies on integration runs.

**Action:** Optional. Adopting Pester is a bigger investment; consider the
subset that protects against regression in shared logic (retirement data,
SKU compatibility, RI/SP bucketing, region presets). Most Availability tests
target the module's `Private/` functions which Lifecycle does not have, so
direct port is limited.

---

## Quick port order (recommended)

1. **#0a Spot/Low-Priority meter exclusion + cache schema bump (jump to v4)** — correctness, blocks all pricing accuracy. Bumping straight to `-v4-` (Availability's current schema) aligns the cache filename so a single tenant served by both modules doesn't double-cache, and simultaneously invalidates v1-poisoned caches and v2 paired-meter-incomplete caches.
2. **#0f Paired meter-name split (`D3 v2/DS3 v2`)** — paired with #0a's bump; ports the v3 → v4 schema fix.
3. **#0g Strip `" Expired"` meter suffix** — one-line addition, port alongside #0f.
4. **#0d Per-sub quota deficit double-counting fix** — eliminates false-positive `Quota: insufficient` reasons.
5. **#0e Drop quota-only current-gen rows from Summary/High/Medium sheets** — pairs with #0d.
6. **#0b Retail-fallback `*` price marker** — visual clarity, low risk.
7. **#0h Advisory upgrade-path recommendations** — biggest QoL win for SAP/HANA/M-series fleets; reduces `"No alternatives"` noise.
8. **#0i Reservation/SP savings as retail-vs-retail percent** — must adopt retail-vs-retail rule from day one if Lifecycle ports #1 (RI/SP harvesting).
9. **#0j Lifecycle Summary legend block** — pure UX, additive.
10. **#0k Cosmetic price-cell cleanup** — small risk, high readability gain.
11. **#0c Tier 1 disk-load logging symmetry** — diagnostic only, trivial.
12. **#5 Dedupe candidate pool** — biggest perf win, safe.
13. **#1 Price-sheet RI/SP parsing** — wait for Availability to finish probe analysis, then port both the parser change and `Probe-PriceSheetRI.ps1` together.
14. **#7 Tenant-wide ARG advisor query** — perf + signal coverage.
15. **#6 NotAvailableForNewDeployments signal** — quality of risk surfacing.
16. **#4b `-AZ` zone columns in lifecycle XLSX** — additive, no schema migration.
17. **#9 docs subset** — pick the 5 high-value files.
18. **#8 Update-RetirementData / Sync-TrafficInfra** — if/when relevant.

---

## Items already at parity (no action needed)

- Auto-detect `TargetEnvironment` from `Get-AzContext` (#3) — Lifecycle source of truth, Availability ported FROM here.
- Cross-region ACU fallback (#4) — Lifecycle source of truth.
- Sovereign meter-location aliases (`armToMeterLocation`) — present at L2911.
- `[switch]$LogFile` parameter — present at L254.
- `data/UpgradePath.json` loader — present at L568, L4171.
- Parallel cross-sub scan (`ForEach-Object -Parallel`) — present at L3978.
- Shared price sheet disk cache (`AzVMLifecycle-PriceSheet-<tenant>.json`) —
  Availability cribs from Lifecycle's filename convention; same cache file
  serves both modules. **Note (2026-04-28):** Availability has bumped the schema
  three times: v1 → v2 (Spot-meter poisoning fix), v2 → v3 (negotiated SP overlay),
  v3 → v4 (paired-meter split + Expired suffix strip). Current filename:
  `AzVMLifecycle-PriceSheet-v4-<tenant>.json`. Until Lifecycle ports #0a, #0f,
  #0g and bumps to `-v4-`, the two modules will write to *different* cache files
  when run on the same tenant; this is intentional (Lifecycle's v1 cache is
  poisoned but it doesn't know it yet).
