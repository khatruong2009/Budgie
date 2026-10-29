> Archived; paths refer to the `flutter-final` tag.

# G. UI Inventory of the Flutter app (budget_app) for the SwiftUI port

Scope: every screen, sheet and dialog in `budget_app/lib`, the design tokens, the reusable widgets, and screenshots.
All paths are relative to `budget_app/lib` unless stated. Line numbers refer to the worktree at commit `b69008d` (app version 3.4.0).
Screenshots are in `native/docs/research/screenshots/` (index in section 4).

Read this first (the six things that matter most for the port):

1. Two visual generations coexist. The "Budgie redesign" (GlowCard / GlowFab / FloatingDock / mono eyebrows, `widgets/glow_*.dart`, `pill_chip.dart`, `budgie_header.dart`) is used by the six tab roots and most sheets. Older screens still use the earlier Material-ish design (`ElevatedCard`, `AppButton` gradient, `ModernAppBar` with an indigo-violet gradient, `ModernTransactionListItem`, `EmptyState`, `ModernTextField`). These are: Transactions list (Home > SEE ALL), Recurring Transactions, the Add/Edit Transaction dialog, Recurring form, Category drill-in rows, Tags and rules, Categories settings, lock screen, init-error screen. See screenshots 15 and 16 versus 05. A SwiftUI port should pick one system; the redesign tokens are the target.
2. Navigation is not a normal tab bar. Six tabs live in a `PageView` of six independent `Navigator`s with swipe disabled, and one custom `FloatingDock` floats above all of them, including above pushed detail pages (`home_page.dart:103-159`, screenshots 15 and 16 show the dock over a pushed page). Sheets and dialogs use `useRootNavigator: true` and cover the dock.
3. The tab labelled "Home" is `SpendingPage` (cash flow hero), the tab labelled "Spend" is `CategoryPage`, "Flow" is `HistoryPage`, "More" is `SettingsPage` (`home_page.dart:26-57`, `112-145`). Titles on the pages differ from dock labels: Categories, Cash flow, Settings.
4. Most add and edit flows are centred dialogs, not sheets: transaction form, net worth account editor, savings goal form, allocation, category editor, tag, merchant rule (`showDialog`). Only pickers and confirmations are bottom sheets.
5. Observed behaviour quirk, do not port blindly: the Safe-to-spend breakdown excludes anything dated "today" with a time of day. `SafeToSpendCalculator` clamps `asOf` to midnight (`safe_to_spend.dart:189-193`) and skips `transaction.date.isAfter(effectiveAsOf)` (`safe_to_spend.dart:80-83`), while the transaction form defaults the date to `DateTime.now()` (`transaction_form.dart:41`) and stores it un-normalised (`transaction_model.dart:275-296`). Result seen in screenshot 14: after adding $3,200 income and $42.50 expense today, the sheet shows "Income recorded $0.00 / Expenses recorded $0.00" and a "Projected shortfall $100" (the whole budget reserve), while the hero on the same page shows +$3,157.50. Decide the intended semantics in Swift (compare by calendar day).
6. Dead code that need not be ported: `InsightsPage` (`insights_page.dart`, never pushed anywhere; the same content appears inline on the Flow tab via `LocalInsightsSection`), `LoadingShimmer` (`widgets/loading_shimmer.dart`, no call sites), `ModernSliverAppBar`, `AnimatedMetricCard` (only in `design_system.dart`), `VoiceRecordingSheet` public name (the flow is `startVoiceExpenseFlow`).

---

## 1. Screens, sheets, dialogs

Legend for "how reached": Dock = tap or drag on the floating dock; FAB = round accent button bottom-right (above the dock).
Count: 6 tab roots + 8 pushed pages + 4 startup or system screens + 30 sheets or dialogs (each is listed below). One page (InsightsPage) is unreachable.

### 1.0 Startup and system screens (`main.dart`)

| Screen | When | What | Notes |
|---|---|---|---|
| Opening screen | While `_initializeApp` runs (`_OpeningScreen`, `main.dart:488`; switcher `main.dart:241`) | Vertical gradient `#0A0A12 -> #0F0F18`, 120pt `budgie_mark.png` centred, "Budgie" (displayMedium 28/700, textPrimaryDark), eyebrow "BUDGET IN BALANCE" (letterSpacing 2.8), 3 pulsing 7pt accent dots at 8% from bottom. Always dark regardless of theme. | Intro animation 1400 ms; glow radial washes in accent `#818CF8`; dots pulse 1200 ms loop. Switches to app via `AnimatedSwitcher` 450 ms easeOut/easeIn (`main.dart:241`). Matches native launch screen so the handoff is invisible. |
| Initialization error | `_initializeApp` threw (data file unreadable) (`_InitializationErrorScreen`, `main.dart:411`) | Centred `sd_storage_rounded` 54pt in danger, title "Budgie couldn't read your data", body "Nothing has been changed on this device. Unlock your phone if it is locked, then try again.", raw error text, primary AppButton "Try again". | The app is never shown on empty models (would overwrite real data). Protected-data wait is `ProtectedDataGate.waitUntilAvailable()` (`main.dart:261`). |
| Onboarding tutorial (3 pages) | First launch only; flag `StorageKeys.onboardingCompleted` in shared_preferences (`onboarding_tutorial.dart:31-46`). Wraps home (`main.dart` build, `OnboardingTutorialGate`). | Page: 116pt tinted accent circle with 52pt icon, mono eyebrow, 26-ish bold title, 1.45-line-height body. "Skip" top-right, animated page dots (active 22x8, inactive 8x8, fully rounded), full-width 56pt button "Continue" / "Start budgeting" (last page), radius 16. | Copy: p1 "WELCOME TO BUDGIE / Your money, made clearer. / Budgie keeps your budget simple and private. Financial data and insights stay on this device unless you choose to export or share a backup."; p2 "START HERE / Track what comes and goes. / On Home, use the add button for income or expenses. Your balance and recent activity update as you go."; p3 "EXPLORE WHEN READY / Plan ahead, then look back. / Worth tracks accounts, Goals keeps savings in view, and Spend, Flow, and More help you understand and manage your budget." (`onboarding_tutorial.dart:90-107`). Shows a spinner until the flag is read. Screenshots 01-03. Note it uses the light-theme primary `#6366F1` in light mode, not the dark accent. |
| App privacy gate | Wraps everything (`widgets/app_privacy_gate.dart`) | (a) App-switcher cover: opaque `#0A0A12`, 72pt mark, "Budgie", "App preview hidden" - shown whenever app goes inactive/hidden/paused and App lock is on. (b) Lock screen: title "Budgie is locked", body "Authenticate to view your financial data." or error, primary button "Unlock" / "Authenticating…", secondary "Disable App Lock". | Locks when resumed after >= `autoLockTimeoutSeconds` in background (0, 30, 60, 300, 900). Uses `local_authentication` with `biometricOnly:false`, reason "Unlock Budgie to view your financial data". Unsupported device message: "Set up a device passcode or biometrics to use App Lock." Child is `AbsorbPointer`ed and excluded from semantics while locked. Also locks immediately when the toggle is switched on. |
| Unsaved-changes banner | Top of Home scaffold when any model has `hasUnsavedChanges` (`widgets/unsaved_changes_banner.dart`, mounted `home_page.dart:99`) | Danger-coloured strip, `cloud_off_rounded` icon, "Some changes are not saved to this device yet." and text button "Retry" (retries all flagged sections). | Also `retryPendingSaves()` fires when app goes inactive/paused (`main.dart:211-212`). A failed add also raises a snackbar (below). |

### 1.1 Shell: floating dock + tab pages

