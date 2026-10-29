> Archived; paths refer to the `flutter-final` tag.

# Analyst report: Insights, Onboarding, Recurring UI, Voice and Integrations

W = /Users/khatruong/Documents/GitHub/flutter-budget/.claude/worktrees/swiftui-mvp-migration-71aa05. All paths are relative to W. Read-only; nothing was changed. No API key value was read or printed.

## Cross-cutting findings (affect several areas)

1. **Insights are shown on the Flow ("Cash flow") tab, not on their own page.**
   - `LocalInsightsSection` is used at `budget_app/lib/history_page.dart:80`, between the metric strip and the Net cash flow card.
   - `InsightsPage` (`insights_page.dart`) is dead code (never pushed; confirmed in `native/docs/research/G_ui_inventory.md:14`). Do not port it.
   - The section uses the shared `TransactionModel.selectedMonth`, which the Spend page's month picker also sets (`transaction_model.dart:152, 232`). Swift keeps the month as a per-view `@State chosenMonth` (`SpendingView.swift:8`). Insights need a shared `AppModel.selectedMonth`, which is a shell/Spending decision.
2. **Sheets present above the lock overlay.**
   - `AppLockModifier` (`Budgie/Views/AppLock.swift:59-64`) draws the lock as an `.overlay` on the content. A `.sheet` from `MainView` sits above that overlay.
   - `MainView.swift:38-43` consumes `pendingAdd` as soon as the view appears, so a quick action or deep link on a locked cold launch shows the add form over the lock screen. It is only an empty form, but the same problem applies to the onboarding, voice and form sheets.
   - Fix: lift `unlocked` into `AppModel` (or an environment value) and only consume `pendingAdd` when unlocked. Present onboarding by swapping the root content inside `.appLock()`, not with `fullScreenCover`.
3. **The Flutter voice feature ships an OpenAI key inside the app binary.**
   - `.env` is a pubspec asset (`budget_app/pubspec.yaml:88`), so the key sits in `flutter_assets/.env` in the IPA and anyone can extract it.
   - A real `.env` exists in the main checkout (251 bytes). Your memory note says it held a placeholder. Confirm whether any App Store build (3.x) shipped a real key; if so, rotate it.
   - Voice is the app's only network feature. It contradicts onboarding page 1 ("Financial data and insights stay on this device…") and AGENTS.md ("offline-first").
4. **UI tests and rehearsal scripts assume no onboarding.**
   - `BudgieUITests/MVPFlowUITests.swift:13` does a fresh `app.launch()` and expects the tab bar.
   - `scripts/upgrade_rehearsal.py:364` already sets `flutter.onboarding_completed` true.
   - The preference reader uses `persistentDomain`, so a `-flutter.onboarding_completed YES` launch argument will not work. Add a DEBUG-only `BUDGIE_SKIP_ONBOARDING=1` environment hook, like the existing `BUDGIE_*` variables, or make the UI tests tap Skip.
5. **Fonts and design tokens.** Onboarding, insight cards and the voice sheet use Gabarito, plus SplineSansMono for eyebrows (`theme/app_typography.dart:8-9, 157-164`). `Theme.swift` has only colours. A design-system task must bundle the fonts and define card, section-header and eyebrow styles first. The tasks below assume `GlowCard`/`IconTile`/`SectionHeader` equivalents exist.

---

## A. Insights

### A1. Feature inventory (Flutter)

**Engine**: `budget_app/lib/insights/insight_engine.dart` (pure, no I/O, no clock).

`generate({transactions, categoryBudgetLimits, savingsGoals, selectedMonth, now, excludedIds={}, limit=3})` (lines 47-104):
- Returns `[]` if `limit <= 0`.
- `month = DateTime(selectedMonth.year, selectedMonth.month)`; `generatedDate` = midnight of `now` (unused by the UI).
- Candidates are concatenated in this order: duplicates, budgetPace, goalProgress, recurringChanges, negativeCashFlow, monthlySpendingChange, unusualTransactions, savingsRateTrend, consistentlyUnderBudget.
- Excluded ids are removed. The list is sorted by severity rank (urgent 0, warning 1, positive 2, info 3), then by `id.compareTo` (UTF-16 order). The first `limit` are kept.

The nine rules. `sameMonth` compares local year and month. Every "current month" figure sums expenses whose `date` falls in the selected month. `slug(s)` = trim, lowercase, `[^a-z0-9]+` → `-`, then strip leading/trailing `-` (lines 457-461).

