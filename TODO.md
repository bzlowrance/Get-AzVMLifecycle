# Get-AzVMLifecycle — Parity TODO

This TODO captures fixes, features, and capabilities currently shipped in
[`Get-AzVMAvailability`](https://github.com/bzlowrance/Get-AzVMAvailability)
that are **not yet present** in `Get-AzVMLifecycle`. Each item links to the
exact file/line in Availability where the working pattern can be cribbed from
verbatim.

**Source repo path used for cross-references:** `C:\coderepo\Get-AzVMAvailability\Get-AzVMAvailability\`
**This repo path:** `C:\coderepo\Get-AzVMLifecycle\`

Last reviewed: 2026-04-27 against Availability branch `GOV_Price_fix` @ `38dedd4`.

---

## P0 — Pricing correctness (active investigation in Availability)

### 1. Negotiated RI / Savings Plan parsing from Consumption Price Sheet
**Status in Availability:** under active investigation on branch `GOV_Price_fix`.
Discovery probe `tools\Probe-PriceSheetRI.ps1` was added 2026-04-27 to determine
exactly which `priceType` / `meterCategory` / `term` fields the Price Sheet API
exposes for Reservation and Savings Plan meters.

**Status in Lifecycle:** `Get-AzActualPricing` block at `Get-AzVMLifecycle.ps1:2549–2683`
captures only PAYG `Regular` rates. Reservation 1Yr/3Yr come exclusively from
the **retail** Cost Management API merge at L3866. This means:

- Sovereign clouds (Gov / China / Germany) where retail RI data is sparse or
  absent will show blank RI savings columns.
- Even on commercial, EA/MCA-negotiated RI rates are not surfaced — the user
  sees retail RI rates instead of their actual contract rates.

**What to port (after Availability finishes the investigation):**
1. Add `tools\Probe-PriceSheetRI.ps1` (verbatim copy from Availability) so users
   can dump their own price sheet schema for support tickets.
2. Extend the price sheet parser in `Get-AzVMLifecycle.ps1:2549–2683` to:
   - Bucket items by `priceType` (`Consumption` → Regular, `Reservation` → RI,
     `SavingsPlan` → SP, `Spot` → Spot).
   - Populate `$reservation1YrPrices` / `$reservation3YrPrices` /
     `$savingsPlan1YrPrices` / `$savingsPlan3YrPrices` from the price sheet
     when those rows exist.
3. In the Tier-1/Tier-2 merge at L3843–L3869, prefer negotiated RI/SP from the
   price sheet, falling back to retail RI/SP only when negotiated is absent.

**Acceptance:** RI savings columns populate for Gov tenants without requiring
a working retail Cost Management API call.

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

1. **#5 Dedupe candidate pool** — biggest perf win, safe, no behavior change.
2. **#1 Price-sheet RI/SP parsing** — wait for Availability to finish probe analysis, then port both the parser change and `Probe-PriceSheetRI.ps1` together.
3. **#7 Tenant-wide ARG advisor query** — perf + signal coverage.
4. **#6 NotAvailableForNewDeployments signal** — quality of risk surfacing.
5. **#9 docs subset** — pick the 5 high-value files.
6. **#8 Update-RetirementData / Sync-TrafficInfra** — if/when relevant.

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
  serves both modules.