Dock (`widgets/floating_dock.dart`, `home_page.dart:26-57,147-159`):
- Six items, order and labels: Home (`paid_rounded`), Worth (`donut_small_rounded`), Goals (`flag_rounded`), Spend (`pie_chart_rounded`), Flow (`bar_chart_rounded`), More (`settings_rounded`). Material Symbols Rounded; port to SF Symbols (dollarsign.circle, chart.pie, flag, chart.pie/circle, chart.bar, gearshape).
- Pill: fully rounded, padding 8, background dark `rgba(19,19,31,0.88)` (`AppColors.dockBackground` `#E013131F`) / light white 88%; border white 10% / black 8%; backdrop blur sigma 20; shadow black 60% (dark) or 15% (light), blur 40, offset (0,16). Distance from bottom = `max(20, safeAreaBottom)`.
- Each button: 44pt high, horizontal padding 12 (16 when active), icon 20pt weight 500. Active button becomes an accent-filled pill with the label (13/700) after the icon (gap 7) and accent glow (alpha 0.6); label text scale is clamped to 1.2. Inactive icon colour dark `#8A8AA8`, light `#6B7280`. Morph 250 ms easeOut (100 ms while drag-selecting).
- Interaction: tap selects (page animates 300 ms easeInOut, `home_page.dart:71-83`); horizontal drag or long-press-then-drag across the pill selects the tab under the finger with `jumpToPage` (no animation) and a selection haptic per change (`floating_dock.dart:88-135,162-177`). Page swiping itself is disabled (`NeverScrollableScrollPhysics`).
- Content bottom padding to clear the dock is `dockBottomOffset + 96` and FAB offset is `dockBottomOffset + 72` (`floating_dock.dart:12-30`).
- Tab pages are kept alive (PageView + Navigators), so scroll position and nested pushes persist between tab switches.

### 1.2 Tab 1 "Home" = SpendingPage (`spending_page.dart`)

- Purpose: current-month cash flow, safe-to-spend, budgets, recent activity, quick add.
- Scaffold: `BudgiePageScaffold` (`widgets/budgie_page_scaffold.dart`) with two stacked FABs at right 20 / bottom `fabBottomOffset`: mic FAB 44pt (mobile only) and main 54pt "+" FAB (`spending_page.dart:481-510`).
- Content (single `SingleChildScrollView`, `spending_page.dart:513-680`), top to bottom:
  1. `BudgieHeader(showLogo)`: 36pt logo mark (radius 12) left, centred `MonthPill` ("September 2026", chevron) - tap toggles inline month wheel.
  2. Inline month panel (`_MonthPickerPanel`, 1001): a `GlowCard` containing a 128pt-high `CupertinoPicker`, item extent 34, 12 English month names, expands with 250 ms easeInOut (0 ms under reduce motion). Selecting a month calls `TransactionModel.selectMonth(DateTime(sameYear, index+1))` (year can never change here). The selected month is global state shared with Flow and Spend.
  3. Hero cash flow (`_HeroCashFlow`, 1093): mono eyebrow "CASH FLOW", 58/800 hero number of |income - expenses| with rolling-digit animation 900 ms (`animated_digit`), text glow; negative shows danger colour and status "SHORT THIS MONTH", positive "SAVED THIS MONTH" (accent), zero "BREAKING EVEN"; subline "$X in · $Y out" (14pt).
  4. Spend gauge (`_SpendGauge`, 1388): 14pt GlowProgressBar value = spent/income (0 if income <= 0), gradient fill with 2pt inset and white thumb, mono labels "SPENT $x" and "INCOME $y".
  5. Two `_FlowChip`s (Income / Expenses): glowing 8pt dot, amount 24/700 (0 decimals), delta line "+12.3% vs August" coloured, or "No August data" in tertiary when previous month has no baseline; delta logic returns +100 when previous is 0 and current isn't, null when both 0 (`spending_page.dart:339`).
  6. Safe-to-spend card (`_SafeToSpendCard`, 1222): shield icon tile (accent) / warning tile (danger) for "Projected shortfall"; subtitle "$X/day for N days left" | "This month is already closed out" | "Add income or reduce planned spending"; right side amount + "DETAILS >". Tap opens the breakdown sheet.
  7. Section "Budgets" + mono link EDIT (`SectionHeader`): `_BudgetsCard` = list of budgeted categories sorted by spent desc then name (`_buildBudgetProgressItems`, `spending_page.dart:107`), each row icon tile, name, "$spent of $limit", status pill and 8pt progress bar; final row "Add a budget" with subtitle "No monthly limits yet" or "Set a limit for another category" (shown while some expense category has no limit).
     - Status colouring (`_BudgetRow`, 1587-1700): progress >= 1 over budget = danger "$X over"; >= 0.85 = warning; else income green "$X left"; amounts under $100 keep cents.
  8. Section "Recent activity" + SEE ALL: last 3 transactions in a `GlowListCard` (income row: green tile with south_west arrow and green `+$`; expense row: category icon on accent tile, primary-colour `-$`). Empty: "No transactions yet."
  9. Two 52pt `PillButton`s: "− Expense" (danger tint) and "+ Income" (income tint), each opens the add form.
- Interactions:
  - Tap FAB: add-expense dialog. Long-press FAB: `_QuickExpenseCategorySheet` (692) a `DraggableScrollableSheet` titled "Add expense / Choose a category, then enter the amount and description." listing expense categories; picking one opens the form pre-set to that category.
  - Tap mic FAB: voice flow (1.9).
  - Tap a budget row: budget limit sheet (1.2a). EDIT: "Edit budgets" picker sheet (lists budgeted categories, or empty subtitle "No monthly limits yet. Add one to start tracking a category."; includes "Add a budget" row when not all categories are budgeted) then the limit sheet. "Add a budget" row: "Add a budget / Choose a category to set a monthly limit." picker of unbudgeted categories then limit sheet.
  - Tap safe-to-spend card: breakdown sheet (1.2b).
  - SEE ALL pushes `TransactionPage` (1.10).
- Empty state: no dedicated component. All zeros render; gauge empty; Budgets shows only the "Add a budget" row; Recent shows "No transactions yet." (screenshot 04).
- No pull-to-refresh anywhere in the app (searched: no `RefreshIndicator`).

#### 1.2a Budget limit sheet (`_BudgetLimitSheet`, `spending_page.dart:811-1000`)
- Modal bottom sheet, `isScrollControlled`, transparent barrier host, container radius 28 top, card colour + 1px card border, 44x4 grab handle in tertiary 35%.
- Header: icon tile + category name (cardTitle) + "Monthly spending limit".
- Field: autofocus decimal numeric keyboard, prefix "$", label "Limit", hint "0.00", helper "Set a positive amount for this category." Filled with `MoneyFormatter.formatNumber(limit, 2)` when editing. Parse strips every non-digit non-dot character; valid iff parsed > 0. Enter/done also saves.
- Buttons: "Remove" (secondary, trash icon; only when a limit exists) and "Save" (primary gradient, disabled until valid). Both pop after awaiting the model call.

#### 1.2b Safe-to-spend breakdown sheet (`spending_page.dart:362-446`)
- Standard M3 sheet with drag handle, scrollable, padding 24. Title "Safe to spend" or "Projected shortfall" (headingLarge 28/bold), explainer ("A forward-looking estimate for the rest of this month." or "What you have spent and reserved for the rest of this month is more than the income you expect."), rows: Income recorded, Income still expected, Expenses recorded, Upcoming recurring bills, Flexible budget reserve, Suggested goal contributions, divider, total row (emphasised; danger when over), footer "$X per day · N days remaining" / shortfall hint / "This month is already closed out."
- Formula (`safe_to_spend.dart:37-56`): safeToSpend = actualIncome + expectedIncome - actualExpenses - (upcomingRecurringExpenses + flexibleBudgetReserve + plannedGoalContributions). Flexible reserve = sum over budgeted categories of max(0, limit - spentSoFar - upcomingRecurring). Goal contributions = sum of `suggestedMonthlyContribution` for non-completed goals, only when the viewed month is not before the current month. See quirk in the top notes.

