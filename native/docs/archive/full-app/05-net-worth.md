> Archived; paths refer to the `flutter-final` tag.

# Worth tab (net worth): analysis for the Swift full-replacement plan

Paths: `F/` = W/budget_app/lib, `N/` = W/native, `NW.dart` = `F/net_worth_page.dart`, `TM.dart` = `F/transaction_model.dart`, `NE.dart` = `F/net_worth_entry.dart`. Everything below was read from source. I ran no builds or tests.

## 0. Key findings up front

1. `carryNetWorthMonthForward` has no UI caller in Flutter. It is only used by tests and the parity harness (`N/ParityHarness/parity/store_scenarios.dart:231`). The same holds for `getTrackedNetWorthEntryCountForMonth` and `staleNetWorthEntryCount`. It is core-only work with no screen.
2. Chart x is the point index, not the date. Points are evenly spaced and axis labels are separate text. The Swift MVP plots by date, so it differs (`N/Budgie/Views/NetWorthView.swift:130`).
3. The hero number hard-codes `$` and ignores `hideBalances` and the currency (`NW.dart:296-303`). Every other amount goes through `MoneyFormatter`.
4. Tapping an account row opens the editor, not the history page. History is only reachable through the long-press sheet (`NW.dart:1147-1156`).
5. The current-month snapshot date is `DateTime.now()`. Every save in the current month therefore adds a new snapshot, even with no changes (`TM.dart:1441-1450`). Past months use `endOfNetWorthMonth`, a constant, so re-saving replaces the same snapshot.
6. In Swift, `FinancialData.selectedNetWorthMonth` and `netWorthRows` are `private(set)`. `AppModel.serialize` returns the stale `data.sections[...]` for `selectedNetWorthMonth` (`AppModel.swift:189`). Both need fixing before persistence works.

## 1. Feature inventory

### 1.1 Page structure and state
- **Page:** `NetWorthPage` (`NW.dart:23`). It consumes `TransactionModel`.
- **Empty state:** `!model.hasNetWorthEntries` (entries list empty) shows the empty state (`NW.dart:52-85`):
  - Header "Net worth".
  - GlowCard with a 56pt IconTile (`trending_up`, accent).
  - Title "No net worth accounts yet", subtitle "Create your first asset or liability to start tracking net worth over time."
  - Filled PillButton "Add account" (height 48, plus icon).
  - FAB, semantic label "Add account", `initialType` unset (asset).
- **Populated page:** a scroll column in this order (`NW.dart:87-190`):
  1. `BudgieHeader("Net worth")`.
  2. `MonthSelector` chip strip.
  3. Hero.
  4. Growth chart card.
  5. Assets/liabilities split card.
  6. Toggle chips.
  7. Accounts list.
  - The FAB passes `initialType` from the active toggle tab.
- **View-only state (not persisted):** `_selectedTab` (0 Assets, 1 Liabilities) and `_range` (default `oneYear`). Per-chart state is `_selectedSpotIndex`.
- **Persisted state:** `selectedNetWorthMonth` (section 1.9).

