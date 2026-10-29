# MVP UI spec (Phase 4)

Views are thin: they read `AppModel` (`@Environment(AppModel.self)`) and call
its async methods. They never touch `FinancialStore`, JSON, preferences or
files. Money is shown with `model.moneyFormatter` (a port of the Flutter
formatter: same symbols, rounding and "Match device" = en_US), dates with
`DartDateTime` fields (never `Date` arithmetic for stored values).

Visual language: native SwiftUI (List/Form, NavigationStack, sheets) with
the owner-approved redesign of 2026-10-03 (PARITY_GAPS "Visual redesign"):
one layout in both modes, flat cards (no glows), "Paper" colours in light
mode and "Midnight" colours in dark mode. Tokens live in
`Budgie/DesignSystem/Tokens/Colors.swift`:

| Token | Light (Paper) | Dark (Midnight) |
|---|---|---|
| background | `#F3EFE6` | `#07090D` |
| card | `#FBF9F4` | `#11151C` |
| textPrimary | `#1A1A17` | `#EEF1F5` |
| textSecondary | `#5C584F` | `#9AA3B2` |
| accent (links, selection, add button) | `#1D6646` | `#B3ADFF` |
| income (and money kept) | `#1D6646` | `#5EE6B0` |
| spent (charts) | `#A63D24` | `#FF8B7B` |
| danger | `#A63D24` | `#FF8B7B` |
| warning | `#7E5300` | `#FFC861` |
| featureFill (Safe to spend, Goals summary) | `#1A1A17` | `#10231F` |
| selectionFill (month chips, segments) | `#1A1A17` | lilac 16% |
| fieldFill (text fields, form rows) | `#F3EFE6` | `#0B0E14` |
| switchOn (Toggle tint) | `#1D6646` | `#5EE6B0` |
| scrim (behind dialogs) | ink 38% | black 55% |

Every text token reaches WCAG AA (4.5:1) on every surface it sits on
(`ColorContrastTests`).

Monospaced digits (`.monospacedDigit()`) for amounts. Respect Dynamic Type
and VoiceOver labels on every control. No third-party packages.

Text styles (`TextSpec` + `.textStyle`, `DesignSystem/Typography`) reproduce
Flutter's line box as the app renders it: every line is
`round(size * height)` points (SkParagraph rounds each line), and the
leading over the faces' natural 1.2 x size is split evenly above and below
(Material's `Typography` sets `leadingDistribution: even`, which the
`AppTypography` styles inherit), so one line of `bodyMedium` (15 / 1.5) is
23pt and a breakdown row 35pt. The modifier also removes SwiftUI's
round-up of a Text's height to the pixel grid.

## Shell

Native `TabView` (Liquid Glass on iOS 26+, accent tint) with five tabs, each
in its own `NavigationStack`: Home (`dollarsign.circle`), Worth
(`chart.line.uptrend.xyaxis`), Goals (`flag`), Spend (`chart.pie`), Flow
(`chart.bar`). Tab roots hide the navigation bar and draw a `BudgieHeader`;
pushed pages keep the system bar and back gesture. Settings is pushed from
the gear in the Home header; Recurring is a row under Settings > Data; the
month's transaction list (Transactions) is pushed from Home's "SEE ALL".
Goals is `GoalsView` (see "Goals" below).

Pages are pushed with a `NavigationLink` or `navigationDestination(item:)`,
never `navigationDestination(isPresented:)`. With `isPresented` the stack
re-installs the pushed page (a fresh root view in its hosting controller)
whenever the tab root's preferences are re-derived, and an accessibility
client re-derives them on every read of the screen. Each re-install
updates the navigation bar, which the client reads again, so under
XCUITest the first SEE ALL push re-rendered its page about 200 times a
second for up to a minute (budgie-uia.55).