### 1.3 Tab 2 "Worth" = NetWorthPage (`net_worth_page.dart`, 2959 lines)

- Purpose: track asset and liability accounts by month, growth chart, per-account history.
- Header `BudgieHeader(title: 'Net worth')`, FAB "Add account" (opens the editor dialog; pre-selects Asset or Liability from the toggle).
- Empty state (`_NetWorthEmptyState`, 198): card with icon tile, "No net worth accounts yet", "Create your first asset or liability to start tracking net worth over time.", primary button "Add account" (screenshot 06).
- Populated content (`net_worth_page.dart:84-193`): `MonthSelector` (horizontal strip of month chips, height 84, item width 120, auto-scrolls to selection; reads `model.getNetWorthAvailableMonths()` and writes `selectNetWorthMonth`, a separate month from the spending month); hero (`_NetWorthHero`, eyebrow "TOTAL · SEPTEMBER 2026", 48/800 number animated 900 ms, `_DeltaPill` with trend icon for month-over-month change); Growth card (`_GrowthChartCard`, 386: title "Growth", mono `SegmentedPillControl` "6M / 1Y / ALL" default 1Y, line chart (`fl_chart`) of up to 24 monthly totals, touch or long-press (150 ms) shows `_NetWorthHoverCard` with Assets / Liabilities / "Monthly snapshot"; empty text "Add balance updates to build your growth chart."); Assets vs Liabilities card with `SplitGlowBar` (green left / rose right, 3px gap); `_AccountsToggle` chips "Assets" / "Liabilities" (200 ms); `_AccountsList` rows.
- Account row (`_AccountRow`, 1095): 44pt icon tile, name, latest balance, percent change vs previous month (green if good for the account type), "x% of assets|liabilities" share label and share bar. Tap = edit dialog. Long-press = action sheet (1228) with "Edit Balance", "View History", "Delete Account".
- Editor dialog (`_NetWorthEditorDialog`, 2202): title "Add account" / "Edit account"; Asset/Liability pill toggle (animated 220 ms); "Account name" text field (error "Name is required"); balance field with live thousands-comma formatter, at most 2 decimals, regex `^\d*\.?\d{0,2}$` (`_CurrencyInputFormatter`, 2161), label "Asset balance"/"Liability balance", valid iff parsed >= 0 (0 is allowed; error "Enter a valid balance"); "Balance month" tile opens a calendar date picker limited to 1970 - end of current month, help text "Select balance month", stored as the first of the month; when editing, switching month reloads that month's stored amount or blank. Buttons "Cancel" / "Add" | "Save".
- Delete: Cupertino alert "Delete account?" (Cancel / Delete) (`net_worth_page.dart:2871`).
- Account history pushed page (`_AccountHistoryPage`, 1370): hero with "Balance history", asset/liability pill, "Last update <date>" or "No recorded updates yet", "CURRENT BALANCE"; stat cards CURRENT and PEAK; trend chart ("Trend"; "Showing the first recorded balance." for one point); "Timeline" list of snapshots (date, time, amount, delta) each with a delete icon button that is disabled when only one snapshot remains (tooltip "Keep at least one balance update"); confirm alert "Delete balance update?" (2909).
- Sync rule from AGENTS.md: month keys and snapshot logic live in `net_worth_entry.dart` (`netWorthMonthKey`, `endOfNetWorthMonth`). Not re-derived here.

### 1.4 Tab 3 "Goals" = SavingsGoalsPage (`savings_goals_page.dart`, 1708 lines)

- Header "Goals", FAB "Add savings goal". Empty state card (`_buildEmptyState`, 164): piggy icon tile, "No savings goals yet", "Create a goal, set a target date, and track progress as you set money aside.", button "Add goal" (screenshot 07).
- Content: `_SavingsGoalsSummary` (608): overall ring with percent, eyebrow "SAVED SO FAR", total saved, "of $target · N of M complete". Then one `_SavingsGoalCard` (691) per goal: 84pt `ProgressRing` (thickness 9, glow) with percent (or check when complete), name (goalTitle 18/700), saved of target, `_StatusPill` (Complete green / Behind amber / On track accent, badgeSmall 11pt), pace copy "Nov 30 · $360/mo keeps you on pace" or "... · bump to $435/mo to catch up" (`_paceCopyFor`, 251), "Add money" filled PillButton (44pt), a "more" button (aria "More goal actions"). Completed cards: green-tinted gradient and 30% green border, no action row, copy "Fully funded on <date> — nice work", long-press opens the actions.
- Status rule (`_statusFor`, 241): complete if `isCompleted`; behind if overdue, or if progress < (elapsed / lifespan) computed from `createdAt` to `targetDate`; same-day deadline behind unless funded.
- Goal form dialog (`_GoalFormDialog`, 1026-1215): "Add savings goal" / "Edit savings goal"; "Goal name" (hint "Vacation, emergency fund, new car", capitalise sentences, required: "Name is required"); "Target amount" (decimal, > 0: "Enter a target greater than 0"); "Saved so far" only when editing (>= 0: "Enter 0 or more"); "Target date" tile with date picker from `year-1` to `year+20`; Cancel / "Add"|"Update". Success snackbars "Savings goal added" / "Savings goal updated".
- Allocation dialog (`_AllocationDialog`, 1219): "Add money", field "Allocation amount" (> 0: "Enter an amount greater than 0"), quick chips "$25", "$100" and "remaining", buttons "Finish goal" (fills remaining), "Cancel", "Add money". Snackbar "Allocation added". Completing a goal plays a 1600 ms confetti celebration overlay "Goal complete" (`_CompletionCelebration`, 1547; `_CelebrationPainter`).
- Actions sheet (371): "Edit goal", "Delete goal". Delete confirm dialog "Delete savings goal?" (433) and snackbar "Savings goal deleted"; errors surface as a snackbar "Savings goal action failed".
- Goals feed Safe-to-spend and the "goal behind schedule" insight.

### 1.5 Tab 4 "Spend" = CategoryPage (`category_page.dart`)

- Header "Categories" with `MonthPill` showing only the month name (e.g. "September"). Tap opens month bottom sheet "Select month" listing months that have data (`DateFormat.yMMMM`), ~`category_page.dart:499-590`. Uses its own `selectedMonth`, falling back to the most recent available month (stale-month guard, lines 36-52); this is not the shared `selectedMonth`.
- Body: `CategoryDonutChart` (240pt, ring thickness 30, selected slice +6, 0.5% gaps, 500 ms; centre shows eyebrow "SPENT", total in 34/800, delta "N% vs August" vs previous month or per-slice name/amount/percent when a slice is selected; tap slice selects) then a `GlowListCard` of category rows sorted by amount desc.
- Colour assignment: top 6 ranks get fixed palette accent, income-green, danger, warning, info, pink (`category_page.dart:106-115`); everything beyond 6 is aggregated into a single grey "N categories" tail row (`donutRemainder`), expandable in place and collapsible with "Show less" (`_tailExpanded`, `_buildTailRow` `category_page.dart:389`, `_buildCollapseRow` `:467`).
- Row: icon tile, name, "N transactions · P%" plus " · over limit" or " · $100 limit" when a budget exists, amount, thin proportional bar. Tap pushes `CategoryTransactionsPage` (Cupertino route).
- Empty states via legacy `EmptyState`: "No Expenses Yet" / "Start tracking your expenses to see category breakdowns" (no months at all) and "No Expenses" / "No expenses recorded for this month" (screenshot 08 shows data, empty variant not captured).