### 1.2 Month selector (`F/widgets/month_selector.dart`)
- Horizontal scroll strip, 84pt tall. It is the older visual generation (uses `AppColors.primary` #6366F1 in both themes).
- Chip: 120x64, radius 12. Text is `MMM` uppercased (bodyLarge bold, letterSpacing 0.5) over the year (bodySmall, w500).
  - Selected: gradient primary to primary@0.8 (topLeft to bottomRight), 2pt primary border, shadow primary@0.3 blur 8 y2, white text (year at 90%).
  - Unselected: surface (#15151F dark / white light) with a thin border and shadowS.
- Data is `getNetWorthAvailableMonths()`: the current month, the selected month, and every snapshot's month, newest first (leftmost). It auto-scrolls to center the selected chip (item 120 + gap 8).
- Tapping a chip fires a selection haptic and `await model.selectNetWorthMonth(m)`.

### 1.3 Hero (`NW.dart:255-320`)
- Eyebrow: `TOTAL · MARCH 2026` (mono 11/600, letterSpacing 2.4, secondary text).
- Number: heroMedium (Gabarito 48/800, letterSpacing -1.8, tabular).
  - `-` is a separate Text when netWorth < 0.
  - The number is `AnimatedDigitWidget($ + abs, 0 fraction digits, separators, 900ms roll, Duration.zero under Reduce Motion)`.
  - Text glow: green if netWorth >= 0, rose if negative, blur 48, alpha .35 (dark; x0.4 in light).
  - Semantics label: `Net worth ${formatSigned}`.
- Delta pill, shown only if `getNetWorthChangeForMonth != null` (`NW.dart:324-382`):
  - Padding 14x7, radius 999, fill color@10%, border color@35%.
  - Icon `trending_up`/`trending_down` (15pt, weight 500).
  - Text `"$dollar · $percent this month"` (badge 13, single line, ellipsis).
  - `dollar = (±)formatSigned(|change|, 0 decimals)`.
  - `percent = ±(|change| / |netWorth - change| * 100).toStringAsFixed(1)%`. If `|prev| <= 0.001` it is `±—`.
  - Sign is `+` when change >= 0. Color is income if change >= 0, else danger.
  - "this month" is hard-coded, even when viewing a past month.

### 1.4 Growth chart card (`NW.dart:386-836`)
- GlowCard, padding (16,20,16,12). Header row: "Growth" (cardTitle 17/700) with `SegmentedPillControl(['6M','1Y','ALL'], mono)`.
  - Mono style: transparent track, active segment accent@18% with accent text, inactive `dockInactiveIcon` #8A8AA8 (dark) / textSecondary (light).
  - Segment padding 11x5, gap 4, `monoLink` type.
  - Changing range clears the selection.
- Data: `getNetWorthHistory(limit: 24)` (newest first), reversed to oldest-first. The limit is applied before the range filter, so ALL means "up to 24 points".
- **Range filter** (`NW.dart:406-422`):
  - ALL returns everything.
  - 6M/1Y: `anchor = data.last.date`, `cutoff = DateTime(anchor.year, anchor.month - (months-1))` with months = 6 or 12. Keep points where `DateTime(p.year, p.month) >= cutoff`.
  - If fewer than 2 remain and `data.length >= 2`, return the last 2 points. If empty, return all.
- **Empty (no history):** a 180pt box with "Add balance updates to build your growth chart."
- **Chart** (180pt high, fl_chart):
  - x = index (0..n-1). One point becomes two spots, `(0,v)` and `(1,v)`, giving a flat line. `maxX = max(1, n-1)`.
  - **Y scale** (`NW.dart:826-836`): `range = max(rawRange, max(1.0, |maxValue| * 0.10))`, `paddedMin = min - 0.18*range`, `paddedMax = max + 0.18*range`.
  - Gridlines: horizontal only, `(paddedMax - paddedMin)/4` interval, hairline color, 1px. No border, no axis titles.
  - Curve: `isCurved`, `curveSmoothness 0.28`, round cap. Two bars are drawn:
    - Glow: 9pt, green@35%.
    - Main: 3pt, green (income color, even when net worth is negative), with a below-area gradient green@35% to 0% (top to bottom).
  - Dots:
    - Only the last spot and the selected spot show a dot (radius 5, stroke 3).
    - The last dot is fill #F2F2FA with a green@50% stroke only when nothing is selected.
    - Otherwise the dot is green with a green@25% stroke.
- **Interaction:**
  - Built-in touches are off. A long press of 150ms selects the nearest spot within a 48pt `touchSpotThreshold`.
  - Long-press move updates the selection with a selection haptic on change. Long-press end or losing interest clears it. This is a scrub gesture, so vertical scrolling is not hijacked.
- **Hover card** (an overlay, `IgnorePointer`; `NW.dart:722-817`):
  - Alignment `(x, useBottom ? 0.5 : -0.6)`.
  - `x = clamp(idx/(n-1)*2-1, ±0.84)`, or 0 if n <= 1. `useBottom = point.netWorth >= (min+max)/2`.
  - Max width 200, padding 14x10, radius 16, chipSurface fill, card border, shadow black@.5 dark / .12 light, blur 20, offset (0,8).
  - Contents:
    - Title: month granularity `MMMM y`, day granularity `MMM d, y` (11/600 secondary).
    - Net worth via `formatSigned`, amount style, income color if >= 0 else danger.
    - Two rows, "Assets  $x" and "Liabilities  $x", each with a 6pt dot (income / danger), 11pt secondary.
    - "Monthly snapshot" (mono 9, tertiary) when the point is a compressed month.
- **Axis labels** (below the chart, 6pt gap; `NW.dart:557-587`):
  - Mono 10, tertiary, `spaceBetween`: first, `chartData[n ~/ 2]` (only if n > 2), and last.
  - Format `DateFormat("MMM ''yy")` uppercased, e.g. `MAR '26`.

### 1.5 Assets vs liabilities card (`NW.dart:840-934`)
- GlowCard with a `SplitGlowBar` (height 16, glow blur 14 alpha .5), then a 14pt gap, then a two-column legend.
  - `fraction = total > 0 ? assets/total : 1.0`.
  - `>= 1` gives a full-width green gradient (#2AB98A to #34D399, always the dark-theme green).
  - `<= 0` gives a full-width rose.
  - Otherwise two flex segments (`fraction*1000` / `(1-fraction)*1000`) with a 3pt gap: green gradient on the left, rose on the right.
- Legend: a 7pt dot, a label (rowSubtitle 600 secondary), and an amount `formatSigned(0 decimals)` (20/700, letterSpacing -0.4, tabular). Liabilities are right-aligned.

### 1.6 Accounts toggle and list
- **Toggle chips** "Assets" / "Liabilities" (`NW.dart:938-1025`):
  - Padding 20x10, radius 999, 8pt gap.
  - Selected: accent fill, accent glow (blur 20 alpha .5), onAccent text w700.
  - Unselected: chipSurface with an 8% white/black border, secondary text w600. 200ms ease-out animation.
  - A tap on the unselected chip fires a selection haptic. A tap on the selected chip does nothing.
- **List:** `getNetWorthEntriesForMonth(month, type)`. Only entries with a value for that month, sorted by amount desc, then lowercased name asc (`TM.dart:483-504`).
  - The total is the whole tab's total for the selected month.
  - Empty: GlowCard, centered "No assets tracked for March 2026." (or "liabilities").
  - Otherwise a `GlowListCard` (padding 8, hairline dividers inset 12).
- **Row** (`NW.dart:1095-1226`; padding 14x12):
  - Icon tile: 44pt, radius 16, tinted by `entry.type` (income green for asset, danger for liability), icon 20 (glyph in 1.6.1).
  - Title: `entry.name` (rowTitle 15/600, one line).
  - Subtitle: `"{x.x}% of assets|liabilities"` (the tab's word), with x = `(amount/totalForCategory).clamp(0,1)*100` via `toStringAsFixed(1)`, or 0 if the total <= 0.
  - Right column: amount `formatSigned(0 decimals)` (amount style 16/700), then a change badge (badge 12/700).
  - Bottom: `GlowProgressBar(percentage, tile color, height 6)`, 800ms easeInOutCubic fill animation from 0 unless Reduce Motion, glow blur 12 alpha .6, track `getTrack`.
  - `effectiveSnapshot = latestSnapshotThrough(endOfMonth(month))`.
  - `previous` = the latest snapshot strictly before `effectiveSnapshot.recordedAt` (`_previousSnapshotBefore`, `NW.dart:1348-1366`).
  - `percentChange = null` if there is no previous or `|prev| < 0.001`. Otherwise `(amount - prev)/|prev|*100`.
  - Badge text: `—` (tertiary) when null, else `(+ if >= 0)` + `toStringAsFixed(1)%`.
  - Badge color: for assets, up is green; for liabilities, down is green, keyed on `entry.type`. Tertiary when null.
  - Tap: light haptic, then the editor for that entry. Long-press: medium haptic and a bottom sheet (radius 26 top, grab handle 36x4) with "Edit Balance" (`edit`), "View History" (`bar_chart`), and "Delete Account" (`delete`, danger).
- **Test-pinned copy** (`test/net_worth_page_widget_test.dart:84-86`): `'78.9% of assets'` is present, `'+78.9%'` is absent, `'+50.0%'` is present. Setup: Brokerage 1000 to 1500 in March, Savings 400, so 1500/1900 = 78.9%.

#### 1.6.1 Icon selection (`NW.dart:1305-1345`)
Matching is `name.toLowerCase().contains(...)`, first match wins.

| Type | Keywords | Icon |
|---|---|---|
| Asset | bank, checking | account_balance |
| Asset | saving | savings |
| Asset | invest, stock, portfolio, broker, etf, 401, ira | trending_up |
| Asset | real estate, house, home, property | home |
| Asset | wallet, cash | account_balance_wallet |
| Asset | (else) | north_east |
| Liability | loan, student, auto, personal | attach_money |
| Liability | credit, card | account_balance_wallet |
| Liability | (else) | south_west |

SF Symbol mapping for the whole page:

| Flutter symbol | SF Symbol |
|---|---|
| account_balance | building.columns |
| savings | banknote |
| trending_up | chart.line.uptrend.xyaxis |
| trending_down | chart.line.downtrend.xyaxis |
| home | house |
| wallet | wallet.pass |
| north_east | arrow.up.right |
| south_west | arrow.down.left |
| attach_money | dollarsign |
| calendar_month | calendar |
| edit | pencil |
| delete | trash |
| bar_chart | chart.bar |
| close | xmark |
| expand_more | chevron.down |
| error | exclamationmark.circle |
| add | plus |

### 1.7 Account history page (`NW.dart:1370-2136`)
Pushed with `MaterialPageRoute` from the row's long-press sheet. It watches the model, so it updates live.

- **AppBar:** the entry name (cardTitle). Actions:
  - Edit: the editor with `month = model.selectedNetWorthMonth`.
  - Delete: the confirm dialog, then pop if the entry is gone.
- **Data:** `chartHistory = getNetWorthEntryHistory(id)` (snapshots ascending by `recordedAt`). `timeline` is that reversed.
  - `latest = last`, `previous = second to last`.
  - `changeFromPrevious = latest - previous`, `totalChange = last - first` (only if count > 1).
  - `totalChangeIsPositive`: for assets `>= 0`, for liabilities `<= 0`.
  - `peak` and `low` are the max and min amount.
- **Body:** padding (20,8,20,32).
- **Hero card** (padding 24):
  - Gradient top to bottom, `color@.16`, `color@.06`, then card color, stops 0/.4/1. Border `color@.18`. Glow blur 24 alpha .16.
  - Top row: IconTile 48 (`north_east` for asset, `south_west` for liability), "Balance history" (cardTitle), subtitle "Last update MMM d, y" (`DateFormat.yMMMd`) or "No recorded updates yet", and a PillChip "Asset"/"Liability" (badgeSmall).
  - "CURRENT BALANCE" eyebrow.
  - `FittedBox(scaleDown)` with `formatSigned(latest)` in heroSmall 34/800.
  - Wrap of meta chips (padding 10x6, radius 999, icon 14):
    - `"N snapshot(s)"`: calendar icon, neutral fill (white@.06 dark / black@.05 light), text color.
    - `"±compact vs prior"`, shown if there is a previous. Colored by the sign of the change: income if >= 0, else danger. It is not inverted for liabilities.
    - `"±compact overall"`, shown if count > 1. Colored by `totalChangeIsPositive`, so it is inverted for liabilities. The two chips are inconsistent.
    - Both use fill `color@.14`. The icon is `north_east` if positive, else `south_west`.
- **Stat cards:** three in a row, 8pt gaps, GlowCard radius 22, padding 16.
  - Label is `monoMetricLabel` (mono 10/600, letterSpacing 1.6): CURRENT, PEAK, LOW.
  - Value is amount 17/700, compact currency.
  - CURRENT and PEAK are colored with the account color (green/rose). LOW uses the text color. PEAK and LOW show `—` when there is no history.
  - Compact format = `format(abs, decimalDigits: 1, compact: true)` with a leading `-` if negative (`NW.dart:2950-2959`), e.g. `$1.5K`.
  - CURRENT is the all-time latest snapshot, not the selected month.
- **Trend chart card** (padding (20,20,20,16)):
  - Empty: 200pt high, "No chart data yet for {name}."
  - Header: "Trend" and a subtitle ("Showing the first recorded balance." if one point, else `MMMd to MMMd`), plus a PillChip with the latest compact amount.
  - Chart is 200pt. Y scale (`NW.dart:1937-1944`): `baseline = max(1, max(|max|,|min|)*0.08)`, `range = max(rawRange, baseline)`, padding 20% each side.
  - Same glow/main bars, curved only if count > 2. Only the last dot shows (always #F2F2FA fill).
  - Bottom axis: mono 10 tertiary `DateFormat.MMMd` uppercased, reserved 24. Interval is `max(1, floor(n/3))`. If n > 3, only i == 0, i == n-1, and i == round(n/2) are drawn. The interval means some of those may not render; treat this as approximate.
  - Touch: built-in (`handleBuiltInTouches: true`, threshold 48). The tooltip is the chipSurface color with `yMMMd\n` (11/600 secondary) then the amount (amount style, text color). The index is clamped to `history.length-1` for the single-point case.
- **Timeline:** header "Timeline" (sectionHeader 20/700) with `"N entry/entries"`. Then a `GlowListCard` of rows, or an empty GlowCard: "Add updates to this account to build a balance timeline."
  - Row (padding 12x12): a 12pt dot with a glow (blur 10, alpha .35); `yMMMd` over `jm` time (rowTitle / rowSubtitle secondary); `formatSigned(amount)` (amount style); optional delta `(+)compact` (badge).
  - `delta = this - next older`, none for the oldest.
  - Delta color: for assets `>= 0` is green, for liabilities `<= 0` is green; secondary if null.
  - Trailing trash IconButton (18pt). Tooltip "Delete this balance update"; disabled with tooltip "Keep at least one balance update" when count <= 1 (greyed with tertiary). The model itself allows deleting the last snapshot; only the UI blocks it.
  - `jm` under intl 0.20.2 en_US is `h:mm a`, with a narrow no-break space, e.g. "9:00 AM". I verified this in the pub-cache patterns file. Use a fixed en_US pattern, not device locale.

### 1.8 Editor dialog (`NW.dart:2140-2513`)
This is a centered `Dialog` (root navigator, inset 24x32), not a sheet.

- **Container:** card color, radius 26, card border, glow accent (blur 32 alpha .18) plus a black shadow (blur 24, offset y12, alpha .5 dark / .15 light), scrollable.
- **Header banner:** gradient topLeft to bottomRight `accent@.22` to `accent@.10` (accent follows the type: income green or danger rose, animated 260ms). Padding (24,24,24,16). IconTile 48, `north_east` for asset, `south_west` for liability. Title "Add account" or "Edit account", subtitle `MMMM y` of `_entryMonth`. A 32pt circular close button (`xmark`).
- **Body** (padding (24,24,24,20), 16pt gaps):
  1. Type toggle: two 48pt pills (radius 14). Selected fills with the color and glow blur 16 alpha .4; the label is onAccent w700. "Asset" (`north_east`, green) and "Liability" (`south_west`, rose). Selection haptic.
  2. "Balance month" field: chipSurface, radius 14, card border, padding 14x14, `calendar_month` icon (accent), text `MMMM y`, `expand_more` icon.
  3. "Account name" field: `account_balance_wallet` prefix icon, text keyboard, words capitalization.
  4. "Asset balance" / "Liability balance" field: `attach_money` prefix, decimal numeric keyboard, `_CurrencyInputFormatter`.
  5. Buttons: "Cancel" (outlined: white@.06/black@.05 fill, card border, text color) and "Add"/"Save" (filled with the type color, onAccent text, glow blur 20 alpha .45). Height 48, radius 999, w700 15pt, light haptic.
- **Field style:** label (rowSubtitle 600) over a box (radius 14, chipSurface fill, animated 180ms). Border is danger if there is an error, accent if focused (2pt), else card border (1pt). The label color follows the same rule. The icon is tertiary unless focused/error. Error row: `error` icon 16 plus the message in danger.
- **`_CurrencyInputFormatter`** (`NW.dart:2159-2200`):
  - Strip commas. Reject (return the old value) unless it matches `^\d*\.?\d{0,2}$`. Empty passes.
  - Regroup the integer part with commas every 3 digits. Keep the `.` and decimals. The caret is forced to the end.
  - Fixed en_US: `.` is the decimal separator regardless of device locale. There is no minus.
- **Prefill** (`NW.dart:2237-2246`): for an existing entry, `NumberFormat('#,##0.##').format(amountForMonth(month) ?? 0.0)`. That is grouped with up to 2 decimals, no trailing zeros, e.g. `1,000`, `2,750.25`, `10,000.5`. Add mode is empty. A `null` amount prefills "0", but when the picked month changes the field becomes `''` if null (inconsistent; see Q14).
- **Type default:** `existing.type ?? initialType ?? asset`. **Month default:** `DateTime(month.year, month.month)`, where `month` is the page's selected month.
- **Month picker:** `showDatePicker`, first 1970-01-01, last end of the current month, calendar-only, helpText "Select balance month".
  - Any picked day maps to `DateTime(y, m)`.
  - If editing an existing entry, the amount field is reset to `amountForMonth(newMonth)` (`''` if null). In add mode the amount is untouched.
  - If `_entryMonth` is later than `lastDate`, `showDatePicker` asserts. A persisted future selected month could crash Flutter.
- **Validation** (`_save`, `NW.dart:2449-2487`), in order:
  1. Name `trim()` empty gives "Name is required".
  2. `double.tryParse(text without commas, trimmed)` is null or `< 0` gives "Enter a valid balance". Zero is allowed.
  - Errors are cleared at the start of each save. Nothing else is validated.
  - The save button is not disabled while saving, so a double tap double-adds in Flutter.
  - After the awaited model call (which includes the durable write), the dialog always pops, even if the save failed. The banner then shows.
- **Save:**
  - Add: `addNetWorthEntry(name.trim(), type, amount, month: _entryMonth)`.
  - Edit: `updateNetWorthEntry(id, name.trim(), type, amount, month: _entryMonth)`. Type and name changes apply to the whole account.

### 1.9 Model behaviour (`TM.dart`, `NE.dart`)

**Month-key helpers** (`NE.dart:9-46`):
- `netWorthMonthKey` = `DateFormat('yyyy-MM')` of `DateTime(y, m)`.
- `netWorthDayKey` = `yyyy-MM-dd`.
- `netWorthMonthFromKey` / `netWorthDayFromKey`: split on `-`, `int.parse`, `DateTime(...)`.
- `endOfNetWorthMonth(m)` = `DateTime(y, m+1)` minus 1 ms (elapsed). `endOfNetWorthDay` = `DateTime(y, m, d+1)` minus 1 ms.
- `formatNetWorthMonth` = `MMMM y`.

**Snapshot model:**
- A snapshot is `{recordedAt, amount}`. Snapshot identity is exact `recordedAt` equality (instant plus UTC flag).
- `monthKey` and `dayKey` are derived from the local fields of `recordedAt`.
- Legacy `fromJson` (`NE.dart:71-99`): if `recordedAt` is non-empty, parse it. Else if `monthKey` is present, use `updatedAt` if it falls in that month, else the first of the month. Else use `updatedAt`, else now. Swift already mirrors this (`Records.swift:351-377`).
- `toJson` writes only `recordedAt` (`toIso8601String`) and `amount` (a double lexeme).

**Entry model:**
- `NetWorthEntry(id? uuid, name, type, createdAt? now, snapshots)`.
- `toJson` key order: `id, name, type, createdAt, snapshots`.
- `fromJson` requires `id`, `name`, `type`, `createdAt`. Any type other than `"liability"` reads as asset.

**Carry-forward semantics** (queries):
- `snapshotForMonth(m)`: latest snapshot whose local `year == m.year && month == m.month`.
- `latestSnapshotThrough(d)`: latest snapshot with `recordedAt <= d`.
- `amountForMonth(m) = amountAt(endOfMonth(m))`. An entry with a snapshot in an earlier month therefore carries that value into later months, and an entry with no snapshot yet has no value.
- `getNetWorthEntriesForMonth` keeps only entries with a non-null amount (`TM.dart:483-504`).
- Totals sum `amountAt(endOfMonth) ?? 0`. Assets minus liabilities gives net worth.
- `hasNetWorthDataForMonth`: any entry with a value that month.
- `getUpdatedNetWorthEntryCountForMonth`: entries with a snapshot recorded in that month. This is distinct from carried values.
- `getNetWorthChangeForMonth(m)`: null if updatedCount(m) == 0, or if the previous month has no data. Otherwise `NW(m) - NW(prev)`.
- `getStaleNetWorthEntryCountForMonth` counts entries whose latest snapshot through end-of-month is in a different month.
- `getNetWorthAvailableMonths`: {current month, selected month, all snapshot months}, newest first.

**History** (`getNetWorthHistory`, `TM.dart:1361-1422`):
- Unique day keys across all snapshots, sorted descending, bucketed by month.
- If the count exceeds `limit`, compress the oldest months first: each month with more than one day-point collapses to one month point, until the count is `<= limit`.
- A month point is dated `endOfMonth`. A day point is dated the day's midnight, with effective time `endOfDay`.
- Emit newest first, then `take(limit)`.
- Each point has assets, liabilities, and counts at the effective date.
- Swift already ports this (`NetWorth.swift:89-137`) and it is parity-tested against Dart (`DomainParityTests`).

**Mutations** (all persist section `netWorthEntries` as the whole entries array via `persistSections`, which also carries any still-unsaved sections; memory is updated first, then the write is awaited):
- **`_defaultSnapshotDateForMonth(m)`** (`TM.dart:1441`): if `(m.y, m.m)` equals the local (y, m) of `DateTime.now()`, use `now` (with time and microseconds); otherwise `endOfNetWorthMonth(m)`.
- **`addNetWorthEntry`:**
  - `effectiveMonth = month ?? selectedNetWorthMonth`; `recordedAt = recordedAt ?? default(effectiveMonth)`.
  - Trimmed name empty is a silent no-op (no save, no notify).
  - Otherwise append `NetWorthEntry(name: trimmed, type, snapshots: [forDate(recordedAt, amount)])`, with a new uuid and `createdAt = now`.
  - Then `_saveNetWorthEntries()`, then `notifyListeners()`. It does not change the selected month.
- **`updateNetWorthEntry`:** same defaults and empty-name no-op. Map entries by id:
  - `copyWith(name: trimmed, type)` keeps `id` and `createdAt`.
  - `.withSnapshot(date, amount)` removes any snapshot whose `recordedAt` equals the new one, appends the new one, and sorts ascending. Never mutates in place otherwise.
  - Always saves and notifies, even if the id was not found.
  - The edit is history-preserving: it adds a snapshot, never rewrites old ones. Changing the type moves the entire history to the other side.
- **`deleteNetWorthEntry(id)`:** remove the entry with all snapshots, save, notify. There is no other side effect. There is no cascade and no change to the selected month.
- **`deleteNetWorthSnapshot(entryId, recordedAt)`:** filter by exact `recordedAt` equality. If nothing matched, return without saving or notifying. Otherwise `copyWith(snapshots:)`, save, notify. The model allows deleting the last snapshot.
- **`getNetWorthEntryHistory(id)`:** copy of snapshots sorted ascending by `recordedAt`; `[]` if the entry is missing.
- **`carryNetWorthMonthForward(month)`** (`TM.dart:697-726`):
  - For each entry with no snapshot in `month` but a `latestSnapshotThrough(endOfMonth(prevMonth))`, add `withSnapshot(default(month), prevAmount)`.
  - Saves and notifies only if something changed; returns whether it changed.
  - Note the default for the current month is `now`, so carried snapshots for the current month are stamped now.
- **`selectNetWorthMonth(date)`** (`TM.dart:236-243`): `_selected = DateTime(y, m)`, `notifyListeners()`, then `persistSections({selectedNetWorthMonth: _selected.toIso8601String()})` (for example `"2026-03-01T00:00:00.000"`). The result is ignored. A failed write flags the section as unsaved and shows the banner, even for mere navigation.
- **Selected month load** (`TM.dart:404-411`): a non-empty string that `DateTime.tryParse` parses is normalised to `DateTime(y, m)`; otherwise it stays the model's construction-time current month.
- **Legacy starting balances** (`TM.dart:392-402, 1473-1514`): on load, if `netWorthEntries` is missing or an empty list, read the prefs `starting_assets` / `starting_liabilities`. For each value above 0, create "Starting Assets" / "Starting Liabilities" entries with one snapshot at now, then save. This re-fires after every launch while the list is empty and the prefs exist. The prefs are never removed (Swift already reproduces this, `FinancialData.swift:97-111`). It becomes more reachable in Swift once delete is possible; PARITY_GAPS already notes it.
- **Restore from backup** (`TM.dart:1197-1237`) writes `netWorthEntries` and `selectedNetWorthMonth` together. That is another analyst's area.
- Other net-worth consumers: only backup/settings restore (`F/backup.dart`, `F/settings_page.dart:306-449`). Nothing else reads it.

**Persistence side effects summary** (a single store write, revision +1, backup rotation):

| Op | Sections written |
|---|---|
| add / update / delete entry, delete snapshot, carry-forward | `netWorthEntries` (+ any unsaved) |
| select month | `selectedNetWorthMonth` (+ any unsaved) |

The widget cash flow is not touched. Nothing is written to `shared_preferences`. The retry banner appears on failure.

## 2. Layout and visual spec (to rebuild)

**Tokens** (`F/theme/app_colors.dart`):

| Token | Dark | Light |
|---|---|---|
| card | #13131F | white |
| background | #0A0A12 | #F9FAFB |
| chipSurface | #15151F | #F1F1F7 |
| cardBorder | white@7% | ink #101020 @ 8% |
| hairline | white@6% | #101020 @ ~6% |
| track | #1B1B2C | #E9E9F1 |
| text | #F2F2FA | #111827 |
| textSecondary | #9A9AB5 | #6B7280 |
| textTertiary | #5C5C78 | #9CA3AF |
| onAccent | #0A0A12 | white |
| accent | #818CF8 | #6366F1 |
| income | #34D399 | #10B981 |
| danger | #FB7185 | #EF4444 |

- **Glow** (`AppColors.glow`): dark is `BoxShadow(color@alpha, blur)`. Light drops the glow for `color@.25`, blur x0.6, offset (0,4). SwiftUI `.shadow(radius:)` should be about half of the Flutter `blurRadius`.
- **GlowCard:** solid card color, radius 26, 1px border, padding 20. `GlowListCard` uses padding 8 and 1px hairlines inset 12.
- **Fonts:** Gabarito (400/500/600/700/800/900) and Spline Sans Mono, both bundled in the Flutter assets. The Swift project does not bundle them yet (`N/project.yml` has no font entries). Fonts are a shared design-system dependency.
- **Type scale used here:**
  - pageTitle 26/800 (letterSpacing -0.6).
  - heroMedium 48/800 (-1.8, tabular).
  - heroSmall 34/800 (-1).
  - sectionHeader 20/700.
  - cardTitle 17/700.
  - rowTitle 15/600.
  - rowSubtitle 12/400.
  - amount 16/700 (tabular).
  - badge 12/700, badgeSmall 11/700.
  - eyebrow mono 11/600 (2.4).
  - monoLink mono 11/600.
  - monoMetricLabel mono 10/600 (1.6).
  - monoAxis mono 10/500.
  - monoLabel mono 11/500.
- **Page:** `BudgiePageScaffold`.
  - The FAB (54pt accent circle, plus, glow, scale-in) sits at right 20, bottom `max(20, safeBottom) + 72`.
  - Scroll bottom padding is `max(20, safeBottom) + 96`.
  - The vertical spacing between blocks is: header (20,12); the month strip is 84pt (padding 8); hero (24,16,24,0); 24; growth card (H20); 16; split card; 24; toggle; 16; list.
- The FAB and content padding assume the Flutter floating dock. Their SwiftUI counterparts depend on the shell decision (standard `TabView` today).

## 3. Gap versus the Swift MVP

`N/Budgie/Views/NetWorthView.swift` (223 lines):
- **Navigation and state:** a `List` with a toolbar `Menu` for months, not the chip strip. `pickedMonth` is view-local and the persisted selection is never written. A fresh `pickedMonth` falls back to `data.selectedNetWorthMonth`.
- **Header:** plain text columns. There is no hero glow, no digit roll, no pill, no percent, and no eyebrow. The hero uses `formatSigned` (currency-aware), unlike Flutter.
- **Chart:**
  - A date-x `LineMark` + `PointMark` with `.monotone`, a y-axis with labels, and no range pills, glow, area gradient, scale padding, axis labels, scrub or hover card.
  - No single-point handling, and no month/day granularity in the tooltip.
- **Sections:** it shows Assets and Liabilities as two sections at once. There is no toggle, no share percent, no change percent, no icon tile, no progress bar and no split card.
- **"Carried from" note:** the MVP shows it, but Flutter has no such text. Decide whether to keep it as an accessibility-only note.
- **Missing screens and actions:** the account history page, the editor, delete entry/snapshot, the FAB, the row long-press actions, and the Flutter empty-state copy ("No net worth accounts yet") are all missing. The MVP says "No accounts yet".
- **UI test:** `N/BudgieUITests/MVPFlowUITests.swift:67` asserts `"No accounts yet"`, so it must be updated when the copy changes.
- **Formatting helpers:** `FieldDateText` (in `NetWorthView.swift`, also used by `RecurringView.swift:93`) has only `monthYear` and `mediumDate`. It lacks the other formats used here: `MMM 'yy` uppercased, `MMM d`, `h:mm a`, and uppercase `MMM`.

`N/BudgieCore/.../Domain/NetWorth.swift` (137 lines) and `Records.swift`:
- **Present and parity-tested:** all read queries: `netWorthEntries(forMonth:type:)`, totals, `netWorthChange`, `hasNetWorthData`, tracked/updated/stale counts, `netWorthAvailableMonths(now:)` and `netWorthHistory(limit:)` (with compression). `NetWorthEntryRecord.amount(...)`, `snapshot(forMonth:)` and `latestSnapshot(through:)` exist.
- **Missing queries:**
  - `netWorthEntryHistory(id:)` (ascending snapshots).
  - Entry lookup by id.
  - `previousSnapshot(before:)` and `percentChange`.
  - `defaultSnapshotDate(forMonth:now:)`.
- **Missing mutations:** every net worth mutation, plus `selectNetWorthMonth`.
- **Immutability:** `NetWorthEntryRecord` fields are `let` and `NetWorthSnapshotRecord` has no raw. Edits need a patch-in-place API (see 4.1).
- **Access control:** `FinancialData.netWorthRows` and `selectedNetWorthMonth` are `public private(set)`. New mutations in another file cannot touch them. Follow the existing pattern (put mutations in `FinancialData.swift`), or widen to `internal(set)`.
- **Serialization gap:** `AppModel.serialize` has no case for `Section.selectedNetWorthMonth`. The default returns the stale `data.sections[...]`, so a persisted month change would write the old value. Add a case returning `.string(data.selectedNetWorthMonth.toIso8601String())`.
- **Unused hook:** `FinancialData.noteWritten` is defined but never called.

## 4. Required BudgieCore additions and AppModel API

### 4.1 BudgieCore (put in `FinancialData.swift`, or widen `private(set)`)

Pure core, no UI, all on `FinancialData`:

```swift
public func defaultSnapshotDate(forMonth: DartDateTime, now: DartDateTime) -> DartDateTime
// same local (y,m) as now -> now; else calendar.endOfNetWorthMonth(month(of: m))

@discardableResult
public mutating func addNetWorthEntry(name: String, type: NetWorthEntryType, amount: Double,
    month: DartDateTime? = nil, recordedAt: DartDateTime? = nil, id: String, now: DartDateTime) -> Bool
// trims; empty -> false (no-op). Appends NetWorthEntryRecord.make(...) with createdAt = now.

@discardableResult
public mutating func updateNetWorthEntry(id: String, name: String, type: NetWorthEntryType, amount: Double,
    month: DartDateTime? = nil, recordedAt: DartDateTime? = nil, now: DartDateTime) -> Bool

@discardableResult public mutating func deleteNetWorthEntry(id: String) -> Bool
@discardableResult public mutating func deleteNetWorthSnapshot(entryID: String, recordedAt: DartDateTime) -> Bool
@discardableResult public mutating func carryNetWorthMonthForward(_ month: DartDateTime, now: DartDateTime) -> Bool
public mutating func selectNetWorthMonth(_ date: DartDateTime)   // month(of:) + sections[selectedNetWorthMonth] = .string(iso)

public func netWorthEntryHistory(id: String) -> [NetWorthSnapshotRecord]   // ascending
public func netWorthEntry(id: String) -> NetWorthEntryRecord?
```

Record support:
- `NetWorthEntryRecord.applying(name:type:snapshots:)` with private setters.
- `withSnapshot(date:amount:)` semantics: drop equal `recordedAt`, append, sort ascending.
- `previousSnapshot(before:)` helper.
- `NetWorthEntryRecord.make` must become reachable from `addNetWorthEntry` (it is `static internal` today; fine inside the module).

Raw-JSON rules for patches (new entries: keys `id, name, type, createdAt, snapshots`, each snapshot `{recordedAt, amount}`, amount always a **double** lexeme, `1000` writes `1000.0`):
- Patch only `name`, `type` and `snapshots` on the existing `raw`. Leave `id`, `createdAt` and unknown keys untouched.
- Rebuild the edited entry's `snapshots` array in canonical form (as Dart's `toJson` would). Untouched entries stay verbatim. This is decision Q8.
- Keep `.unreadable` rows in `netWorthRows` in place through every mutation.
- Reject NaN/Infinity amounts before mutating (`amount.isFinite`, risk R14).

Presentation logic worth putting in BudgieCore (pure, unit-testable) in a new `Domain/NetWorthPresentation.swift`:
- `GrowthRange { sixMonths, oneYear, all }` with `filter(points)` implementing 1.4 exactly.
- `chartScale(values, padding: 0.18, minPct: 0.10)` for the growth chart and `(padding: 0.20, baseline: 0.08)` for the account chart.
- `accountRowStats(entry, month, categoryTotal)` returning amount, share (clamped), and `percentChange`.
- `deltaPillPercentText`.
- `splitFraction`.
- `hoverAlignmentX(index, n)` and `useBottom`.
- `currencyInputSanitize(old:new:)` and `prefillText(amount)` (`#,##0.##`, i.e. `formatNumber(2)` with trailing zeros stripped).
- Icon keyword mapping.
- Percentage formatting via `DartFixed.toStringAsFixed(_, 1)` so `-0.04` gives `-0.0`, as Dart does.

### 4.2 AppModel API (`N/Budgie/App/AppModel.swift`)

Same pattern as the existing mutations: `guard data != nil ...; mutate; return await persist([...])`. `persist` already serializes the requested sections plus every unsaved section and updates `hasUnsavedChanges` and `lastSaveError`.

```swift
@discardableResult func selectNetWorthMonth(_ month: DartDateTime) async -> Bool
   // mutates data.selectNetWorthMonth; persist([Section.selectedNetWorthMonth])
@discardableResult func addNetWorthEntry(name: String, type: NetWorthEntryType, amount: Double,
   month: DartDateTime? = nil, recordedAt: DartDateTime? = nil) async -> Bool
   // newID() + now; persist([Section.netWorthEntries])
@discardableResult func updateNetWorthEntry(id: String, name: String, type: NetWorthEntryType, amount: Double,
   month: DartDateTime? = nil, recordedAt: DartDateTime? = nil) async -> Bool
@discardableResult func deleteNetWorthEntry(id: String) async -> Bool
@discardableResult func deleteNetWorthSnapshot(entryID: String, recordedAt: DartDateTime) async -> Bool
@discardableResult func carryNetWorthMonthForward(_ month: DartDateTime) async -> Bool  // core-only; no UI in Flutter
```

Also:
- In `serialize`, add `case Section.selectedNetWorthMonth: return .string(data.selectedNetWorthMonth.toIso8601String())`.
- The `Bool` result means "verified on disk", matching `persist`.
- Guards: `guard data != nil, amount.isFinite`.
- Use `now`/`calendar`, never `Date()`, so tests inject the clock.
- Views need `data.selectedNetWorthMonth` read from the model (drop the view-local `pickedMonth`).
- The editor's saving flag should prevent double taps, unlike Flutter.
- Dismiss after the await even on `false`, matching Dart. The banner shows.

### 4.3 Parity tests (port the Dart tests)

The Dart oracle already exists: the harness scenario at `N/ParityHarness/parity/store_scenarios.dart:203-251` drives the real model (add, update, carry-forward, delete snapshot, select month) with a fixed clock. Extend it with an ops log and a replay:

1. Add a dedicated `net_worth_mutations` scenario (or extend `typical`) that records the initial `netWorthEntries` and, after each op, Dart's resulting `netWorthEntries` JSON and `selectedNetWorthMonth` string.
2. In Swift, replay with an injected `newID` sequence and a fixed `now`. Normalize ids (Dart's `NetWorthEntry` uses an inline `Uuid().v4()`, so compare with ids replaced by entry order). Compare canonical JSON bytes.
3. Run the matrix under several `TZ` values (America/New_York, Pacific/Auckland, Asia/Kolkata, and one midnight-DST zone such as America/Sao_Paulo), as `DateTests` already does.
4. Add Dart-side verification that a Swift-edited store still loads (`verify_swift_output_test.dart:120` already checks the net worth entry count).

Swift Testing cases, ported from `test/transaction_model_net_worth_test.dart` (inject `now` fixed away from Jan/Feb 2026 so "past month" defaults apply; the Dart tests use the real clock):
- **T1** (`:16`): Checking 1000 asset + Credit Card 400 liability, March 2026: assets 1000, liabilities 400, net worth 600.
- **T2** (`:57`): carry-forward. Jan: Brokerage 200000 asset, Mortgage 150000 liability. `carry(Feb)` returns true, then update Mortgage to 149500 for Feb. Expect assets(Feb) 200000, liabilities 149500, NW 50500, tracked 2, updated 2, stale 0.
- **T3** (`:99`): available months are `[current, previous, older]` when an older month is selected and an entry lives in the older month (relative to `now`).
- **T4** (`:120`): carried balances make no synthetic history. Savings 5000 recorded Jan 20 09:00, select Feb: `hasData(Feb)` true, `updatedCount(Feb)` 0, history has 1 point dated `2026-01-20 00:00`, NW 5000, `change(Feb) == nil`.
- **T5** (`:147`): change uses the previous month's recorded balance. Brokerage 200000 (Jun 20 09:00) to 210000 (Jul 20 09:00): `change(Jul) == 10000`.
- **T6** (`:173`): same-month updates make separate points. March 10 09:00 = 1000 then March 25 17:00 = 1400: dates `[Mar 25, Mar 10]`, NW `[1400, 1000]`, counts `[1,1]`/`[0,0]`, all `.day`, `NW(Mar) == 1400`.
- **T7** (`:215`): compression at `limit: 4`. Snapshots Jan 2/10/20, Feb 5/18, Mar 8. Expect 4 points: Mar 8 (day), Feb 18 (day), Feb 5 (day), and a Jan month point dated `2026-01-31 23:59:59.999` with NW 1200.
- **T8** (`:286`): deleting one snapshot keeps the account, history is `[1500.0]`, and `netWorthHistory(limit: 10).netWorth == [1500.0]`.
- **T9** (`:324`): legacy starting balances (3200 / 900) give 2 entries and NW 2300. It is already covered by the legacy fixtures; keep an explicit case.

Widget-test ports (`test/net_worth_page_widget_test.dart`):
- (a) A UI test: tap "Add account", expect "Balance month" and "Cancel" (and then Cancel dismisses).
- (b) A unit test on `accountRowStats` for the `78.9% of assets` / `+50.0%` / no `+78.9%` case, using the values in 1.6.

Additional new tests:
- Empty or whitespace name is a no-op with no write.
- The name is trimmed.
- Past-month re-save replaces the same end-of-month snapshot (no duplicate).
- Current-month re-save adds a new now-stamped snapshot each time.
- A type change moves the whole history to the other side.
- `deleteNetWorthEntry` removes all snapshots.
- `deleteNetWorthSnapshot` with no match is unchanged and writes nothing.
- The selected-month string round-trips (`2026-03-01T00:00:00.000`) after reload.
- Unreadable rows and unknown keys survive every mutation.
- The persisted amount lexeme is double (`1000.0`).
- `createdAt == now` and canonical key order on new entries.
- NaN/Infinity is rejected.

Note that Swift's `Read.optionalString` and typed parsing need the `null`/missing `type` cases covered with the existing legacy fixtures.

## 5. SwiftUI view breakdown and build sequence

**Files** (`N/Budgie/Views/NetWorth/`, replacing the single `NetWorthView.swift`; keep `FieldDateText` somewhere shared and extend it):
- `NetWorthView.swift`: root `NavigationStack`, scroll column, header, FAB, sheet/navigation destinations, delete alerts, and the empty state. It reads `model.data` and calls the model.
- `NetWorthMonthStrip.swift`: chips + `ScrollViewReader` centering, persisted through `model.selectNetWorthMonth`.
- `NetWorthHero.swift`: eyebrow, number, delta pill.
- `NetWorthGrowthCard.swift`: range pills, Swift Charts chart, scrub gesture, hover card, axis labels.
- `NetWorthSplitCard.swift`: split bar + legend.
- `NetWorthAccountsSection.swift`: toggle chips, list card, `AccountRow`, icon mapping, context menu.
- `AccountHistoryView.swift`: hero card, three stat cards, `AccountTrendChart`, timeline rows, delete-snapshot alert.
- `NetWorthEditorSheet.swift`: header banner, `TypePill`, `MonthPickerField`, `EditorField`, currency input sanitizer.
- Shared design components (coordinate with the design-system work): `GlowCard`/`GlowListCard`, `IconTile`, `PillChip`, `PillButton`, `SegmentedPillControl(mono)`, `GlowProgressBar`, `SplitGlowBar`, glow shadow modifier, font registration.

**Charts.** Swift Charts is workable:
- **Coordinates:** use integer x indices (0...max(1,n-1)), the padded y-domain, hidden axes, and custom gridlines via `AxisMarks(values:)` (5 lines).
- **Glow line:** two `LineMark`s (9pt at 35%, 3pt at full) plus an `AreaMark` with the gradient (`yStart: paddedMin`).
- **Scrub:** `chartOverlay` with `LongPressGesture(0.15).sequenced(before: DragGesture(minimumDistance: 0))`, nearest index within 48pt, selection haptic.
- **Selection and hover:** the last-dot and selected-dot styling follows 1.4. Overlay the hover card at the computed alignment with hit testing off.
- **Curve:** `.catmullRom` is the closest built-in to fl_chart's 0.28-smoothness bezier. It overshoots less; `.monotone` avoids overshoot. Exact reproduction needs a custom `Shape`/`Path` chart. Decide by how close the look must be.
- **Account chart:** iOS 17 `chartXSelection` plus a `RuleMark` with an annotation reproduces the built-in tooltip.
- **VoiceOver:** add `accessibilityChartDescriptor` or per-point labels.

**Month picker.** Use a custom month/year picker (wheel or grid built from integers 1970...current) rather than `DatePicker`. That avoids `Calendar.current` (a device Buddhist/Japanese calendar would shift years) and avoids the Flutter assert when the selected month is in the future.

**Row actions.** SwiftUI `.contextMenu` (Edit Balance, View History, Delete Account) matches the long-press sheet natively. Keep tap = edit. The screens are cards in a `ScrollView`, so swipe actions are unavailable.

**Ordered build sequence with effort:**
1. Core: mutable records, `defaultSnapshotDate`, mutations, entry history and helpers, presentation helpers. **M**. Plus the ported tests and the harness scenario, **M**. **L** overall.
2. AppModel APIs and the `selectedNetWorthMonth` serialize case. **S**.
3. Shared design components and fonts (shared with other areas). **M**.
4. Month strip with persisted selection, hero, delta pill, split card, toggle, accounts list/rows, empty state. **M**.
5. Growth chart card: range pills, scale, glow, dots, axis labels. **M**. Scrub and hover card. **M**.
6. Editor sheet: field styles, sanitizer, month picker, validation, add/update, saving guard. **M**.
7. Delete flows: entry alert, snapshot alert, context menu. **S**.
8. Account history page: hero card, stat cards, trend chart with touch tooltip, timeline. **L**.
9. Accessibility, Reduce Motion, `hideBalances`, light/dark review, UI test update ("No net worth accounts yet"). **S-M**.
10. Rehearsal: Dart harness loads a Swift-edited store (`verify_swift_output_test`). **S**.

## 6. Risks and open questions

**Risks (month-key, timezone, DST):**
- **Timezone.** Stored dates are offset-less local wall-clock strings, so month membership survives a zone change. Only DST-gap and ambiguous local times and "now" are zone-sensitive.
  - `endOfNetWorthMonth` and `endOfNetWorthDay` are `DateTime(...) minus 1 ms of elapsed time`, so a zone whose DST starts at 00:00 shifts the next-month midnight. `DartDateTime` ports it and the tz vectors in `DateTests.swift` cover it.
  - Add gap and overlap cases to the net worth matrix.
- **Ambiguous hour.** Two snapshots in the repeated fall-back hour serialize to the same string and collapse to one after reload. Extremely rare; same in Flutter.
- **Identity by exact instant.** Snapshot deletion and replacement compare `recordedAt` including microseconds. Never round-trip through `Date` or `Double`. Use `DartDateTime.microsecondsSinceEpoch`.
- **Injected clock.** Every default (`defaultSnapshotDate`, `createdAt`, available months) must use `AppModel.now`. Dart uses `DateTime.now()` inline, so the harness replays with a fixed clock.
- **Calendar.** Don't use `Calendar.current` or `DatePicker` for month math (`TransactionFormView` already does for days; different calendars can shift years).
- **Name sorting.** Dart `compareTo` compares UTF-16 code units. Swift `String <` compares Unicode scalars, so emoji or supplementary-plane names could sort differently. Compare `Array(name.utf16)` as the History sort does.
- **Number input.** Dart `double.tryParse("12.")` and `".5"` are valid. Verify Swift `Double("12.")` before relying on it (the transaction form normalizes these itself). Huge digit strings become Infinity, which Dart would save and then fail to encode forever; Swift must reject non-finite.
- **Rapid saves.** Two quick mutations both serialize the whole section, and the store actor orders them. Disable Save while saving to avoid Flutter's double-add.
- **Legacy re-fire.** Deleting all accounts brings back "Starting Assets/Liabilities" on the next launch if the prefs exist. Flutter has the same behavior; now easier to hit.
- **Persisted stale month.** A stored future or old selected month is honored on load. Clamp any date picker range.
- **Chart curve.** fl_chart's bezier is not a Catmull-Rom spline, so the curve shape only approximates.

**Open questions (decisions needed):**
1. **Hero currency and hideBalances.** Flutter hard-codes `$` and ignores `hideBalances` in the hero. Use `MoneyFormatter.formatSigned(0 digits)` (identical for USD, honors currency and hidden balances) or copy the quirk? Recommend the formatter.
2. **Carry-forward UI.** Flutter has no UI for it. Core-only, or add a "Carry forward" action?
3. **History discoverability.** Only the long-press sheet opens history. Add a chevron or "View history" affordance? Recommend keeping tap = edit and adding a context menu plus a chevron.
4. **Editor presentation.** Centered dialog versus native sheet with detents? Recommend a sheet with `presentationDetents` and corner radius 26.
5. **Range pills.** ALL is capped at the 24-point history. Keep.
6. **Delta coloring.** "vs prior" chip is colored by sign; "overall" by asset/liability direction. Copy the inconsistency or unify?
7. **Current-month re-save.** A no-op save adds a new snapshot. Copy for data parity, or skip when nothing changed? Skipping alters history counts versus Flutter.
8. **Snapshot canonicalization.** On edited entries, rewrite all snapshots canonically (Dart-identical) or preserve each snapshot's raw JSON where possible?
9. **Shell.** FAB and content inset depend on the shell (standard `TabView` versus a floating dock).
10. **Legacy starting balances** after delete-all: keep parity (already in PARITY_GAPS)?
11. **Fonts.** Bundle Gabarito and Spline Sans Mono for a close look, or use system fonts?
12. **UI test copy.** The empty-state copy and the UI test at `MVPFlowUITests.swift:67` need to change together.
13. **Locale decimals.** Flutter's editor is fixed to `.` and en_US grouping. Accept the locale separator as well? The transaction form already does.
14. **Prefill for missing amounts.** Editing an account with no value for the month prefills "0" on open but `''` after a month change. Unify (recommend `''`)?
15. **Untouched amounts.** The prefill rounds to 2 decimals and saving re-parses it. Adopt the transaction form's rule (keep the stored value if the text is unchanged)?
