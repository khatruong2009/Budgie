# Performance on a 10,000-row store (Phase 5 item 2, budgie-uia.47)

What was measured, how, what was fixed, and what only a device can answer.
Everything here is from the simulator unless a section says "device". The
simulator numbers are valid for main-thread CPU work and for O(N)-per-render
regressions. They say nothing reliable about GPU cost (shadows, blur), frame
pacing or ProMotion: see "Needs a device".

## Method

**Store.** `native/scripts/perf_seed.py` generates a deterministic store
relative to today and installs it (plus an identical backup file) in a
simulator's app container. Not `Fixtures/store/large_10k`: that one is all
income, dated 2020-2027 (part of it in the future), has App Lock on and stale
recurring templates, so it is wrong for UI timing (it stays the Core timing
fixture).

- 10,000 transactions over 60 months ending in the current month, none after
  today, about 70% expense. The current month has 500 rows (350 Groceries, for
  the Spend drill-in), each of the 3 months before it 250, the rest evenly.
  About 4% are "Coffee..." rows for the search box; 10% carry a tag. File:
  2.9 MB.
- USD, App Lock off, no recurring templates (launch generates and writes
  nothing), 5 budget limits. Categories, tags, rules, goals and net worth
  entries come from `large_10k`, plus a net worth account "Perf History" with
  500 weekly snapshots (the account history page).
- `perf_seed.py --rows N` makes a smaller store of the same shape (used to
  tell "10k problem" from "always this slow").

**Lane.** `native/scripts/perf_run.sh`: Debug configuration with
`SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s` (Debug is needed for the
`BUDGIE_SKIP_ONBOARDING` hook; -Onone numbers are
meaningless). The build log has no `-Onone` (BudgieCore is built with `-O`
too). No Release build, so no API key is involved.

**Tests.** `BudgieUITests/PerformanceUITests.swift`, skipped unless
`TEST_RUNNER_BUDGIE_PERF=1` (so normal suites never run it). `perf_run.sh`
installs the build, seeds the store, sets light/dark, and runs the class with
10 iterations (XCTest runs one extra, discarded warm-up). Nothing in it changes
data, so one seeding serves a whole run. It asserts the seed is present
(Flow SEE ALL must read "... of 10000").

```
cd native && xcodegen generate
scripts/perf_run.sh build <udid> <derived-dir>
PERF_APPEARANCE=dark PERF_ITERATIONS=10 \
  scripts/perf_run.sh run <udid> <derived-dir> <results-dir> <name> \
  BudgieUITests/PerformanceUITests/testFlowSeeAllScroll ...
xcrun xcresulttool get test-results metrics --path <results-dir>/<name>.xcresult
```

**Signposts** (`Budgie/App/Signposts.swift`, subsystem
`com.khatruong.budgetbuddy`; free when nothing records, so kept in every
configuration). Read them in Instruments (os_signpost), with
`xcrun simctl spawn <udid> log show --signpost --predicate 'subsystem == "com.khatruong.budgetbuddy"'`,
or as `XCTOSSignpostMetric`s.

| Category | Name | Covers |
|---|---|---|
| Launch | `bootstrap` | `AppModel.start()` to `.ready` (the whole bootstrap, all paths) |
| Launch | `protectedDataWait`, `store.read`, `FinancialData.load`, `recurringGeneration`, `ledgerIndex.first`, `insights.first` | the stages; events `processLaunch`, `ready`, `firstFrame` |
| Ledger | `LedgerIndex.build` (off main), `ledgerRebuild` (mutation to published index), `insights.generate` | |
| UI | `tabSwitch` | tab tap to the end of the update transaction (main-thread work of the switch) |
| UI | `flow.refilter` | one Flow SEE ALL filter pass (apply + summary), metadata `matches=` |
| UI | `home.safeToSpend` | `SafeToSpend.calculate` in Home's body |

**Launch log** (`.notice`, persisted, category `launch`; consumed by
REAL_DEVICE_CHECKLISTS budgie-uia.8): `launch prewarm=<0|1>
protectedData=<available|unavailable>`, `protected data available after <s>s`
(only when it waited), `pre-native snapshot <created|exists|failed>`,
`store loaded revision=<n>` (or `store load failed <kind>`). No financial data.

**Glow A/B (retired).** The `BUDGIE_PERF_NO_GLOW` switch (and the
`PERF_NO_GLOW` option of `perf_run.sh`) is gone. It removed the per-row shadow
on Home SEE ALL; since the visual redesign (2026-10) SEE ALL rows have no
shadow, so it changed nothing (budgie-ou0.21). The measurements below are kept
as history.
Since the 2026-10-03 redesign the app draws no glows, text glows or hero
blur at all, so the glow numbers below describe the earlier build. It does
not remove the FAB's shadow or the `DialogShadow` black layer. Release
builds ignore the variable.