Category drill-in (`category_transactions_page.dart`): back chevron, category name/icon, summary card "TOTAL SPENT" amount with pills for the month (`MMMM yyyy`) and "N transaction(s)", eyebrow "TRANSACTIONS", list rows with swipe-to-delete (Dismissible endToStart, Cupertino alert "Delete Transaction" / "Are you sure you want to delete this transaction?" Cancel/Delete). Empty: "No Transactions" / "No transactions found in this category for <Month>". Recurring rows show `RecurrenceIndicator`. Rows are not tappable to edit.

### 1.6 Tab 5 "Flow" = HistoryPage (`history_page.dart`, 2149 lines)

- Header "Cash flow" with `MonthPill` labelled "3 months / 6 months / 12 months" (default 6). Tap opens "CHART RANGE" sheet (`_showRangePicker`, 439) with three `_RangeOptionTile`s. Range is UI-only state.
- Body (`history_page.dart:47-127`): metric strip of two `_MetricChip`s "AVG SAVED / MO" and "SAVINGS RATE" (rate = (income-expenses)/income x 100 over the range; 0 if no income); `LocalInsightsSection` (Insights cards; see below); "Net cash flow" card of bars (`_NetCashFlowBars`, 665: chart height 190, zero line at 116, max positive bar 76, max negative 40, bar corner 10, current-month bar glows and shows a "+$3,158" pill; empty text "No cash flow data yet."; tap a bar opens month detail sheet `_showMonthDetailsBottomSheet` 498 with Income, Expenses, "Net cash flow"); "Year over year" card (title, mono "SEP '26 VS SEP '25", Income and Expenses rows with this-year vs last-year bars, delta "new" when last year is 0, legend "This year"/"Last year"); a trend card "NET / MO" (12-month sparkline via `fl_chart`); section "Transactions" + SEE ALL with the 3 latest rows (`_TransactionRow`, read-only).
- Data window: chart months are those `<= model.selectedMonth`, last N (`_getChartDisplayData`, `history_page.dart:126`). The Home month picker therefore also moves this chart.
- Insights (`widgets/local_insights_section.dart`, `insights/insight_engine.dart`): rule-based (no AI) cards under a "Insights" header and caption "Calculated privately on this device · Not financial advice". Nine types: budgetPace, monthlySpendingChange, unusualTransaction, savingsRateTrend, recurringAmountChange, consistentlyUnderBudget, goalBehindSchedule, negativeCashFlow, possibleDuplicate; severity info/positive/warning/urgent. Each card has an overflow menu "Snooze for 30 days" and "Dismiss"; state in shared_preferences keys `local_insights_dismissed_v1` (string list of ids) and `local_insights_snoozed_v1` (JSON id -> ISO date) (`local_insights_section.dart:19-21`). Hidden entirely when there are none.
- Transactions detail page (`_TransactionsDetailPage`, 1248, pushed by SEE ALL): back chip, "Transactions" title, `MonthPill` month sheet ("SELECT MONTH") that changes the shared month; "Filters" card with RESET link, search field (hint "Search descriptions", matches description substring, case-insensitive), All/Income/Expense segmented control, Category picker sheet ("SELECT CATEGORY", "All categories"), tag FilterChips (only when tags exist), From/To date pickers ("Any date"), Min/Max amount fields (commas stripped); "Results" header with "N of TOTAL", pills Income / Expenses / Net; list of read-only rows; paginated 50 at a time with text "Showing X of Y matches" and a "Load more transactions" button (`_visibleTransactionCount`, resets to 50 when any filter changes). Empty: "No transactions match these filters." / "No transactions have been recorded yet." Rows cannot be edited or deleted here.

### 1.7 Tab 6 "More" = SettingsPage (`settings_page.dart`, 1310 lines)

Single scroll of `GlowListCard`s (screenshot 10 and 10b):
- Header "Settings", brand card (gradient, mark image, "Budgie", "Make every dollar count").
- APPEARANCE: Theme row with mono `SegmentedPillControl` "Light / Dark / Auto" (Auto = system). Stored as `themeMode` in shared_preferences (`theme_provider.dart`).
- PERSONALIZATION: "Categories" (subtitle "N active · custom names, icons, and order") pushes 1.11; "Tags & rules" ("N tags · M rules") pushes 1.12; "Currency" (bottom choice sheet "Base currency": USD, CAD, EUR, GBP, AUD, JPY, CNY, INR, KRW, MXN, BRL with names, `settings_page.dart:1039-1049`); "Number format" (choice sheet: "Match device" + en_US, en_CA, en_GB, en_AU, de_DE, fr_FR, es_ES, ja_JP, `1053-1060`).
- PRIVACY: "App lock" switch ("Require device authentication" / "Lock after X"), "Lock delay" row (only when on; sheet choices Immediately, 30 seconds, 1 minute, 5 minutes, 15 minutes; default read from `AppSettingsProvider`), "Hide balances" switch ("Mask amounts throughout the app"; `MoneyFormatter` returns "••••" everywhere).
- DATA: "Recurring transactions" (subtitle "No active recurring transactions" or a count) pushes 1.13; "Export as CSV" ("All N transactions", share sheet, snackbar "Transactions exported successfully!"); "Import from CSV" (file picker `csv`, confirmation dialog, snackbar summarises added / duplicates skipped / unreadable rows, or "No transactions found in this file" / "All transactions in this file already exist"); "Export backup" ("Everything, as a JSON file", share sheet, subject "Budgie Backup", snackbar "Backup exported"); "Import backup" ("Restore everything (replaces current data)", dialog "Replace all data?" with "This will import N transactions, M net worth entries, K budgets, G goals and R recurring templates, replacing everything currently in Budgie. This cannot be undone." Cancel/Replace, snackbar "Backup restored"). Errors: "Could not import: ...", "Could not export backup: ...", "Could not import backup: ...".
- ABOUT: Version "Budgie 3.4.0" (from package info).

### 1.8 Add/Edit transaction dialog (`transaction_form.dart`, `showTransactionForm`)

- Reached from: Home FAB, "− Expense" / "+ Income" pills, quick actions, deep links `budgetapp://add-expense|add-income`, voice prefill, tapping a row in the Transactions list (edit), the "Add Transaction" button in the Transactions empty state. Route is a `showDialog`, not a sheet. Screenshot 11.
- Layout: max width 500, radius 20, XL shadow, card colour. Title centred: "Add Expense" | "Add Income" (headingMedium 22/600). Note the title does not change for edits (it depends only on type); the primary button says "Update" for edits, "Add" for new.
- Fields: Amount (`ModernTextField`, `$` prefix icon, decimal keyboard, hint 0.00, autofocus on open), Description (hint "What was this for?"), Category (`CupertinoPicker`, 90pt tall, item extent 32, coloured 24pt icon chip per row: red for expense, green for income; ordered per `CategoryProvider`), Tags (`FilterChip`s, shown only if any tags exist), Date tile (`MMM dd, yyyy`, date picker 2000 to today; future dates not allowed).
- Validation (`validateForm`, `transaction_form.dart:152`): amount required ("Amount is required"), numeric ("Please enter a valid number" - uses `double.tryParse`, so "1,000" fails), > 0 ("Amount must be greater than 0"). Description is only advisory: shows "Description is recommended" but saving proceeds, storing "Transaction" when empty. Errors clear when typing.
- Merchant rules: typing a description or amount runs `CategorizationProvider.suggest` and silently switches category and tags (`applySuggestion`).
- Buttons: "Cancel" (secondary) and primary gradient (expense red / income green) "Add"|"Update" with spinner while the durable save runs; dialog closes only after the save future resolves. Footer link "Make this recurring" (hidden when prefilled by voice) closes the dialog and opens the recurring form for the same type.
- After save: if the entry's month differs from the selected month, snackbar "Added to <Month>" (adds the year when not current) in success colour. On save failure: floating danger snackbar "Couldn't save to this device. The entry is kept in memory until Retry succeeds." with action "Retry", 8 s (`transaction_form.dart:129`).
- `barrierDismissible` is true except for voice prefill.

