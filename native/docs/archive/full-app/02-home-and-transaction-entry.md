> Archived; paths refer to the `flutter-final` tag.

# Home tab + transaction entry: analysis for the Swift full-replacement plan

Paths are relative to W (the worktree root). `F:` means `W/budget_app/lib/`, `N:` means `W/native/`. I read every file you listed in full, plus `design_system.dart`, the theme files, and the glow_*, pill_chip, budgie_header, modern_transaction_list_item, modern_text_field, recurring_form (head), categorization_rule, transaction_tag and main.dart (init/theme/deep links) sources. I also looked at the Flutter screenshots in `N:docs/research/screenshots/` (05, 05b, 11, 12, 13, 16) and the MVP screenshot `N:docs/screens/spending-1.png`.

## 0. Headline findings

- **The MVP Spending tab is a different screen from the Flutter Home.**
  - Flutter Home (`F:spending_page.dart:448-686`) has no month transaction list and no "Expenses by category" (that is the Spend tab).
  - Flutter Home has: hero cash flow, spend gauge, income/expense chips with month-over-month deltas, safe-to-spend card, Budgets, Recent activity (3 rows), two pill buttons, FAB.
  - The transaction list lives on a separate pushed page, `TransactionPage` ("SEE ALL").
- **Budgets are the biggest functional gap.**
  - `categoryBudgetLimits` is read-only in Swift (`FinancialData.budgetLimits` is `private(set)`, and no mutation, no `serialize` case and no view exists).
- **Category list divergence.**
  - Flutter's `expenseCategories` map is built from persisted definitions plus categories created at launch (`main.dart:272-290`) from transactions, recurring templates, and budget-limit keys.
  - Swift's `categoryPicker` (`N:BudgieCore/.../Categories.swift:104-110`) only adds names used by transactions.
  - So a budget key, or a template-only category, that has no definition shows a budget row in Flutter but not in Swift.
  - Fix in BudgieCore (see section 4).
- **`selectedMonth` is shared state in Flutter.**
  - `TransactionModel.selectedMonth` (`F:transaction_model.dart:152,231`; not persisted) is read by Home and the History tab (`F:history_page.dart:43,1300,2004`).
  - The MVP keeps it as `@State` in SpendingView. It must move to `AppModel`.
- **Categorization rules and tags are not ported.**
  - The Flutter form applies them while typing (`F:transaction_form.dart:106-121`), and Swift lacks the parsing and matching logic.

## 1. Feature inventory: Flutter Home (`SpendingPage`)

### 1.1 Data and calculations on every rebuild (`spending_page.dart:450-485`)

- **Month.** `selectedMonth` is the model's, initialised to `DateTime.now()`, and normalised to `DateTime(y, m)` for calculations.
- **Totals.** `totalIncome` / `totalExpenses` are the month ledger sums over all transactions whose `date` is in that month (`year*12+month` key, list order; `transaction_model.dart:199-228,263-270`).
- **Recent transactions.** `getRecentTransactions(3)` takes the 3 newest across ALL months, not the selected one. Order is `compareNewestFirst`: day desc, then createdAt desc, then id desc (`transaction.dart:75-81`).
- **Safe to spend.**
  - `SafeToSpendCalculator.calculate(month: selected, asOf: DateTime.now())`, with `wallClock` equal to now.
  - Swift `SafeToSpend.calculate` is already a port, including the same-day and DST quirks (Q1).
- **Previous month.**
  - `DateTime(y, m-1)`, so January wraps to December of the prior year.
  - `getMonthlySummary` gives income and expenses.
  - `_percentDelta(cur, prev)` (`spending_page.dart:339-345`):
    - prev == 0 and cur == 0 gives null.
    - prev == 0 and cur != 0 gives +100.
    - Otherwise `(cur - prev) / prev * 100`.
  - `previousMonthLabel` is `DateFormat.MMMM` of the previous month, en_US.
- **Budget rows** (`_buildBudgetProgressItems`, `:107-136`).
  - Iterate `expenseCategories.keys` (active expense definitions in sort order plus launch-created legacy ones).
  - Keep those with `limit != null && limit > 0`.
  - `spent = categoryExpenses[category]` for the selected month. This is an exact, case-sensitive category-string match.
  - Sort by spent descending, then `category.compareTo` (UTF-16 code-unit order).
  - Limits belonging to archived or renamed categories that are not in the map are hidden here but still count in the safe-to-spend flexible reserve.

### 1.2 Sections in order (`spending_page.dart:521-680`)

1. **Header** (`budgie_header.dart`).
   - Left: the Budgie logo, 36x36, radius 12 (`assets/budgie_mark.png`).
   - Centre: `MonthPill`, labelled `DateFormat.yMMMM(selectedMonth)` (e.g. "September 2026"). Tap toggles the inline picker panel and fires a light haptic.
   - Right: a 36px empty spacer.
2. **Month picker panel** (`:1001-1054`).
   - `AnimatedSize` 250 ms easeInOut (0 ms under Reduce Motion), collapsed to nothing when closed.
   - Padding (20,12,20,0).
   - Contains a `GlowCard` (padding v8) with a 128px-high `CupertinoPicker`, itemExtent 34, and 12 month names ("January".."December") in `rowTitle` 16.
   - `onSelectedItemChanged` calls `selectMonth(DateTime(selectedMonth.year, index+1))` immediately on scroll settle. The panel stays open.
   - The year cannot be changed from Home. It only changes via History's month sheet, which mutates the same model.
   - The wheel's initial item is the current calendar month, captured once. It goes stale if History changes the month.