**Environment of the numbers below.** MacBookPro18,4 (M1 Max, 10 cores, 64 GB),
macOS 27.0, Xcode 27.0 (27A266a); simulator "Budgie-Agent-2" = iPhone 17
template, iOS 27.0, erased before the verification run. Other agents were
building on the same Mac, so load ranged from 5 to 900: wall-clock numbers
carry that noise. `CPU Instructions Retired` does not, and is the metric to
trust for A/B. Mean and standard deviation over 10 iterations unless noted.

## Results

### Launch at 10k rows (`testLaunchToReady`, 10 iterations)

| Stage | Mean | sd | Thread |
|---|---|---|---|
| `bootstrap` (total) | 263 ms | 18 ms | main actor, awaits included |
| `store.read` (reads + decodes primary AND backup) | 75 ms | 9 ms | FinancialStore actor |
| `FinancialData.load` (parse 10k rows) | 71 ms | 3 ms | **main** |
| `recurringGeneration` | 13 ms | 4 ms | main |
| `ledgerIndex.first` (await) / `LedgerIndex.build` | 29 ms / 21 ms | 9 / 3 ms | detached |
| `insights.first` / `insights.generate` | 14 ms / 14 ms | 2 / 1 ms | detached |
| launch to Home tab existing (`XCTClockMetric`) | 6.8 s | 0.25 s | includes the 1.4 s opening animation, the 0.45 s cross-fade and XCUITest |

A 400-row store of the same shape: `bootstrap` 200 ms, `FinancialData.load`
11 ms, `store.read` 51 ms, `LedgerIndex.build` 1 ms. So 10k rows add about
85 ms to the launch; the rest is fixed. **No change made**: a 71 ms parse on
the main thread during the opening screen and a doubled decode of the backup
(here the backup is the same size as the primary: real installs do the same)
are worth knowing but not worth touching decode/load semantics for. Both are
candidates if the device numbers are bad (section "Needs a device").

### Interactions

| Metric | 10k rows | sd | Verdict |
|---|---|---|---|
| Flow SEE ALL refilter, one keystroke, wide match ("c") | 0.95 ms | 0.06 | fine (limit 16 ms); no change |
| same, nothing matches ("q") | 0.76 ms | 0.05 | fine |
| `home.safeToSpend`, per Home body pass | 2.9 ms | 0.4 | below the 4 ms bar; **no change** (see below) |
| tab switch, already built (mean of 5 switches) | 37 ms | 2 | fine |
| first visit of Worth / Flow / Spend / Goals | 289 / 202 / 154 / 138 ms | 14 / 5 / 14 / 9 | same at 400 rows (281 / 208 / 169 / 137): framework first render of a lazy tab, not a data-size effect |

`home.safeToSpend`: Home's body runs `SafeToSpend.calculate` over a copy of all
10k rows on every body pass (sheet open or close, month panel). It measured
2.9 ms per pass (3.3 ms and 3.5 ms in the glow runs). That is a real O(N) in a
body but far below a frame, on a Mac that is faster than the phone by a
factor of about 1.5 to 2, so roughly 5 to 6 ms on device at 10k rows. A cache
keyed by data revision, month and day is easy, must keep the stored-order
summation (FULL_APP_PLAN section 3), and would gain 3 ms per Home state
change; left alone on purpose. Revisit if the device shows Home hitching on
sheet presentation.

### Scrolling (6 fast swipes, 2.58 s of `Scroll_DraggingAndDeceleration`)

App CPU time per iteration (includes XCUITest's accessibility snapshots, so
use it to compare, not as a frame cost):

| List | CPU time | sd |
|---|---|---|
| Home | 1.8 s | 0.06 |
| Home SEE ALL (500 rows, lazy) | 1.7 s | 0.08 |
| Spend | 0.8 s | 0.06 |
| Spend drill-in (350 rows, lazy) | 2.8 s | 0.11 |
| Flow SEE ALL (first 150 rows, lazy) | 3.0 s | 0.08 |
| Worth account history, 500 snapshots, **before** | **43.5 s** | 0.86 |
| Worth account history, 500 snapshots, **after** | **2.9 s** | 0.06 |

`XCTHitchMetric` and the scroll metric's hitch data produced no values on the
simulator (only the duration); hitch numbers need a device.

### Fix: account history timeline built lazily

`GlowListCard` put every row in a `VStack`, so the history page built all 500
timeline rows (each with a glow dot) at once. Measured before and after,
same lane, 10 iterations:

| Metric | Before | After |
|---|---|---|
| open the page (tap View History to hero, XCUITest-inclusive) | 7.80 s (sd 0.12) | 2.34 s (sd 0.02) |
| app CPU, 6 fast swipes | 43.45 s (sd 0.86) | 2.83 s (sd 0.10) |
| resident memory with the page open | 161 MB | 82 MB |