An `UnsavedChangesBanner` (danger strip, white content, "Some changes are
not saved to this device yet." + "Retry" calling `model.retrySaves()`) sits
above the tabs whenever `model.hasUnsavedChanges`; it never hides data.
`model.pendingAdd` (from quick actions, widget, deep links) opens the add
sheet preset to income or expense, or (`.voice`) the voice flow, over the
current tab, once the data is
ready, App Lock is passed and onboarding is done (`takePendingAdd()`); until
then it stays queued. As Flutter pushes the form on the root navigator, it
opens on top of whatever is presented (a Home sheet, an edit form or its
date picker, a Goals or Worth dialog, an alert) and leaves that untouched
underneath; a route arriving while a form is open stacks another, except a
`.voice` route while a voice flow is up, which is taken and dropped (one
voice flow at a time, as Flutter's `_voiceFlowActive`; the presenter tracks
the latest voice host weakly, so a refused or finished one leaves nothing
behind). One
presenter, `AddFormPresenter`, handles every route: from the key window's
topmost presented controller it presents, unanimated, a transparent
`.overFullScreen` host whose SwiftUI root shows the form as a normal
`.sheet` and dismisses itself when the sheet goes. A voice route shows the
recording sheet in that one sheet, whose content is then replaced in place
by the prefilled form (never a second presentation, so the host is not torn
down between the two). A route is taken only
when there is a controller to present from; while one is mid-transition it
stays queued and is retried every 150ms, so no route is lost or blocks the
next. The screens beneath are hidden from VoiceOver while the host is up.
Toasts float above the tab bar (`toastHost`), so a toast posted by a form
opened over a sheet is under that sheet.

Dialogs (`budgieDialog`, centred or bottom) float over a dimmed scrim in a
full-screen cover. A scrim tap closes the dialog unless its content sets
`budgieDialogDismissDisabled` (while a write is awaited) or the keyboard is
showing, hiding or changing height: the keyboard moves the card, so such a
tap was aimed at the card (e.g. its Add button) and is ignored.

## Home (spec full-app/02; Flutter `spending_page.dart`)

- Header: logo, month pill (`DartDateFormat.yMMMM(model.selectedMonth)`),
  Settings gear. The pill opens a panel with a year stepper (D13) and a
  five-row month drum always bound to `model.selectedMonth`.
- Hero: "CASH FLOW", `format(abs(income - expenses))` with a forward-rolling
  odometer (900 ms; none under Reduce Motion; plain "••••" when balances
  are hidden), "$X in · $Y out", SAVED / SHORT THIS MONTH / BREAKING EVEN.
- Spend gauge (spent / income), Income and Expenses chips with deltas vs
  the previous month (`HomeSummary`), the safe-to-spend card and its
  breakdown sheet (`SafeToSpend.calculate(... month:, asOf: model.now,
  wallClock: model.now ...)`).
- Budgets (`model.budgetOverview(forMonth:)`): rows by spent desc with
  status colours, EDIT and "Add a budget" pickers, and the limit sheet
  (`setBudgetLimit` / `removeBudgetLimit`, awaited before dismissing).
- Recent activity: the 3 newest rows across all months (`ledger.recent`),
  "See all" pushes Transactions. A row opens its edit form (`HomeSheet.edit`),
  as SEE ALL's rows do, with a light haptic.
- The FAB opens the form (expense, with its Expense / Income switch); a
  FAB long-press opens
  the quick-expense category sheet. Above the FAB, centred on it and 12pt
  clear of it, a 44pt mic FAB (`GlowFab`, `mic.fill`, VoiceOver "Add by
  voice", identifier `home.voice`) sets `model.pendingAdd = .voice`, so it
  takes the same path, gate and one-voice-flow guard as the quick action,
  link and widget. The scroll content clears both buttons (130pt: 20 + 54 +
  12 + 44).
- The settings gear keeps its 36pt glyph slot but its tap area is 44 x 44pt
  (the label's frame and content shape, centred on the glyph).
- UI-test identifiers: `home.monthPill`, `home.monthPanel.prevYear`,
  `home.monthPanel.nextYear`, `home.monthPanel.year` (the year stepper),
  `home.monthWheel` (the adjustable "Month" element, value = month name),
  `home.safeToSpend` (the card), `home.budgets.row.<category>` (a budget row),
  `home.budgets.add` (the card's "Add a budget" row),
  `budgets.picker.<category>` (a tile in the Edit / Add pickers),
  `budgets.limit.field`, `budgets.limit.save`, `budgets.limit.remove` (the
  limit sheet).

## Transaction form (sheet, D5)

Card-styled sheet. Fields: type toggle (Expense/Income), Amount (validated
on Add/Update: "Amount is required" / "Please enter a valid number" /
"Amount must be greater than 0"; Dart `double.tryParse` forms plus the
locale decimal separator; non-finite rejected), Description (trimmed;
empty saves "Transaction"), Category, Date, Tags (when any exist). Date semantics match the Flutter form: a new transaction's date is
`model.now` (with time) unless the user picks a day, stored as
`calendar.date(y, m, d)`; editing keeps the stored date unless a new one is
picked. Categorisation rules apply on every Amount/Description edit
(`model.suggestion`). Add/Update await the write; a failure shows the
Retry toast, an add outside the selected month shows "Added to <Month>".
Edit mode offers Delete (confirm). "Make this recurring" turns the sheet
into the recurring form.

Prefill mode (`.prefill(VoiceDraft)`, the confirmation after a voice entry;
Flutter's `prefill`): an add seeded from the draft. Type, description and
category come from the draft; Amount is `toStringAsFixed(2)` only when the
draft's amount is above zero (a zero, negative or `-0.0` amount leaves the
field empty, so Add says "Amount is required"); the date is the draft's
exact value, time of day included, saved as is unless the user picks a day
(then midnight of that day). A draft category that is not in the active
picker list is kept as an extra menu row and saved, as Flutter keeps and
saves a prefill category. The categorisation rules run once as the form
opens, on the draft's raw amount: the first matching rule whose category is
active for the type sets the category and replaces the tags (duplicates
collapse); a later type switch drops those tags, and switching back to the
draft's type restores the draft's category (as an edit restores its
record's). The title stays "Add Expense" / "Add Income", the type toggle
stays, "Make this recurring" is hidden, and the sheet cannot be swiped away
(Flutter: `barrierDismissible: false`); Cancel and Add still close it.

Layout (redesign, REDESIGN_PLAN 4.1). Everything through "Make this
recurring" fits above the decimal pad on a 874pt-tall phone (iPhone 17
Pro) at the default text size, without scrolling; shorter phones and large
text scroll, with a 44pt fade at the bottom of the scroll area while more
is below. Top to bottom: grab handle; title row (`FormTitleRow`: the title
22 ExtraBold, the 176 x 32 Expense / Income `SegmentedPills` on the right,
stacked under the title when both do not fit, through `RowOrColumn` so the
audit and VoiceOver follow them across sizes); Amount (`BudgieField`
`.amount`: 64pt, "Amount" inside at the top left, the currency symbol and
the 36pt figure right-aligned, autofocused); Description (`.inline`, 46pt);
Category (`CategoryMenuRow`: a `FormRow` whose `Menu` holds an inline
`Picker` over the same categories the wheel had, in the same order, so the
menu checks the selection; one button "Category", value the name,
`form.category`); Date (`DateTile`, opens `DayPickerSheet`); Tags
(`FormRow` with "Optional", 34pt chips: selected accent 13% with bold
accent text, unselected outlined); Delete Transaction (edit only). The
footer is pinned above the keyboard: a hairline, Cancel (outlined) and
Add / Update (50pt capsules, `expenseFixed` / `incomeFixed` with a white
label, spinner while saving), then "Make this recurring". The recurring
form uses the same title row, Amount, Description and Category row, and
keeps its pattern and day wheels.

## Sheets, dialogs and empty states (redesign)

- Sheets: `.budgieSheetChrome()` (card fill, 1pt top border, radius 30, a
  38 x 5 handle in `hairline`); title in `TextSpec.sheetTitle` (24
  ExtraBold) with an optional 14pt secondary blurb; content in cards
  (list rows with hairlines) or the feature card (`.featureCard()`); a
  full-width filled pill (52pt) for the primary action, an outlined pill
  for the secondary. Safe to spend shows its total on the feature card
  above the six breakdown rows (mono values: income in `income`, zeros in
  `textSecondary`, expenses in `textPrimary`).
- Dialogs: `budgieDialog` cards over the `scrim` token, one plain drop
  shadow for every dialog (the glow API is gone); title in `sheetTitle`;
  fields on `fieldFill`; Cancel outlined in `textPrimary`, the primary
  filled.
- Empty states: `EmptyStateView`, a card with a 1.5pt dashed border
  (`textTertiary` 60%), radius 22, padding 36 / 24: a 72pt tile (accent
  12%, `danger` for `.error`) with a 32pt symbol, the title 21 ExtraBold,
  the message 15 secondary (max 280 wide), an optional 48pt filled pill
  with a plus (`actionIdentifier` names it). Home's Recent activity uses a
  compact version (48pt tile, the message only). Flow's empty chart
  messages stay inline in their cards.

## Home screen widgets (BudgetWidgets)

The extension cannot use `BudgieColor`: a private palette in
`BudgetWidgets.swift` repeats the token values and follows the widget's
colour scheme; the container background is `card` (`#FBF9F4` /
`#11151C`). Quick actions (small): the logo (18pt) and the month's cash
flow in whole units (system monospaced 13 SemiBold; `income`, `danger`
when negative, bullets when balances are hidden) over two equal buttons
(radius 14, `incomeFixed` / `expenseFixed`, white 14 Bold "Income" /
"Expense"), linking to `budgetapp://add-income` / `add-expense`. Voice add
(small): a 52pt accent circle with the mic in `onAccent`, the same cash
flow text top-trailing (omitted when none is stored), "Speak a
transaction" and "Budgie". Kinds, families, timelines and App Group keys
are unchanged. The extension does not bundle Gabarito or Spline Sans Mono,
so it uses the system fonts.

## Transactions (SEE ALL; Flutter `transaction_page.dart`)

Month chip strip (months with data, newest first; page-local selection),
monthly summary card, rows of the selected month grouped under pinned
`yMMMd` day headers, each day one card of rows like Home's Recent activity
(the category's tile, the amount signed: + income in `income`, - expenses
in `textPrimary`). Tap to edit (D7), swipe left to delete with a
"Delete Transaction" confirmation. Reads `model.ledger` only.

## Spend (spec full-app/04 section 1.1; Flutter `category_page.dart`)

`SpendView` (`Views/Spend/`), titled "Categories". Its month is local to the
tab (never `model.selectedMonth`): the newest month with any transaction,
re-resolved with `SpendMonth.resolve` on every ledger change; a month that
loses its last row falls back to the newest and clears the slice and the
expanded tail. `CategoryBreakdown.build` runs once per render from the
ledger's month summaries (no transaction scan).

- Header: `BudgieHeader` with a `MonthPill` (`MMMM`, hidden with no
  months). The pill opens `SpendMonthSheet`: card fill, 26pt top corners
  with the border along the top only, 40x4 grabber, "Select month", one
  56pt row per month with data (`yMMMM`, newest first, the list capped at
  320pt), the selected row accent with a check. Picking closes the sheet
  and clears the slice and tail. Haptics: light (pill), selection (open),
  selection (pick).
- Empty states: "No Expenses Yet" (no months) and "No Expenses" (the
  month's expense total is 0; the pill stays), `chart.pie`.
- Donut (`DonutChart`, 240pt, D16 `Canvas` from `DonutGeometry`): the
  accent glow is a filled blurred circle behind the ring, so it tints the
  band inside it and the gaps; the centre disc is the page background.
  The ring sweeps in over 500 ms (Flutter `easeOut`) on first appearance
  and on a month change only (the ring is keyed by month), instant under
  Reduce Motion. The whole square takes taps; `DonutGeometry.tap` selects,
  deselects or ignores, and the selection haptic plays only on a change.
  Centre: "SPENT", whole-unit total and the delta pill, or the selected
  slice's name, value and percent. VoiceOver: one adjustable element,
  "Spending by category", valued "Spent $X, up 12% vs August" or
  "<name>, <amount>, <percent>"; swipe up/down selects slices.
- List (`GlowListCard`): up to six ranked rows (tile in the rank colour
  with the active category's icon by exact name, else the grid; name;
  `Record.subtitle(money:)`; whole-unit amount; a 6pt bar against the
  largest category), the selected slice's row tinted (200 ms), then
  "N more categories" (expands in place) or "Show less". Row taps play a
  light impact; a category row pushes `CategoryTransactionsView`.
- Drill-in (`CategoryTransactionsView`): system back bar with the
  category as title, the tinted "TOTAL SPENT" card (two decimals, text
  glow, `MMMM yyyy` and count pills, 56pt tile), "TRANSACTIONS", then the
  month's expense rows of that exact category name, newest first. Rows tap
  to edit and swipe to delete (awaited, then "Transaction deleted" or the
  save-failed toast). Colour and icon follow the category's current rank;
  with no rows left it shows "No Transactions" under the card.
- State (month, slice, tail, pushed drill-in) survives tab switches.
- Accessibility identifiers: `spend.monthPill`, `spend.monthSheet`,
  `spend.month.<yyyy-MM>`, `spend.donut`, `spend.row.<rank>`,
  `spend.tail`, `spend.showLess`, `spend.empty`, `spend.drillIn.summary`,
  `spend.drillIn.row`.
## Flow (spec full-app/04; Flutter `history_page.dart` `HistoryPage`)

`Views/Flow/`. Every figure comes from `model.ledger` through
`CashFlowMath` (no transaction scans); money through `model.moneyFormatter`
(Hide balances masks amounts and badges, never percentages or shapes).

- Header: `BudgieHeader("Cash flow")` with a `MonthPill` showing the chart
  range (`CashFlowMath.rangeLabel`, default 6 months; page `@State`, not
  persisted). Tap: light haptic, range sheet ("CHART RANGE", rows 3 / 6 /
  12 months, selected accent/bold with a check; a pick gives a selection
  haptic and closes). The range drives only the bars and the metric strip;
  the month is `model.selectedMonth` (read-only here).
- Page order (horizontal padding 20): header, 24, metric strip, 16,
  `FlowInsightsSlot` (the Insights section below; nothing and so 32pt when
  there are no cards), 16, net cash flow, 16, year over year, 16, 12-month trend, 16,
  "Transactions" / "SEE ALL", 12, preview.
- Metric strip: equal-height chips (radius 22, padding 16): AVG SAVED / MO
  (`avgSavedText`) and SAVINGS RATE (`savingsRateText`), income colour when
  >= 0, danger otherwise; values wrap, no scaling.
- Net cash flow: custom layout (D16) from `CashFlowMath.barLayout` for the
  card's inner width: 190pt band, baseline at 116 (primary @12%), columns of
  `barWidth` spaced like `spaceAround`, bars radius 10; the selected month
  saturated with a glow (blur 20, .6) and its `badgeText` capsule 30pt above
  the bar; `MMM` labels in the bottom band. A column (the whole 190pt) tap:
  light haptic, month detail sheet (`CashFlowMath.MonthDetail`: bar-chart
  tile, `yMMMM`, Income / Expenses tiles, net row). Empty window: "No cash
  flow data yet." No bar animation (Flutter has none).
- Year over year: `CashFlowMath.yearOverYear` rows (Income, Expenses) with
  delta labels and two 12pt `GlowProgressBar`s each (800ms fill, instant
  under Reduce Motion), legend "This year" / "Last year".
- 12-month trend: `TrendLine`, a custom `Path` through
  `CashFlowMath.trendPoints` with `trendControlPoints` (fl_chart's exact
  cubic), 9pt accent @40% underlay, 3pt accent line, dashed zero line on top
  (fl_chart `extraLinesOnTop`), a 5pt #F2F2FA dot on the last point
  overhanging the plot edge; no fill, grid or axes. A data change animates
  150ms linear (none under Reduce Motion). Self-contained so it can become
  Swift Charts.
- Preview: `ledger.recent(3)` rows (category icon on an income or accent
  tile, description, "category · MMM d", signed amount); a row or the empty
  card ("No transactions recorded yet.") pushes `FlowTransactionsView`, as
  does "SEE ALL".
- VoiceOver: each bar is a button "September 2026, net +$3,158" (selected
  trait on the current month); chips read "Average saved per month" /
  "Savings rate" with the value; YoY rows read the delta; the trend reads
  "12-month net trend, From <month>, <net>, to <month>, <net>".
- Accessibility identifiers: `flow.rangePill`, `flow.range.3|6|12`,
  `flow.metric.avgSaved`, `flow.metric.savingsRate`, `flow.netCashFlow`,
  `flow.bar.<yyyy-MM>`, `flow.yoy`, `flow.trend`, `flow.preview.row`,
  `flow.preview.empty`; SEE ALL is the button "See all transactions".

### Flow: Insights (Flutter `LocalInsightsSection`, local_insights_section.dart)

`FlowInsightsSlot` (FlowView.swift) and `InsightCard` (InsightCard.swift);
cards from `model.insights` (BudgieCore `InsightEngine`, limit 3).

- Section (padding 20): `SectionHeader("Insights")`, 12, the cards 10
  apart, 8, "Calculated privately on this device · Not financial advice"
  (caption, text tertiary, no inset). No cards: the slot takes no space.
- Card: plain `GlowCard` (no tap): 40pt `IconTile` in the severity colour
  (urgent danger, warning warning, positive income, info accent), 12, a
  column of headline (rowTitle, primary), 4, explanation (rowSubtitle,
  secondary), 8, suggested action (caption, severity colour), all wrapping
  without limits; trailing `Menu` with a bold 17pt `ellipsis` (SF Symbols
  draw about 18% larger, so it matches the 24pt `more_horiz`, as the
  Categories rows) in a 48pt box (Flutter's 48pt IconButton, top-aligned),
  items "Snooze for 30 days" and "Dismiss" (fixed order, no icons, no
  destructive role). At accessibility text sizes the tile sits above the
  text, which takes the card's full width, and the menu stays top trailing
  level with the tile (as RecurringCard stacks; beside the fixed tile and
  menu the text column breaks words). Icons (D3):
  pace `speedometer`, monthly change `chart.line.uptrend.xyaxis`, unusual
  `bell.badge.fill` (Material `notification_important`, a bell), savings
  rate `banknote`, recurring `repeat`, under budget `hand.thumbsup.fill`,
  goal `flag.fill`, negative flow `chart.line.downtrend.xyaxis`, duplicate
  `doc.on.doc`.
- A menu pick acts at once: no confirmation, no undo, no haptic, no
  animation (Flutter has none, so Reduce Motion changes nothing). Every
  card with that id goes (ids can repeat; cards are keyed by position) and
  the next candidate fills in when the recomputation lands.
- Data: `AppModel` recomputes `insights` off the main thread (a generation
  counter drops stale results) when an engine input changed: the stored
  transaction, budget-limit or goal rows, the selected month, the ids the
  preferences exclude now, or the calendar day. It checks on every `data`
  change, month change, dismiss and snooze, and when Flow appears or the
  scene becomes active (the clock ends snoozes and moves budget pace); a
  net worth, settings, tag or rule edit, or the first Flow visit after
  launch, computes nothing. Untouched row arrays compare in O(1); the
  engine's lists are derived inside the detached task. The first cards are
  computed in the bootstrap before `.ready`. The slot's refreshes sit on
  one container, so switching between no cards and cards does not rerun
  them. The dismissed/snoozed ids are
  the two `flutter.local_insights_*` preferences, loaded after the
  protected-data wait and written synchronously like the theme mode (never
  the store, the retry banner or the backup). Money formatting, Hide
  balances, currency and locale do not apply (the copy has no amounts).
- VoiceOver: the tile and the three texts are one element with the actions
  "Snooze for 30 days" and "Dismiss"; the menu is a separate button
  "Insight options" (value: the headline); the header has the header trait.
  Dynamic Type through `TextSpec`.
- Accessibility identifiers: `flow.insights` (section), `flow.insight.card`
  and `flow.insight.menu` (each card), `flow.insight.snooze`,
  `flow.insight.dismiss`.
## Flow: all transactions (Flow "SEE ALL"; Flutter `_TransactionsDetailPage`)

`FlowTransactionsView`, pushed from Flow (system back). Every transaction,
newest first, filtered by `TransactionFilter` (all conditions ANDed).

- Navigation bar: 'Transactions' (sectionHeader) beside the back button
  and, when any month has data, the month pill (`MMMM` of
  `model.selectedMonth`) trailing; the list scrolls under the bar. The pill
  opens 'SELECT MONTH' (`yMMMM` rows of `ledger.availableMonths`, list
  capped at 320pt). A pick calls `model.selectMonth` and
  `filter.limit(toMonth:calendar:)` (From/To = the month's first and last
  day, D6 fix). While `filter.isLimited(toMonth:calendar:)` is false the
  pill is dimmed and no month is ticked.
- Filters card: 'Filters' + 'RESET' (only while `filter.isActive`; clears
  every filter and the amount text). Search field (description only, D8;
  hint 'Search descriptions'; a minus button clears it while the trimmed
  query is non-empty). Type pills 'All' / 'Income' / 'Expense' (compact,
  left-aligned). Category button ('All categories' or the name) opening
  'SELECT CATEGORY' ('All categories' + `ledger.categoryNames`). Tag chips
  ('All tags' + `model.tags` in provider order; tapping the selected tag
  clears it) when tags exist. From / To buttons ('Any date' or `MMM d`)
  opening the day picker (2000-01-01 to Dec 31 of now.year + 10; the other
  bound moves when crossed). Min / Max amount fields (decimal pad, floating
  label, base-currency prefix while floated; parsed by `AmountInput.parse`
  with the money format's separators, 0 and up, D6).
- Results: 'Results' + "{matches} of {all}", pills 'Income ...', 'Expenses
  ...', 'Net ...' over every match, then one list card of rows (tile,
  description, "{category} · {MMM d}", signed amount). 50 rows at first;
  while more match, "Showing N of M matches" and 'Load more transactions'
  (+50). The count resets to 50 only when the filter signature changes.
  Empty: 'No transactions match these filters.' / 'No transactions have
  been recorded yet.'
- Rows (D7): tap opens the edit form; swipe left (or the VoiceOver Delete
  action) confirms "Delete Transaction" and awaits `deleteTransaction`.
- Rows are keyed by transaction id and built lazily (`LazyVStack`); each
  row's card slice takes no touches. The filtered rows and summary are
  cached per filter + `ledgerRevision`. Money goes through
  `model.moneyFormatter` (Hide balances masks rows and pills).
- UI-test identifiers: `flow.all.month`, `flow.all.search`,
  `flow.all.type`, `flow.all.category`, `flow.all.from`, `flow.all.to`,
  `flow.all.min`, `flow.all.max`, `flow.all.reset`, `flow.all.count`,
  `flow.all.empty`, `flow.all.row`, `flow.all.showing`,
  `flow.all.loadMore`, `flow.all.option` (sheet rows).

## Worth (spec full-app/05; Flutter `net_worth_page.dart` `NetWorthPage`)

`Views/Worth/`. Totals, rows and history come from the Core net worth
queries on `model.data`; every mutation is an awaited `AppModel` call
(failure: the save-failed toast). Money through `model.moneyFormatter`
(Hide balances masks the hero, legend, row amounts, hover card and the
delta pill's amount; never percentages, share labels, the chart shape or
the editor's prefill).

- Empty (`!model.hasNetWorthEntries`): `BudgieHeader("Net worth")`, then 56
  below a card with a 56pt accent trend tile, "No net worth accounts yet",
  "Create your first asset or liability to start tracking net worth over
  time." and a filled 48pt "Add account" pill. The FAB shows too.
- Page order: header, month strip, hero (padding 24, 16, 24, 0), 24, growth
  card, 16, split card, 24, toggle, 16, accounts (horizontal padding 20),
  96 bottom clearance for the FAB.
- Month strip (D13): the shared `MonthStrip` over
  `model.netWorthAvailableMonths`, bound to `model.selectedNetWorthMonth`; a
  tap ticks and awaits `model.selectNetWorthMonth` (also for the selected
  chip, as Flutter).
- Hero: `NetWorthText.heroEyebrow`, then `RollingAmount` in heroMedium,
  leading, rolling `formatSigned(netWorth, 0 digits)` (rounded, base
  currency, D6) with a green (>= 0) / rose text glow at .35; VoiceOver
  "Net worth -$1,234.56". Delta pill (`NetWorthText.deltaPill`) when
  `netWorthChange(forMonth:)` is non-nil.
- Growth: `SegmentedPills` mono 6M / 1Y / ALL (`NetWorthGrowthRange`,
  default 1Y, page state) over `netWorthHistory(limit: 24)` oldest first;
  a Canvas plot drawn like fl_chart: `NetWorthChartScale.growth`, index x
  (`points`), grid at `gridLines`, 9pt glow + area gradient from the
  topmost spot + 3pt line through `CashFlowMath.trendControlPoints`
  (smoothness 0.28), end / selected dots; axis labels at
  `growthAxisLabelIndices`. A 150ms long press scrubs (`nearestSpot`, x
  only, 48pt) with a selection tick per spot and the hover card at
  `hoverAlignment`; lifting clears it. Same-length data changes animate
  150ms linear (none under Reduce Motion). VoiceOver: "Net worth growth",
  a summary value, swipe up / down steps through the points.
- Split card: `SplitGlowBar(splitFraction)` (flex via `splitFlex`) over the
  Assets / Liabilities legend (whole units).
- Toggle: Flutter's two chips (accent fill + glow when selected), page
  state, default Assets; the FAB adds on the active side.
- Accounts: `netWorthEntries(forMonth:type:)` rows in a `GlowListCard`
  (`NetWorthAccountIcon` symbol on a 44pt tile tinted by type, name,
  `NetWorthText.rowShare`, whole-unit amount, `rowChange` coloured by
  `changeIsFavorable`, 6pt share bar), or "No assets tracked for March
  2026." Tap: light haptic, opens the editor for the selected month.
  Context menu: Edit Balance (the same editor), View History (pushes
  `AccountHistoryView(entryID:)`), Delete Account ("Delete account?",
  `NetWorthText.deleteAccountMessage`, Cancel / Delete, plain role);
  VoiceOver activates Edit and offers View History and Delete Account as
  actions. No carry-forward control (Flutter has none;
  `carryNetWorthMonthForward` stays Core-only).
- Editor: `budgieDialog(padding: 0)` with the type glow; banner (type
  tile, "Add account" / "Edit account", `yMMMM` of the balance month,
  close), Asset / Liability pills, "Balance month" `DateTile` opening an
  inline month grid (1970 to this month), "Account name" and "Asset
  balance" / "Liability balance" `BudgieField`s (`NetWorthAmountInput`
  sanitize and prefill), Cancel and Add / Save. Save: "Name is required",
  "Enter a valid balance", then `addNetWorthEntry` / `updateNetWorthEntry`
  with the balance month, awaited before closing; scrim and buttons
  disabled while saving.
- Accessibility identifiers: `worth.add` (FAB), `worth.empty.add`,
  `worth.hero`, `worth.delta`, `worth.growth`, `worth.growth.range`,
  `worth.growth.chart`, `worth.split`, `worth.toggle.assets`,
  `worth.toggle.liabilities`, `worth.accounts.empty`,
  `worth.account.<name>` (rows), `worth.editor`, `worth.editor.asset`,
  `worth.editor.liability`, `worth.editor.month`, `worth.editor.close`,
  `worth.editor.cancel`, `worth.editor.save`; the fields are the text
  fields "Account name" and "Asset balance" / "Liability balance".

## Worth: account history (Flutter `_AccountHistoryPage`)

`AccountHistoryView(entryID:)`, pushed from a Worth row's View History
(system back, D2). Reads `model.netWorthEntry(id:)` and
`NetWorthAccountHistory` over `model.netWorthEntryHistory(id:)` on every
change, so it is live; every value is all-time, independent of the
selected month.

- Navigation bar: the account name (cardTitle, centred), a `pencil` edit
  button opening the Worth editor (`AccountEditorDialog`) for the account
  at `model.selectedNetWorthMonth`, and a danger trash button: "Delete
  account?" / `NetWorthText.deleteAccountMessage` / Cancel, Delete (plain
  role). The delete is awaited; a failed write shows `.saveFailed`; the
  page pops whenever the account is gone afterwards.
- Scroll content padding (20, 8, 20, 32) inside the safe area (clears the
  tab bar). Blocks: hero, 16, stat cards, 16, trend card, 24, timeline
  header, 12, timeline.
- Hero: GlowCard padding 24, gradient account colour 16% / 6% / card (stops
  0, .4, 1), border 18%, glow halo (24, .16). 48pt tile (`arrow.up.right`
  asset, `arrow.down.left` liability), 'Balance history' +
  `NetWorthText.lastUpdate`, 'Asset' / 'Liability' chip; 'CURRENT BALANCE';
  `formatSigned(latest)` in heroSmall shrunk to one line; chips
  (`snapshotCount`, "{+compact} vs prior" by sign, "{+compact} overall" by
  `totalChangeIsPositive`) wrapped with 8pt gaps.
- Stat cards: CURRENT / PEAK (account colour), LOW (text colour),
  `formatCompact`, '—' when there is no history; radius 22, padding 16.
- Trend card: empty 'No chart data yet for {name}.' (200pt). Otherwise
  'Trend' + `NetWorthText.trendRange` + latest compact chip, then the
  chart: 176pt plot + 24pt titles, `NetWorthChartScale.account` with index
  x (`points`; one snapshot drawn at 0 and 1), grid at `gridLines`, glow
  line 9pt 35%, area 35% to 0 from the highest spot, main line 3pt, round
  caps, fl_chart cubic (`CashFlowMath.trendControlPoints`,
  `curveSmoothness` 0.28) only when more than two snapshots, last dot
  #F2F2FA with a 3pt 50% ring. Titles: `accountAxisLabelIndices`, `trendAxisLabel`,
  monoAxis tertiary, centred on the spot 8pt below the plot. Touch: while a
  finger is down, the `nearestSpot` (x only, 48pt) gets fl_chart's default
  indicators and one tooltip (yMMMd over `formatSigned`, chip surface,
  radius 4, 16pt above the spot, clamped inside the plot); lifting clears it.
- Timeline: 'Timeline' + `NetWorthText.entryCount`; empty 'Add updates to
  this account to build a balance timeline.'; else one list card, newest
  first: glowing 12pt dot, yMMMd over jm, `formatSigned` over the compact
  delta from the next older update (green when good for the type), and a
  48pt trash button, disabled (tertiary) when only one update is left.
  Trash (or the row's VoiceOver Delete action) confirms "Delete balance
  update?" / `NetWorthText.deleteSnapshotMessage` / Cancel, Delete (plain
  role), then awaits `deleteNetWorthSnapshot`; a failed write shows
  `.saveFailed`. No haptics (as Flutter).
- Account gone while open: 'Account deleted' empty state, no edit or delete
  button.
- Money through `model.moneyFormatter` (Hide balances masks the hero,
  chips, stat cards, pill, tooltip, rows and the chart's VoiceOver value).
- UI-test identifiers: `worth.history` (scroll view), `worth.history.hero`,
  `worth.history.stat.current`, `worth.history.stat.peak`,
  `worth.history.stat.low`, `worth.history.chart`,
  `worth.history.chartEmpty`, `worth.history.timeline.count`,
  `worth.history.timeline.row`, `worth.history.timeline.delete`,
  `worth.history.timeline.empty`, `worth.history.edit`,
  `worth.history.deleteAccount`, `worth.history.missing`.

## Goals (spec full-app/03; Flutter `savings_goals_page.dart`)

`Views/Goals/`. Reads `model.savingsGoals` (incomplete first, then target
date, stable) and `model.savingsGoalsSummary`; copy from `SavingsGoalText`;
money through `model.moneyFormatter` (Hide balances masks amounts, the pace
line and the $25 / $100 chips, never percentages, statuses, dates or the
form's prefilled amounts).

- Header `BudgieHeader("Goals")`; the add button (`GlowFab`, "Add savings
  goal") floats bottom-trailing and opens the add form.
- Empty state: GlowCard (padding 28) with a 56pt accent `banknote` tile,
  "No savings goals yet", the body copy and a filled "Add goal" pill.
- Summary card: 72/8 accent `ProgressRing` with the overall percent, "SAVED
  SO FAR", the saved total (0 decimals) and "of {target} · {n} of {count}
  complete".
- Goal card: 84/9 ring in the status colour (accent On track, warning
  Behind, income Complete; percent, or a check when complete), name and
  status `PillChip`, "{saved} of {target}" or "{saved} saved", the pace line
  or "Fully funded on {MMMd} — nice work" in green, then a filled "Add money"
  pill and the 44pt ellipsis ("More goal actions"); a completed card has
  only the ellipsis, a green gradient and border, and long-presses (medium
  haptic) to its actions. Cards are keyed by goal id.
- Actions sheet (ellipsis): floating card with the name, "Edit goal" and
  "Delete goal"; the chosen dialog opens after the sheet closes.
- Dialogs (`budgieDialog`): the add / edit form (Goal name, Target amount,
  Saved so far when editing, Target date tile opening `DayPickerSheet` over
  Jan 1 of last year to Jan 1 of year + 20, stretched to the shown date;
  errors "Name is required", "Enter a target greater than 0", "Enter 0 or
  more" on submit), Add money (autofocused amount, chips that replace the
  text: $25.00, $100.00, "Finish goal" while something remains; "Enter an
  amount greater than 0"), and "Delete savings goal?". Amounts parse with
  `AmountInput`; an edit's untouched prefill, and the untouched "Finish
  goal" text, keep the exact stored / remaining value.
- Every mutation is awaited with its dialog open (scrim and buttons inert),
  then the dialog closes and toasts "Savings goal added / updated /
  deleted" or "Allocation added", or the save-failed toast when the write
  failed. An Add money that completes the goal (`willComplete` on the goal
  as shown) then plays the medium haptic, queues a "Goal complete, {name}"
  announcement and, unless Reduce Motion is on, the 1600 ms celebration
  (scrim, 18 dots, scaling card; no touches).
- UI-test identifiers: `goals.fab`, `goals.empty`, `goals.empty.add`,
  `goals.summary`, `goals.card` (one per goal; label "{name}, {status}"),
  `goals.card.addMoney`, `goals.card.more`, `goals.actions.edit`,
  `goals.actions.delete`, `goals.form.date`, `goals.form.cancel`,
  `goals.form.submit`, `goals.allocate.chip.25`, `goals.allocate.chip.100`,
  `goals.allocate.chip.finish`, `goals.allocate.cancel`,
  `goals.allocate.submit`, `goals.delete.cancel`, `goals.delete.confirm`,
  `goals.celebration`. Fields by label: "Goal name", "Target amount",
  "Saved so far", "Allocation amount".

## Categories (spec full-app/06 section 1.5; Flutter `category_settings_page.dart`)

`Views/Settings/CategoriesView.swift`, pushed from Settings >
PERSONALIZATION > Categories (system back; "Categories" in cardTitle in
the bar, a "+" "Add category" button trailing, no FAB). Reads
`model.categoryDefinitions(type:includeArchived:)` (Dart `categoriesFor`);
every mutation is an awaited `AppModel` call returning `CategoryOutcome`.

- Top: the centred `SegmentedPills` "Expenses" | "Income" (padding 16, 8,
  16, 0), then "Show archived" (M3 bodyLarge 16 / 1.5, systemGreen switch,
  padding 24 leading and 32 trailing so the track ends where
  CupertinoSwitch's does, 56 tall; the title also toggles it). Neither is
  persisted.
- List (padding 16, 0, 16, 32; 8 apart, lazy): one `GlowCard(padding: 8)`
  per definition in sort order, archived rows interleaved only while the
  switch is on. A new list per type (`.id(typeIndex)`), so switching type
  starts at the top. Row: 72 tall, content padding 16 / 24, 16 gaps, the
  40pt `IconTile` with its symbol at `Metrics.categoryGlyph` (17), the name
  (rowTitle, tracking 0.5) over "Built in" / "Archived" joined with " · "
  (rowSubtitle, tracking 0.25; 4 apart; an empty subtitle keeps its line),
  and the 48pt `ellipsis` (17, bold) system `Menu` "Category actions". No row
  tap.
- Menu (`CategoryRowAction.menu`): Edit; Move up unless archived or first
  shown; Move down unless archived or last shown; Restore (archived) or
  Archive. Moves pass `model.categoryMoveOffset` (relative to the rows
  shown). Saved and no-op outcomes are silent; `.failed` shows
  `Toast.saveFailed`; `.rejected` shows `error.message` in the neutral
  toast (`CategoryRowAction.refusedToast`: "At least one category must
  remain active").
- Editor (`CategoryEditorDialog`, `budgieDialog(item:)` centred card):
  "New category" / "Edit category" (goalTitle), the autofocused
  `BudgieField` "Name" (words, Done return key that dismisses the
  keyboard), "Icon" and "Color" captions over `FlowLayout`s (8 / 8,
  capped at five buttons a row: 5 x 44 + 4 x 8) of 44pt choice buttons
  (radius 12; selected accent 18% + accent border, else surface + border):
  the 18 `CategoryCatalog.iconIdentifiers` symbols in textPrimary (17,
  regular), then the 8 `colorTokens` as 20pt circles; Cancel / Add | Save
  pills (44). A new
  category's type is the selected segment. Save validates inline:
  "Enter a category name" (empty after trim), else
  `validateCategoryName`'s message; after the first Save the error follows
  the text. The edit is then awaited with the dialog inert
  (`budgieDialogDismissDisabled`); it closes on `.saved` / `.unchanged`,
  and on `.failed` with the save-failed toast; `.rejected` shows inline.
  A rename's cascade is one commit and rebuilds the ledger, so every screen
  shows the new name.
- VoiceOver: each row's text is one element (name, value = subtitle) with
  the menu items as custom actions, followed by the "Category actions"
  menu, valued with the category's name; choice buttons are named ("Cart", "Green", ...) with the selected
  trait; the "Icon" / "Color" captions are headers.
- UI-test identifiers: `settings.categories`, `categories.add`,
  `categories.type`, `categories.showArchived`, `categories.list`,
  `categories.row.<id>`, `categories.row.menu.<id>`,
  `categories.editor.name`, `categories.editor.icon.<identifier>`,
  `categories.editor.color.<token>`, `categories.editor.submit`,
  `categories.editor.cancel`; the field is the text field "Name".

## Tags & rules (spec full-app/06 section 1.6; Flutter `categorization_settings_page.dart`)

`Views/Settings/TagsRulesView.swift`, pushed from Settings >
PERSONALIZATION > Tags & rules (system back; "Tags & rules" in cardTitle
in the bar). Reads `model.tags` (stored order) and `model.rules` (Flutter's
`rules`, priority descending); every mutation is an awaited `AppModel` call
returning `TagRuleOutcome`. Scope is Flutter's add / delete tag and add /
delete rule, plus the Swift superset (PARITY_GAPS): edit a rule in place
(`updateRule`), an enable switch (`setRuleEnabled`), optional amount
bounds and "Any type". No priority or reorder.

- Page: a scroll view padded 16 (Flutter's ListView). "Tags"
  (headingMedium) with a trailing "ADD" text button (accent, M3 labelLarge
  14 / w500, min 64 x 48; VoiceOver "Add tag"), 8, the tags card; 32;
  "Merchant rules" with "ADD" ("Add merchant rule"), 8, the rules card.
- Empty cards: `GlowCard` with bodyMedium in textSecondary: "Add tags to
  group transactions across categories." / "Rules can automatically choose
  a category and tags from a merchant name."
- Rows (`GlowListCard`, padding 16 / 24, 16 gaps, trailing 48pt `trash`
  button in textSecondary): a tag is the `tag` IconTile in accent and the
  name (rowTitle), 56 tall, no tap; a rule is the `sparkles` IconTile in
  info and the merchant text (rowTitle) over the subtitle (rowSubtitle,
  secondary), both one button that opens the editor, then the enable
  switch (system Toggle, `.green` like the Settings switches, inert while
  its write is in flight), then the trash button; 72 tall. A disabled
  rule's tile and text are at `Metrics.opacityMuted` (the switch and
  trash are not dimmed). Subtitle (`TagsRulesView.ruleSubtitle`):
  Flutter's exact `"{matchType raw} · {category}"` plus `" · {n} tags"`
  when it has tags ("contains · Groceries · 1 tags"), then, each after
  " · ", "any type" (no type), the bounds via `model.moneyFormatter`
  ("at least $5.00", "up to $20.00", "$5.00 to $20.00", "exactly
  $5.00") and "off" when disabled. A rule Flutter's dialog could make
  shows exactly Flutter's string.
- Enable switch: memory first (switch and dimming follow at once), one
  awaited write; `.failed` shows `Toast.saveFailed`.
- Delete rule: instant (Flutter); memory changes first, so the row goes
  at once and the write follows (failure: `Toast.saveFailed` and the
  unsaved banner). Delete
  tag: the "Delete tag?" centred card ("This removes "{name}" from your
  tags and from any merchant rule that uses it.", Cancel / Delete in
  danger), awaited with the dialog inert, closing afterwards.
  Transactions keep the id (D9); the form and SEE ALL chips no longer
  show it.
- "New tag" (`NewTagDialog`, `budgieDialog(item:)` centred card, goalTitle
  title): the autofocused `BudgieField` "Tag name" (prompt "Travel
  planning", words; Return adds), Cancel / Add pills (44). A blank name
  closes silently (Flutter); `validateTagName`'s "A tag with this name
  already exists" shows inline and then follows the text.
- "New merchant rule" / "Edit merchant rule" (`RuleEditorDialog`, `rule`
  nil for new): "Merchant text" (prompt "Whole
  Foods", autofocus, no capitalisation, Done closes the keyboard), then
  dropdowns in the field style (caption above, chip-surface box radius 14,
  52 tall, value in rowTitle, footnote up-down chevron): a tap opens a
  popover list anchored to the box (rowTitle rows at least 48 tall, accent
  check on the current one, scrolled to it, about nine rows high), and
  with the keyboard up it first dismisses the keyboard and opens once
  it has gone. "Type" (Income, Expense, Any type; default Expense),
  "Match" (Contains, Starts with, Exact match; default Contains),
  "Category" (`model.categories(for:)` names; for Any type the expense
  names then the income names they lack, UTF-16; an edited rule's own
  category is appended under its own type when the list lacks it;
  default the first; a type change keeps the shown name when the new
  list has it, else its first). Under Any type with a one-type category,
  a caption (caption, secondary): "Only expenses have {name}, so income
  won't be categorized by this rule." (or "Only income has {name}, so
  expenses won't ..."). Then, when tags exist, a "Tags" caption over the
  form's tag pills (FlowLayout 8, one line, truncated at the card's
  width), selected in tap order. Then "Minimum amount" and "Maximum
  amount" (`BudgieField`, prompt "Optional", the currency's SF symbol,
  decimal pad; empty is no bound; an edit prefills
  `formatNumber(bound, 2)` and a field left as prefilled keeps the stored
  value). The fields are a `DialogScroll`: its indicator flashes when the
  keyboard has shown, and its bottom 48pt fades while more is below (iOS
  18+). Add / Save is disabled (38%) while the trimmed text is empty.
  On submit the bounds are checked first, inline under the field ("Enter
  an amount of 0 or more"; "Minimum can't be more than maximum" under
  Maximum), announced. The edit mode (tap on a rule row) is titled "Edit
  merchant rule", is prefilled, does not autofocus, and saves with
  `updateRule`; priority and enabled state are kept as stored. A refusal
  shows in danger caption above the buttons.
- Outcomes: `.saved` / `.unchanged` close silently; `.failed` closes with
  `Toast.saveFailed`; `.rejected` shows `error.message` inline.
- VoiceOver: a tag row's name is one element with a "Delete" action; a
  rule row's text is one button (label pattern, value subtitle) with
  "Edit" and "Delete" actions, then the switch "Enable rule {pattern}";
  each is followed by the "Delete {name}" / "Delete rule {pattern}"
  button; section titles and dialog titles are headers; dropdowns read
  "Type, Expense"; tag pills and the dropdown list's current row carry the
  selected trait. No animation is added (the switch is the system's).
- UI-test identifiers: `tagsRules.list`, `tags.add`, `rules.add`,
  `tags.empty`, `rules.empty`, `tags.row.<id>`, `tags.row.delete.<id>`,
  `rules.row.<id>`, `rules.row.enabled.<id>`, `rules.row.delete.<id>`,
  `rules.editor.minimum`, `rules.editor.maximum`,
  `rules.editor.anyTypeNote`, `tags.editor.name`,
  `tags.editor.submit`, `tags.editor.cancel`, `tags.delete.confirm`,
  `tags.delete.cancel`, `rules.editor.pattern`, `rules.editor.type`,
  `rules.editor.match`, `rules.editor.category`,
  `rules.editor.tag.<id>`, `rules.editor.submit`, `rules.editor.cancel`;
  the Settings row is the button "Tags & rules"; the fields are the text
  fields "Tag name", "Merchant text", "Minimum amount" and "Maximum
  amount"; each rule's switch is labelled "Enable rule {pattern}".

## Toasts

`Toast.Style`: `.success` (income), `.danger` (danger) and `.neutral`
(Flutter's default SnackBar: `textPrimary` fill with `background` text,
standing in for M3 inverseSurface / onInverseSurface), all floating,
radius 12, above the tab bar (`toastHost`).

## Recurring

`Views/Recurring/` (`recurring_transactions_page.dart`,
`recurring_transaction_form.dart`, on the redesign tokens: D1, D15).
Pushed from Settings > DATA "Recurring transactions". System bar with the
principal title "Recurring Transactions" (`cardTitle`) and a trailing
group: refresh (`arrow.clockwise`, "Generate Due Transactions",
`recurring.generate`) and "+" ("Add recurring transaction",
`recurring.add`).

- Generate: `model.generateDueNow()`, then its toast: "Due transactions
  generated and next occurrences updated" (also when nothing was due) or
  the save-failed toast. With nothing due it first retries any unsaved
  write and reports success only once nothing is unsaved. The button is
  disabled while it runs.
- Empty state (`recurring.empty`): 120pt `primaryGradient` circle with a
  white 52pt semibold `repeat` glyph, "No Recurring Transactions" (`headingLarge`), "Create
  recurring transactions to automatically\ngenerate expenses and income on
  a schedule" (`bodyMedium`, secondary), centred, padding 32; plus a filled
  "Add Recurring" pill (Swift only).
- List: `data.templates`, active first then paused, each in stored order,
  `RecurringCard`s 8pt apart, padding 16. Card (`recurring.card`, a
  GlowCard with padding 16): 44pt `IconTile` (category icon, income green
  or accent; fallback `bag.fill` / `dollarsign`), description (`cardTitle`)
  with a 16pt `RecurrenceGlyph` and, when paused, a warning "Paused" chip,
  the category (`caption`, tertiary), the amount (`numericMediumBold`,
  22 bold tabular, scaling down to 0.6; income green or primary text,
  masked by Hide balances); a hairline with 16pt above and below; two
  columns "Pattern" (`repeat`; Weekly / Bi-weekly / Monthly) and "Next
  Occurrence" (`calendar`; `MMM dd, yyyy`), 18pt symbols in a 20pt frame,
  labels `captionStrong` secondary, values `bodySmall`; then three outlined
  pills at least 44pt tall (`PillButton(minHeight:)`, growing with the
  text): Edit (accent), Pause (warning) / Resume (income), Delete
  (danger), stacked vertically when they do not fit (large text). At
  accessibility text sizes the description wraps freely, the Paused chip
  and the amount move under it, and the two detail columns stack. A paused card's
  content is at 0.65 opacity, its buttons are not. VoiceOver: one summary
  element (`recurring.summary`) "description, income|expense, amount,
  category, pattern, next occurrence date[, paused]", then the three
  buttons (`recurring.edit`, `recurring.pause`, `recurring.delete`).
- Pause / Resume: `setTemplateActive`, save-failed toast on a failed write.
  Resume moves the cursor to the first occurrence on or after today
  (`RecurringGenerator.resumedCursor`): nothing missed while paused is
  generated; one due today still is.
- Delete: alert "Delete Recurring Transaction?", message `This will stop
  generating future transactions for "<description>". Previously generated
  transactions will not be affected.`, Cancel / Delete (destructive, heavy
  haptic); the awaited `deleteTemplate` shows "Recurring transaction
  deleted" or the save-failed toast.

Form (`RecurringFormView`, a sheet with `budgieSheetChrome`, large detent;
also swapped in place into the transaction form by "Make this recurring"):
title "Add|Edit Recurring Expense|Income" (`headingMedium`); the
Expense/Income pills when adding only; Amount (`BudgieField`, currency
symbol, "0.00", decimal pad, focused on open; prefill
`toStringAsFixed(2)`); Description ("What is this for?", `doc.text`);
"Category" wheel (`CategoryWheelRow`: the tile in the fixed `expenseFixed` /
`incomeFixed` red or green, the same in dark mode),
"Recurrence Pattern" wheel (Weekly, Bi-weekly, Monthly; default Monthly) and,
for monthly, "Day of Month" wheel 1-31 (90pt boxes, chip surface, radius 12,
1.5pt border, selection haptic), each captioned in `captionStrong` (as are
the `BudgieField` labels); "Start Date" `DateTile` (`MMM dd, yyyy`;
danger border, label and icon with the error below it) opening
`DayPickerSheet` over `RecurringForm.startDateRange` (which also offers an
edit's stored start day, so an older template's picker opens on it and OK
keeps it); the "Next 3
Occurrences" card (`eye`, `EEEE, MMM dd, yyyy` lines, `bodySmall`); footer
Cancel (outlined) and Save / Update (expense or income gradient, spinner
while saving, interactive dismiss disabled). The start is
`RecurringForm.resolvedStart` (the form-open moment with its time, a picked
day at midnight, an edit's stored value). Day of Month starts at
`RecurringForm.initialDayOfMonth` (today's day when adding, else the stored
day) and follows the resulting start day until the wheel is moved (an
edit whose stored day differs from its start day counts as moved). Save runs `RecurringForm.validate`
(all three errors at once, the first announced to VoiceOver; typing clears
the amount / description error, a pick re-checks the date), then
`addTemplate` / `updateTemplate` with `RecurringForm.edit`, and dismisses
after the awaited Bool (save-failed toast on false). The preview is
`previewOccurrences(pattern:start:...)` when adding and
`previewOccurrences(editing:...)` from the cursor the edit will leave when
editing (`lastGeneratedDate` is read once when the form opens).

Recurrence glyph: every transaction row shows a 16pt `RecurrenceGlyph`
after the description when `isRecurring` (Home Recent activity, Home SEE
ALL, Flow preview, Flow SEE ALL, Spend category drill-in), and adds
", recurring" to the row's VoiceOver label or value.

## Settings

- Appearance: System / Light / Dark (`setThemeMode`).
- Currency: the 11 codes the Flutter app offers
  (USD CAD EUR GBP AUD JPY CNY INR KRW MXN BRL) (`setBaseCurrency`).
- Face ID lock toggle (`setAppLockEnabled`), shown with the device's
  biometry name; enabling requires a successful authentication first.
- About: version, "Data diagnostics" (the existing `DiagnosticsView`).
- UI-test identifiers added for the chunk-1 tests: `settings.theme` (the
  Light | Dark | Auto pills container), `settings.tagsRules`,
  `settings.diagnostics`, `settings.licences`.

### Settings > DATA (spec full-app/06 sections 1.7-1.8; Flutter `settings_page.dart`)

- Rows: Recurring transactions, Export as CSV ("All N transactions"),
  Import from CSV, Export backup, Import backup (identifiers
  `settings.exportCSV`, `settings.importCSV`, `settings.exportBackup`,
  `settings.importBackup`). While one of the four data rows runs (from the
  tap until its message, through the share sheet, the document picker and
  the confirmation) all four are disabled and the running one shows the
  20pt accent spinner; VoiceOver reads "Exporting", "Importing" or
  "Restoring" for it.
  Recurring is never disabled. Row subtitles take two lines at
  accessibility text sizes (one otherwise).
- Share sheet (`SharePresenter`: a `UIActivityViewController` with a
  `UIActivityItemSource`, presented from the topmost presented controller,
  so it is the system's compact sheet, as share_plus): the subject
  ("Budgie Backup", "Budget Transactions Export") is the Mail subject and
  the header's title; the header's subtitle is share_plus's "JSON • 70 KB"
  / "CSV • 6 KB". The success toast ("Backup exported", "Transactions
  exported successfully!") shows only when an activity completed. Both
  files are built off the main thread (`model.exportBackup()`,
  `model.exportCSV()`), written with complete file protection, and passed
  to `model.finishExport` (deleted) when the sheet reports back, or at
  once when the page was left before the file was ready; leftovers are
  swept at launch and when the app goes to the background.
- Document picker: one `.fileImporter` on the page, typed by what it is
  choosing (`.json` for a backup, `.commaSeparatedText` for CSV); the
  file is read in place (security scope, `NSFileCoordinator`) off the
  main thread. Cancel is silent; an unreadable file toasts "Could not
  import backup: The file could not be read" / "Could not import: The file
  could not be read", and a file over 50 MB (checked before reading) "...:
  The file is larger than 50 MB".
- Confirmation: `DataImportDialog`, the centred `budgieDialog` card
  (goalTitle title, bodyMedium secondary message in a `DialogScroll`,
  Cancel and the action as 44pt pills). The action is awaited with the
  card modal and inert (Cancel disabled at 40% opacity, no scrim dismiss;
  the action pill shows an `onAccent` spinner on its fill, identifier
  `<prefix>.busy`, VoiceOver label and announcement "Restoring" /
  "Importing"); a scrim tap is Cancel.
  - Backup: "Replace all data?", `RestorePlan.confirmationMessage`
    (Flutter's text, plus the kept-items sentence for a file that leaves
    sections out), Cancel / Replace (danger fill). Identifiers
    `backup.confirm.title|message|cancel|confirm`. Then "Backup restored"
    (success) or "Could not import backup: <reason>" (danger).
  - CSV: `Summary.confirmTitle` ("Import 2 transactions?"),
    `confirmMessage` (counts only, "2 duplicates will be skipped\n1 row
    could not be read"; no body when nothing was skipped), Cancel / Import
    (accent fill). Identifiers `csvimport.confirm.*`. Then
    `successMessage` (success) once the write verified, else the
    save-failed toast.
- A file the decoder refuses toasts "Could not import backup: <Flutter
  message>" (danger), e.g. "This is not a valid Budgie backup file".
- CSV: parsed off the main thread (`model.previewCSVImport`); nothing to
  import shows `emptyResultMessage` in its tone (neutral for "All
  transactions in this file already exist" and "No transactions found in
  this file", danger when rows could not be read) and no dialog; a
  refused file shows "Could not import: Not a valid transactions CSV
  export" (danger).

## Onboarding (spec full-app/07 section B; Flutter `onboarding_tutorial.dart`)

Shown once, when `flutter.onboarding_completed` is not true
(`model.showsOnboarding`, read at bootstrap): `MainView` shows
`OnboardingView` instead of the tabs; the lock
screen and privacy cover (`AppLockWindow`) sit above it (not a `fullScreenCover`), and
VoiceOver cannot reach it while locked. Skip and
"Start budgeting" call `model.completeOnboarding()` (`OnboardingFlag
.markCompleted`: the key is removed, then set to a bool true); the tabs replace the
tour at once (Home) and a queued quick action, widget tap or link opens
then. Launch hook (DEBUG): `BUDGIE_SKIP_ONBOARDING=1` starts past the tour,
`=0` removes the flag.

- Background `background`; padding 24 / 8 top / 24 bottom inside the safe
  area. "Skip" top right: accent, Gabarito Medium 14 (+0.1), 64x48 minimum.
- Pager: a paged `TabView`, swipeable. Each page, centred (scrolls at large
  text sizes), padding 8: a 116pt circle (accent 14%) with a `GlowHalo`
  (blur 32, alpha 0.25; the light-mode ambient version in light) holding a
  40pt accent symbol (`wallet.bifold.fill` or `creditcard.fill`,
  `chart.bar.xaxis.ascending`, `chart.xyaxis.line`); 48pt; eyebrow
  (`.eyebrow`, accent); 16pt; title (`.displayMedium`, primary, header);
  16pt; body (Gabarito 17, -0.4, line height 1.45, secondary, max width
  390).
- Copy: WELCOME TO BUDGIE / "Your money, made clearer." / "Budgie keeps
  your budget simple and private. Financial data and insights stay on this
  device unless you choose to export or share a backup. Voice entries are the
  one exception: your recording is sent to OpenAI to be turned into an
  expense."; START HERE /
  "Track what comes and goes." / "On Home, use the add button for income or
  expenses. Your balance and recent activity update as you go."; EXPLORE
  WHEN READY / "Plan ahead, then look back." / "Worth tracks accounts, Goals
  keeps savings in view, and Spend, Flow, and Settings (behind the gear on
  Home) help you understand and manage your budget."
- Dots: active 22x8 accent capsule, others 8x8 `border`, 4pt margins,
  resized over 150ms linear. VoiceOver: one adjustable element "Tutorial
  page", value "n of 3".
- The whole page is a column capped at 600pt (`Metrics.maxContentWidth`) and centred where the window is wider.
- 24pt, then a full-width button (min 56pt, radius 16, accent fill,
  `onAccent` Gabarito Medium 14): "Continue" moves to the next page (300ms
  easeInOut; a jump under Reduce Motion) and announces it to VoiceOver;
  "Start budgeting" on page 3.
- Identifiers: `onboarding.skip`, `onboarding.next`, `onboarding.dots`,
  `onboarding.page.<n>`.

## App lock

When `appSettings.appLockEnabled`: an opaque privacy cover whenever the
scene is inactive/background; on returning after
`autoLockTimeoutSeconds` (0 = immediately), or at launch, require
`LAContext.evaluatePolicy(.deviceOwnerAuthentication)` before showing data.
The lock never blocks the bootstrap or saves. Only an authentication
unlocks the session: the lock screen's own, or the Settings toggle's (it
authenticates, then calls `markUnlocked()` before turning the lock on). A
backup restore that turns App Lock on locks the session at once
(BackupUITests `testRestoreThatTurnsAppLockOnLocksTheApp`).

The cover and the lock screen are drawn in a second `UIWindow` of the same
scene (`AppLockWindow`, `windowLevel = .alert + 1`), not as an overlay on
`MainView`: sheets, `budgieDialog`s and the over-full-screen `AddFormHost`
are presented inside the app window, so an overlay sat below them (a sheet
stayed in the app-switcher snapshot, and after a relock the lock screen
showed under a still-open sheet). The window is created by the
`SceneDelegate` after the app window (which stays key), hosts
`PrivacyCover` or, while `model.isLocked`, `LockScreen` (theme tokens; it
gets the same `overrideUserInterfaceStyle` as the app window), and is
`isHidden` (no touches, no VoiceOver) whenever neither applies. Nothing is
dismissed: the user's sheets and their input stay as they were underneath.

- Timing: the cover goes up synchronously in `sceneWillResignActive` (and
  `sceneDidEnterBackground`) when the lock is on: window shown, laid out
  and `CATransaction.flush()`ed before the callback returns, with an opaque
  #0A0A12 background on the window's root view as a floor until SwiftUI has
  rendered. It does not wait for `scenePhase`. `sceneDidBecomeActive` relocks
  (`model.relock()`) when the time since `sceneDidEnterBackground` is at
  least `autoLockTimeoutSeconds`, then lowers the cover; a lock screen that
  takes over stays up with no gap. A brief inactive period (Control Center,
  a system alert) only covers.
- Enable prompt: the decision to cover is taken at resign, when the lock is
  not on yet while Settings' Face ID / passcode prompt (`isEnablingAppLock`)
  is up, so no cover flashes over Settings when the lock turns on under the
  prompt (this replaces the old `coverHeld`).
- VoiceOver while locked: the app window has `accessibilityElementsHidden`
  (so the tabs, the tour, any sheet and any over-full-screen host are out of
  the tree, which `AddFormHost`'s own hiding of the screens beneath does
  not cover), and the lock screen is modal. Unhidden again on unlock.
- Keyboard: when the cover goes up the app window's first responder is
  resigned (`endEditing`). The keyboard and its QuickType bar are in system
  windows above any app window and could show typed text in the snapshot.
  Text already typed stays; the field only loses focus.
- Identifier: `applock.lock` on the lock screen. UI tests: `AppLockUITests`
  with the DEBUG hooks `BUDGIE_UITEST_APP_LOCK=<seconds>` (lock on, in
  memory) and `BUDGIE_UITEST_AUTH_SUCCESSES=<n>` (`AppLockTestHooks`).

## Accessibility audit

`BudgieUITests/AccessibilityAuditUITests.swift` runs
`XCUIApplication.performAccessibilityAudit(for:)` (iOS 17+) on every main
screen and sheet; `AuditSupport.swift` holds the runner and the one table of
exclusions (mirrored below). Any issue the audit reports that the table does
not accept fails the test with the screen, the audit type, the element's
identifier and label, its frame and, for contrast, the colours measured in a
screenshot taken at rest (`BUDGIE_AUDIT_REPORT=<file>` writes every issue,
accepted or not, to a file).

### Method

- Seeded through the UI, deleted afterwards (a per-run suffix on everything):
  an expense, an income and an older expense, a tag, a budget, a Worth
  account and a goal. Home is audited at the top and scrolled to the bottom,
  as are the tab roots, Settings and the long pushed pages.
- The regression runs one pass (`testEveryScreen`, seeded once): light at
  the default size with every audit type but `.textClipped`, on every
  screen. Accessibility-XXXL Dynamic Type (launch argument
  `-UIPreferredContentSizeCategoryName
  UICTContentSizeCategoryAccessibilityXXXL`; `.textClipped`, `.hitRegion`,
  `.dynamicType` on the tab roots, Settings and the main sheets) and dark
  (every type but `.textClipped`, same screens) are opt-in for a manual
  sweep after a design-system change:
  `TEST_RUNNER_BUDGIE_AUDIT_PASSES=light,xxxl,dark`. The theme is chosen
  through Settings and put back. Separate methods, light only: the three
  onboarding pages, the lock screen (DEBUG hook `BUDGIE_UITEST_APP_LOCK`,
  authentication refused) and the voice sheet with the microphone denied
  (`BUDGIE_VOICE_MIC_DENIED`; nothing reaches OpenAI).
- `.textClipped` runs only at XXXL. "May be clipped at larger Dynamic Type
  sizes" is a prediction; at the default size it fired for dozens of
  one-line labels and for every text in any bottom sheet, a plain SwiftUI
  `.sheet` with a `.medium` detent included (checked in a scratch view), and
  at XXXL, where there is no larger size, it names text that does not fit.
- Screens: the five tab roots (Home, Worth, Goals, Spend, Flow), Settings
  and its pushed pages (Categories, Tags & rules, Recurring, Data
  diagnostics, Licences), the transaction forms (add expense, add income,
  edit, the date picker, the recurring form), the budget picker and limit
  sheet, the safe-to-spend sheet, the quick-expense sheet, the Home month
  panel, Home SEE ALL, Flow SEE ALL with its filters, category and month
  sheets, the Flow range sheet and month detail, the Spend month sheet and
  drill-in, the Worth account editor (and its month grid) and account
  history, the goal form, allocation dialog, actions sheet and delete
  dialog, the currency and number format sheets, the category editor, tag
  dialog and rule editor, the onboarding pages, the lock screen and the
  voice sheet.

### Issues found at BASE (light, default size, before any fix)

Counts of reported issues per screen and audit type from the first run on
the unchanged BASE app (screens the run reached; it stopped at Flow month
detail, whose identifier sat on a container that swallowed its children, so
Flow SEE ALL, Settings and the pushed pages were not audited at BASE):

| Screen | contrast | hitRegion | dynamicType | textClipped | elementDetection | sufficientElementDescription |
|---|---|---|---|---|---|---|
| Add Expense form | 7 | 0 | 0 | 1 | 0 | 0 |
| Add Income form | 5 | 0 | 0 | 1 | 0 | 0 |
| Budget limit sheet | 4 | 0 | 0 | 2 | 2 | 0 |
| Budget picker | 1 | 0 | 0 | 5 | 5 | 0 |
| Date picker | 2 | 0 | 30 | 1 | 7 | 0 |
| Edit Transaction form | 8 | 0 | 0 | 1 | 0 | 0 |
| Flow | 16 | 1 | 6 | 8 | 7 | 0 |
| Flow month detail | 5 | 0 | 0 | 4 | 4 | 0 |
| Flow range sheet | 2 | 0 | 1 | 4 | 5 | 0 |
| Goal actions sheet | 2 | 0 | 0 | 0 | 0 | 0 |
| Goal allocation dialog | 3 | 0 | 0 | 1 | 0 | 2 |
| Goal delete dialog | 2 | 0 | 0 | 0 | 0 | 0 |
| Goal form | 3 | 0 | 0 | 1 | 0 | 0 |
| Goals | 4 | 0 | 4 | 2 | 0 | 0 |
| Home | 64 | 3 | 5 | 19 | 1 | 0 |
| Home SEE ALL | 8 | 0 | 2 | 3 | 0 | 0 |
| Home month panel | 45 | 1 | 4 | 7 | 0 | 0 |
| Quick expense sheet | 7 | 0 | 0 | 8 | 1 | 0 |
| Recurring form (from the transaction form) | 6 | 0 | 0 | 0 | 0 | 0 |
| Safe to spend sheet | 1 | 7 | 0 | 9 | 2 | 0 |
| Spend | 2 | 0 | 2 | 4 | 0 | 0 |
| Spend drill-in | 10 | 0 | 10 | 4 | 0 | 0 |
| Spend month sheet | 1 | 0 | 0 | 3 | 3 | 0 |
| Worth | 62 | 0 | 11 | 2 | 0 | 0 |
| Worth account editor | 4 | 0 | 0 | 1 | 1 | 0 |
| Worth account history | 14 | 0 | 17 | 2 | 1 | 0 |
| Worth editor month grid | 4 | 0 | 0 | 1 | 0 | 0 |
| Total | 292 | 12 | 92 | 94 | 39 | 2 |

Mostly: contrast 292 (tokens, below, and false alarms the pixels refute),
dynamicType 92 (every `.caption2`-scaled text, the system date picker, text
in a `ViewThatFits`), textClipped 94 (advisory at the default size, above),
elementDetection 39 (no element named), hitRegion 12 (the "Edit" and "SEE ALL"
links, the safe-to-spend rows, the add budget link), sufficientElementDescription 2
(the allocation chips labelled only "$25.00").

### Fixes (look unchanged at the default text size)

- Tap areas of at least 44 x 44pt, drawn size and layout unchanged
  (`View.tapArea(horizontal:vertical:)`, Pills.swift: transparent padding
  inside the label, taken back out of the layout): `MonthPill`,
  `SectionHeader` links (EDIT, SEE ALL), `SegmentedPills` (theme, form type,
  categories type, Flow type, Worth range), tag chips (forms, Flow filters),
  the allocation quick-amount chips, the Worth editor's close button, month
  grid cells and step buttons, the Assets / Liabilities toggle, the year
  stepper, RESET, the toast's Retry, "Make this recurring", the Flow bars
  (the column's share of the row, so neighbours do not overlap; narrower
  than 44pt only at 12 months), the tag row's name (a 44pt strip).
- Elements: `flow.monthDetail` and `SegmentedPills` are containers
  (`.accessibilityElement(children: .contain)`, so an identifier on them no
  longer replaces their children: `worth.growth.range`'s pills and the month
  detail's tiles are their own elements); the toast with Retry keeps its
  button as an element (it was combined into the text); the safe-to-spend
  rows are static text; the allocation chips say "Fill amount $25.00".
  `goals.delete.confirm` measured 150 x 44 (its own button) in this audit.
- Dynamic Type: `TextSpec` scales `.caption2` text from `.caption`
  (`TextSpec.scalingStyle`: the same size at Large, so every line box is as
  before and `TextLineHeightTests` pass; `.caption2` is the one style that
  stays 11pt up to Large, which the audit reads as "partially unsupported");
  `View.singleLine()` (one line as designed, up to three lines scaled to
  60% at accessibility sizes instead of an ellipsis) replaces `lineLimit(1)` on
  31 text sites; `View.wrapsWords()` (up to two lines, scaled to 50%) on
  eyebrows and page titles so no word breaks letter by letter ("Catego /
  ries", "6 month / s" at XXXL); the month pill and segmented pills stay on
  one line; the Worth growth header stacks its pills under the title when
  they do not fit; the Spend donut's delta chip may wrap.
- Colour tokens: see the next section.

### Colour tokens (owner-approved 2026-09-30)

Light accent, income, danger and warning, light textSecondary and
textTertiary, dark textTertiary, `primary`, the unselected segment label and
the primary, income and expense button gradients were adjusted to WCAG AA
(4.5:1 for text and for the white label on a fill); nothing else changed
(dark income, danger, warning and accent already passed). Old and new values
and the ratios before and after:

| Token | Mode | Flutter / old | New | Pair | Ratio before | Ratio after |
|---|---|---|---|---|---|---|
| textSecondary | light | 6B7280 | 626977 | text on card | 4.83 | 5.52 |
| textSecondary | light | 6B7280 | 626977 | text on chip | 4.30 | 4.90 |
| textTertiary | light | 9CA3AF | 686F7A | text on card | 2.54 | 5.07 |
| textTertiary | light | 9CA3AF | 686F7A | text on chip | 2.26 | 4.50 |
| textTertiary | dark | 5C5C78 | 81829F | text on card | 2.86 | 4.93 |
| textTertiary | dark | 5C5C78 | 81829F | text on chip | 2.81 | 4.86 |
| dockInactiveIcon | light | 6B7280 | 636A78 | text on track | 4.00 | 4.50 |
| accent | light | 6366F1 | 5453DD | text on card | 4.47 | 5.74 |
| accent | light | 6366F1 | 5453DD | text on chip | 3.97 | 5.10 |
| accent | light | 6366F1 | 5453DD | white on fill | 4.47 | 5.74 |
| income | light | 10B981 | 07744F | text on card | 2.54 | 5.80 |
| income | light | 10B981 | 07744F | text on chip | 2.25 | 5.16 |
| income | light | 10B981 | 07744F | white on fill | 2.54 | 5.80 |
| danger | light | EF4444 | C60D21 | text on card | 3.76 | 6.03 |
| danger | light | EF4444 | C60D21 | text on chip | 3.34 | 5.36 |
| danger | light | EF4444 | C60D21 | white on fill | 3.76 | 6.03 |
| warning | light | F59E0B | 8F5B05 | text on card | 2.15 | 5.73 |
| warning | light | F59E0B | 8F5B05 | text on chip | 1.91 | 5.09 |
| primary | both | 6366F1 | 5453DD | white on fill | 4.47 | 5.74 |
| primaryGradient stop 1 | light | 6366F1 | 5F61EC | white on fill | 4.47 | 4.76 |
| primaryGradient stop 2 | light | 8B5CF6 | 8757F1 | white on fill | 4.23 | 4.50 |
| incomeGradient stop 1 | light | 10B981 | 006E4B | white on fill | 2.54 | 6.30 |
| incomeGradient stop 2 | light | 34D399 | 05875E | white on fill | 1.92 | 4.53 |
| incomeGradient stop 1 | dark | 059669 | 056647 | white on fill | 3.77 | 7.00 |
| incomeGradient stop 2 | dark | 10B981 | 04875D | white on fill | 2.54 | 4.54 |
| expenseGradient stop 1 | light | EF4444 | C2021D | white on fill | 3.76 | 6.32 |
| expenseGradient stop 2 | light | F87171 | CC4A4D | white on fill | 2.77 | 4.51 |
| expenseGradient stop 1 | dark | DC2626 | CC0716 | white on fill | 4.83 | 5.82 |
| expenseGradient stop 2 | dark | EF4444 | DF3337 | white on fill | 3.76 | 4.50 |

Also: `textSecondaryOnTint` (`#4B5563` light, `#BEBED2` dark) for text on a
strongly tinted card (Spend drill-in total, Worth history hero);
`BudgieColor.legible(_:tint:)` mixes a pale chart colour towards the primary
text colour until it reads on its own tint (the Spend drill-in chips and the
Worth history Asset / Liability chip); the Spend rank palette and the wash and
glow of the Worth hero and editor banner keep Flutter's lighter values
(`chartAccent`, `chartIncome`, `chartDanger`, `chartWarning`); the home
screen widget's two white-labelled buttons and its mic circle were darkened
the same way. `BudgieAppTests/ColorContrastTests` asserts the pairs.

### Exclusions

Only these are accepted (audit type, element identifier or label, or where
the element is); everything else fails the test. Rows marked FOLLOW-UP are
findings that are not fixed, only accepted for now.

| # | Audit type | Matches | Screens | Reason |
|---|---|---|---|---|
| 1 | all | `inTabBar` | - | The system tab bar (UIKit; Liquid Glass on iOS 26). |
| 2 | contrast, dynamicType, textClipped | `nearTabBar` | - | Content scrolled under the floating tab bar: the audit reads it through the bar's scroll-edge blur. |
| 3 | contrast, dynamicType, textClipped | `scrollEdge` | - | A page scrolled to its bottom: the rows at its top edge fade out under the status bar and the navigation bar (some are partly off screen, y < 0), and those at the bottom sit under the tab bar's blur. The same elements are audited, at rest, in the page's top audit. |
| 4 | contrast | `labelPattern(".*")` | pages scrolled to the bottom | FOLLOW-UP: on a page scrolled to its bottom the screenshot that measures contrast is taken while the page may still be settling, so the pixel check cannot clear these (the page's top audit is checked at rest). |
| 5 | contrast | `disabled` | - | A disabled control (opacity 0.38): WCAG 1.4.3 exempts inactive components. |
| 6 | contrast | `pixelsAtLeast(4.5)` | - | The audit reports a failure, but the rendered pixels of the element measure at least 4.5:1 at rest (it sampled a glow, a border, a tinted tile or the anti-aliased edge of a thin 10-12pt glyph). |
| 7 | contrast | `labelPattern("^[0-9$.,€—-]$")` | ["Home", "Worth"] | Hero amount glyphs (RollingAmount): one node per rolling digit, drawn over a text glow (UI_SPEC Home hero). |
| 8 | elementDetection | `noElement` | sheets and dialogs, pages scrolled to the bottom pages, ["Flow", "Categories"] | FOLLOW-UP (name the regions): no element: the page behind a sheet or dialog is dimmed and hidden from accessibility while its text stays visible; on scrolled pages the text under the tab bar's blur. |
| 9 | textClipped | `labelPattern(".*")` | every sheet and dialog | FOLLOW-UP (give the sheets a scrollable large detent and re-audit): text in a bottom sheet or dialog: the audit scales text without growing the presentation, which is sized from its measured content (and scrolls); even a plain SwiftUI .sheet with a .medium detent is reported. Checked at accessibility-XXXL in the screenshots. |
| 10 | dynamicType | `labelPattern("^(1 transaction\|[0-9]+ transactions\|[A-Z][a-z]+ [0-9]{4})$")` | ["Spend drill-in"] | Chips inside a ViewThatFits: the same PillChip outside one passes (lab: two identical chips, one in a ViewThatFits flagged, one beside it not). |
| 11 | dynamicType | `labelPattern("^(Growth\|6M\|1Y\|ALL\|1M\|3M)$")` | ["Worth"] | The growth title and range pills sit in a ViewThatFits (beside each other, or stacked); see the chip row above. |
| 12 | hitRegion | `identifier("onboarding.dots")` | - | The tour's page indicator (8pt dots): one adjustable element (swipe up or down), not a tap target; the pages change by swiping and by Continue (48pt). |
| 13 | hitRegion, textClipped | `identifier("flow.all.search")` | - | The text field's own element is 19pt tall, inside a 56pt field whose whole area focuses it. |
| 14 | contrast, dynamicType | `labelPattern(".*")` | ["Data diagnostics", "Licences"] | FOLLOW-UP (restyle with design-system colours): system List pages (Section headers and rows in the system's own colours and fonts); not part of the design system. |
| 15 | textClipped | `labelPrefix("A11y Trip ")` | ["Goals"] | FOLLOW-UP (cap the name at two lines, ring above): a goal name wrapped over three lines beside the progress ring at XXXL (frame 83x145); complete in the XXXL screenshot. |
| 16 | textClipped | `noElement` | ["Worth", "Settings"] | FOLLOW-UP (find the element): the audit names no element; the XXXL screenshots of Worth and Settings show every label complete. |
| 17 | dynamicType | `labelPattern("^[0-9]{1,2}$")` | ["Date picker"] | Day numbers of the system UIDatePicker. |
| 18 | dynamicType | `labelPattern("^(Theme\|Light, dark, or match device\|Light\|Dark\|Auto)$")` | ["Settings"] | The theme row is capped at accessibility2 on purpose (dynamicTypeSize(...accessibility2)) so its pills stay on one line. |
| 19 | all | `inKeyboard` | - | The system software keyboard. |
| 20 | dynamicType | `inNavigationBar` | - | Titles and bar buttons in the system navigation bar: UIKit bar items, which scale to the bar's own cap. |

`pixelsAtLeast(4.5)` (row 6) is a rule, not a list: a contrast report is
accepted when the screenshot, taken after the screen has come to rest, shows
the element at 4.5:1 or better (the commonest colour in its frame against the
colour furthest from it; anti-aliasing can only lower this). Every contrast
issue on a static text that it does not clear is fixed or listed.
