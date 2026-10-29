> Archived; paths refer to the `flutter-final` tag.

# Analyst report: Spend tab (Flutter CategoryPage), Flow tab (Flutter HistoryPage), transaction lists

Paths are relative to W = `.../swiftui-mvp-migration-71aa05`. Flutter files are under `budget_app/lib`, Swift under `native`. Dock labels: Spend and Flow (`home_page.dart:24-49`). Page titles are 'Categories' (`category_page.dart:163`) and 'Cash flow' (`history_page.dart:66`).

Findings that change the plan:
1. Flutter has two transaction lists, not one.
   - The Flow "SEE ALL" list (`_TransactionsDetailPage`) is all-time, filterable and **read-only**. Its rows have no onTap and no swipe.
   - The editable list is `transaction_page.dart` (`TransactionPage`), reached from Home "Recent activity". It is month-scoped, with sticky day headers, tap-to-edit and swipe-to-delete.
   - The Swift `HistoryView` blends the two.
2. `model.selectedMonth` is shared state. Home sets it, Flow reads it, and the Flow detail page's month pill writes it. The Spend tab has its own local month. Swift has no shared month today (`SpendingView` keeps `@State chosenMonth`).
3. The Swift ledger code is O(N) per call, so calling it per chart month is unusable at 10k rows (details in section 4).

---

## 1. Feature inventory

### 1.1 Spend tab (`category_page.dart`)

**State**
- Local `selectedMonth?`, `_selectedSliceIndex = -1`, `_tailExpanded = false` (`:30-32`).
- The month defaults to `availableMonths.first`, the most recent month **with data**, not the current month (`:44-56`).
- It is re-validated on every build. If the month vanished (all its rows deleted), it falls back to the newest month and resets the slice and tail state.

**Header**
- `BudgieHeader(title:'Categories')` with a trailing `MonthPill`.
- Pill label is `DateFormat.MMMM` (month name only, no year). It is hidden when no months exist.
- Tap opens a bottom sheet:
  - Radius 26 at the top, card colour with a border.
  - Grabber 40x4.
  - Title 'Select month' (sectionHeader).
  - List of `yMMMM` rows, max height 320.
  - Selected row is accent-coloured with a check icon.
  - Picking a month resets the slice and tail state.
- The picker lists only months with transactions (`getAvailableMonths`).

**Empty states** (`EmptyState`, icon `chart_pie`, expense-gradient tile)
- No months at all: 'No Expenses Yet' / 'Start tracking your expenses to see category breakdowns' (`:209-217`).
- Month total == 0 (income-only month): 'No Expenses' / 'No expenses recorded for this month' (`:219-227`).

**Calculations** (`:60-154`)
- `expensesPerCategory = getCategoryExpensesForMonth(month)`, an insertion-ordered map from `_monthLedger` (`transaction_model.dart:833`).
- `totalAmount` = fold of the per-category **sums** in map order, not a fold over transactions. Float order matters for parity.
- `transactionCounts`: count of expense rows per category in that month.
- `previousMonthTotal`:
  - `null` if the previous month has zero transactions of either type.
  - Otherwise the sum of that month's expenses, which may be 0.
- Records are sorted descending by amount. Dart's sort is insertion sort (stable) up to 33 elements and an unstable quicksort from 34, so ties keep first-appearance order up to 33 categories. Swift's stable sort matches up to 33; `DartSort` matches at any size.
- `percentage = amount / total * 100`.
- Colours for ranks 0..5 come from the fixed palette `[accent, income, danger, warning, info, pink]` (`:119-129`):

| Token | Dark | Light |
|---|---|---|
| accent | #818CF8 | #6366F1 |
| income | #34D399 | #10B981 |
| danger | #FB7185 | #EF4444 |
| warning | #FBBF24 | #F59E0B |
| info | #60A5FA | #3B82F6 |
| pink | #F0ABFC | #F0ABFC |

- Ranks 6+ (visible only after expansion) use `chartColors[indexInExpenseCategories % 14]`. That list is `AppColors.getChartColors` (`app_colors.dart:220-241`).
  - `expenseCategories` is the active, non-archived, sort-ordered category list (`category_provider.dart:272`).
  - Unknown categories fall back to `chartColors[key.hashCode.abs() % 14]`. Dart string hashCode is not portable, so Swift needs a stable substitute (FNV).