3. **Hero cash flow** (`:1093-1217`).
   - `cashFlow = income - expenses`.
   - The eyebrow is "CASH FLOW".
   - The amount shows `format(abs(cashFlow))` (two decimals, never a minus sign). It uses the danger colour and danger glow when negative; otherwise primary text and accent glow.
   - Rolling odometer digits over 900 ms (`animated_digit`), with currency prefix/suffix and separators taken from the formatter. The rolling widget is used only when balances are not hidden; hidden shows plain "••••".
   - A transparent Text underneath carries the halo, because the rolling cells clip shadows.
   - Subline: `"$3,200 in   ·   $43 out"` (0 decimals, three spaces each side of the middle dot).
   - Status caption: "SAVED THIS MONTH" (accent) when > 0; "SHORT THIS MONTH" (danger) when < 0; "BREAKING EVEN" (accent) when == 0.
   - Semantics: "Cash flow, $X this month." or "Cash flow, $X short this month."
4. **Spend gauge** (`:1388-1461`).
   - `value = income <= 0 ? 0 : spent / income`, clamped 0..1 by the bar.
   - Labels below: "SPENT  $43" on the left and "INCOME  $3,200" on the right (0 decimals). They use `monoLabel`: the prefix is tertiary colour and the value is primary text colour.
5. **Flow chips** (`:1465-1550`). Two equal cards, "Income" (green dot) and "Expenses" (rose dot).
   - Amount with 0 decimals.
   - Delta line: `"+100.0% vs August"` (the sign is "+" when delta >= 0, then `toStringAsFixed(1)`), or "No August data" (tertiary colour) when the delta is null.
   - Delta text is always green for the Income chip and always danger for the Expenses chip, regardless of direction.
6. **Safe-to-spend card** (`:1222-1328`). Tap opens the breakdown sheet.
   - Title and amount: over-committed shows "Projected shortfall" with `overCommitment`, otherwise "Safe to spend" with `safeToSpend` (0 decimals).
   - Subtitle:
     - `days <= 0`: "This month is already closed out"
     - over-committed: "Add income or reduce planned spending"
     - otherwise: "$X/day for N days left" ("1 day left" singular).
   - Icon: `shield_rounded` (accent) or `warning_rounded` (danger).
   - A "DETAILS >" affordance sits under the amount.
   - Semantics: "$title $amount. $subtitle. Double tap for breakdown."
7. **Budgets**. Section header "Budgets" with an "EDIT" link, then `_BudgetsCard`.
8. **Recent activity**. Section header "Recent activity" with a "SEE ALL" link (pushes `TransactionPage`), then `_RecentActivityCard`.
9. **Action pills**. "Expense" (danger, `remove_rounded`) and "Income" (green, `add_rounded`), both opening the form.
10. **FAB stack** (bottom-right, above the dock).
    - Mic FAB (44px, mobile only): "Add by voice", starts the voice flow.
    - Add FAB (54px): tap opens the expense form; long-press opens the quick category sheet. Semantic label "Add transaction".

### 1.3 Budgets feature end to end

- **Card.** `GlowListCard` containing one `_BudgetRow` per budgeted category, then an "Add a budget" row.
  - The Add row shows only if `budgets.length < expenseCategories.length`.
  - Its subtitle is "No monthly limits yet" when there are no budgets, otherwise "Set a limit for another category".
- **Row.**
  - Tap opens the limit sheet (light haptic).
  - Contents: IconTile in the status colour, category name, subtitle, status `PillChip`, and an 8px `GlowProgressBar` in the status colour.
  - Subtitle: `"$spent of $limit"`.
  - Currency helper: 0 decimals if `abs(value) >= 100`, else 2 decimals.
- **Progress and states.**
  - `progress = spent / limit`; the bar clamps to 0..1.
  - `remaining = limit - spent`.
  - Over budget means `remaining < 0`, i.e. spent > limit strictly. Spent == limit gives "$0.00 left" in warning colour.
  - Status colour: over is danger; `progress >= 0.85` is warning; otherwise income green. The unreachable "no limit" branch uses accent with an outlined "Set limit" chip.
  - Chip text: "$X over" (abs of remaining, tinted) or "$X left".
- **EDIT link** (`_showEditBudgetsSheet`, `:173-198`).
  - Opens a bottom sheet titled "Edit budgets" listing the budgeted categories in category order (not sorted by spent).
  - Subtitle: "Tap a budget to change or remove its monthly limit." when there are budgets, otherwise "No monthly limits yet. Add one to start tracking a category."
  - Each tile shows the icon (accent tint), the name, and "$X limit" (0 decimals), with a chevron.
  - Plus an "Add a budget" row when `budgeted.length < all`.
  - Picking a tile closes the picker, then opens the limit sheet. Picking Add opens the Add sheet.
- **Add a budget sheet.**
  - Titled "Add a budget", subtitle "Choose a category to set a monthly limit.", listing the unbudgeted categories.
  - A pick opens the limit sheet.
  - Chrome (shared): background card colour, 1px card border, 28px top radius, grab handle 44x4, max height 75% of the screen.