### 1.9 Voice add flow (`widgets/voice_recording_sheet.dart`, `voice_expense_service.dart`)

- Entry points: mic FAB, quick action `action_voice_add`, deep link `budgetapp://voice-add`. Guarded against re-entry (`_voiceFlowActive`).
- Sheet states: recording (eyebrow "LISTENING", live level animation 1400 ms loop, mm:ss countdown from 30 s max, stop to submit), processing ("THINKING" / "Making sense of it..."), error (message; buttons "Cancel" and "Try again"). Errors: mic permission ("Microphone access is off. Enable it in Settings > Budgie."), no speech ("Didn't catch anything — try again"), transcribe or parse failures ("Something went wrong. Try again.").
- On success it opens the transaction form prefilled (`prefill`, non-dismissible by tapping outside).
- This is the only network feature: it uploads audio to OpenAI (`gpt-4o-mini-transcribe`) and parses with a chat model using `OPEN_AI_API_KEY` from the bundled `.env` (`voice_expense_service.dart:24-31,40-58`). Contradicts the "offline-first" note in AGENTS.md; decide whether it is in the native MVP. A dated spoken expense is bounded to 90 days back (`maxSpokenDateLookbackDays`).

### 1.10 Transactions list (`transaction_page.dart`, legacy style)

- Reached: Home "SEE ALL". Plain `AppBar` "Transactions" (centred), `MonthSelector` chip strip (available months, newest first), summary `GlowCard` (Income, Expenses, divider, "Net Cash Flow"), sticky date headers (pinned 48pt, mono pill `Sep 28, 2026`) with `ModernTransactionListItem` rows (48pt solid colour tile, description, "Category • Mon d", amount 22/bold in green/red, recurrence glyph). Screenshot 16.
- Row interactions: tap = edit dialog; swipe left (endToStart) = reveals red delete background, Cupertino confirm "Delete Transaction" -> deletes -> snackbar "Transaction deleted" (danger colour, floating). Haptics: medium on threshold, heavy on delete.
- Empty (no data at all): `EmptyState.noData` "No Transactions Yet" / "Start tracking your finances by adding your first transaction" with button "Add Transaction"; month empty: "No Transactions" / "No transactions for this month".
- Uses its own local `selectedMonth` (defaults to the newest month with data).

### 1.11 Categories settings (`category_settings_page.dart`) - plain Material AppBar "Categories"

- "+" action in AppBar ("Add category"), and a floating add button. `SegmentedPillControl` Expenses / Income, "Show archived" switch. List rows show icon, name, badges "Built in" / "Archived", overflow menu (Edit, Move up, Move down, Archive / Restore).
- Editor dialog: title "New category" / "Edit category"; Name (error "Enter a category name"); Icon grid from `categoryIconRegistry` (18 icons, `common.dart:5-24`); Color choices from 8 tokens: accent, green, blue, orange, red, purple, pink, cyan (`category_settings_page.dart:381-390,392-411`); Cancel / "Add"|"Save".
- Provider rules (`category_provider.dart:118-130,178-190,198-208`): name required and unique per type (case-insensitive check `_containsName`): "A category with this name already exists"; archiving fails with "At least one category must remain active" for the last active category of a type. Errors show in a snackbar (`_friendlyError`, 334).
- Built-in defaults: expense General, Eating Out, Groceries, Housing, Transportation, Travel, Clothing, Gift, Health, Entertainment, Pets, Family, Loan Payment; income Salary, Investment, Gift, Other (`common.dart:27-49`). The global maps `expenseCategories` and `incomeCategories` are mutated at runtime by `CategoryProvider`; many screens still read those maps directly.

### 1.12 Tags and rules (`categorization_settings_page.dart`) - plain Material AppBar "Tags & rules"

- Sections "Tags" and "Merchant rules", each with an add control and an empty card ("Add tags to group transactions across categories." / "Rules can automatically choose a category and tags from a merchant name.").
- "New tag" dialog (hint "Travel planning"); errors "Tag name is required" and "A tag with this name already exists" (`categorization_provider.dart:59-62`) via snackbar.
- "New merchant rule" dialog: "Merchant text" (hint "Whole Foods", required), "Type" dropdown (income/expense), "Match" dropdown (contains, startsWith, exact; `categorization_rule.dart:5,85-87`), "Category" dropdown, tag choices. Rule rows: summary text and a delete icon ("Delete rule").

### 1.13 Recurring transactions (`recurring_transactions_page.dart`, `recurring_transaction_form.dart`) - legacy

- Reached: More > Recurring transactions (page uses `ModernAppBar` with the indigo-violet gradient, screenshot 15). AppBar refresh button "Generate Due Transactions" runs the generator manually (snackbar "Due transactions generated and next occurrences updated").
- There is no add button on this page. Templates are created only from the transaction form link "Make this recurring".
- Card per template: category tile, description + recurrence glyph, amount, hairline, "Pattern" (Weekly / Bi-weekly / Monthly), "Next Occurrence" (`MMM dd, yyyy`), "Edit" and "Delete" buttons. Delete confirmation dialog "Delete Recurring Transaction?" with body "This will stop generating future transactions for "<desc>". Previously generated transactions will not be affected." and snackbar "Recurring transaction deleted".
- Empty state: 120pt gradient circle with repeat icon, "No Recurring Transactions", "Create recurring transactions to automatically\ngenerate expenses and income on a schedule".
- Form dialog: Amount (same three messages), Description ("Description is required" - required here, unlike the normal form), Category `CupertinoPicker`, Pattern picker (Weekly, Bi-weekly, Monthly), day-of-month picker 1-31 for monthly (clamped to month length), Start date (date picker, +/-365 days; error "Start date cannot be more than 1 year in the past"), a preview "Next 3 Occurrences" (`EEEE, MMM dd, yyyy`), Cancel / "Save"|"Update".
- Generation: `TransactionGenerator` runs on launch and materialises missed occurrences up to 90 days back (AGENTS.md, `main.dart` `_initializeApp`).

### 1.14 Other sheets and alerts (inventory)

| Item | Where | Type |
|---|---|---|
| Month wheel (inline) | Home | inline picker |
| Select month | Spend, Flow detail | bottom sheet |
| Chart range | Flow | bottom sheet |
| Month details | Flow bar tap | bottom sheet |
| Select category | Flow detail filters | bottom sheet |
| Base currency / Number format / Lock delay | Settings | bottom choice sheet (`_showChoiceSheet`, `settings_page.dart:985-1030`) |
| Account actions | Worth row long-press | bottom sheet |
| Goal actions | Goals more button | bottom sheet |
| Edit budgets / Add a budget / Quick expense category | Home | bottom sheets |
| Delete confirmations | transactions, accounts, snapshots, goals, recurring, rules | Cupertino alert or `AlertDialog` |
| Import CSV confirmation, Replace-all-data confirmation | Settings | dialog |
| Snackbars | save failure, "Added to <Month>", deleted, imports, goals | floating, radius 12 |