- Donut slices: the top 6 individually. If more than 6 categories exist (`records.length > 6`), append one 'Other' slice with the tail sum, coloured `donutRemainder` (dark #3A3A52, light #C9C9DA).

**Body** (`:229-275`)
- `ListView`, padding (20, 32, 20, dockBottom), where dockBottom = max(20, safeBottom) + 96.
- Donut centred, 20pt gap, then a `GlowListCard`.
- `GlowListCard` = 26 radius, 8 padding, 1pt hairline dividers inset 12.

**Category row** (`:286-387`)
- Tap pushes `CategoryTransactionsPage` with a Cupertino route and a light haptic.
- `AnimatedContainer` (200ms):
  - margin (2,2), padding (12,10), radius 18.
  - Highlight = row colour at 14% (dark) or 8% (light) when `index == selectedSlice && index < 6`.
- Top line: `IconTile` 40 (colour at 13% background, radius 14, glyph 20, weight 500) with the category icon, or square_grid_2x2 if none.
- Title is the category name (15/600).
- Subtitle (12/400, secondary): `"{count} transaction(s) · {pct.toStringAsFixed(0)}%"`.
  - If limit > 0, append `" · over limit"` when amount > limit, else `" · {$limit, 0 digits} limit"`.
- Amount `MoneyFormatter.format(amount, decimalDigits: 0)` in `AppTypography.amount` (16/700 tabular).
- Below: `GlowProgressBar` height 6, value = amount / largestAmount, row colour, animates 0 to value over 800ms easeInOutCubic (skipped under reduce-motion).

**Tail row** (`:389-463`), shown when more than 6 categories and not expanded
- Tile with `more_horiz` and a neutral background (white 6% dark, black 5% light).
- Title: '{N} more categories' / '1 more category'.
- Subtitle: names joined with ', ' (one line, ellipsis).
- Amount is the tail sum; the bar uses the remainder colour.
- Tap expands in place. All records then show, with rank 7+ in chart colours.
- The tail row is replaced by a collapse row (`:465-497`): centred accent 'Show less' in monoLink plus `expand_less` 16pt.

**Donut** (`category_donut_chart.dart`)
- Size 240, ring thickness 30, gap = 0.5% of the circle per slice (`:171-172`).
- Painter (`:242-313`): stroked arcs, butt caps, start at 12 o'clock, clockwise.
  - Arc radius = 105 (outer 120 minus 15), so the ring spans r 90..120.
  - Each slice sweeps `2π·share·sweepProgress − gapAngle` (min 0).
  - Selected slice: stroke 36 at radius 102, so its outer edge stays at 120 and it grows inward to r 84.
- Centre disc: background colour, radius 120 − 38 = 82.
- Circle box shadow: `glow(accent, blur 24, alpha .25)`. In light mode: accent at 25%, blur 14.4, offset y=4.
- Entry sweep: 500ms easeOut on mount and on year+month change. Instant when reduce-motion is on.
- Hit test (`:143-169`):
  - Annulus 90..120 measured from the centre.
  - Angle measured clockwise from 12 o'clock.
  - Cumulative shares by `slice.value / Σslices` (no gap).
  - Tap on a slice selects it; tap on the selected slice, the hole or outside deselects.
  - Selection click haptic.
- Centre label, unselected: eyebrow 'SPENT', then whole-dollar total (heroSmall 34/800, ls -1, tabular, scale-down).
- Delta pill below the total, hidden if `previousMonthTotal == null || == 0`:
  - `delta = (total − prev)/prev·100`.
  - Text `'{|delta|.toStringAsFixed(0)}% vs {PrevMonthName}'`, badge 12/700, padding (9,3).
  - Neutral if |delta| < 0.5: `remove` icon, secondary colour.
  - Increase: `north_east`, danger.
  - Decrease: `south_west`, income.
- Centre label, selected: uppercase label (eyebrow), whole-dollar value, `'{pct.toStringAsFixed(0)}%'` where pct = value / totalAmount (rowSubtitle, secondary).
- There are no tooltips anywhere in the Spend tab.

**`CategoryTransactionsPage`** (`category_transactions_page.dart`)
- Data: month ledger rows with `category == name` (exact) and type expense, sorted `compareNewestFirst`.
- Header: 36x36 back chevron, centred title (cardTitle 17/700), 36 spacer.
- Summary `GlowCard` (`:159-235`):
  - Gradient TL to BR from `alphaBlend(colour@0.22, card)` to card; border colour@0.3.
  - 'TOTAL SPENT' eyebrow.
  - `MoneyFormatter.format(total)` with 2 decimals in heroSmall, with a text glow of the category colour (48 blur, .45; x0.4 in light mode).
  - Two tinted pills: `MMMM yyyy` and '{N} transaction(s)'.
  - `IconTile` 56, radius 18, icon 28 on the right.
- 'TRANSACTIONS' eyebrow (tertiary), only when non-empty, padding (24,28,24,0).
- List: padding (20,12,20,dock), 10 separators. Each row is a `GlowCard`, padding (12,14):
  - Tile in the category colour.
  - Description plus recurrence glyph if `recurringTemplateId != null`.
  - `MMMd` date in tertiary.
  - Amount with 2 decimals, unsigned, `amountSmall`, primary text colour.
  - **No tap-to-edit.**
- Swipe end-to-start deletes:
  - Background is a danger colour, radius 26, with a white delete icon.
  - Medium haptic on the threshold, heavy on delete.
  - `CupertinoAlertDialog` 'Delete Transaction' / 'Are you sure you want to delete this transaction?', Cancel / Delete (destructive).
  - On confirm, `deleteTransaction`.
- Empty: 'No Transactions' / 'No transactions found in this category for {MMMM}', icon `square_list`.

### 1.2 Flow tab (`history_page.dart`)

**State**
- Only `_rangeMonths = 6`. It is not persisted and resets on relaunch.
- Everything else derives from `model.selectedMonth`.
- The whole page is rebuilt from a `Consumer<TransactionModel>`.

**Vertical order** (`:54-116`), page horizontal padding 20:
1. `BudgieHeader('Cash flow')` with a `MonthPill(label '{3|6|12} months')`. Tap opens the range sheet: eyebrow 'CHART RANGE' and three tiles (3, 6, 12 months). The selected tile is accent/700 with a check.
2. 24pt gap.
3. Metric strip.
4. 16pt gap.
5. `LocalInsightsSection`, a conditional dependency owned by the Insights analyst (see `widgets/local_insights_section.dart`).
6. Net cash flow card.
7. Year-over-year card.
8. 12-month trend card.
9. `SectionHeader('Transactions', 'SEE ALL')`.
10. Preview card (3 rows).

Cards are separated by 16pt (12 between the section header and the list).

**Data windows** (`:126-152`, `transaction_model.dart:1253`)
- `allChartData = getNetCashFlowHistory()`: only months **with data**, ascending, as `MonthCashFlow(income, expenses, net = income − expenses)`.
- `chartData` = entries with `month <= selectedMonth` (year, then month), then `suffix(_rangeMonths)`. Gap months are not filled.
- Metrics are computed over `chartData` (same range):
  - `avgSaved = (Σincome − Σexpenses)/count`.
  - `savingsRate = Σincome > 0 ? savings/Σincome·100 : 0`.
  - Both use sequential ascending sums.
  - Empty data gives 0 and 0.

**Metric strip** (`:208-242`, chip `:625-660`)
- Two equal chips, 12 gap, each a `GlowCard` radius 22, padding 16.
- Label monoMetricLabel (10/600 mono, ls 1.6, secondary): 'AVG SAVED / MO' and 'SAVINGS RATE'.
- Value metricAmount (24/800, ls -0.5):
  - `formatSigned(avg, decimalDigits: 0)`, with no '+' for positive values.
  - `'{rate.toStringAsFixed(0)}%'`. Dart's `toStringAsFixed` keeps `-0` for small negatives; `DartFixed` already reproduces that.
- Colour is income if >= 0, else danger.

**Net cash flow card** (`:244-276`, bars `:665-879`)
- `GlowCard` padding 20. Title 'Net cash flow' (cardTitle), 20 gap, chart.
- Empty: 'No cash flow data yet.' (13pt, secondary).
- Chart is a hand-rolled `Stack`, 190pt tall:
  - Zero baseline: 1pt hairline at y=116 (white 12% dark, black 12% light).
  - `maxPositiveBar = 76`, `maxNegativeBar = 40`. `barHeight = |net|/maxAbsNet × (net>=0 ? 76 : 40)`. `maxAbsNet` is 0 → height 0.
  - `barWidth = min(34, availWidth/count − 4)`. Row is `spaceAround`.
  - Corner radius 10 on all corners.
  - Positive bars sit above the baseline; negative bars hang below.
- Colours:
  - Current month (`sameMonth(entry, selectedMonth)`): fully saturated, income if net>=0 else danger, with glow (blur 20, alpha .6).
  - Other positive months: income at 45%.
  - Other negative months: danger at 60%.
- Current-bar badge:
  - Capsule filled with the bar colour.
  - Positioned 30pt above the bar top, centred.
  - Text `formatSigned(net, 0 digits, plusForPositive)`, e.g. '+$2,322', badgeSmall 11/800, onAccent colour.
  - For a zero bar it sits at baseline − 30.
- Month labels: `MMM` uppercase, monoMonth (11/500 mono), at the bottom band; primary text for the current month, tertiary otherwise.
- Tap a bar: light haptic and the month detail sheet:
  - 44pt `bar_chart` `IconTile` in the net colour.
  - `yMMMM` title.
  - Two tinted tiles (Income / Expenses) with `MoneyFormatter.format` (2 decimals), a `south_west` icon for Income and `north_east` for Expenses.
  - Net row: 'Net cash flow' with `formatSigned(net)`, a check icon if net >= 0, else `trending_up` (quirk: probably a bug).
- The current bar is absent when the selected month is not in the window. There are no tooltips or hover.

**Year-over-year card** (`:278-355`, row `:881-941`)
- Compares `selectedMonth` against the same month one year earlier: **income and expenses only**. `getYearOverYearComparison` (per category) exists in the model but is unused by the UI.
- Header: title 'Year over year'. Trailing monoMonth tertiary text `"{MMM ''yy uppercase} VS {…}"`, e.g. "SEP '26 VS SEP '25".
- `percentDelta = prev == 0 ? null : (cur − prev)/prev·100`.
- Label: `null` → 'new' (also when both are 0); otherwise sign ('+' if >0, '-' if <0, else '') + `|d|.toStringAsFixed(1)` + '%'.
- Delta colours:
  - Income: `(d ?? 0) >= 0 ? income : danger`.
  - Expenses: `(d ?? 0) > 0 ? danger : income`.
- Two `GlowProgressBar`s of height 12, 4 apart:
  - 'This year': accent, fraction `cur/max(cur,prev)`, 0 if max is 0.
  - 'Last year': trackSecondary (dark #2A2A3E, light #D9D9E6) on a track background (dark #1B1B2C, light #E9E9F1).
- Rows: 'Income', 'Expenses' (13/600 secondary) with the delta at the right (badge 13). 16 between rows.
- Legend under the rows: 8x8 radius-3 dots labelled 'This year' and 'Last year'.

**12-month trend card** (`:357-396`, sparkline `:982-1055`)
- Padding (16,20,16,14). Title '12-month trend'; trailing 'NET / MO' (monoMonth, tertiary). Chart height 120.
- Data: `months = DateTime(sel.year, sel.month − 11 + i)` for i in 0..11. This is **contiguous**, and zero months are included. It ends at `selectedMonth`. Values are net = income − expenses.
- fl_chart `LineChart`:
  - `minY = −bound`, `maxY = +bound`, `bound = maxAbs<=0 ? 100 : maxAbs·1.15`, so the zero line is centred.
  - No titles, grid, border or touch.
  - Dashed zero line, dash [3,4], white 8% dark / black 12% light, width 1.
  - Two curved series:
    - Glow underlay: accent at 40%, width 9.
    - Main line: accent, width 3.
  - Only the last point gets a dot: radius 5, colour #F2F2FA.

**Transactions preview** (`:398-427`)
- The 3 newest rows, sorted with `Transaction.compareNewestFirst`. Note this copies and sorts the full list on every build; it does not use the cache.
- `GlowListCard` of `_TransactionRow` (`:1057-1129`):
  - Padding (12,12). `IconTile`: income → income colour, expense → accent. Icon from the category map, with fallback `money_dollar` (income) or `square_grid_2x2`.
  - Title = description. Subtitle `"{category} · {MMMd}"`, secondary.
  - Trailing amount `formatSigned(income ? +a : −a, plusForPositive)`. Income is green; expense is primary text.
  - Tap opens the detail page.
- Empty: a `GlowCard` 'No transactions recorded yet.' that also opens the detail page.

### 1.3 Transactions detail page (`_TransactionsDetailPage`, `:1248-2119`)

**Navigation and header**
- Pushed with `MaterialPageRoute`. The header has a 36x36 chip back button, title 'Transactions' (pageTitle), and a month pill.
- The month pill (shown if months exist) opens a 'SELECT MONTH' sheet and calls `model.selectMonth(month)`.
- **Quirk:** this changes the shared month used by Home and Flow, but does not filter this list.

**Filters card** (`GlowCard`), title 'Filters', and 'RESET' (monoLink accent) when any filter is active:
1. Search field, hint 'Search descriptions'.
   - Fill chipSurface, radius 16, border, accent 1.5 when focused.
   - The prefix icon is `grid_view` (a copy quirk).
   - A clear icon appears when text is non-empty.
   - `query = value.trim()`.
2. Type: `SegmentedPillControl(['All','Income','Expense'])`.
3. Category button:
   - Label 'Category', value `selected ?? 'All categories'`.
   - Opens a 'SELECT CATEGORY' sheet with 'All categories' plus distinct categories.
   - Options = category names from **all** transactions, both types merged, trimmed, non-empty, sorted case-insensitively (`:1393`).
4. Tags: `ChoiceChip` wrap ('All tags' plus one per tag), shown only if tags exist (from `CategorizationProvider.tags`).
5. From and To buttons (each labelled 'Any date' or `MMMd` with no year):
   - Material date picker, first 2000-01-01, last `now.year+10-12-31`.
   - Initial value is `start ?? end ?? now`.
   - Choosing a start after the end (or an end before the start) moves the other bound to the picked date.
6. Min amount and max amount:
   - Number fields with decimal keyboard and a hard-coded '$ ' prefix (not currency-aware).
   - Parsing: `replaceAll(',', '').trim()`, then `double.tryParse`, and null if empty.

**Filter semantics** (`:1350-1391`)
- Base list is `getAllTransactionsSorted()`, newest first.
- All conditions are AND:
  - `description.toLowerCase().contains(query.toLowerCase())`. Description only, not category.
  - Type.
  - `category == selected` (exact, case-sensitive).
  - `tagIds.contains(tagId)`.
  - Date-only local day compare, inclusive: `dateOnly(t.date) < dateOnly(start)` excludes, and `> dateOnly(end)` excludes.
  - `amount >= min` and `amount <= max`, regardless of type.
- `_hasActiveFilters` = any of the above set, including a non-empty search.
- Reset clears all controllers.

**Results block**
- Header row: 'Results' (sectionHeader) and trailing `'{filtered.count} of {model.transactions.length}'` (monoLabel).
- Three `PillChip`s computed over **all** filtered rows, not just visible ones:
  - 'Income {format}' (income colour).
  - 'Expenses {format}' (danger).
  - 'Net {formatSigned, plus}' (income if >= 0, else danger).
- List: `GlowListCard` of `_TransactionRow`. Read-only: no edit, no delete, no day headers.
- Empty: `GlowCard` with 'No transactions match these filters.' or, without filters, 'No transactions have been recorded yet.'
- Pagination: visible = 50. When `filtered.count > visible`, show 'Showing {n} of {m} matches' and a 'Load more transactions' text button (+50). Visible resets to 50 when the filter signature changes (`:1285-1298`).

### 1.4 Editable month list (`transaction_page.dart`, "TransactionPage")
- AppBar 'Transactions', centred, with a back button.
- `MonthSelector`: an 84pt horizontal strip of 120x64 chips (`MMM` uppercase over year). Selected = primary gradient; unselected = surface with border.
- Local `selectedMonth` defaults to the newest available month.
- Summary card: Income and Expenses columns, a hairline divider, and 'Net Cash Flow' (`formatSigned`, 20pt). It uses the AppDesign spacing scale.
- List: `CustomScrollView` of one `SliverMainAxisGroup` per day:
  - Day key is `DateFormat.yMMMd` (e.g. 'Sep 28, 2026').
  - A pinned 48pt header with a mono-label capsule pill on the background colour.
  - Rows are `ModernTransactionListItem`, 8 apart, wrapped in a `RepaintBoundary`.
  - Sort is `compareNewestFirst`.
- `ModernTransactionListItem`:
  - Elevated card, 48x48 solid colour tile (expense/income colour) with a white glyph.
  - Description (17/600) plus a recurrence glyph.
  - `"{category} • {MMMd}"`.
  - Bold 22pt amount in the type colour, unsigned, with 2 decimals.
  - Tap opens `showTransactionForm` in edit mode.
  - Swipe left shows a confirm dialog; on confirm the transaction is deleted and a snackbar 'Transaction deleted' (danger, floating) appears.
- Empty states:
  - No months: 'No Transactions Yet' / 'Start tracking your finances by adding your first transaction' plus an 'Add Transaction' button.
  - Empty month: 'No Transactions' / 'No transactions for this month'.

### 1.5 Caching and perf strategies in Flutter (commit df8c7da)
- `_monthLedger()` (`transaction_model.dart:199`):
  - A `Map<int, _MonthLedger>` keyed by `year*12+month`, holding transactions, income, expenses and insertion-ordered `categoryExpenses`.
  - Cached while the source list identity and length are unchanged.
  - Invalidated in `notifyListeners()` (`:193`) and `saveTransactions`.
- `_sortedTransactionsCache` for `getAllTransactionsSorted` and `getRecentTransactions`, cleared whenever the ledger rebuilds.
  - The getters return copies (`List.of`).
  - `getRecentTransactions` is used by Home. Flow's preview does not use the cache.
- The detail page paginates 50 rows at a time.
- The Goals page tab was moved to a `Consumer` to limit rebuilds.

---

## 2. Visual layout and Swift mapping

### 2.1 Tokens the Spend and Flow screens use (Theme.swift has only a subset)

| Token | Dark | Light |
|---|---|---|
| background | #0A0A12 | #F9FAFB |
| card | #13131F | #FFFFFF |
| card border | white 7% | ink #101020 at 8% |
| hairline | white 6% | ink at ~6% |
| chipSurface | #15151F | #F1F1F7 |
| text | #F2F2FA | #111827 |
| text secondary | #9A9AB5 | #6B7280 |
| text tertiary | #5C5C78 | #9CA3AF |
| onAccent | #0A0A12 | white |
| track | #1B1B2C | #E9E9F1 |
| trackSecondary | #2A2A3E | #D9D9E6 |
| donutRemainder | #3A3A52 | #C9C9DA |

- Also needed: the 14 chart colours, plus `info` and `pink` (see 1.1).
- Fonts: bundle Gabarito Regular/Medium/SemiBold/Bold/ExtraBold/Black and SplineSansMono Regular/Medium/SemiBold via `UIAppFonts` (`budget_app/assets/fonts`).
- Type scale used by these screens (`app_typography.dart`):

| Style | Spec |
|---|---|
| pageTitle | 26/800, ls -0.6 |
| sectionHeader | 20/700, ls -0.3 |
| cardTitle | 17/700 |
| rowTitle | 15/600 |
| rowSubtitle | 12/400 |
| amount | 16/700 tabular |
| amountSmall | 15/700 tabular |
| heroSmall | 34/800, ls -1, tabular |
| metricAmount | 24/800, ls -0.5 |
| chipAmount | 24/700 |
| badge | 12/700 |
| badgeSmall | 11/700 |
| eyebrow | mono 11/600, ls 2.4 |
| monoLabel | mono 11/500, ls 1 |
| monoLink | mono 11/600, ls 1.5 |
| monoMetricLabel | mono 10/600, ls 1.6 |
| monoMonth | mono 11/500 |

### 2.2 Shared components these screens need
- `GlowCard` (26 radius, 1pt border, pressed scale .98), `GlowListCard` (8 padding, 12-inset hairlines) and `IconTile` (`glow_card.dart`).
- `GlowProgressBar` (glow fill, 800ms fill animation), `PillChip` (14% tint; outlined variant), `SegmentedPillControl` (default style).
- `MonthPill`, `SectionHeader`, `BudgieHeader` (`budgie_header.dart`).
- An empty-state view, a bottom-sheet style (top radius 24-26, grabber 40x4, card colour, border), and a recurrence glyph (custom-drawn, `recurrence_indicator.dart`).
- Haptics (`sensoryFeedback` or `UIImpactFeedbackGenerator`) on these interactions:
  - Light impact: category row tap.
  - Selection: donut slice select/deselect, and SegmentedPillControl segment change.
  - Medium impact on swipe threshold; heavy impact on delete confirm.

### 2.3 Chart to Swift approach

| Chart | Approach | Notes |
|---|---|---|
| Category donut | Custom SwiftUI `Shape` or `Canvas`: `Path.addArc` stroked with `StrokeStyle(lineWidth: 30, lineCap: .butt)`, in a 240x240 frame | Exact 1:1 with the painter, including gap and selected geometry. Drive the sweep with an animatable `progress` (500ms easeOut, skipped under `accessibilityReduceMotion`); hit-test with a `SpatialTapGesture` using the same annulus and angle maths. `SectorMark` (`innerRadius: .ratio(0.75)`, `angularInset`, `chartAngleSelection`) also works and gives audio graphs, but the sweep animation and the shrinking-inward selected slice are awkward. Add per-slice `accessibilityElement` labels either way. |
| Category progress bars | Custom `GlowProgressBar` view | |
| Net cash flow bars | Hand-built SwiftUI (like Flutter): fixed 190pt `ZStack`, `HStack` distribution, baseline at y=116, layout computed by a pure BudgieCore function | Swift Charts would need a fake pre-scaled y-value and a fixed domain. Per-bar `accessibilityLabel` such as "Sep, net +$2,322, current month" and a tap gesture. |
| Year-over-year bars | Two `GlowProgressBar`s | |
| Trend sparkline | Swift Charts: `LineMark`, `.interpolationMethod(.catmullRom)` (or `.monotone` to avoid overshoot), two series (glow: `lineWidth 9`, opacity .4; main: `lineWidth 3`), `PointMark` on the last point (symbol ~10pt, #F2F2FA), `RuleMark(y: 0)` dashed [3,4], `chartYScale(domain: -bound...bound)`, axes hidden | Give `chartXScale` a small trailing padding so the end dot is not clipped. Add an `accessibilityChartDescriptor`. |

Swipe-to-delete on card rows needs a `List` (`listRowSeparator(.hidden)`, clear row background, 20pt insets). That also gives lazy rows and pinned day headers. For single-card lists (the `GlowListCard` look) a plain `VStack` is fine because only 50 rows are shown at a time.

---

## 3. Gap vs the Swift MVP

**`SpendingView.swift:104-121`, category list**
- It shows only icon, name and amount. It lacks the donut, percentages, transaction counts, budget limit text, progress bars, drill-in, the top-6 plus tail expansion and slice selection.
- It follows the current month; Flutter follows the newest available month.
- Its month selector uses chevrons; Flutter uses a pill and a sheet.

**`HistoryView.swift`, day-grouped list**
- It has a day net, weekday titles and search (description and category), with swipe delete and tap edit over a lazy `List`. This is closer to Flutter's `TransactionPage` than to Flow.
- It is missing the Flow charts, the type/category/tag/date/amount filters, results summary, pagination, and a month-scoped view with the month strip.
- It searches description and category (`HistoryDay.filter`); Flutter searches description only.
- It shows weekday plus day-net headers; Flutter shows only `yMMMd`.
- **Perf risk:** `.onChange(of: model.data?.transactionRows)` compares 10k-element arrays of records (which contain a raw `JSONObject`) on each observation.

**BudgieCore**
- `FinancialData.transactions` is a computed `compactMap` on every access. `monthLedger()` is O(N) per call and `totals(forMonth:)` re-runs it. `categoryExpenses` uses a linear `firstIndex` per row. `transactionsNewestFirst(inMonth:)` filters all rows and re-sorts.
- Each `DartDateTime.fields` access recomputes a timezone offset (`DartDateTime.swift:72-85`, `timeZone.secondsFromGMT`). There is no cache.
- No cash-flow series, YoY, metrics, category breakdown, transaction filter or `DateFormat`-style helpers exist. `SpendingFormat.monthTitle/shortDay` live in the app target, untested.
- `MoneyFormatter`, `DartFixed` (correct `-0` handling), `compareNewestFirst`, `CategoryInfo` and the `transactionTags` section key already exist.

**AppModel**
- There is no shared `selectedMonth`, no ledger index or revision counter, and no tag access.
- The shell has 5 tabs (Spending/History/Net Worth/Recurring/Settings); Flutter has 6 (Home, Worth, Goals, Spend, Flow, More).

---

## 4. Required BudgieCore additions (pure, with Dart parity tests) and AppModel API

Perf principle: build one immutable `LedgerIndex` per data revision (one O(N) pass); every chart, filter and list reads from it.

### 4.1 `Domain/LedgerIndex.swift`

```swift
public struct LedgerRow: Sendable, Identifiable {   // index-friendly projection
  public let record: TransactionRecord
  public let dayKey: Int          // y*10000+m*100+d, local
  public let descriptionLower: String
  public var id: String { record.id }
}
public struct MonthSummary: Sendable {
  public let income, expenses: Double
  public let categoryExpenses: [(name: String, amount: Double)]  // first-appearance order (Dart map order)
  public let expenseCounts: [String: Int]
  public let transactionCount: Int      // both types (drives previous-month null vs 0)
  public var net: Double { income - expenses }
}
public struct LedgerIndex: Sendable {
  public static func build(_ rows: [TransactionRecord], calendar: DartCalendar) -> LedgerIndex
  public var newestFirst: [LedgerRow] { get }            // sorted once, keys precomputed
  public func newestFirst(inMonth: DartDateTime) -> ArraySlice<LedgerRow>
  public func summary(forMonth: DartDateTime) -> MonthSummary
  public var availableMonths: [DartDateTime] { get }     // descending
  public var netCashFlowHistory: [MonthCashFlow] { get } // ascending, months with data
  public func rollingNet(endingAt month: DartDateTime, months: Int) -> [MonthCashFlow] // contiguous, zero-filled
  public var categoryNames: [String] { get }             // filter options
}
public struct MonthCashFlow: Sendable, Equatable { month, income, expenses; var net }
```

- Build cost target: single pass, `fields` computed once per row, bucket per `ledgerMonthKey`, global sort with precomputed keys (reuse `FinancialData.sortNewestFirst`). Monthly newest-first lists are sub-slices of the global sort because the order is day-major.
- Keep `FinancialData.monthLedger`/`totals` as the oracle for tests, or re-implement them on top of `LedgerIndex`.

### 4.2 `Domain/CashFlowMath.swift`

```swift
public enum CashFlowMath {
  static func chartWindow(_ all: [MonthCashFlow], selectedMonth: DartDateTime, months: Int) -> [MonthCashFlow]
  static func metrics(_ w: [MonthCashFlow]) -> (avgSaved: Double, savingsRate: Double)
  static func percentDelta(current: Double, previous: Double) -> Double?   // nil when previous == 0
  static func formatPercentDelta(_ d: Double?) -> String                   // 'new' | ±x.x%
  struct YoY { current, previous: MonthCashFlow; incomeDelta, expenseDelta: Double?
               incomeFractions, expenseFractions: (this: Double, last: Double) }
  static func yearOverYear(_ index: LedgerIndex, selectedMonth: DartDateTime) -> YoY
  struct BarLayout { entry, height, isCurrent, isPositive, barWidth }
  static func barLayout(_ w: [MonthCashFlow], selectedMonth:, availableWidth:, maxUp: Double = 76, maxDown: Double = 40) -> [BarLayout]
  static func sparklineBound(_ nets: [Double]) -> Double                   // maxAbs<=0 ? 100 : maxAbs*1.15
}
```

### 4.3 `Domain/CategoryBreakdown.swift`

```swift
public struct CategoryRecord { name, amount, percentage, count, budgetLimit: Double?, rank: Int, paletteIndex: PaletteSlot }
public struct CategoryBreakdown {
  static func build(summary: MonthSummary, previousSummary: MonthSummary?, limits: [(String, Double)],
                    activeExpenseOrder: [String], maxVisible: Int = 6) -> CategoryBreakdown
  let records: [CategoryRecord]        // sorted desc, stable
  let total: Double                    // fold over per-category sums in map order
  let previousTotal: Double?           // nil if previous month has 0 transactions
  var deltaPct: Double?                // nil if previous nil or 0
  var slices: [Slice]                  // top 6 + 'Other' when records.count > 6
  var tail: (count: Int, total: Double, names: String)?
}
```
- Stable fallback colour index: hash the name with FNV-1a over UTF-8 (document that Dart's `hashCode` cannot be reproduced).

### 4.4 `Domain/TransactionFilter.swift`

```swift
public struct TransactionFilter: Equatable, Sendable {
  public enum Kind { case all, income, expense }
  var search: String; var kind: Kind; var category: String?; var tagId: String?
  var from: DartDateTime?; var to: DartDateTime?; var minAmount, maxAmount: Double?
  var isActive: Bool
  func apply(_ index: LedgerIndex) -> [LedgerRow]        // reads dayKey and descriptionLower
  static func summary(_ rows: [LedgerRow]) -> (income: Double, expenses: Double, net: Double, count: Int)
  static func parseAmount(_ text: String) -> Double?     // strip ',', trim, Dart tryParse (finite, decimal syntax)
}
```
- Mirror Dart's `dateOnly` comparisons using `dayKey` integers.
- Sums run over all filtered rows, in filtered (newest-first) order.

### 4.5 `Formatting/DartDateFormat.swift`
- en_US, ASCII helpers: `MMMM`, `MMM`, `yMMMM`, `MMMd`, `yMMMd`, `MMM ''yy`, `MMMM yyyy`.
- Move `SpendingFormat` into BudgieCore and cover it with tests.

### 4.6 AppModel additions

```swift
private(set) var ledger: LedgerIndex             // rebuilt off-main after each mutation, coalesced
private(set) var ledgerRevision: Int             // Views observe this, not transactionRows
var selectedMonth: DartDateTime                  // shared Home/Flow; default calendar.month(of: now); not persisted
func selectMonth(_ m: DartDateTime)              // normalises to DateTime(y, m)
var expenseCategoryOrder: [String]               // active expense names in sort order (palette index)
func categoryInfo(named:type:) -> CategoryInfo?  // exists
var tags: [TransactionTagInfo]                   // read-only view of Section.transactionTags (id, name, colorToken)
func deleteTransaction(id:) -> Bool              // exists
func updateTransaction / addTransaction          // exist; every mutation bumps ledgerRevision
```

### 4.7 Parity tests
Extend `native/ParityHarness/parity/` with a `cashflow_fixtures_test.dart` (generated JSON into `Fixtures/logic/`), and a Swift test in `DomainParityTests` style.
- Oracle setup: use the real `TransactionModel` for `getAvailableMonths`, `getNetCashFlowHistory`, `getMonthlySummary`, `getCategoryExpensesForMonth` (ordered entries), `getAllTransactionsSorted`, `getRecentTransactions`. Datasets: the typical fixture, `large_10k`, gap months, cross-year, empty, and DST-boundary dates under several `TZ` values.
- The page-level formulas (`_getChartDisplayData`, `_computeMetrics`, `_percentDelta`, bar heights, breakdown records) are private in `history_page.dart` and `category_page.dart`, so a harness test cannot call them. Options: pump `HistoryPage`/`CategoryPage` with a fixed model and read the rendered texts (metric chips, badge, YoY labels, 'N of M', pill texts, the donut delta pill), which is the true oracle and what `history_pagination_test.dart` already does; or write a documented Dart mirror of these formulas in the harness. Prefer widget-driven for text outputs plus model-level for series.
- Filter parity: enumerate a matrix of filter combinations (search, type, category, date range, min/max) and compare filtered id lists from a mirror of `_getFilteredTransactions`.

---

## 5. SwiftUI view breakdown and build sequence

**New files** (under `Budgie/Views/`)
- `Spend/SpendView.swift`, `Spend/DonutChart.swift` (Shape, centre label, delta pill), `Spend/CategoryRow.swift`, `Spend/CategoryTailRow.swift`, `Spend/MonthPickerSheet.swift`, `Spend/CategoryTransactionsView.swift`.
- `Flow/FlowView.swift`, `Flow/MetricStrip.swift`, `Flow/NetCashFlowCard.swift` (with `NetCashFlowBars`), `Flow/MonthDetailSheet.swift`, `Flow/YearOverYearCard.swift`, `Flow/TrendCard.swift` (Charts), `Flow/RangeSheet.swift`, `Flow/TransactionsPreviewCard.swift`.
- `Transactions/TransactionsDetailView.swift`, `Transactions/FiltersCard.swift`, `Transactions/PickerSheets.swift` (category, date), `Transactions/ResultsList.swift`, `Transactions/MonthTransactionsView.swift` (the Flutter `TransactionPage` equivalent), `Transactions/TransactionRow.swift` (shared).
- `Components/` (shared): `GlowCard`, `GlowListCard`, `IconTile`, `GlowProgressBar`, `PillChip`, `SegmentedPillControl`, `MonthPill`, `SectionHeader`, `EmptyStateView`, `BottomSheetChrome`, `RecurrenceGlyph`.

**Build order** (S/M/L are effort estimates)
1. Shared foundations: full `Theme` tokens, bundled fonts, the components above. (M; dependency on the shared design-system work.)
2. `LedgerIndex` + `MonthCashFlow` + tests, with `large_10k` timing test. (M)
3. `DartDateFormat` helpers. (S)
4. `CashFlowMath` + tests. (M)
5. `CategoryBreakdown` + tests. (M)
6. `TransactionFilter` + amount parser + tests. (M)
7. Parity harness fixtures (Dart side) + Swift assertions. (M-L)
8. AppModel `ledger`, `ledgerRevision`, `selectedMonth`, `tags`; retire `transactionRows` change-detection. (S-M)
9. Spend tab, donut and drill-in. (L)
10. Flow tab and month detail sheet. (L)
11. Transactions detail page (filters, results, pagination). (L)
12. Month-scoped list (Flutter `TransactionPage`) and shared row. (M)
13. Perf pass on a 10k store: signposts, `measure` tests for rebuild, filter, scroll. (M) Results and method: [PERFORMANCE.md](../../PERFORMANCE.md).
14. UI/accessibility tests (VoiceOver labels for bars and slices, Dynamic Type, reduce motion). (S-M)

---

## 6. Risks and open questions

Decisions needed:
1. **Detail list actions.** Flutter's Flow detail list is read-only; the Swift MVP History edits and deletes. Recommend a superset (tap to edit and swipe to delete on detail rows). Confirm.
2. **Search scope.** Flutter matches description only; MVP matches description and category. Which to keep?
3. **Month pill on the detail page.** In Flutter it changes the shared month (Home/Flow) but does not filter the list. Replicate, drop, or make it a real filter?
4. **Amount field prefix '$'.** Flutter hard-codes it. Use the configured currency symbol instead?
5. **Row headers on the month list.** Flutter shows plain `yMMMd`; the MVP adds weekday and day net. Keep or drop the extras?
6. **Tab shell.** The MVP has 5 native tabs. Flutter's 6-tab floating dock changes bottom padding (dock inset = max(20, safeBottom) + 96) and the page structure. This belongs to the shell analyst.
7. **Insights.** Flow embeds `LocalInsightsSection` between the metric strip and the chart. It depends on the `InsightEngine` (`insights/insight_engine.dart`, 471 lines) and `local_insights_*` prefs. This needs a slot and coordination with the Insights analyst.
8. **Tags.** Filtering by tag needs the `transactionTags` section read (`transaction_tag.dart`: id, name, colorToken). Tag management is out of scope; only the filter chips are needed here.

Risks:
- **Perf** (measured at 10k rows in [PERFORMANCE.md](../../PERFORMANCE.md)).
  - Rebuilding the ledger per mutation on the main thread is ~tens of ms at 10k; do it off-main and swap atomically, keeping deletes/edits addressed by id.
  - Avoid `Equatable` diffs of 10k records in views (`ledgerRevision` instead).
  - `DartDateTime.fields` recomputes the offset on every access, so never call it inside a hot loop more than once per row.
- **Float parity.**
  - Category total is a fold over per-category sums; metrics fold months ascending; filter summary folds in newest-first order. Swift must preserve these exact orders.
  - Percentage strings must use `DartFixed.toStringAsFixed` (round half away from zero, negative zero preserved, e.g. '-0%').
- **Sort ties.** Dart is stable only up to 33 elements; category ties from 34 differ from a stable sort (`DartSort` matches).
- **Category colour fallback.** Dart `String.hashCode` cannot be reproduced. Ranks >= 7 for unknown or archived names will get a different colour than Flutter unless we pick a defined substitute.
- **Chart fidelity.**
  - fl_chart's cubic smoothing vs `.catmullRom` may differ visibly on spiky series.
  - `SectorMark` cannot reproduce the exact inward-grow selection and gap geometry, hence the Shape recommendation.
  - Glow/shadow blur radii: Flutter `blurRadius` ≈ 2σ, so use radius ≈ blur/2 in SwiftUI `.shadow`.
- **Month semantics.**
  - Spend defaults to the newest month with data; Flow follows Home's month (default: current month, which may have no data, giving no highlighted bar).
  - Flutter's Home month picker only lets you change month within the selected year (PARITY_GAPS row 25), while the Spend and Flow pickers can jump across years.
- **Empty and error strings** are listed in section 1. Keep them verbatim; some (grid_view search icon, `trending_up` for negative net) look like Flutter bugs and are mentioned above so the plan can choose to fix or copy them deliberately.
- **Accessibility gap in Flutter.** The donut and bars have no semantics in Flutter, so any VoiceOver labels here are net-new work (label templates should be agreed before tests are written).