`GlowListCard(lazy: true)` switches the stack to a `LazyVStack`; only the
timeline passes it, every other user is unchanged. 500 snapshots is an extreme
account (weekly for ten years); a typical one has 12 to 60, where this is not
visible. Cost is O(snapshots), not O(10k rows), so it did not show on the
regular `large_10k` fixture.

### Glow A/B (`BUDGIE_PERF_NO_GLOW`, retired; simulator)

Per iteration (6 fast swipes; Home body = add sheet open/close plus the month
panel twice). Glow on / glow off, 10 iterations each:

| Test | Light: instr. (M) | Light: CPU s | Dark: instr. (M) | Dark: CPU s |
|---|---|---|---|---|
| Home scroll | 7417 / 7373 (-0.6%) | 1.83 / 1.78 | 7543 / 7522 (-0.3%) | 1.73 / 1.79 |
| Spend scroll | 3050 / 2985 (-2.1%) | 0.81 / 0.93 | 3126 / 3094 (-1.0%) | 0.90 / 0.89 |
| Flow SEE ALL scroll | 13570 / 13500 (-0.5%) | 3.02 / 2.93 | 14010 / 13960 (-0.3%) | 3.55 / 3.16 |
| Home SEE ALL scroll | 7998 / 7994 (0.0%) | 1.73 / 1.92 | 8242 / 8217 (-0.3%) | 1.81 / 1.93 |
| Home body re-renders | 9654 / 9642 (-0.1%) | 1.48 / 1.43 | 9763 / 9732 (-0.3%) | 1.49 / 1.48 |

Instructions retired are load independent and differ by at most 2%. CPU
seconds move up to 15% in either direction (sd 3 to 8%) with machine load. The
app's CPU does not include shadow or blur rasterisation, which happens in the
render server and on the GPU, so the simulator cannot answer the question.
**Verdict: no measurable main-thread cost; GPU cost unknown until measured on
a device. No look change made.** Screenshots confirmed the switch works (hero
halo, bar glows and FAB glow are gone with it).

## Needs a device (procedure for the owner)

The simulator renders through the Mac GPU, has no ProMotion cadence and shares
CPU with the Mac. Do these on the iPhone, with a Release-like build
(`xcodebuild -configuration Release` with your real key, installed with
`devicectl`), after installing the 10k store (below).

1. **Install the 10k store on the phone.** `perf_seed.py --generate-only <dir>`
   writes `financial_store_v2.json` and `.backup.json`. Install the build, then
   copy them into the app container's `Library/Application Support/financial_store/`
   with `xcrun devicectl device copy to --device <id> --domain-type appDataContainer
   --domain-identifier com.khatruong.budgetbuddy --source <file> --destination
   "Library/Application Support/financial_store/<file>"` with the app not running.
   Complete the tour once. **Use a spare phone or restore your own data after**: this
   replaces the store.
2. **Scroll hitch ratio on ProMotion.** Instruments > Animation Hitches
   (`xcrun xctrace record --template 'Animation Hitches' --device <id> --launch
   -- com.khatruong.budgetbuddy`), or `XCTHitchMetric` from
   `PerformanceUITests` run against the device (Debug build, `-O`). Scroll Flow
   SEE ALL, Home SEE ALL, Spend drill-in, Home and the account history. Record
   hitch time ratio (ms per s) per screen. Apple's guide: under 5 ms/s is good,
   over 10 ms/s is noticeable.
3. **Glow cost.** Retired: the `BUDGIE_PERF_NO_GLOW` switch is gone and the
   app draws no glows since the redesign (2026-10).
4. **Cold and prewarm launch.** Instruments > App Launch for a cold launch with
   the 10k store (note `bootstrap`, `FinancialData.load` on the main thread and
   time to Home). For the prewarm/locked launch follow REAL_DEVICE_CHECKLISTS
   budgie-uia.8 and read the `launch` log lines. If `bootstrap` exceeds about
   1 s on the phone, the two candidates are the main-thread
   `FinancialData.load` parse and the backup's double decode
   (`FinancialStore.load`).
5. **Memory at 10k.** Xcode > Debug navigator > Memory (or Instruments
   Allocations) after launch, on Home, and after opening Flow SEE ALL and
   loading more. Simulator: about 82 MB resident on Home with the 10k store.
6. **Thermal and battery** (optional): five minutes of scrolling, note thermal
   state in Instruments.

Record the results below.

| Measure | Device | iOS | Result |
|---|---|---|---|
| Cold launch, `bootstrap` | | | |
| Prewarmed launch (budgie-uia.8) | | | |
| Flow SEE ALL scroll, hitch ms/s | | | |
| Home SEE ALL scroll, hitch ms/s | | | |
| Glow on vs off, hitch ms/s (Home, Spend) | | | |
| Memory on Home at 10k | | | |