---

## 2. Design tokens

Sources: `theme/app_colors.dart`, `theme/app_typography.dart`, `theme/app_animations.dart`, `design_system.dart`. Both colour sets exist because Light/Dark/Auto is user-selectable (`ThemeProvider`, default system). The redesign is dark-first; light values were added "so Light/Auto stay usable" (`app_colors.dart:27`).

### 2.1 Colour tokens (hex, ARGB in Flutter `0xAARRGGBB`; alpha shown as %)

Core surfaces and text

| Token | Light | Dark | Source |
|---|---|---|---|
| background (scaffold, canvas) | `#F9FAFB` | `#0A0A12` | `app_colors.dart:113,118` |
| card / dialog / sheet fill | `#FFFFFF` | `#13131F` | `:114,119` |
| surface (inputs fill in dark) | `#FFFFFF` | `#15151F` | `:112,117` |
| chip surface (pills, month pill, date tile, gauge track) | `#F1F1F7` | `#15151F` | `:33,25` |
| card border | ink `#101020` @ 8% (`0x14101020`) | white @ 7% (`0x12FFFFFF`) | `:31,22` |
| hairline (list dividers) | `#101020` @ 6% (`0x10101020`) | white @ 6% (`0x0FFFFFFF`) | `:32,23` |
| generic border / divider | `#E5E7EB` | white @ 7% | `:134,135` |
| track (progress inset) | `#E9E9F1` | `#1B1B2C` | `:28,17` |
| track secondary (comparison bars) | `#D9D9E6` | `#2A2A3E` | `:29,18` |
| donut remainder / tail | `#C9C9DA` | `#3A3A52` | `:30,19` |
| text primary | `#111827` | `#F2F2FA` | `:122,128` |
| text secondary | `#6B7280` | `#9A9AB5` | `:123,129` |
| text tertiary | `#9CA3AF` | `#5C5C78` | `:124,130` |
| text on primary / on accent | `#FFFFFF` | `#0A0A12` | `:125,131,14` |
| dock inactive icon | `#6B7280` | `#8A8AA8` | `floating_dock.dart:243-244` |
| dock background | white @ 88% | `#13131F` @ 88% (`0xE013131F`) | `:21`, `floating_dock.dart:155` |
| dock border | black @ 8% | white @ 10% | `floating_dock.dart:158-160` |

Accent and semantic

| Token | Light | Dark |
|---|---|---|
| accent (`getAccent`) | `#6366F1` (`primary`) | `#818CF8` (`accent`) |
| primary dark / light | `#4F46E5` / `#818CF8` | same |
| income (`getIncome`) | `#10B981` | `#34D399` |
| expense / danger (`getDanger`) | `#EF4444` | `#FB7185` (`danger`) |
| neutral / info | `#3B82F6` | `#60A5FA` |
| success | `#10B981` | `#34D399` |
| warning | `#F59E0B` | `#FBBF24` |
| error | `#EF4444` | `#FB7185` |
| pink | `#F0ABFC` (both) | |
| cyan (category token only) | `#22D3EE` (`category_settings_page.dart:406`) | |
| onboarding/opening gradient | dark only `#0A0A12 -> #0F0F18` (`main.dart` `_OpeningScreen`) | |
| income split-bar gradient | `#2AB98A -> #34D399` (`glow_progress_bar.dart`) | |
| gauge thumb | white with 2pt accent@60% border | `#F2F2FA` |

Gradients (135 degrees, topLeft -> bottomRight): primary light `#6366F1 -> #8B5CF6`, dark `#4F46E5 -> #7C3AED`; income light `#10B981 -> #34D399`, dark `#059669 -> #10B981`; expense light `#EF4444 -> #F87171`, dark `#DC2626 -> #EF4444`; accent(amber) light `#F59E0B -> #F97316`, dark `#FBBF24 -> #FB923C`; neutral light `#3B82F6 -> #60A5FA`, dark `#2563EB -> #3B82F6` (`app_colors.dart:138-197`). Used by `AppButton.primary` (primary gradient), add-expense button (expense gradient), add-income button (income gradient), recurring `ModernAppBar`.

Category / chart palette (14 colours, `app_colors.dart:200-241`)

| # | Light | Dark |
|---|---|---|
| 1 | `#6366F1` | `#818CF8` |
| 2 | `#8B5CF6` | `#A78BFA` |
| 3 | `#10B981` | `#34D399` |
| 4 | `#34D399` | `#6EE7B7` |
| 5 | `#EF4444` | `#F87171` |
| 6 | `#F87171` | `#FCA5A5` |
| 7 | `#F59E0B` | `#FBBF24` |
| 8 | `#FBBF24` | `#FCD34D` |
| 9 | `#3B82F6` | `#60A5FA` |
| 10 | `#60A5FA` | `#93C5FD` |
| 11 | `#EC4899` | `#F472B6` |
| 12 | `#F472B6` | `#F9A8D4` |
| 13 | `#14B8A6` | `#2DD4BF` |
| 14 | `#2DD4BF` | `#5EEAD4` |

Note: the Spend donut does not use this 14-colour list for its first six slices; it uses accent, income, danger, warning, info, pink in rank order (`category_page.dart:106-115`). The 14-colour list is a fallback for lower ranks and for `CategoryTransactionsPage`. Custom category colour tokens are the 8 named tokens above.

Glow helpers (`app_colors.dart:56-85`): `glow(color, blur=24, alpha=0.55)` = `BoxShadow(color@alpha, blur)` no offset in dark; in light it becomes `color@25%, blur*0.6, offset (0,4)`. `textGlow(color, blur=48, alpha=0.45)` = text shadow; in light alpha x 0.4.

Flutter `ThemeData` set at the app level (`main.dart:63-146`): Material3 `ColorScheme.fromSeed(seed #6366F1)` overridden with primary accent, surface card, error; scaffold, canvas, card, dialog and bottom-sheet backgrounds as in the table above; `surfaceTintColor` transparent everywhere; `AppBarTheme` transparent, 0 elevation; input fill = background (light) / surface (dark); page transitions Cupertino on iOS (slide from right, iOS back swipe works on pushed pages).

### 2.2 Typography

Fonts (bundled TTFs in `assets/fonts`, registered in `pubspec.yaml:90-112`):
- Gabarito: Regular 400, Medium 500, SemiBold 600, Bold 700, ExtraBold 800, Black 900. Default app font (`ThemeData.fontFamily`).
- Spline Sans Mono: Regular 400, Medium 500, SemiBold 600. Used for eyebrows, mono labels, chart axes and dates on the Transactions list.
Sizes below are logical points. Line height in Flutter is a multiplier of font size. Tabular figures are on for money styles (`fontFeatures: tabularFigures`).

Redesign styles (`app_typography.dart:14-216`)