- **Limit sheet** (`_BudgetLimitSheet`, `:811-999`).
  - Header: IconTile (danger) plus the category name (`cardTitle`) and "Monthly spending limit".
  - Field: numeric decimal keyboard, autofocus, labelled "Limit", prefix "$" hard-coded (not currency-aware), hint "0.00", helper "Set a positive amount for this category.".
  - Prefill: `formatNumber(limit, 2)` (grouped, e.g. "1,500.00"), empty when there is no limit.
  - Parse: strip everything except `[0-9.]`, then `double.tryParse`.
    - This is a latent bug for non-en_US locales, where "1.500,00" parses as 1.5.
    - The parse also accepts junk like "1.2.3", which yields null.
  - Save is enabled iff `!isSaving && parsed > 0`; the field's submit key also saves.
  - Remove ("Remove", trash icon, secondary) appears only when a limit exists.
  - Save has a spinner while saving; Remove and Save both dismiss after the awaited call resolves.
  - The sheet owns its `TextEditingController`.
- **Persistence.**
  - `setCategoryBudgetLimit` (`transaction_model.dart:750-767`):
    - Trims the category; ignores it if empty.
    - `limit <= 0` delegates to remove.
    - Otherwise `_categoryBudgetLimits = {..., category: limit}` (an existing key keeps its position, a new key is appended).
    - Then awaits `persistSections({categoryBudgetLimits: Map<String,double>})`, and calls `notifyListeners()` AFTER the write. Memory is assigned before the await.
    - Failure sets the section unsaved (the banner) and there is no toast.
  - `removeCategoryBudgetLimit` is a no-op if the key is missing, otherwise the same flow.
  - The whole map is rewritten from memory on any budget save.
  - On load, entries with limit <= 0 are removed from memory (`transaction_model.dart:413-420`), so they disappear on the next budget save.
  - JSON: `{"General":100.0,...}` with double lexemes.
  - No other section changes.

### 1.4 Recent activity (`:1706-1816`)

- Empty state: a `GlowCard` with centred "No transactions yet." (14px, secondary).
- Otherwise a `GlowListCard` of 3 non-interactive rows (they have no tap handler).
  - Padding 12.
  - IconTile 40:
    - Expense: category icon in accent tint (`expenseCategories[name]`, falling back to the grid icon).
    - Income: `south_west_rounded` in green.
  - Title: the description, or "Transaction" if empty.
  - Subtitle: "Category · MMMd" (e.g. "Salary · Sep 28").
  - Amount: `formatSigned(±amount, plusForPositive)` in `amountSmall` (15/700). Expense is primary text, "-$42.50"; income is green, "+$3,200.00".
  - Semantics: "desc, category, Sep 28, expense $X".

### 1.5 Safe-to-spend breakdown sheet (`:362-446`)

- Standard modal sheet with the drag handle (not the custom chrome). Padding (24,8,24,24).
- Title: "Projected shortfall" or "Safe to spend", in `headingLarge` (28/bold).
- Blurb:
  - Over-committed: "What you have spent and reserved for the rest of this month is more than the income you expect."
  - Otherwise: "A forward-looking estimate for the rest of this month."
- Rows (label and signed value; the six rows plus the total):
  - Income recorded (+)
  - Income still expected (+)
  - Expenses recorded (−)
  - Upcoming recurring bills (−)
  - Flexible budget reserve (−)
  - Suggested goal contributions (−)
  - Divider, then the total row (bold, accent; danger when over-committed).
- Row value colour is secondary. The emphasised row uses w800.
- Footer (caption, secondary):
  - `days <= 0`: "This month is already closed out."
  - over-committed: "Add income or reduce planned spending to close the shortfall · N days remaining"
  - otherwise: "$X per day · N days remaining" (0 daily allowance formatted with 2 decimals; "1 day remaining" singular).
- The Swift sheet matches this text exactly.

### 1.6 Quick expense category sheet (`:692-803`)

- Opened by long-pressing the FAB. A `DraggableScrollableSheet`: initial 0.66, min 0.36, max 0.9; the custom chrome is the same as the budget picker.
- Title: "Add expense". Subtitle: "Choose a category, then enter the amount and description."
- Rows: an IconTile in danger tint, the name, and a chevron, with hairline separators. Semantics: "Choose <name>". Tapping fires a selection haptic.
- Choosing a category then opens the expense form with `initialCategory`. The form focuses Amount as usual.

### 1.7 Transactions page ("SEE ALL", `transaction_page.dart`)