| Type | Lines | Trigger and id | Copy and severity |
|---|---|---|---|
| budgetPace | 106-145 | Only if limits are non-empty and the selected month is the current month. `daysInMonth`; `elapsedRatio = clamp(now.day,1,daysInMonth)/daysInMonth`. Per limit with value > 0: `spent` = expenses in that category; `usedRatio = spent/limit`. Skip if `spent < 25 \|\| usedRatio < 0.65 \|\| usedRatio <= elapsedRatio + 0.15`. Id `budget-pace:<slug(category)>:<year>-<month>` (month not zero-padded). | Headline "`<Cat>` is ahead of budget pace". Explanation "You have used `N`% of this budget, while `M`% of the month has passed." (N = round(usedRatio·100), M = round(elapsedRatio·100)). Action "Review `<cat lowercased>` transactions". Severity urgent if `usedRatio >= 1`, else warning. |
| monthlySpendingChange | 147-180 | Current and previous month each have ≥3 expenses; previous total ≥50; `change = (cur−prev)/prev`; `abs(change) >= 0.2`. Id `monthly-change:<y>-<m>`. | "Spending is `P`% higher/lower" (P = round(abs·100)). "This compares expenses in the selected month with the previous month." Action "See what changed" / "Keep the momentum". Warning if higher, positive if lower. |
| unusualTransaction | 182-221 | Current-month expenses sorted by date desc. For the first candidate that qualifies: history = expenses in the same category with `date` before the candidate and NOT in the selected month, amount >0, sorted ascending. Need `history.length >= 4`, `median = _median(history)`, `amount >= 50` and `amount >= 2.5·median`. Emits one insight and stops. Id `unusual:<slug(cat)>:<yyyy-MM-dd of date>:<amount.toStringAsFixed(2)>`. | "Unusual `<cat lowercased>` expense". "`<description>` was `X.X`× your typical expense in this category." (`multiple.toStringAsFixed(1)`, U+00D7). Action "Check this transaction". Warning. |
| savingsRateTrend | 223-255 | Income >0 in both months; `rate = net/income`; `abs(delta) >= 0.08`. Id `savings-rate:<y>-<m>`. | "Savings rate is up/down `P` points" (P = round(abs(delta)·100)). "This is the share of income left after expenses compared with last month." Action "Keep the momentum" / "Review flexible spending". Positive if up, warning if down. |
| recurringAmountChange | 257-295 | Group ALL transactions by `recurringTemplateId`, sort each group by date desc, need ≥2, `previous.amount > 0`. Skip if `abs(change) < 0.05 && abs(latest−previous) < 5`. Id `recurring-change:<slug(templateId)>:<latest.year>-<latest.month>`. | "`<latest.description>` changed by `P`%". "The latest recurring amount is higher/lower than the previous occurrence." Action "Review the recurring transaction". Warning if higher, positive if lower. |
| consistentlyUnderBudget | 297-331 | Per limit >0: the three prior months (offsets 1-3) must each have spend >0 (else the ratios are cleared) and every `spent/limit < 0.7`. Id `under-budget:<slug(cat)>:<y>-<m>`. | "`<Cat>` has stayed under budget". "You used an average of `N`% of this budget over the last three full months." Action "Consider adjusting this budget". Positive. |
| goalBehindSchedule | 333-362 | Per non-completed goal: `duration = targetDate.difference(createdAt).inDays`, `elapsed = today.difference(createdAt).inDays`, skip if `duration <= 0 \|\| elapsed < 14`; `expected = clamp(elapsed/duration, 0, 1)`; skip if `goal.progress + 0.1 >= expected`. Id `goal-behind:<slug(goal.id)>`. | "`<name>` is behind schedule". "Progress is `progressPercent`%; about `E`% would keep this goal on pace." Action "Review this savings goal". Urgent if `targetDate.isBefore(today)`, else warning. |
| negativeCashFlow | 364-388 | Current and two prior months all have income >0 and net <0. Id `negative-flow:<y>-<m>`. | "Cash flow has been negative for 3 months". "Expenses exceeded recorded income in each of the last three months." Action "Review income and recurring expenses". Urgent. |
| possibleDuplicate | 390-422 | Within the selected month, key = `type.name : slug(description) : amount.toStringAsFixed(2) : local-midnight ISO` (e.g. `...:2026-07-04T00:00:00.000`). Every repeat after the first with the same key emits one insight. Id `duplicate:<key>`. | "Possible duplicate transaction". "`<description>` appears more than once with the same amount and date." Action "Review matching transactions". Warning. |

`supportingValues` (a `Map<String,double>`) is built but never displayed. Keep it in the Swift port only if you want a bit-exact differential test.

**UI**: `widgets/local_insights_section.dart`.
- The section renders nothing until preferences load, and nothing if there are no insights. It is recomputed on every model change: `DateTime.now()`, `excludedIds = dismissed ∪ {snoozed until > now}`, default limit 3.
- Layout, top to bottom:
  - `SectionHeader("Insights")` (20/700, ls −0.3, horizontal padding 4)
  - 12pt gap
  - 1-3 `_InsightCard`s, 10pt apart
  - 8pt gap
  - caption "Calculated privately on this device · Not financial advice" (13pt, tertiary text)
- Card (lines 156-219): `GlowCard` (radius 26, padding 20, card surface, 1px card border) containing a Row (top-aligned):
  - `IconTile` 40×40, radius 14, icon 20, colour @13% background.
  - 12pt gap.
  - Column: headline (rowTitle 15/600, primary text), 4pt, explanation (rowSubtitle 12/400, secondary text), 8pt, suggestedAction (caption 13, severity colour).
  - Trailing `PopupMenuButton`, "more_horiz" icon, tooltip "Insight options", items "Snooze for 30 days" and "Dismiss". No confirmation and no undo. There is nowhere to restore a dismissed insight.