| Style | Family | Size | Weight | Letter spacing | Height | Notes |
|---|---|---|---|---|---|---|
| hero | Gabarito | 58 | 800 | -2 | 1.0 | tabular; Home cash flow |
| heroDecimals | Gabarito | 32 | 700 | 0 | 1.0 | tabular |
| heroMedium | Gabarito | 48 | 800 | -1.8 | 1.0 | tabular; Net worth |
| heroSmall | Gabarito | 34 | 800 | -1 | 1.1 | tabular; donut centre |
| pageTitle | Gabarito | 26 | 800 | -0.6 | 1.2 | header titles |
| sectionHeader | Gabarito | 20 | 700 | -0.3 | 1.2 | |
| cardTitle | Gabarito | 17 | 700 | 0 | 1.25 | |
| goalTitle | Gabarito | 18 | 700 | -0.3 | 1.25 | |
| rowTitle | Gabarito | 15 | 600 | 0 | 1.25 | |
| rowSubtitle | Gabarito | 12 | 400 | 0 | 1.25 | secondary colour |
| amount | Gabarito | 16 | 700 | 0 | 1.2 | tabular |
| amountSmall | Gabarito | 15 | 700 | 0 | 1.2 | tabular |
| chipAmount | Gabarito | 24 | 700 | -0.5 | 1.15 | tabular |
| metricAmount | Gabarito | 24 | 800 | -0.5 | 1.15 | tabular |
| badge | Gabarito | 12 | 700 | 0 | 1.2 | |
| badgeSmall | Gabarito | 11 | 700 | 0 | 1.2 | |
| eyebrow | Spline Sans Mono | 11 | 600 | 2.4 | 1.2 | UPPERCASE |
| eyebrowTight | Spline Sans Mono | 11 | 600 | 2.0 | 1.2 | |
| monoLabel | Spline Sans Mono | 11 | 500 | 1.0 | 1.2 | |
| monoLink | Spline Sans Mono | 11 | 600 | 1.5 | 1.2 | EDIT / SEE ALL |
| monoMetricLabel | Spline Sans Mono | 10 | 600 | 1.6 | 1.2 | |
| monoAxis | Spline Sans Mono | 10 | 500 | 0 | 1.2 | |
| monoMonth | Spline Sans Mono | 11 | 500 | 0 | 1.2 | |

Legacy styles (no explicit font family, so they inherit Gabarito from the theme) (`app_typography.dart:218-366`)

| Style | Size | Weight | LS | H |
|---|---|---|---|---|
| displayLarge | 34 | bold | -0.5 | 1.2 |
| displayMedium | 28 | bold | -0.3 | 1.2 |
| displaySmall | 24 | bold | -0.2 | 1.3 |
| headingLarge | 28 | bold | -0.3 | 1.2 |
| headingMedium | 22 | 600 | -0.2 | 1.3 |
| headingSmall | 20 | 600 | -0.1 | 1.3 |
| bodyLarge | 17 | 400 | -0.4 | 1.5 |
| bodyMedium | 15 | 400 | -0.2 | 1.5 |
| bodySmall | 13 | 400 | -0.1 | 1.4 |
| labelLarge / buttonLarge | 17 | 600 | -0.4 | 1.3 / 1.2 |
| labelMedium / buttonMedium | 15 | 600 | -0.2 | 1.3 / 1.2 |
| labelSmall / buttonSmall | 13 | 600 | -0.1 | 1.3 / 1.2 |
| caption | 13 | 400 | -0.1 | 1.4 |
| captionSmall | 11 | 400 | 0 | 1.3 |
| numericLarge | 34 | bold | -0.5 | 1.2 (tabular) |
| numericMedium | 22 | 600 | -0.2 | 1.3 (tabular) |
| numericSmall | 17 | 600 | -0.4 | 1.3 (tabular) |

Accessibility: text scaling is honoured everywhere except the dock label (clamped to 1.2). Reduce Motion is honoured in the hero digit roll, month panel, GlowProgressBar and GlowFab burst.

### 2.3 Spacing, sizes, radii, borders, opacity (`design_system.dart:29-151`)

| Group | Tokens |
|---|---|
| Spacing | XXS 2, XS 4, S 8, M 16, L 24, XL 32, XXL 48, XXXL 64 |
| Radius | XS 4, S 8, M 12, L 16, XL 20, XXL 24, round 999. Redesign literals: GlowCard 26 (22 for stat chips), IconTile 14 (16 when size >= 44), sheets 28 top (24 on Flow sheets), dock/pills 999, date tile 14, logo mark 12, month chip radius 12 header buttons 12. |
| Icon sizes | XS 16, S 20, M 24, L 32, XL 48, XXL 64 |
| Touch targets | min/S 44, M 48, L 56 |
| Border width | thin 1, medium 1.5, thick 2 |
| Opacity | disabled 0.38, muted 0.60, subtle 0.87 |
| Breakpoints | phone < 600, tablet < 900, desktop >= 900 (iOS phone layout only needs the phone values); max content width 600 |
| Layout literals | page horizontal padding 20 (24 for hero blocks); header row padding (20,12,20,0); section gap 28; card gap 12-16; list-card outer padding 8 with 1px hairline dividers inset 12 |
| Sizes | logo 36, IconTile 40 (44 on Net Worth), FAB 54 (mic 44), progress ring 84 (thickness 9), donut 240 (thickness 30), gauge 14, budget bar 8, category bar 6, comparison bars 12-16, PillButton 52 (44 filled compact) |

### 2.4 Shadows and glows

| Name | Value |
|---|---|
| shadowXS / S / M / L / XL (`design_system.dart:64-102`) | black @ 5% blur 2 dy1; 8% blur 4 dy2; 10% blur 8 dy4; 12% blur 16 dy8; 15% blur 24 dy12 |
| elevation levels | 0, 1, 2, 4, 8, 16 mapped to XS..XL (`getElevationShadow`) |
| ElevatedCard (legacy) | Material elevation 2, shadowColor black@10% |
| Dock | black 60% dark / 15% light, blur 40, offset (0,16) |
| GlowFab | accent glow (blur 32 + flare, alpha 0.55) plus black@50% blur 28 dy12 |
| Progress fill | accent-colour glow blur 12 alpha 0.6 (0.8 for the thumb) |
| Stat dot | glow blur 10 alpha 0.8 |
| Filled PillButton | colour glow blur 20 alpha 0.45 |
| Split bar | blur 14 alpha 0.5 |
| Progress ring | blur 28, alpha 0.4-0.45 |
| Hero number | text glow blur 48, alpha 0.45 (light: x0.4) |
Dark mode glows are true halos. Light mode swaps to a soft ambient shadow (`color@25%, blur x0.6, dy4`).

### 2.5 Animation and motion

| Token | Value | Source |
|---|---|---|
| durations | instant 0, fast 150, normal 300, slow 500, verySlow 800 ms | `app_animations.dart:7-11` |
| curves | easeIn, easeOut, easeInOut, easeInOutCubic, elasticOut (spring), bounceOut, decelerate, fastOutSlowIn | `:14-21` |
| shimmer | 1500 ms easeInOut | `:105` |
| list stagger | delay 50 ms, duration 300 ms | `:109-110` |
| button press | 100 ms, scale 0.95 | `:113-114` |
| chart | 1200 ms easeInOutCubic (AppAnimations); redesign GlowProgressBar uses 800 ms easeInOutCubic, donut 500 ms | `:117-118`, `glow_progress_bar.dart`, `category_donut_chart.dart:83` |
| tab page change | 300 ms easeInOut (jump when dragging) | `home_page.dart:77-81` |
| dock morph | 250 ms easeOut (100 while dragging) | `floating_dock.dart:250` |
| GlowCard press | scale 0.98, 120 ms easeOut | `glow_card.dart:64-69` |
| PillButton press | scale 0.96, 120 ms | `pill_chip.dart` |
| FAB | entry 300 ms easeOutBack; press 0.95; tap burst 500 ms (ping ring +70%, glow flare, icon pop 1.22) | `glow_fab.dart` |
| hero digit roll | 900 ms | `spending_page.dart`, `net_worth_page.dart` |
| month panel expand | 250 ms easeInOut | `spending_page.dart:1022` |
| segmented control | 200 ms easeOut | `pill_chip.dart` |
| opening screen | intro 1400 ms, dots 1200 ms, handoff 450 ms | `main.dart` |
| goal celebration | 1600 ms | `savings_goals_page.dart:66` |
| net worth chart long-press | 150 ms | `net_worth_page.dart:709` |
Haptics (`utils/micro_interactions.dart`): light on taps, medium on long-press/swipe threshold, heavy on delete, selection click on dock/segment/picker changes.