- **Route.** A pushed page, AppBar "Transactions", centred, transparent.
- **Empty (no data at all).** `EmptyState.noData`, title "No Transactions Yet", message "Start tracking your finances by adding your first transaction", button "Add Transaction" (opens the expense form), icon `money_dollar_circle`.
- **Month selector** (`month_selector.dart`).
  - 84px bar with a horizontal scroll of 120x64 chips, one per `getAvailableMonths()` (months with data, newest first).
  - Chip: month abbreviation uppercased plus year. Selected chip: primary gradient (#6366F1 to 80%), border 2px primary, glow. Unselected: surface with border. Radius 12.
  - The selected chip auto-scrolls to centre on change.
  - Default selection is the newest month with data. It is local state and does NOT follow `model.selectedMonth`.
  - A selection fires a selection-click haptic.
- **Summary card** (`GlowCard`, padding 16): Income (green) and Expenses (danger), each labelled 13/600 with a 20px amount; a hairline divider; then "Net Cash Flow" (16/700) with `formatSigned(net)` at 20px, green when >= 0 and danger when < 0.
- **List.**
  - Empty month: "No Transactions" / "No transactions for this month", tray icon.
  - Otherwise sorted `compareNewestFirst` and grouped by `DateFormat.yMMMd` (e.g. "Sep 28, 2026").
  - Each group has a pinned 48px header with a pill chip (chip surface, border, radius 999, `monoLabel` secondary).
  - Item padding is 16 horizontal and 8 between rows; the bottom has dock clearance.
- **Row** (`ModernTransactionListItem`, an older design).
  - `ElevatedCard` (radius 16, elevation 2, padding 16).
  - 48x48 solid tile (radius 12) in expense/income colour (`AppColors.getExpense` / `getIncome`) with a white icon (24px).
  - Title is `bodyLarge` 17 w600 with a `RecurrenceIndicator` (a custom-painted oval-arrows glyph, 16x9.6) when `recurringTemplateId != null`.
  - Subtitle "Category • MMMd" in `caption`, tertiary.
  - Amount is UNSIGNED `format(amount)` in `headingMedium` (22) bold in expense/income colour.
  - Tap opens the edit form. Semantics: "desc, $X, category C, on <date>", hint "Double tap to edit, swipe left to delete".
- **Delete.**
  - End-to-start swipe with a red background and trash icon. Medium haptic at the threshold.
  - `CupertinoAlertDialog` "Delete Transaction" / "Are you sure you want to delete this transaction?" with Cancel and Delete (destructive).
  - On dismiss: a heavy haptic, then `deleteTransaction(t)` (fire-and-forget), then a floating snackbar "Transaction deleted" in danger colour, shown regardless of the save result.

### 1.8 Transaction form (`transaction_form.dart`)

**Presentation.**
- A centred `Dialog` (maxWidth 500, inset 24 horizontal and 16 vertical, radius 20, XL shadow, card colour).
- Barrier-dismissible unless `prefill != null`.
- Content scrolls; the button footer is pinned above the keyboard.
- Amount is autofocused post-frame.

**Entry points.**
- Type is fixed by the entry point: FAB, Expense pill, or quick-category sheet give expense; Income pill gives income; quick action, widget and deep link give whichever.
- There is NO type toggle in the form, so an edit cannot change type. The MVP's segmented "Expense/Income" control is an extra.
- The title reads "Add Expense" / "Add Income" even in edit mode (`:211-219`). The button reads "Add" or "Update".

**Fields, top to bottom.**
1. **Amount.**
   - `ModernTextField`: fixed caption label "Amount", hint "0.00", `attach_money` prefix icon, decimal keyboard.
   - Border colours: 1.5px normal, 2px primary when focused, error red when in error. An error row shows an icon and text.
   - Validation runs only on tapping Add (`validateForm`):
     - empty gives "Amount is required"
     - `double.tryParse(text)` null gives "Please enter a valid number"
     - `<= 0` gives "Amount must be greater than 0"
   - The error clears as soon as the amount is edited.
   - Dart's `tryParse` accepts forms like "1e3", ".5", "5." and "Infinity" (a Flutter quirk). It rejects "1,5".
2. **Description.**
   - Label "Description", hint "What was this for?", `description_outlined` icon.
   - Empty gives a non-blocking "Description is recommended" error text (set, but the dialog closes in the same frame, so it is effectively invisible).
   - Saved trimmed, and "Transaction" if empty.
3. **Category.**
   - Label "Category", then a 90px-high bordered `CupertinoPicker` wheel (itemExtent 32).
   - Each row has a solid 20px tile (expense `AppColors.expense` #EF4444, income #10B981, white icon) plus the name.
   - The default is the first category, or `initialCategory` if it exists in the map.
   - A selection fires a selection-click haptic.
   - In edit mode the stored category is kept even if it is no longer in the map (the picker index is then -1; the value survives).
   - The category list is `expenseCategories` / `incomeCategories` (active definitions in sort order plus legacy names).
4. **Tags.** A "Tags" label plus `FilterChip`s, shown only if any `transactionTags` exist. Selected ids are a Set (insertion order).
5. **Date tile.**
   - `event_rounded` icon, "Date" (12px), value `DateFormat('MMM dd, yyyy')` (e.g. "Sep 05, 2026", zero-padded day), chevron.
   - Chip surface, radius 14, card border.
   - Opens the Material `showDatePicker`: initial is the selected date, range 2000-01-01 to now.
   - A picked date is stored at midnight; an untouched date keeps `DateTime.now()` (with time) for a new entry, or the stored date for an edit.

**Auto-categorisation** (`applySuggestion`, on every keystroke in Amount or Description).
- If a rule matches, it overwrites `category` AND replaces the selected tags, discarding any manual tag toggles.
- It runs only if `suggestion.category` exists in the current map.
- Amount is parsed with `double.tryParse(text) ?? 0`.
- Rule match (`categorization_rule.dart:72-89`):
  - disabled, or an empty pattern: no match
  - `transactionType` mismatch: no match
  - `amount < min` or `amount > max`: no match
  - `description.trim().toLowerCase()` compared with `pattern.toLowerCase()` by contains, startsWith, or exact
- `rules` are sorted by priority descending, and the first match wins.
- The same suggestion also runs on `prefill` (the voice draft path).

**Footer.**
- Cancel (secondary, disabled while saving) and Add/Update (gradient: expense red or income green; spinner while saving).
- Below, a pill "Make this recurring" (repeat icon).
  - It is hidden when `prefill != null`, but shown in edit mode too (a quirk).
  - It closes the form and opens the recurring form for the same type, with no values carried over.

**Save** (`:440-530`).
- Add: `addTransaction(type, description|'Transaction', amount, category, date, tagIds)`, awaited. The form pops after the await.
- Edit: `updateTransaction(id, copyWith(type, description, amount, category, date, tagIds))`.
- After a failed write, a floating snackbar in danger colour with an 8 s duration and a Retry action: "Couldn't save to this device. The entry is kept in memory until Retry succeeds."
- After a successful ADD whose date's month != `model.selectedMonth`, a success snackbar reads "Added to <MMMM>" (or "<MMMM yyyy>" when not the current year).
- Persistence:
  - `transactions` section (whole list; `updatedAt` is now, or old + 1 µs if not after the old one; `createdAt` and `recurringTemplateId` kept).
  - Then the widget cash-flow sync writes App Group `cashFlow` and `cashFlowMonth`.
  - No other sections change.

## 2. Layout and visual spec (rebuild-ready)

- **Fonts.** Gabarito (400/500/600/700/800/900) and Spline Sans Mono (400/500/600) are bundled from `budget_app/assets/fonts/`.
  - Everything not in the redesign styles falls back to the theme `fontFamily` (Gabarito), so nearly all text is Gabarito.
  - The Swift MVP uses the system font. The `.ttf` files must be copied into the native target, with `UIAppFonts` added in `project.yml`, and used with `relativeTo:` for Dynamic Type.
- **Tokens.** Accent, income, danger, warning, background and card already match `Theme.swift`. Missing from it:
  - dark: text primary #F2F2FA, secondary #9A9AB5, tertiary #5C5C78; card border white 7% (#12FFFFFF), hairline white 6%; track #1B1B2C; chip surface #15151F
  - light: text #111827 / #6B7280 / #9CA3AF; card border ink 8% (#14101020), hairline #10101020; track #E9E9F1; chip surface #F1F1F7
  - onAccent: #0A0A12 in dark, white in light
- **Page.**
  - Solid `background`, no nav bar. Content padding: top safe area; bottom `max(20, safeBottom) + 96`.
  - Cards are `GlowCard`: fill `card`, 1px card border, radius 26 (22 for chips and the safe card, 20 for the form). Press scales to 0.98 over 120 ms.
  - `GlowListCard`: padding 8, 1px hairline separators inset 12 horizontally.
  - `IconTile`: 40x40, radius 14, fill colour at 13% alpha, 20px icon, weight 500.
  - Section spacing:
    - header top 12
    - hero top padding 36, then a 20 gap to the gauge (horizontal padding 24)
    - 20 gap to the chips (horizontal 20, 12 between)
    - 12 gap to the safe card
    - 28 to Budgets, 28 to Recent activity, 24 to the pills; horizontal padding 20 for all of them
- **Type styles** (Gabarito unless noted; sizes/weights):
  - hero 58/800, ls -2, tabular
  - chipAmount 24/700, ls -0.5
  - sectionHeader 20/700, ls -0.3
  - cardTitle 17/700
  - rowTitle 15/600
  - rowSubtitle 12/400
  - amountSmall 15/700
  - badge 12/700
  - eyebrow: mono 11/600, ls 2.4
  - monoLabel: mono 11/500, ls 1
  - monoLink: mono 11/600, ls 1.5
  - caption 13; captionSmall 11
- **Glow.**
  - Dark: coloured `BoxShadow` with blur B and alpha A. SwiftUI `.shadow(color:radius:)` is roughly radius = B/2.
  - Light: the glow is dropped and replaced by a soft shadow, colour@25%, blur B*0.6, offset y 4.
  - Hero text glow: blur 48 at 45% (light: 18%).
  - FAB: accent glow 32/0.55 plus a black shadow with blur 28 at y 12, alpha 0.5.
- **Gauge.**
  - Track: height 14, chip surface, 1px hairline border, radius 999.
  - Fill: inset 2, gradient from `accent@55%` blended over the background to `accent`, glow blur 12 at 0.6.
  - Thumb: a 14px circle in #F2F2FA (light: white with a 2px accent@60% border) with an accent glow.
  - The thumb is clamped to stay inside the track.
  - Animates 0 to value over 800 ms easeInOutCubic on entry, then animates on changes.
- **Budget bar.** Height 8, track `getTrack`, fill in the status colour with a glow.
- **PillChip.** Padding 10/5, radius 999, fill colour@14%, text `badge` in the colour. The outlined variant has a colour@40% border.
- **PillButton** (Expense/Income). Height 52, radius 999, fill colour@10%, 1px border colour@35%, 20px icon plus an 8px gap, label 15/700 in the colour. Press scales to 0.96.
- **FAB.** 54px circle in accent, `add` icon 26px in onAccent.
  - Entry scale 300 ms easeOutBack.
  - Tap burst: a ping ring expanding to 1.7x with a fading 2px stroke, a glow flare, and an icon pop of up to 1.22x, all 500 ms.
  - Skipped under Reduce Motion.
  - Placement: right 20; bottom = `max(20, safeBottom) + 72`. The mic FAB (44) sits above it with a 12 gap.
- **Form card.**
  - Padding 16, radius 20, card colour.
  - Title centred 22/600. Field gap 8; label 13/600, secondary.
  - Field container: card fill, radius 12, 1.5px border.
  - Category wheel box: 90 high, radius 12, 1.5px border.
  - Tag chips are Material `FilterChip`s.
  - Footer: Cancel and Add side by side (48 high, radius 12, secondary has a 1.5px 30% border).
  - The gradients are red `#EF4444`→`#F87171` (light) / `#DC2626`→`#EF4444` (dark), and the income equivalents `#10B981→#34D399` / `#059669→#10B981`.
- **Haptics.** Light on taps, selection on pickers / long-press / FAB long-press, medium at swipe threshold, heavy on delete.
- **Reduce Motion.** Hero digits and the month panel drop to 0 ms; the FAB burst is skipped. Gauge and progress fills also skip via `disableAnimations`.

## 3. Gap versus the Swift MVP

| Area | Swift MVP today | Flutter |
|---|---|---|
| Overall look | `List`/`Form`, system fonts, system tab bar, Theme tokens only | Custom dark design, Gabarito/mono, glow cards |
| Header and month | Chevron/menu selector, month is `@State` | Logo + pill + wheel (year-locked), month is shared model state |
| Hero, gauge, flow chips, deltas | Missing (basic income/expenses/net card) | All present |
| Safe-to-spend card | Present, same copy, `tint.opacity(0.15)` tile | Same logic; visual restyle only |
| Breakdown sheet | Present, text parity (`SpendingSafeToSpendSheet.swift:47-55`) | OK; restyle |
| Budgets (card, EDIT, Add, limit sheet, remove) | Missing (read-only in safe-to-spend) | Full feature |
| Recent activity | Missing | 3 latest, all months |
| Month transactions list, "Expenses by category" | On Spending (`SpendingView.swift:100-134`) | Not on Home. List is `TransactionPage`; categories live in the Spend tab |
| SEE ALL page | Missing (History tab is a separate day-grouped list) | Month chips, summary, sticky day headers |
| Delete UX | `confirmationDialog` | `CupertinoAlertDialog`, "Transaction deleted" snackbar |
| Action pills, FAB + long-press quick sheet | Toolbar "+" menu only | Present |
| Voice (mic FAB) | Removed by decision | Present |
| Form: layout | Grouped `Form` sheet | Card dialog, wheel picker, date tile |
| Form: type | Segmented control | No control (entry point decides) |
| Form: title / buttons | "Edit Transaction" / "Save" | "Add Expense/Income" always; "Add"/"Update" |
| Form: validation | Silent (Save disabled; footer "Enter an amount greater than 0.") | Three specific messages on Add tap |
| Form: amount parse | Locale separator accepted, non-finite rejected, `.5`/`5.` OK | `double.tryParse` on the raw text |
| Form: tags, auto-categorisation | Missing (tags on existing rows preserved) | Present |
| Form: "Make this recurring" | Missing | Present |
| Form: date | `DatePicker` compact, semantics match | Material dialog; store at midnight when picked |
| Save-failure toast, "Added to <Month>" toast | Missing (banner only) | Snackbars (Retry action on failure) |
| Category list | Definitions + transaction names | Also template names + budget keys (`main.dart:272-290`) |
| Widget | Same values | Same |

Matches to keep: date semantics, "Transaction" default, `amountText == toStringAsFixed(2)` keeps the stored value on edit, delete-from-form, `interactiveDismissDisabled`, and the unsaved banner.

## 4. Required BudgieCore additions

All go in `N:BudgieCore/Sources/BudgieCore/Domain/`. Every mutation is pure (a `FinancialData` mutating func); persistence stays in `AppModel`.

1. **Budget limits mutations** (`FinancialData`).
   - `budgetLimitsSection() -> JSONValue`.
   - `@discardableResult mutating func setBudgetLimit(category: String, limit: Double) -> Bool`.
     - Trims the category; empty gives false.
     - `limit <= 0` removes.
     - Non-finite is rejected.
     - Otherwise it updates `budgetLimits` in place (an existing key keeps its position, a new key is appended, exactly like `{...old, key: v}`) and patches `sections[categoryBudgetLimits]` with `.double(limit)`.
   - `@discardableResult mutating func removeBudgetLimit(category: String) -> Bool`. False (no write) if the key is absent, matching Dart's early return.
   - Patch in place rather than rewriting the whole map: it keeps untouched lexemes, and Dart's load tolerates them. Dart itself rewrites the whole map with doubles, dropping entries <= 0 on the next budget save.
   - **Gotcha:** `noteWritten` is unused today, so `data.sections` is stale after a write. `AppModel.serialize` must add `case Section.categoryBudgetLimits: data.budgetLimitsSection()`, or the tracker's retry would re-serialize the stale section.
2. **Budget progress.**
   - `struct BudgetProgress { category, spent, limit; remaining, progress, isOver (remaining < 0), status: .ok/.warning(>= 0.85)/.over }`.
   - `FinancialData.budgetProgress(forMonth:) -> [BudgetProgress]`. Names come from the expense category list (section 4.4 semantics); spent comes from `totals(forMonth:).categoryExpenses`, an exact string match; sort by spent desc, then UTF-16 code-unit name order.
   - Plus `budgetedCategoryNames()` and `unbudgetedCategoryNames()` in list order, for the EDIT and Add pickers.
3. **Home summary helpers** (new `HomeSummary.swift`).
   - `previousMonth(of:)` via `calendar.date(y, m-1)`.
   - `percentDelta(current:previous:)` with the exact 0/0, prev == 0 and normal cases from section 1.1.
   - `deltaLabel(...)` using `DartFixed.toStringAsFixed(1)`.
   - `recentTransactions(limit:)`, taking the prefix of `transactionsNewestFirst`. Add a ledger cache (see Risks).
4. **Category names.** Change `categoryPicker(for:)` so `usedNames` = transaction names (existing order), then recurring template names of that type, then (expense only) the keys of the budget limits, deduped case-insensitively (Dart `_containsName`). This is not persisted (Swift never writes the `categories` section). Whoever builds category management must materialise these definitions before editing.
5. **Categorisation.**
   - `TransactionTagRecord { id, name, colorToken }` (read-only for now).
   - `CategorizationRuleRecord` with lossless `parse`, default values as in `fromJson` (`matchType` defaults to contains, `category` to "General", `priority` 0, `isEnabled` true), and `matches(type:description:amount:)` exactly as `categorization_rule.dart:72-89`.
   - `FinancialData.tags` / `rules` read from the sections `transactionTags` / `categorizationRules` (the legacy bare keys are already migrated by `LegacyMigration.swift:60-61`).
   - `CategorizationEngine.suggest(rules:type:description:amount:) -> Rule?`: priority descending with `DartSort` (Dart's `List.sort`: stable up to 33 elements, its quicksort's tie order from 34), first match wins.
6. **Tag IDs on edits.**
   - `TransactionRecord.Edit` gains `tagIds: [String]?`. `applying` writes `raw["tagIds"]` only if it changed (order-preserving).
   - `FinancialData.addTransaction` already accepts `tagIds`; `AppModel.addTransaction` must forward it.

**Parity tests** (`N:BudgieCore/Tests/BudgieCoreTests`, plus Dart fixtures via `N:ParityHarness` like the existing `DomainParityTests`):
- Budget set/remove sequences produce byte-identical `categoryBudgetLimits` JSON, checked through the Dart harness `verify_swift_output`.
- Cases: new key appended; existing key kept in position; `limit <= 0` removes; a trimmed category; an empty category is a no-op; removing a missing key returns false and writes nothing.
- Number lexeme: `100.0`, plus a stored int lexeme `100` being left untouched when other keys are patched.
- Budget progress: the sort tie-break, exactly equal spent == limit (not over), ratios around 0.85, and a category that exists in limits but not in the categories list.
- `percentDelta` table (0/0, 0/x, negative previous, rounding at `.05` through `toStringAsFixed(1)`).
- Rule matching table (trim, case, boundaries inclusive, type filter, disabled, empty pattern, priority order).
- Category list including template and budget-key names.
- Edit `tagIds`: only touched when changed, order preserved, other keys untouched.

**AppModel API additions** (`N:Budgie/App/AppModel.swift`):
```swift
// Shared, in-memory, not persisted (Flutter TransactionModel.selectedMonth)
private(set) var selectedMonth: DartDateTime          // starts calendar.month(of: now)
func selectMonth(_ month: DartDateTime)

// Budgets: memory first, awaited verified write, unsaved flag via persist([Section.categoryBudgetLimits])
func budgetLimit(for category: String) -> Double?
@discardableResult func setBudgetLimit(category: String, limit: Double) async -> Bool
@discardableResult func removeBudgetLimit(category: String) async -> Bool
func budgetProgress(forMonth month: DartDateTime) -> [BudgetProgress]
func budgetedCategories() -> [CategoryInfo]
func unbudgetedCategories() -> [CategoryInfo]

// Transactions
@discardableResult func addTransaction(type:description:amount:category:date:tagIds: [String] = []) async -> Bool
// updateTransaction(id:_ edit:) unchanged; Edit gains tagIds

// Categorisation and tags
var tags: [TransactionTagRecord] { get }
func suggestion(type: TransactionType, description: String, amountText: String) -> CategorizationRuleRecord?

// Toasts (root overlay hosted in MainView)
var toast: Toast? { get }
func showToast(_ toast: Toast)   // .savedElsewhere(month), .saveFailed, .deleted
```
- Add `Section.categoryBudgetLimits` to `serialize`.
- The `persist` call sets `hasUnsavedChanges` and `lastSaveError`, and syncs the widget only for transactions.

## 5. SwiftUI view breakdown and build sequence

Shared design-system files (probably owned by another analyst; Home depends on them). Put them in `N:Budgie/Views/DesignSystem/`:
- Fonts and `Font.budgie...` styles.
- `GlowCard`, `GlowListCard`, `IconTile`, `PillChip`, `PillButton`, `GlowProgressBar` (with gradient and thumb), `SectionHeader`, `MonthPill`, `GlowFab`, `BudgieSheetChrome` (handle, radius 28).
- Extended `Theme` tokens from section 2.

Home files (`N:Budgie/Views/Home/`):
- `HomeView.swift` (replaces `SpendingView.swift`): a `ScrollView`/`LazyVStack`, not a `List`, with `HomeHeader`, `MonthPickerPanel`, `HeroCashFlow`, `SpendGauge`, `FlowChip`, `SafeToSpendCard`, `BudgetsSection`, `RecentActivityCard`, `HomeActionPills`, and `AddFab` (overlay).
- `SafeToSpendSheet.swift` (reuse the existing sheet, restyle).
- `BudgetsSection.swift`: `BudgetsCard`, `BudgetRow`, `AddBudgetRow`.
- `BudgetCategoryPickerSheet.swift` (shared by Edit and Add) and `BudgetLimitSheet.swift`.
- `QuickExpenseSheet.swift`.
- `TransactionsView.swift` (SEE ALL): `MonthChipBar`, `MonthlySummaryCard`, sticky day headers via `LazyVStack(pinnedViews:)`, `TransactionListRow` (the older solid-tile style, with a recurring glyph).
- `TransactionFormView.swift` (rewrite): `AmountField`, `DescriptionField`, `CategoryWheel`, `TagChips`, `DateTile`, `FormFooter`.
- `ToastHost` in `MainView`.

**Build order and effort:**
1. Core budget mutations, progress, home summary, category names, and `AppModel` (selectedMonth, budgets, tags, toasts, `serialize`) plus their parity tests. **M.**
2. Design system foundations: fonts, tokens, glow components. **M/L (shared).**
3. Home shell: header, month pill and wheel bound to `model.selectedMonth`, hero (`.contentTransition(.numericText())`), gauge, flow chips, safe card, action pills, FAB stack. **L.**
4. Budgets UI: card, rows, EDIT and Add pickers, limit sheet (+ tests). **M.**
5. Recent activity plus the `TransactionsView` (SEE ALL) with month chips, summary and swipe-to-delete with confirm. **M.**
6. Transaction form: restyle, validation messages, wheel, date tile, tags and auto-categorisation, toasts, "Make this recurring". **M/L.**
7. Quick expense sheet and long-press. **S.**
8. Update the UI tests (`N:BudgieUITests/MVPFlowUITests.swift` depends on "Add transaction", "Add Expense", "Amount", "Description", "Save"). **S.**
9. Visual QA against the Flutter screenshots in light and dark, Reduce Motion, and Dynamic Type. **M.**

## 6. Risks, hard-to-match behaviour, open questions

**Risks.**
- **Performance.** `FinancialData.monthLedger()` is recomputed on every call, a full pass over all transactions. Home body needs totals, the previous month, available months, the budget spent map, safe-to-spend and a sorted recent list. Add a versioned ledger cache in `AppModel` (like Dart's `_monthLedgerCache` / `_sortedTransactionsCache`), invalidated on any transaction mutation, or 10k rows will hitch.
- **Rolling hero digits.** `.contentTransition(.numericText())` will not match `animated_digit` exactly (900 ms per-digit roll with a halo drawn separately). Match approximately.
- **Glow rendering and Dynamic Type.** Many shadows in a scroll view can cost frames. Use `compositingGroup()` / `drawingGroup` sparingly. Custom fonts need `relativeTo:`; chip amounts use `FittedBox` scale-down, so use `.minimumScaleFactor`.
- **CupertinoPicker versus `Picker(.wheel)`.** Not pixel-identical (selection band, fade). The form's wheel sits inside a 90pt box with custom row views; test that it renders.
- **The dialog-style form.**
  - A true centred card needs a custom overlay or a `fullScreenCover` with a clear background.
  - The sheet route is lower risk. Recommend a sheet, sized at the `.large`/`.medium` detents with the same card content, unless the user wants the dialog look.
- **Currency and locale.**
  - The budget sheet's hard-coded "$" prefix and the strip-to-`[0-9.]` parser mis-handle non-en_US formats (a Flutter bug, e.g. "1.500,00" gives 1.5).
  - Do not port the bug. Recommend a currency-aware prefix and a locale-aware parser; needs a decision.
- **Deferred `ensureLegacyCategories`.** Swift computes synthetic categories but never writes them. That is compatible in both directions, but the category-management work must persist them first.
- **Same-day safe-to-spend quirk** stays reproduced (Q1). The Flutter screenshot 05 shows exactly this ("Projected shortfall $100" right after adding an expense).
- **Voice.**
  - The MVP removed it, and the FAB stack has a mic button. If the goal is truly "every feature", it needs an API-key decision (currently a fake key, per memory).
  - The form's `prefill` path (runs the rules, hides "Make this recurring", non-dismissible barrier) should exist in the Swift form even if voice is deferred.
- **Dock/FAB dependency.** FAB offset assumes the Flutter floating dock (72 above the dock). It changes if the tab bar is native.
- **Undo semantics.** The "Transaction deleted" snackbar has no undo. Same in Flutter.

**Open questions for the user.**
1. **Form presentation:** a bottom sheet (native, recommended) or a centred dialog card?
2. **Title:** keep "Add Expense" for edits (Flutter) or use "Edit …"? And drop the Type segmented control, so type is fixed by entry point like Flutter?
3. **Year navigation on Home:** the Flutter wheel is locked to the selected year (the MVP's chevron selector crosses years). Keep the pill + wheel and add a year stepper?
4. **Save-failure feedback for budgets:** Flutter shows only the banner. Add a toast like the transaction form?
5. **Budget limit input:** OK to fix the "$" prefix (use the base currency symbol) and the locale-aware parsing?
6. **Voice entry:** in scope for full replacement, or stay removed? (Decided in the MVP; not restated in your goal.)
7. **SEE ALL versus History tab:** the Flutter History tab is charts. The current MVP History list becomes `TransactionsView`; confirm the tab set is owned by the shell analyst.
8. **Tab label:** Flutter says "Home", the MVP says "Spending".

Key files: `F:spending_page.dart`, `F:transaction_form.dart`, `F:transaction_page.dart`, `F:safe_to_spend.dart`, `F:transaction_model.dart:231-270,275-308,441-480,729-870,966-995`, `F:categorization_rule.dart`, `F:main.dart:255-300`, `N:Budgie/Views/SpendingView.swift`, `N:Budgie/Views/TransactionFormView.swift`, `N:Budgie/App/AppModel.swift:180-243`, `N:BudgieCore/.../Domain/{FinancialData,Categories,SafeToSpend,Records}.swift`.