- Severity colour: urgent = danger (light #EF4444, dark #FB7185), warning = warning (#F59E0B / #FBBF24), positive = income (#10B981 / #34D399), info = accent. These are the same tokens as `Theme.expense/warning/income/accent`.
- Icons (Material Symbols → suggested SF Symbols):

| Type | Flutter icon | SF Symbol |
|---|---|---|
| budgetPace | speed | `speedometer` |
| monthlySpendingChange | trending_up | `chart.line.uptrend.xyaxis` |
| unusualTransaction | notification_important | `exclamationmark.bubble.fill` |
| savingsRateTrend | savings | `banknote` |
| recurringAmountChange | repeat | `repeat` |
| consistentlyUnderBudget | thumb_up | `hand.thumbsup.fill` |
| goalBehindSchedule | flag | `flag.fill` |
| negativeCashFlow | trending_down | `chart.line.downtrend.xyaxis` |
| possibleDuplicate | content_copy | `doc.on.doc` |

**Persistence** (`local_insights_section.dart:21-93`). These are real preferences in the `flutter.` namespace, not store sections:
- `flutter.local_insights_dismissed_v1`: string list. Written as `_dismissedIds.toList()..sort()` (UTF-16 order). Ids are never pruned.
- `flutter.local_insights_snoozed_v1`: string holding JSON `{id: localISO8601}`, where the value is `DateTime.now().add(Duration(days:30)).toIso8601String()`. Entries are never pruned, and a dismiss does not clear a snooze.
- Load quirks to copy:
  - A non-map JSON value gives an empty map.
  - A non-String value throws mid-loop, and the entries added before the throw are kept.
  - An unparseable date string is skipped.
  - After a malformed load, the next snooze write replaces the whole pref with only the in-memory entries.
- Snooze comparison is `until.isAfter(now)`. A dismissal is permanent.
- Dismissed ids must stay byte-identical between the two apps for dismissals to carry over. That means the id formats above, `toStringAsFixed(2)` via `DartFixed`, and local ISO strings via `toIso8601String`.

**Tests in Flutter**: `budget_app/test/insight_engine_test.dart` has 7 tests (budget pace, duplicate id stability, recurring change, 3 negative months, goal behind, exclusions and limit, sparse data).

### A2. Gap vs Swift
Absent entirely. `MIGRATION_SPEC` D11 and `PARITY_GAPS.md:16` say "not shown; prefs untouched". Already available in BudgieCore: `FinancialData.budgetLimits` (values >0, stored order), `.savingsGoals` (`SavingsGoalRecord`, `Records.swift:459`), `.transactions`, `DartCalendar`, `DartDateTime.differenceInDays`/`adding(days:)`/`toIso8601String`, `DartFixed.toStringAsFixed`, `JSONValue`/`DartJSON`, `PreferencesStore` with `.stringList`.

### A3. BudgieCore and AppModel additions
New file `BudgieCore/Sources/BudgieCore/Insights/InsightEngine.swift`:
```swift
public enum InsightType: String, Sendable, CaseIterable { case budgetPace, monthlySpendingChange, unusualTransaction, savingsRateTrend, recurringAmountChange, consistentlyUnderBudget, goalBehindSchedule, negativeCashFlow, possibleDuplicate }
public enum InsightSeverity: Int, Sendable { case urgent = 0, warning, positive, info }   // rank = rawValue
public struct LocalInsight: Identifiable, Hashable, Sendable {
  public let id: String; type; severity; headline; explanation: String
  public let supportingValues: [(String, Double)]; suggestedAction: String }
public enum InsightEngine {
  public static func generate(transactions: [TransactionRecord], budgetLimits: [(String, Double)],
     savingsGoals: [SavingsGoalRecord], selectedMonth: DartDateTime, now: DartDateTime,
     excludedIDs: Set<String> = [], limit: Int = 3, calendar: DartCalendar) -> [LocalInsight]
}
```
- Add `SavingsGoalRecord.progress` and `progressPercent` (Dart `savings_goal.dart`: clamp(current/target, 0, 1), 0 if target ≤ 0; percent = round(progress·100)).
- Add an internal `dartSlug(_:)` helper.
- Use the UTF-16 comparator for the id tie-break (`Array(a.id.utf16).lexicographicallyPrecedes(...)`, as in `TransactionRecord.newestFirst`).
- Dart `.round()` is half away from zero, which matches Swift `.rounded()`.
- Use `DartSort`. Dart's `List.sort` is insertion sort (stable) up to 33 elements and an unstable quicksort from 34; exact-timestamp ties in `unusual`/`recurring` depend on it.
- Perf: `unusual` is O(monthExpenses×n). It is fine, but compute off the main thread (`FinancialData` is a value type, so pass a copy into a `Task`) and cache, as `HistoryView` does.

New file `Insights/InsightPreferences.swift`:
```swift
public struct InsightPreferences: Equatable, Sendable {
  public private(set) var dismissed: Set<String>; public private(set) var snoozed: [(id: String, until: DartDateTime)] // insertion order
  public static func load(from: PreferencesStore, calendar: DartCalendar) -> Self   // reproduces the load quirks above
  public func excludedIDs(now: DartDateTime) -> Set<String>
  public mutating func dismiss(_ id: String) -> PreferenceValue          // .stringList(sorted UTF-16)
  public mutating func snooze(_ id: String, now: DartDateTime, calendar:) -> PreferenceValue // .string(jsonEncode map), until = now.adding(days: 30)
}
```
Also add `PreferenceKey.localInsightsDismissed = flutter("local_insights_dismissed_v1")` and `localInsightsSnoozed = flutter("local_insights_snoozed_v1")`.

AppModel additions:
- Load `insightPrefs` in `bootstrap()` after the protected-data wait, next to `themeMode` at `AppModel.swift:97`.
- Add `@Observable var insights: [LocalInsight]` (or a small `InsightsModel`), refreshed on data revision, selected month, and dismiss/snooze.
- Add `func dismissInsight(_ id: String)` and `func snoozeInsight(_ id: String)`, which write the preference synchronously (`preferences.set`).
- Add `var selectedMonth: DartDateTime` (shared with Spending, see cross-cutting item 1).

**Parity tests**:
1. Port the 7 Dart tests to Swift Testing (`InsightEngineTests`).
2. Extend `native/ParityHarness/parity/logic_fixtures_test.dart` with an `insights` test, following the `safe_to_spend` and `safe_to_spend_random` pattern. Output goes to `Fixtures/logic/tz/<zone>/insights.json` and `insights_random.json`. Use a randomized corpus over the three time zones, including month-boundary timestamps 23:59:59.999, Unicode descriptions and categories, ≥32-row months, and duplicates. Keep the dates unique except in one deliberate tie test. Assert full equality of id, type, severity, headline, explanation, supportingValues (bit-for-bit via the lossless parser) and suggestedAction.
3. `InsightPreferences` codec tests: Dart `jsonEncode` vectors, the malformed-JSON quirk, sort order, and a dismiss/snooze round trip.
4. Add a `verify_swift_output_test.dart` step that loads the Swift-written prefs (if the harness reads prefs).

### A4. SwiftUI breakdown
- `InsightsSection` (a `View`, no NavigationLink; hidden if empty): `SectionHeader("Insights")`, a `VStack(spacing: 10)` of `InsightCard`, then the caption.
- `InsightCard`: card surface (shared Glow card style), `HStack(alignment: .top, spacing: 12)` with `IconTile(symbol, color)`, a `VStack(alignment: .leading)` (headline 15/600, explanation 12, action 13 in severity colour) and a trailing `Menu { Button("Snooze for 30 days"); Button("Dismiss") } label: { Image(systemName: "ellipsis") }`.
- Accessibility: `.accessibilityElement(children: .combine)`, plus `.accessibilityAction(named:)` for Snooze and Dismiss, and a menu label "Insight options".
- Placement: top of the Flow view (after the metric strip), as in Flutter. Until the Flow tab exists, put it at the top of `HistoryView`. `HistoryView` uses `List`, so use a `Section` with the card as a row (clear background, no separators). Coordinate with the History/Flow analyst.

### A5. Steps and effort
1. Core `dartSlug` + `SavingsGoalRecord.progress` (S).
2. `InsightEngine` port with 7 unit tests (L, about 500 lines of logic).
3. Harness differential fixtures and Swift comparison test (M).
4. `InsightPreferences` + tests (S).
5. AppModel state, `selectedMonth`, off-main compute (M).
6. `InsightsSection`/`InsightCard` views and the Flow/History hook (M, blocked on design tokens and the Flow tab).

### A6. Risks and open questions
- Id drift silently un-dismisses insights. The differential test is the mitigation.
- Where do insights live if the Flow tab is deferred? Recommendation: top of History as an interim.
- Should "Restore dismissed insights" exist in Settings? Flutter has none; recommendation: no.
- Dart's `toLowerCase` vs Swift `lowercased` can differ for exotic Unicode; the slug collapses non-ASCII to `-` anyway, so exposure is minimal. Include it in the fuzz corpus.

---

## B. Onboarding

### B1. Inventory
- **Gate**: `budget_app/lib/onboarding_tutorial.dart:11-71`, used in `main.dart:233-236` as `AppPrivacyGate(child: OnboardingTutorialGate(child: BudgetHomePage))`, after init succeeds and after unlock.
- **Preference**: `flutter.onboarding_completed` (Bool). `StorageKeys.onboardingCompleted = 'onboarding_completed'` (`storage/storage_keys.dart:48`). A missing key or a read error means show the tour. Completion is written in a `finally`, so the tour is dismissed even if the write fails. It never re-shows once true. Already exists as `PreferenceKey.onboardingCompleted`.
- **Loading state**: a spinner in the accent colour on the background while the flag is read (async in Flutter; synchronous in Swift, so no spinner is needed).
- **Pages** (lines 87-109), three; copy verbatim:
  1. icon wallet; eyebrow "WELCOME TO BUDGIE"; title "Your money, made clearer."; body "Budgie keeps your budget simple and private. Financial data and insights stay on this device unless you choose to export or share a backup."
  2. icon add_chart; "START HERE"; "Track what comes and goes."; "On Home, use the add button for income or expenses. Your balance and recent activity update as you go."
  3. icon insights; "EXPLORE WHEN READY"; "Plan ahead, then look back."; "Worth tracks accounts, Goals keeps savings in view, and Spend, Flow, and More help you understand and manage your budget."
- **Layout** (lines 146-236):
  - Background `AppColors.getBackground` (#F9FAFB light, #0A0A12 dark). SafeArea padding L24/S8/L24/L24.
  - "Skip" text button top-right, disabled while completing.
  - Swipeable `PageView`. Each page is centred: a 116pt circle (accent @14% with an accent glow of blur 32 α.25 in dark) holding a 52pt accent icon; 48pt gap; eyebrow (mono 11/600, ls 2.4, accent, uppercase); 16pt; title (28 bold, ls −0.3, primary); 16pt; body (17, height 1.45, secondary, max width 390, centred).
  - Page dots: an animated Row; the active dot is 22×8 accent, the others 8×8 in the border colour, margins 4, fully rounded. Semantics "Tutorial page N of 3".
  - 24pt gap, then a full-width 56pt `FilledButton` (accent fill, on-accent text, radius 16): "Continue" (advances the page, easeInOut) and "Start budgeting" on the last page. While completing it shows a 20pt spinner.
  - Skip and the last button both call complete.
  - Accent is `getAccent(isDark)`: #6366F1 in light, #818CF8 in dark. Screenshot: `native/docs/research/screenshots/01_onboarding_1_light.png`.
- **Tests in Flutter**: `test/onboarding_tutorial_test.dart` (first-launch flow, already-completed, skip, dark mode).
- **Copy dependencies**:
  - Page 2 says "Home" and page 3 says "Worth/Goals/Spend/Flow/More". If the native shell keeps its current tab names (Spending, History, Net Worth, Recurring, Settings), this copy is wrong. It must follow whatever tab names the shell analyst chooses.
  - If voice moves to OpenAI, the privacy sentence on page 1 stays false as written.

### B2. Gap
Never shown; the flag is untouched (`PARITY_GAPS.md:18`).

### B3. AppModel additions
- Read the flag in `bootstrap()` after the protected-data wait: `onboardingCompleted = preferences.bool(PreferenceKey.onboardingCompleted) ?? false`. Expose `private(set) var showsOnboarding: Bool`.
- `func completeOnboarding() { preferences.set(.bool(true), forKey: PreferenceKey.onboardingCompleted); … }`. The bool must be written as a CFBoolean; `UserDefaultsPreferences.set(.bool)` does this.
- DEBUG hook: `BUDGIE_SKIP_ONBOARDING=1`, read in `bootstrap()`.
- Parity test: `BudgieAppTests` checks that the written key is a real Bool (the existing `PreferencesTests` style) and that `false`/missing shows the tour and `true` does not.

### B4. SwiftUI breakdown
`OnboardingView`:
- `TabView(selection:)` with `.tabViewStyle(.page(indexDisplayMode: .never))`.
- Custom capsule dots with `.animation(.easeInOut(duration: 0.2))`.
- A `Button` in Flutter style: `.frame(height: 56)`, `RoundedRectangle(cornerRadius: 16)`, fill `Theme.accent`.
- A "Skip" text button.
- `OnboardingPage` (circle plus `Image(systemName:)` at 52pt with `.shadow` for dark, eyebrow, title, body).
- Symbols: `wallet.bifold.fill` (iOS 17), `chart.bar.xaxis`, `chart.line.uptrend.xyaxis`.
- `.accessibilityLabel("Tutorial page N of 3")` on each page and on the dot row.
- Present by swapping content inside `MainView`, before `.appLock()`: `if model.showsOnboarding { OnboardingView() } else { TabView… }`.
- Pending quick actions during the tour: keep `pendingAdd` set and consume it only after completion (Flutter would show the form over the tour, which is arguably a bug).

### B5. Steps and effort
1. AppModel flag, `completeOnboarding`, and the DEBUG skip hook (S).
2. `OnboardingView`, blocked on fonts and tokens (M).
3. UI test updates: set the hook in the existing tests and add an onboarding UI test (S).
4. Update `PARITY_GAPS.md` (S).

### B6. Risks and open questions
- Existing Flutter users carry the flag as true, so no tour (S1 rehearsal already checks this). A Flutter user with the flag missing sees it once, same as Flutter.
- Page copy depends on the final tab names.
- Reverting to the Flutter build after the Swift tour keeps the flag, so the tour is not shown twice.

---

## C. Recurring UI parity

### C1. Flutter inventory
**Entry points**:
- Only Settings → DATA card row "Recurring transactions" (`settings_page.dart:745-765`). Icon `repeat_rounded` in accent; subtitle `_recurringSubtitle` (lines 913-917): "No active recurring transactions", or "`N` active · `desc1, desc2, desc3`" (first three active descriptions); chevron; pushes `RecurringTransactionsPage` with a `CupertinoPageRoute`.
- Templates are otherwise created only via the "Make this recurring" link in the transaction form (`transaction_form.dart:537-562`). The link shows when `prefill == null` (add and edit) and is hidden for voice prefill. It closes the form and opens `showRecurringTransactionForm(context, type)` with defaults, not prefilled from the typed values. The Recurring page itself has no add button.
- Not a tab; Swift's `MainView.swift:24` currently has it as its own tab.

**Page** (`recurring_transactions_page.dart`): legacy visual generation (`native/docs/research/G_ui_inventory.md:9`). Screenshot `15_recurring_empty_dark.png`.
- Full-bleed indigo→violet gradient `ModernAppBar`: centred white title "Recurring Transactions", back chevron, and a right-hand refresh icon (tooltip "Generate Due Transactions"). The refresh runs `TransactionGenerator.generateDueTransactions()`, then shows a floating snackbar (income-green) "Due transactions generated and next occurrences updated".
- Empty state: 120pt primary-gradient circle with a 60pt white `repeat` icon, "No Recurring Transactions" (28 bold), "Create recurring transactions to automatically\ngenerate expenses and income on a schedule".
- List: stored order (not sorted), 16pt padding, 8pt separators, bottom padding for the dock.

**Card** (`ElevatedCard`, radius 16, elevation 2, padding 16; lines 227-366):
- Row: a 48×48 tile (radius 12) in solid expense red or income green with a white 24pt category icon (`expenseCategories`/`incomeCategories`, fallback `shopping_bag`/`attach_money`). Then the description (bodyLarge 17/600) followed by the `RecurrenceIndicator` (16pt), with the category (caption, tertiary) below. Then the amount (headingMedium, bold, type colour) via `MoneyFormatter.format`.
- 1px divider.
- Two detail columns: "Pattern" (repeat icon) showing Weekly / Bi-weekly / Monthly; and "Next Occurrence" (calendar icon) showing `MMM dd, yyyy` (zero-padded day).
- Two secondary small buttons: "Edit" (edit icon) and "Delete" (delete_outline icon).
- Delete alert: title "Delete Recurring Transaction?", body `This will stop generating future transactions for "<desc>". Previously generated transactions will not be affected.`, actions Cancel and Delete (red, bold). Snackbar afterwards: "Recurring transaction deleted". The delete future is not awaited (no save verification shown). There is no pause and no inactive display.

**`RecurrenceIndicator`** (`widgets/recurrence_indicator.dart`): a custom 1.5pt round-capped stroked glyph of two chevron-headed arcs forming an elongated oval (size × 0.6 tall), default colour secondary text. Shown on transaction rows when `transaction.isRecurring` (`modern_transaction_list_item.dart:122-125`, `category_transactions_page.dart:306`, plus the recurring cards). Swift has it nowhere (`grep isRecurring` finds nothing in `Budgie/Views`).

**Form** (`recurring_transaction_form.dart`): a centred dialog, max width 500, radius 20, XL shadow. Type is fixed by the caller, not selectable.
- Title "Add Recurring Expense|Income" or "Edit Recurring Expense|Income".
- Fields in order:
  - Amount (autofocus; hint "0.00"; prefix `$`-style icon)
  - Description (hint "What is this for?")
  - Category (90pt Cupertino wheel with icon tiles)
  - Recurrence Pattern (wheel: Weekly, Bi-weekly, Monthly; default Monthly)
  - Day of Month (wheel 1-31), or Day of Week (wheel Monday-Sunday) for weekly and biweekly
  - Start Date (tile "MMM dd, yyyy"; picker range today ±365 days; default `DateTime.now()` WITH time-of-day; a picked day is midnight)
  - Preview card "Next 3 Occurrences" (`EEEE, MMM dd, yyyy`)
  - Cancel / "Save" or "Update" (expense or income gradient)
- Validation, run on tap:
  - Amount: "Amount is required", "Please enter a valid number", "Amount must be greater than 0".
  - Description: "Description is required".
  - Start date: "Start date cannot be more than 1 year in the past" (blocks editing any template older than a year unless the date is changed).
- Preview (lines 713-761): first = `startDate` verbatim; weekly +7×24h, biweekly +14×24h (elapsed); monthly = next month at `min(dayOfMonth, daysInMonth)`, midnight. This is exactly the generator's arithmetic.
- **`dayOfWeek` is cosmetic**: it is stored, but neither the generator nor the preview uses it (`transaction_generator.dart:53-70`). The first occurrence is `startDate` even when `dayOfMonth` differs.
- Add: `addRecurringTransaction`, then `generator.generateDueTransactions()` immediately, without awaiting. Update: `updateRecurringTransaction(id, RecurringTransaction(…))` with `nextOccurrence` reset to `startDate` and `isActive` true. The Swift version deliberately differs (approved).
- Flutter `RecurringTransactionModel.renameCategory` (`recurring_transaction_model.dart:39-52`) rewrites template categories on rename. This is a hook for the category-management analyst.

### C2. Gap vs `Budgie/Views/RecurringView.swift`
Approved differences (KEEP, per `PARITY_GAPS.md` "Deliberate differences"): edit preserves cursor and paused state, pause/resume, an "Add" button on the Recurring page, generated rows and cursor saved in one write.

Gaps to close (not approved differences):
1. Placement: own tab; should be a pushed page from Settings DATA (row copy above). `RecurringView` owns a `NavigationStack` (`:27`), so it must become a pushed destination without its own stack.
2. Visuals: a plain `List` row. Flutter shows the card layout, gradient bar, and Pattern and Next Occurrence columns with Edit/Delete buttons. Decision needed (Q1 below).
3. Copy: "Every 2 weeks" and "Monthly on the 31st" vs Flutter "Bi-weekly" and "Monthly" (`RecurringView.swift:122-128`, `:216-218`). Empty-state, delete-dialog and toast copy all differ. Next date is "Next: <mediumDate>" vs `MMM dd, yyyy`. No `RecurrenceIndicator`. No snackbars.
4. No manual "Generate Due Transactions" action; the generator runs only on launch and after add (`AppModel.swift:147, 254`).
5. Form: description before amount, no autofocus on amount; no "Next 3 Occurrences" preview; no "Day of Week" wheel (harmless, see the cosmetic note); type is a segmented control (superset, needed for an add-from-Recurring); title "New Recurring" vs "Add Recurring Expense|Income"; validation messages absent (Save just disables); no 1-year start-date rule and no picker range; monthly-only "Day of month" picker exists. The Save button is not gradient-coloured.
6. **Start-date time-of-day**: Flutter's untouched default is `DateTime.now()` (with time), so the first occurrence lands "now". Swift's `RecurringFormView.save` (`RecurringView.swift:270-272`) always uses local midnight for a new template. This changes safe-to-spend (an expense stamped now is not counted until tomorrow under the approved same-day quirk, whereas midnight is counted). Mirror `TransactionFormView`'s `dayIsPicked` logic: use `model.now` when the day was not touched, midnight when picked.
7. No "Make this recurring" link in `TransactionFormView`.
8. No `RecurrenceIndicator` on Spending, History or category drill-in rows (other analysts own those views, but the component is here).
9. Settings has no Recurring row.

### C3. BudgieCore and AppModel additions
- `RecurringGenerator.previewOccurrences(pattern: RecurrencePattern, start: DartDateTime, dayOfMonth: Int?, count: Int = 3, calendar: DartCalendar) -> [DartDateTime]` (first = start; then `nextOccurrence`-style steps). Refactor `nextOccurrence(of:after:calendar:)` (`RecurringGenerator.swift:8-27`) to delegate to a pattern-based overload. Test it against `budget_app/test/recurring_transaction_test.dart` (9 tests, the DST-drift cases) and the existing generator fixtures (`Fixtures/logic/tz/*/generator.json`).
- Extract the cursor rule from `FinancialData.updateTemplate` (`FinancialData.swift:244-262`) into a pure function `FinancialData.cursor(forEdit:of:)` so the form preview can show the real next occurrences for an edit (the cursor is kept unless the schedule changed, and never lands on or before the last generated occurrence). Otherwise the preview would lie in edit mode.
- `AppModel.generateDueNow() async -> Int` (calls `RecurringGenerator.generateDue` and persists both sections), for the manual button; return the generated count for the toast.
- Optional `RecurringSummary.subtitle(templates:)` in Core for "N active · a, b, c" so it is unit-testable.
- Parity tests: preview vs Dart `_calculatePreviewDates` fixtures (extend the harness generator scenario); validation strings unit test (view-level).

### C4. SwiftUI breakdown
- `RecurringListView` (pushed destination): navigation title "Recurring Transactions", toolbar refresh (`arrow.clockwise`, label "Generate Due Transactions") plus the "+" add button.
- `RecurringCard` (per Q1): 48×48 tinted tile with the category glyph, description with a `RecurrenceIndicator`, category, amount; divider; Pattern and Next Occurrence columns; Edit and Delete buttons. Add a "Paused" capsule and Pause/Resume as an extra button or swipe action (approved). A paused card is dimmed (Swift's current 0.65 opacity).
- `RecurrenceIndicator`: a SwiftUI `Shape` port of the painter (2 cubic arcs plus 2 arrowheads, 1.5pt stroke, 16×9.6). The SF Symbol `repeat` is an acceptable fallback if pixel parity is not required.
- `RecurringFormView` changes: amount first with autofocus, the "Next 3 Occurrences" card, Flutter validation strings under the fields, wheel-style pickers (`.pickerStyle(.wheel)` in 90pt-high boxes) if you want a close match, and the dayIsPicked date fix.
- `TransactionFormView`: a "Make this recurring" footer link (hidden for voice prefill) that dismisses and presents `RecurringFormView` for the type. Coordinate with the transaction-form analyst. Decide whether to prefill it from the typed fields; Flutter does not.
- Settings row (accent `repeat` icon, subtitle, chevron) → `NavigationLink`.
- Remove the tab from `MainView.swift:11, 24-26` (coordinate with the shell analyst).
- Delete confirmation with the Flutter copy. Toasts: a lightweight banner or the existing notice mechanism (Swift has no snackbar).

### C5. Steps and effort
1. `previewOccurrences` and cursor extraction with tests (S/M).
2. `AppModel.generateDueNow` (S).
3. `RecurrenceIndicator` shape and use in rows (S).
4. Move the view to a Settings destination; Settings row and subtitle; remove the tab (S, depends on shell).
5. Card list and copy alignment (M).
6. Form parity: preview, validation, start-date semantics, pickers (M).
7. "Make this recurring" link (S).

### C6. Open questions and risks
- **Q1 Look**: replicate the Flutter legacy screen (gradient bar and elevated cards) or restyle to the redesign card language? Research G recommends the redesign tokens for a port, but you asked for a close match to what ships. Recommendation: match Flutter as shipped, cheap in SwiftUI (`.toolbarBackground(gradient)`, `.toolbarColorScheme(.dark)`).
- **Q2 Copy**: adopt Flutter's "Bi-weekly" (recommended for parity) or keep "Every 2 weeks"?
- **Q3 Old-template validation**: do not port "start date more than 1 year in the past" for edits when the start date is unchanged. With the approved cursor-preserving edit it is unnecessary, and in Flutter it forces users to touch the date. Confirm.
- **Q4 Day of Week**: not showing it is functionally identical since it is unused; Swift's edit rewrites `dayOfWeek` from the start date (the stored value is ignored by both apps).
- **Q5 Preview basis** in edit mode: the recomputed cursor (recommended) or the start date.

---

## D. Voice entry and platform integrations

### D1. Flutter voice inventory
**Entry points**:
- Mic FAB on Spending (44pt `GlowFab`, `Symbols.mic_rounded`, semantic label "Add by voice", stacked above the main FAB, mobile only; `spending_page.dart:490-497`).
- Quick action `action_voice_add` "Add by Voice" (`main.dart:190-194`, handler `:348-353`).
- Deep link `budgetapp://voice-add` or `voice_add` (`:388-393`).
- Widget "Voice Add" (`BudgetVoiceAdd`, `widgetURL budgetapp://voice-add`).
- Re-entry guard `_voiceFlowActive`.

**Flow** (`widgets/voice_recording_sheet.dart`):
1. Modal bottom sheet (root navigator, top radius 28, card colour and border, drag handle 44×4, padding 24).
2. On appear it requests microphone permission, then records AAC-LC (`.m4a`) at 16 kHz, 1 channel, 32 kbps into a temp file (`voice_expense_<ms>.m4a`), with a 30-second cap.
3. Auto-stops at 30 s, and when the app is paused. The file is deleted on dispose.
4. Then transcribe → parse → the sheet returns a `Transaction` draft → `showTransactionForm(prefill: draft)`. The form is not dismissable by tapping outside, and has no "Make this recurring" link.

**Sheet states**:
- LISTENING: mono eyebrow in accent; a pulsing mic (88pt accent circle with glow, a 2px ping ring scaling 1→1.7, alpha .55→0, 1400 ms; static if reduce-motion); a countdown "0:30" down to "0:00" (numericMedium 22, secondary); a full-width filled "Stop" pill (44pt, stop icon). Medium haptic on start, light on stop.
- THINKING: eyebrow, a 56pt spinner, "Making sense of it...". Not dismissable and drag blocked while processing.
- ERROR: a 48pt danger icon, message (cardTitle 17/700, centred), the quoted transcript when parse failed, "Cancel" and "Try again" pills. Error vibration.

**Errors and retry**:
- 'Microphone access is off. Enable it in Settings > Budgie.'
- "Didn't catch anything — try again"
- "Couldn't read that as a transaction — try again"
- "That didn't sound like a transaction — try again"
- 'Something went wrong. Try again.'
- 'OpenAI is not configured. Add OPEN_AI_API_KEY to the app .env file.'
- Retry re-records for noSpeech and re-runs transcription for transcribeFailed. For parseFailed it re-parses the stored transcript, or re-records if there is none.

**Service** (`voice_expense_service.dart`, the only network code in the app):
- Key: `dotenv.load('.env')`, `OPEN_AI_API_KEY`, trimmed; empty fails with the message above. Loaded on every call. The `dart_openai` package (a third-party dependency; the native app has none).
- Transcription: OpenAI audio transcription, model `gpt-4o-mini-transcribe`, with prompt "Personal expense phrases with dollar amounts like $12.50 and merchant names."; an empty result throws "Didn't catch anything — try again".
- Parse: OpenAI chat completions, model `gpt-5.4-nano`, `response_format json_object`, system prompt at lines 62-77 with today's date, weekday, and the built-in expense and income category names from `common.dart:28-49`. It returns `{type, description, amount, category, date}` or `{"error":"not_a_transaction"}`.
- Vocabulary is the built-in maps only (`expenseCategories`, `incomeCategories`), not user-defined categories.

**Deterministic post-processing** `parseVoiceJson` (lines 108-205), covered by 40 Dart tests (`test/voice_expense_service_test.dart`; groups type, category clamp, amount, description, date, fence stripping, errors, returned object):
- Strip a leading ```` ```lang\n ```` and a trailing ```` ``` ````.
- The value must be a JSON object, else "Couldn't read that as a transaction — try again" (carrying the transcript). An `error` key gives "That didn't sound like a transaction — try again".
- `type == 'income'` → income, else expense.
- Category must be an exact member of the type's set, else fallback "Other" (income) or "General" (expense).
- Amount: a number, or a string via `double.tryParse`, else 0; NaN, infinite or negative → 0.
- Description: trimmed string if non-empty, else the transcript.
- Date: `DateTime.tryParse(date)` or today; if after `today` or before `DateTime(y, m, d − 90)` (calendar arithmetic), it is set to `today` (with time-of-day). A date-only string parses to local midnight.

**Quick actions and deep links** (`main.dart`):
- Dynamic shortcut items registered at `:179-195`: `action_add_expense` "Add Expense" (`minus.circle.fill`), `action_add_income` "Add Income" (`plus.circle.fill`), `action_voice_add` "Add by Voice" (`mic.circle.fill`). Flutter's icon strings referenced assets that did not exist, so its items had no icon (`PARITY_GAPS.md` "Platform").
- Deep-link method channel `budget_app/deeplink` (`:163, 309-325`). The action is `uri.host`, else the first path segment. The 2-second same-link dedup at `:396-407` is needed only because Flutter delivers the initial link twice.
- Handlers wait on the init completer, then post a frame callback to `showTransactionForm` (or the voice flow) on the root navigator's context, so the form opens over whichever tab is showing.
- Native side: `ios/Runner/SceneDelegate.swift:83-113`, `AppDelegate.swift:95-160`. Also `budget_app/widget_data` (App Group cash flow) and `budget_app/protected_data`.
- Info.plist strings: `NSMicrophoneUsageDescription` "Budgie uses the microphone so you can add transactions by speaking." (`ios/Runner/Info.plist:83-84`). No `NSSpeechRecognitionUsageDescription`.

### D2. Swift state

Status (2026-09-30): implemented as option C1 (Phase 4): three shortcuts, `AddRoute.voice`, the recording sheet and the prefilled form exist. The analysis below is the state before Phase 4 and is kept as written; see PARITY_GAPS "Voice entry".
- Quick actions and deep links: `AppModel.swift:325-355`, `BudgieApp.swift:46-73`, `MainView.swift:35-43`. The mapping (`budgetapp://add-income` and so on, underscore variants, `voice-add` → expense form) is unit-tested in `BudgieAppTests/RoutingTests.swift`.
- Only two shortcuts are registered (voice dropped); an old leftover `action_voice_add` opens the expense form (verified in `BudgieUITests/SystemIntegrationUITests.swift:52-58`). `MIGRATION_SPEC` §11.2 fixes the types and links.
- Swift always switches to the Spending tab; Flutter opens the form over the current tab (minor).
- No dedup needed: Swift receives each link once.
- Widget (`native/BudgetWidgets/BudgetWidgets.swift`) is byte-identical to `budget_app/ios/BudgetWidgets/BudgetWidgets.swift` (verified with `diff`).
  - `BudgetVoiceAdd` (`:194-205`) has `configurationDisplayName("Voice Add")` and `.description("Speak a transaction and review it before saving.")`. That is the stale text; it is wrong while voice is not implemented. Its mic glyph and `widgetURL` `budgetapp://voice-add` (which opens the expense form) also mislead.
  - The Quick Add widget copy "Add income or expense from your home screen." is fine.
  - Changing display names, descriptions and the entry view is safe; changing `kind` blanks placed widgets (`MIGRATION_SPEC` §2). The widget always formats USD `en_US` regardless of base currency (same as Flutter).
- `Info.plist` in `project.yml:49` has no microphone or speech strings (dropped per §11.4).
- Cash-flow sync is done (`AppModel.syncWidget`).

### D3. Options for voice entry (user must decide)

Status (2026-09-30): implemented as option C1 (D11 in FULL_APP_PLAN), see PARITY_GAPS "Voice entry". The table and recommendation below are the analysis that preceded the decision.

| | A. Remove voice (status quo) | B. On-device Speech + local parser | C. Keep OpenAI (C1 key in binary; C2 user's own key in Keychain; C3 proxy) | D. Hybrid: B by default, optional OpenAI parse |
|---|---|---|---|---|
| What ships | Mic entry points open the expense form; widget retitled or changed | `SFSpeechRecognizer` (on-device where available, `requiresOnDeviceRecognition`) with `AVAudioEngine` streaming; a deterministic Swift parser; optional `FoundationModels` (iOS 26+, guarded by `#available` and availability check) for structured extraction; `NSDataDetector` for dates | Same recording and 2 OpenAI calls via plain `URLSession` (no dependency): multipart to `/v1/audio/transcriptions`, JSON to `/v1/chat/completions` | B, plus a setting to send the transcript (not audio) to OpenAI with the user's key |
| Privacy | Best | Data never leaves the device (if on-device recognition is supported for the locale) | Audio and text go to OpenAI; contradicts onboarding page 1; App Privacy label must declare it | Local unless the user opts in |
| Key handling | None | None | C1: extractable from the IPA (today's Flutter posture, risky). C2: Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), enter in Settings; fine for a personal app, poor for the public. C3: a backend with App Attest and rate limits; contradicts AGENTS.md "no backend" and adds ops and privacy-policy work | Keychain only for the opt-in |
| Accuracy | Not applicable | Good transcription; parsing weaker on messy phrases ("twelve fifty", categories by keyword) but the user always confirms in the form, as in Flutter | Best parsing (LLM) | Good default, best when opted in |
| Offline | Yes | Yes | No | Yes by default |
| Cost | 0 | 0 | Per use to you (C1/C3) or user (C2) | 0 |
| Parity of UX | Loses the feature | Same sheet, same confirm form; recognition errors differ | Closest to today | Close |
| Effort | S | L | M (C2 adds Settings and Keychain UI; C3 is L plus hosting) | L + M |
| Permissions | none | Microphone and `NSSpeechRecognitionUsageDescription` | Microphone (existing string) | Both |
| Extra risk | Feature loss, `PARITY_GAPS` update | Locale coverage of on-device models; recognizer variance; the number-word parser must be written | Key exposure (C1), spend abuse, review and disclosure | More surface |

My recommendation, for you to confirm: D (or B alone at first). Reasons: no shipped key, consistent with the product's privacy claims, no backend, works offline, and the confirm form keeps errors cheap. C2 (BYOK) is reasonable if the app is personal-use only. C1 should be ruled out.

### D4. Shared pieces regardless of option (BudgieCore)
- `VoiceDraft` value type (`type, description, amount, category, date`), and `VoiceDraftParser.parse(modelJSON: String, transcript: String, today: DartDateTime, calendar:, allowedCategories:) throws(VoiceParseError) -> VoiceDraft` porting `parseVoiceJson` exactly. Run it on the local parser's output too, to enforce category membership, amount sanitizing and the 90-day date clamp. Port all 40 Dart tests as Swift Testing tests; generate a differential fixture from the real `VoiceExpenseService.parseVoiceJson` via the ParityHarness (a `voice_fixtures` test with a corpus of raw model outputs).
- Decide the category vocabulary: Flutter uses only the built-ins. Swift should use `model.categories(for:)` (includes custom categories) with fallback "General"/"Other" (or the first category if archived); this is an intentional superset.
- Local parser (options B/D): pure Swift `LocalVoiceParser.parse(transcript:today:calendar:categories:) -> [String: JSON]` shaped like the model JSON, so it goes through the same clamp. It needs a number-word parser ("twelve fifty" → 12.50, "three thousand"), income keyword detection (paid, salary, received, refund, deposit), date phrases (today, yesterday, N days ago, last weekday, "on the 3rd"), and a category keyword map.
- AppModel/route: add `AddRoute.voice` and route `voice-add`, `voice_add`, `action_voice_add`, and the widget to it; re-register the "Add by Voice" shortcut (`mic.circle.fill`); update `RoutingTests` and `SystemIntegrationUITests`.
- `TransactionFormView` needs a `prefill: VoiceDraft?` mode. The date is stored as the draft date. It hides "Make this recurring", and the sheet is not dismissible by swipe (`interactiveDismissDisabled`). Coordinate with the transaction-form analyst.
- SwiftUI `VoiceRecordingSheet`: `presentationDetents([.medium])`, custom background radius 28, states listening/processing/error as above, reduce-motion handling, haptics (`UIImpactFeedbackGenerator`), a 30 s countdown, stop on background, delete the temp file, and `interactiveDismissDisabled` while processing.
- Info.plist: keep or add `NSMicrophoneUsageDescription` (same string); add `NSSpeechRecognitionUsageDescription` for B/D. Update `MIGRATION_SPEC` §11.4 ("Drop: microphone/speech strings") and `PrivacyInfo.xcprivacy`; update `PARITY_GAPS.md`.
- Widget: if voice returns, no widget change is needed. If voice stays out, keep `kind BudgetVoiceAdd`, retitle to something like "Quick Add", change the mic to a plus glyph, and set the description to "Open Budgie to add an expense." The two widget copies then diverge from Flutter's (the Flutter build can still be reinstalled).

### D5. Routing and lock fixes (independent of voice)
- Gate `pendingAdd` on unlock (cross-cutting item 2).
- Hold `pendingAdd` during onboarding.
- Consider whether to open the form over the current tab (Flutter) or force Spending (Swift now); the Swift behaviour is simpler and consistent.

### D6. Steps and effort
1. Decision on voice (user).
2. Widget copy fix, S (do in every case).
3. Routing lock and onboarding gating, S.
4. `VoiceDraftParser` port + 40 tests + fixtures, M.
5. Form prefill mode, S/M.
6. Recording sheet UI, M.
7. Speech (B): AVAudioEngine and recognizer wrapper, permission flow, local parser and tests, L. Or OpenAI (C): `URLSession` client, key storage and Settings UI (C2), M. Foundation Models tier, M optional.
8. Info.plist, privacy manifest, docs, S.

### D7. Risks and open questions
- Whether any shipped Flutter build contained a live key; rotate if so.
- On-device recognition availability per locale; behaviour when unsupported (fail or fall back to Apple's servers).
- App Store privacy label and review notes for whichever option is chosen.
- Voice from a locked launch: the sheet must wait for unlock (item 2).

---

## Suggested ordering across A-D
1. Routing gating and onboarding hook (S).
2. Widget copy (S).
3. Insights core, prefs and tests (L/M) in parallel with recurring core additions (S/M).
4. Views for onboarding, recurring and insights once design tokens and fonts exist.
5. Voice after the decision.

## Key files
- Flutter: `budget_app/lib/insights/insight_engine.dart`, `widgets/local_insights_section.dart`, `history_page.dart:80`, `onboarding_tutorial.dart`, `main.dart:179-407`, `voice_expense_service.dart`, `widgets/voice_recording_sheet.dart`, `recurring_transactions_page.dart`, `recurring_transaction_form.dart`, `widgets/recurrence_indicator.dart`, `transaction_generator.dart`, `settings_page.dart:745-765, 913`.
- Swift: `native/Budgie/App/AppModel.swift`, `BudgieApp.swift`, `Views/MainView.swift`, `Views/RecurringView.swift`, `Views/AppLock.swift`, `native/BudgetWidgets/BudgetWidgets.swift`, `native/BudgieCore/Sources/BudgieCore/Domain/{Records,FinancialData,RecurringGenerator}.swift`, `Store/Preferences.swift`, `native/ParityHarness/parity/logic_fixtures_test.dart`.