---

## 3. Reusable widgets (`lib/widgets/` plus `design_system.dart`)

| Widget | File | One line |
|---|---|---|
| `GlowCard` | glow_card.dart | Base card: fill `card`, radius 26 (22 for chips), 1px card border, padding 20, press scale 0.98, optional gradient/border/shadow/tap/long-press. |
| `GlowListCard` | glow_card.dart | GlowCard with padding 8 and 1px hairline dividers (inset 12) between children. |
| `IconTile` | glow_card.dart | Rounded-square icon container, colour @13% background, 40pt r14 (44pt r16), icon 20 weight 500. |
| `FloatingDock` / `DockItem` / `DockMetrics` | floating_dock.dart | The six-item blurred pill tab bar and the layout constants for dock, FAB and content padding. |
| `GlowFab` | glow_fab.dart | 54pt accent circle with glow, entry pop, press scale, tap burst, optional long-press. |
| `GlowProgressBar` | glow_progress_bar.dart | Pill progress bar with glowing fill, optional gradient, thumb, inset and track border; animates 800 ms. |
| `SplitGlowBar` | glow_progress_bar.dart | Two-segment assets vs liabilities bar with 3px gap. |
| `ProgressRing` | progress_ring.dart | Circular progress with glow and inner child; used for goals. |
| `PillChip` | pill_chip.dart | Small pill badge, tinted (colour@14%) or outlined (@40%), optional icon and tap. |
| `PillButton` | pill_chip.dart | 52pt (or 44pt filled) full-radius button, tinted outline or accent-filled with glow. |
| `SegmentedPillControl` | pill_chip.dart | Segmented pills: solid track with accent-filled segment (Settings) or mono transparent style (chart ranges). |
| `BudgieHeader` | budgie_header.dart | Page header row: title or 36pt logo, optional trailing pill, padding (20,12,20,0). |
| `MonthPill` | budgie_header.dart | Chip with label and expand_more, chip surface, 1px border. |
| `SectionHeader` | budgie_header.dart | Section title with optional mono accent link (EDIT / SEE ALL). |
| `BudgiePageScaffold` | budgie_page_scaffold.dart | Scaffold with body plus optional FAB pinned right 20 / above the dock. |
| `CategoryDonutChart` / `CategorySlice` | category_donut_chart.dart | 240pt animated donut with selectable slices, centre label, delta vs last month. |
| `MonthSelector` | month_selector.dart | Horizontally scrolling month chip strip (Transactions list and Net worth). |
| `EmptyState` (`noData` / `noResults` / `error`) | empty_state.dart | Legacy icon + title + message + optional action button. |
| `ModernTransactionListItem` | modern_transaction_list_item.dart | Legacy transaction row with swipe-to-delete and Cupertino confirm; 48pt solid tile. |
| `ModernTextField` | modern_text_field.dart | Legacy floating-label input: radius 12, border 1.5 (2 focused), primary focus colour, error colour and message row. |
| `ModernAppBar` / `ModernSliverAppBar` | modern_app_bar.dart | Legacy gradient AppBar (used only by Recurring page). |
| `RecurrenceIndicator` | recurrence_indicator.dart | Small custom-painted "repeat" glyph shown on recurring-generated rows. |
| `LocalInsightsSection` | local_insights_section.dart | Insight cards with snooze/dismiss and persisted state. |
| `UnsavedChangesBanner` | unsaved_changes_banner.dart | Red "not saved" strip with Retry. |
| `AppPrivacyGate` | app_privacy_gate.dart | App lock and app-switcher privacy cover. |
| `VoiceRecordingSheet` | voice_recording_sheet.dart | Recording / thinking / error bottom sheet (record -> transcribe -> parse -> prefilled form). |
| `LoadingShimmer` | loading_shimmer.dart | Skeleton loaders; unused. |
| `ElevatedCard`, `AppButton` (primary/secondary, S/M/L = 44/48/56pt, radius 12), `AnimatedMetricCard` | design_system.dart | Legacy card, button and metric card; `AppButton` still used by dialogs, forms and empty states. |

Icon sources: Material Symbols Rounded (`material_symbols_icons`, dock, headers, tiles) and `CupertinoIcons` for categories (`categoryIconRegistry`, 18 entries in `common.dart:5-24`). Both need an SF Symbols mapping table in Swift.

---

## 4. Screenshots

Captured on a new simulator "Budgie-UI-Research" (iPhone 17 Pro, iOS 27.0, UDID `28011DDB-E01D-4C1F-A08B-426503B36B74`), 1206x2622 px. Data is minimal on purpose: two fake transactions dated Sep 28 2026 (Paycheck +$3,200 Salary, Trader Joe's $42.50 General) and one $100 budget on General; no goals, accounts or recurring items. Light is the simulator default; dark was forced with `simctl ui appearance dark` (the app's theme is Auto).

Folder: `native/docs/research/screenshots/`

The table lists the retained research captures. Current Home and Settings
branding is shown in `design/branding/` and `native/Marketing/AppStore-4.0/`.

| File | Shows |
|---|---|
| `01_onboarding_1_light.png`, `02_...2_light.png`, `03_...3_light.png` | Onboarding pages 1-3 (light) |
| `05b_home_scrolled_light.png` | Home scrolled: budgets, recent activity, pill buttons |
| `06_worth_empty_light.png`, `06_worth_empty_dark.png` | Net worth empty state |
| `07_goals_empty_light.png`, `07_goals_empty_dark.png` | Goals empty state |
| `08_spend_empty_light.png`, `08_spend_data_light.png` | Categories tab (empty and with donut) |
| `09_flow_empty_light.png`, `09_flow_data_light.png`, `09_flow_data_dark.png` | Cash flow tab |
| `10b_more_scrolled_dark.png` | Settings lower part |
| `11_add_expense_form_light.png` | Add Expense dialog with numeric keyboard |
| `12_add_budget_picker_dark.png` | "Add a budget" category sheet |
| `14_safe_to_spend_sheet_light.png` | Safe-to-spend breakdown (shows the same-day exclusion quirk) |
| `15_recurring_empty_dark.png` | Recurring transactions empty page (legacy gradient app bar) |
| `16_transactions_dark.png` | Transactions list pushed from SEE ALL (legacy row style, dock still visible) |

Not captured: Worth and Goals with data and their dialogs, account history, category drill-in, donut with more than one slice, Flow detail with filters, insights cards, categories/tags settings, voice sheet, lock screen, error screen, month wheel expanded, quick-expense sheet, swipe-to-delete state. Reason: time budget; these are described from code only.

How the run was done (for reproducibility): `flutter run -d <udid>` was executed from a copy of `budget_app/` in the session scratchpad with a placeholder `.env` (the `.env` asset is gitignored and absent from the worktree, so a build from the repo directory would have needed a new file inside `budget_app/`). No file under `budget_app/` was changed; `git status` shows only `native/` as untracked. Interaction used `xcrun simctl io screenshot`, `simctl openurl budgetapp://add-income` (the "Open in Budgie?" system dialog was confirmed by tapping Open in the simulator), and simulator tap/swipe/text input. The simulator was shut down at the end and not deleted. The app is still installed on it.
