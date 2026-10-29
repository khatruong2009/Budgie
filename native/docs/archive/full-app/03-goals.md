> Archived; paths refer to the `flutter-final` tag.

# Goals tab (savings goals): analyst report

Paths: F = `W/budget_app/lib` (W = `.claude/worktrees/swiftui-mvp-migration-71aa05`), N = `W/native`. Citations are `file:line`.

## 0. Headline findings

- **Allocating money to a goal creates no transaction.** It only changes `currentAmount` (and possibly `completedAt`) on the goal. Goals never touch the ledger, net worth, budgets or widget. Confirmed by `F/transaction_model.dart:934-963` and `N/docs/research/C_domain_models.md:232`.
- **The only readers of goals outside the Goals page:**
  - Safe-to-spend: `F/safe_to_spend.dart:121-129`, via `suggestedMonthlyContribution`.
  - The "goal behind schedule" insight: `F/insights/insight_engine.dart:333-362`.
  - Backup export/import: `F/backup.dart:67,157,205`.
  - Settings restore: `F/settings_page.dart:429,451`.
- **The only mutations are the four in `F/transaction_model.dart:868-963`:** `addSavingsGoal`, `updateSavingsGoal`, `deleteSavingsGoal`, `allocateToSavingsGoal`. There is no archive, no explicit complete, no explicit withdraw and no reorder.
  - "Complete" is derived: `currentAmount >= targetAmount`, and it stamps `completedAt`.
  - "Withdraw" exists only at model level, as a negative `allocate` amount clamped at 0. No UI reaches it. The edit form's "Saved so far" field is the only way to lower the saved amount.
- **Swift today is read-only and lossy for writes.**
  - `SavingsGoalRecord` (`N/BudgieCore/Sources/BudgieCore/Domain/Records.swift:459-508`) has no `raw` object.
  - `FinancialData.load` does `compactMap` over goals (`Domain/FinancialData.swift:128-130`). Unreadable rows are dropped from memory, so writing the array back would lose them.
  - `AppModel.serialize` falls through to `data.sections[...]` for goals (`Budgie/App/AppModel.swift:~150`).
  - Once anything mutates goals, that path must be replaced by a typed section serializer. The pattern to copy is `transactionRows` / `StoredRow`.
- **The Swift shell has no Goals tab.** `MainView` has 5 tabs (`Budgie/Views/MainView.swift:14-32`). Flutter has 6 destinations (Home, Worth, Goals, Spend, Flow, More).
  - A 6th `TabView` tab collapses into iOS's "More" overflow.
  - This is a shell-owner decision (custom floating dock vs `TabView`). Flag it.

## 1. Feature inventory (Flutter behaviour)

### 1.1 Data model (`F/savings_goal.dart`)

JSON key order in `toJson` (`:81-89`). Written under store section key `savingsGoals` (`F/storage/atomic_financial_store.dart:21`):

| Key | Type | Notes |
|---|---|---|
| `id` | string | Generated as `savings_goal_<µs-since-epoch base36>_<static counter base36>` (`:130-134`). `fromJson` reads `as String?`; a missing id gets a fresh generated one. |
| `name` | string | Trimmed. On read, empty or missing becomes the literal `"Savings Goal"`. |
| `targetAmount` | double | Constructor clamps `< 0` to 0. Written as `5000.0`. |
| `currentAmount` | double | Same clamp. Can exceed target; there is no upper clamp. |
| `targetDate` | ISO string | Local, no `Z`. On add it is normalised to local midnight (`transaction_model.dart:882`). |
| `createdAt` | ISO string | `DateTime.now()` with time-of-day and microseconds. Never edited. |
| `completedAt` | ISO string or `null` | Key always written. |

Read tolerance (`:91-107`, `_readDouble` `:136`, `_readDate` `:147`):
- Amounts accept a number, or a String via `double.tryParse` (else 0).
- Dates accept a non-empty String via `DateTime.tryParse`, else `now`.
- `completedAt` falls back to null.
- `id` or `name` of the wrong type throws, so the row is unreadable.

Derived and never persisted (`:27-79`):
- `progress` = `current / target`, clamped 0..1, and 0 when `target <= 0`.
- `progressPercent` = `(progress * 100).round()`. Dart rounds half away from zero, which matches Swift `.rounded()`.
- `remainingAmount` = `max(target - current, 0)`.
- `isCompleted` = `target > 0 && current >= target`.
- `isOverdue` = `!isCompleted && midnight(targetDate) < midnight(now)`.
- `daysRemaining` = whole days from midnight today to midnight of target. It is not used by any UI.
- `suggestedMonthlyContribution`:
  - Returns 0 if completed or `remaining <= 0`.
  - `monthsRemaining = (t.year - n.year) * 12 + t.month - n.month + 1`, using the wall clock.
  - If `monthsRemaining <= 1` it returns `remaining`; otherwise `remaining / monthsRemaining`.
  - A past-due goal therefore reserves its whole remainder.
  - Swift already ports this (`Records.swift:494-503`).

### 1.2 Model mutations (`F/transaction_model.dart`)

All four call `persistSections({savingsGoals: serializeSection})` (`:1466`), then `notifyListeners`. They are `Future<void>`; the bool from the save is ignored. A save failure flags `hasUnsavedChanges` (`storage/persistence_status.dart:36-60`), and the home retry banner shows.

**`addSavingsGoal(name, targetAmount, targetDate)` (`:868-887`):**
- Silently returns if `name.trim().isEmpty || targetAmount <= 0`.
- Appends to the end of the list.
- `targetDate` becomes `DateTime(y, m, d)` (local midnight).
- `currentAmount` = 0.0, `createdAt` = now, `completedAt` = null.

**`updateSavingsGoal(goal)` (`:890-921`):**
- Returns if name is empty or `target <= 0`, or if the id is not found.
- Replaces by id using the passed goal's fields, which already carry `createdAt` and `id` from the UI's copy.
- Name is trimmed.
- `current` is clamped to `>= 0`.
- `completedAt = (current >= target) ? (goal.completedAt ?? now) : null`.
- It maps over all entries with that id, so duplicate ids would all be replaced.
- The stored `targetDate` is not re-normalised.

**`deleteSavingsGoal(id)` (`:923-932`):**
- Filters out every goal with that id.
- Does nothing and does not save if none matched.

**`allocateToSavingsGoal(id, amount)` (`:934-963`):**
- No-op if `amount == 0`.
- `updated = max(current + amount, 0)`.
- `completedAt = (updated >= target) ? (old ?? now) : null`.
- Not found means no save.
- Negative amounts are allowed at model level and act as a withdrawal.

### 1.3 Page structure (`F/savings_goals_page.dart`)

**Shell (`:83-123`):**
- `BudgiePageScaffold` with a `GlowFab` (add icon, semantic label "Add savings goal"). The FAB is disabled while `_isBusy`.
- Body is a `SingleChildScrollView` with bottom padding `DockMetrics.contentBottomPadding` (dock offset + 96, minimum 116).
- Inside it, `SafeArea(bottom:false)` holds `Column[BudgieHeader(title: 'Goals'), emptyState | content]`.
- The celebration overlay is a `Positioned.fill` sibling of the scroll view. It sits above the content and below the FAB and dock.
- The page is wrapped in `Consumer<TransactionModel>` (`home_page.dart:124-127`), so it rebuilds on any model change.
- "Now" is read at build time with no ticking timer.

**Sort (`:154-162`):**
- Incomplete goals first, then completed.
- Within each group, `targetDate` ascending.
- Dart's `List.sort` is stable only up to 33 elements (unstable quicksort from 34). Use `DartSort` to match its tie order.

**Empty state (`:164-211`):**
- Outer padding `(20, 48, 20, 0)`.
- `GlowCard` with padding 28.
- `IconTile` 56 (piggy `savings_rounded` icon, size 28, accent).
- 20pt gap, then "No savings goals yet" (sectionHeader 20/700, centered).
- 8pt gap, then "Create a goal, set a target date, and track progress as you set money aside." (12pt base with 13 override, secondary color, height 1.45, centered).
- 24pt gap, then a filled `PillButton` "Add goal" with plus icon, height 44, full width.
- Reference screenshot: `N/docs/research/screenshots/07_goals_empty_dark.png`.

**Content (`:214-241`):**
- Summary card at padding `(20, 24, 20, 0)`.
- Then one goal card per goal at `(20, 16, 20, 0)`. There are no keys.

**Summary card (`:608-688`):**
- Layout: `GlowCard` (padding 20) containing a Row.
- Left: `ProgressRing` 72px, thickness 8, glowAlpha 0.35, accent color. The center text is `"{round(totalProgress*100)}%"` at 14/800, primary color.
- 18pt gap.
- Right column, left-aligned:
  - Eyebrow: literal `SAVED SO FAR` (mono 11/600, letterSpacing 2, secondary color).
  - 6pt gap.
  - `MoneyFormatter.format(totalSaved, decimalDigits: 0)` at 28/800, tracking -0.8, tabular.
  - 2pt gap.
  - `of {total target} · {completedCount} of {goals.length} complete` at 13pt secondary.
- Aggregation:
  - `totalSaved = Σ currentAmount`; `totalTarget = Σ targetAmount`. Both include completed and over-funded goals.
  - `totalProgress = clamp(saved / target, 0, 1)`, and 0 when `target <= 0`.
  - `completedCount` = number with `isCompleted`.

**Goal card (`:691-836`):** `GlowCard` padding 20.
- Row (center-aligned):
  - Ring: 84px, thickness 9, glowAlpha 0.4 (0.45 when complete).
    - Ring color: complete = success, behind = warning, on track = accent.
    - Fill value is `1.0` when complete, else `progress`.
    - Center: `"{progressPercent}%"` at 16/800 (`badgeSmall` with size override), or a filled `check_rounded` at size 28 in success when complete.
  - 18pt gap.
  - Expanded column (left-aligned):
    - Row: name (goalTitle 18/700, tracking -0.3, 1 line, ellipsis) + 8pt gap + status pill.
    - 6pt gap.
    - Amount line: 15/600 tabular, primary color. Format `{current}` then a secondary-colored w500 ` of {target}`, both with 0 decimals. When complete: `{current}` then ` saved`.
    - 4pt gap.
    - Sub-copy (12/400):
      - Not complete: pace copy in secondary color.
      - Complete: `Fully funded on {MMMd of (completedAt ?? targetDate)} — nice work` in success color.
- 16pt gap.
- Action row:
  - Not complete: `PillButton` "Add money" (filled accent, plus icon, height 44, Expanded), 8pt gap, then a 44px `MoreButton`.
  - Complete: `Spacer` then `MoreButton`, so the ellipsis is right-aligned with no Add money button.
- Complete card styling:
  - Gradient topLeft to bottomRight, success at 10% to success at 2%. A gradient replaces the card fill, so the tint is drawn over the page background, not over the card color.
  - Border is 1px success at 30%.
  - Long-press on the card opens the actions sheet (medium haptic). A plain tap does nothing, and there is no press-scale.

**Status (`:246-268`):**
- `complete` if `isCompleted`.
- `behind` if `isOverdue`.
- Otherwise, with `start = createdAt`:
  - `totalSpan = targetDate.difference(start).inMilliseconds`. Note `targetDate` is midnight at the START of the target day.
  - If `totalSpan <= 0`: `progress >= 1.0 ? onTrack : behind`.
  - Otherwise `expected = clamp(elapsedMs / totalSpanMs, 0, 1)`, where `elapsedMs = now - start`.
  - Result is `onTrack` if `progress + 1e-9 >= expected`, else `behind`.
- Millisecond values truncate toward zero. `Int64 / 1000` in Swift matches.

**Pace copy (`:271-281`):**
- `{MMMd} · $X/mo keeps you on pace`, or `{MMMd} · bump to $X/mo to catch up` when behind. `X` is `suggestedMonthlyContribution` with 0 decimals.
- Dates use en_US: `DateFormat.MMMd` gives "Nov 30" and `yMMMd` gives "Sep 28, 2026". The app never sets an intl default locale (`main.dart:60` only sets the MaterialApp locale).
- With `hideBalances`, every `MoneyFormatter.format` returns `••••`. That includes the pace copy, summary and chips.

**Status pill (`:896-915`):** `PillChip` (tinted at 14% alpha, capsule, padding h10 v5, `badgeSmall` 11/700 in the color):

| Status | Color (light / dark) | Label |
|---|---|---|
| Complete | success `#10B981` / `#34D399` | `Complete` |
| Behind | warning `#F59E0B` / `#FBBF24` | `Behind` |
| On track | accent `#6366F1` / `#818CF8` | `On track` |

**More button (`:919-958`):**
- 44x44 circle, 1px border at 10% (white in dark, black in light).
- `more_horiz` icon, size 18, secondary color.
- Semantics label "More goal actions".
- Light haptic on tap.

**Actions sheet (`:371-428`):**
- `showModalBottomSheet`, root navigator, transparent background.
- Inside: `SafeArea(top:false)`, padding `(20, 0, 20, 20)`, `GlowCard` with vertical padding 8.
- Header row padding `(12, 12, 12, 8)` with the goal name (goalTitle, 1 line, ellipsis).
- Two tiles, each padding v12 h12: `IconTile` 40 (icon 20) + 14pt gap + label (rowTitle 15/600).
  - "Edit goal" (pencil icon, primary color).
  - "Delete goal" (trash icon, danger color).
- Each tile fires a light haptic and closes the sheet before acting.

**Delete confirm (`:431-497`):** `_DarkDialog`, padding 20.
- Title: "Delete savings goal?" (goalTitle, centered).
- Body: `This removes "{name}" and its saved progress from your goals.` (13pt secondary, height 1.45, centered).
- Buttons: outlined `Cancel` (secondary color) and filled `Delete` (danger color), height 44, side by side with a 12pt gap.
- Success snackbar: "Savings goal deleted".

**Goal form dialog (`:1026-1216`):**
- Title: "Add savings goal" / "Edit savings goal" (centered, then 20pt gap).
- Fields (12pt gaps):
  - "Goal name", hint `Vacation, emergency fund, new car`, flag icon, sentence capitalisation. Validation error: `Name is required` (blank after trim).
  - "Target amount", hint `0.00`, dollar icon, decimal keyboard. Prefill in edit mode is `toStringAsFixed(2)`. Validation error: `Enter a target greater than 0`.
  - "Saved so far", shown ONLY when editing, savings icon, prefill `toStringAsFixed(2)`. Validation error: `Enter 0 or more`.
- 16pt gap, then the date tile "Target date" showing `yMMMd`.
  - Default is `DateTime(now.year, now.month + 6, now.day)`, using Dart lenient overflow (Aug 31 + 6 months = Mar 3).
  - Material `showDatePicker` with range `[DateTime(year-1), DateTime(year+20)]`. Range is Jan 1 to Jan 1, so the last selectable day is effectively Dec 31 of year+19.
  - Selection click haptic on pick.
  - Flutter bug: `initialDate` outside the range asserts. An edited overdue goal older than about a year hits this.
- 24pt gap, then a `Cancel` / `Add` (plus icon) or `Update` (check icon) button row.
- Validation runs on submit only (`Form.validate`) and shows all errors at once.
- Result is popped, then the mutation runs.
  - Add: `addSavingsGoal(name, target, targetDate)`. Snackbar "Savings goal added".
  - Edit: `updateSavingsGoal(goal.copyWith(name, target, current, targetDate, completedAt: current >= target ? (goal.completedAt ?? now) : null))`. Snackbar "Savings goal updated".
- Editing a goal to a "Saved so far" >= target completes it with NO celebration and NO haptic.
- Amount parser (`:1694`): strips `,` and `$`, trims, then `double.tryParse`. It accepts `1e3`, `.5`, `Infinity`, `NaN` and hex (`0x1A`). A decimal comma is treated as a thousands separator.

**Allocation dialog (`:1219-1359`), max width 460:**
- Title "Add money" (centered). 6pt gap. Goal name (13pt secondary). 20pt gap.
- Field "Allocation amount" (autofocus, hint `0.00`, dollar icon). Validation error: `Enter an amount greater than 0`.
- 12pt gap, then a Wrap (spacing 8, run spacing 8) of quick chips:
  - `MoneyFormatter.format(25)` reads "$25.00" (2 decimals).
  - `MoneyFormatter.format(100)` reads "$100.00".
  - "Finish goal" (only if `remaining > 0`) fills `remaining.toStringAsFixed(2)`.
  - Chip style: padding h14 v9, chip-surface fill, 1px card-border stroke, capsule, label 13/600 primary, selection haptic.
  - Flutter bug: rounding `remaining` to 2 decimals can leave it fractionally short (for example 33.334 fills 33.33), so the goal does not complete.
- 24pt gap, then `Cancel` / filled `Add money` (plus icon), height 44.
- Result `amount > 0`. `willComplete = !goal.isCompleted && amount >= goal.remainingAmount`, computed on the UI's stale snapshot.
- Then `allocateToSavingsGoal(id, amount)` and snackbar "Allocation added".
- If `willComplete`: medium haptic always. The overlay plays only when reduce-motion is off.

**Text field style (`_SavingsTextField`, `:1402-1462`):**
- Material `TextFormField`, filled with chip surface (dark `#15151F`, light `#F1F1F7`).
- Radius 14, 1px card-border stroke; focused stroke is 1.5px accent.
- Floating label (13 secondary), hint 13 tertiary, prefix icon 20 secondary, input text rowTitle 15/600 primary.
- Error text and borders use the theme error color.

**Date tile (`_DatePickerTile`, `:1465-1530`):** container padding 16, radius 14, chip-surface fill, 1px card-border stroke.
- Row: calendar icon 20 (secondary), 14pt gap, column (label 12pt secondary, 2pt gap, value rowTitle 15/600 primary), chevron-right 20 secondary.
- Light haptic on tap.

**Dialog shell (`_DarkDialog`, `:1004-1023`):**
- Material `Dialog`, transparent background, inset h24 v32, `maxWidth` 500.
- `GlowCard` padding 20.
- Default Material barrier (dismissible) and appear animation.

**Snackbars (`:~540`):** floating, radius 12 (`AppDesign.radiusM`), colored background (success or danger).
- Text color is not set explicitly. It comes from the Material default (onInverseSurface); verify on device.
- Messages: "Savings goal added", "Savings goal updated", "Allocation added", "Savings goal deleted", and failure "Savings goal action failed".
  - The failure message fires only if the mutation throws, which the model never does.
- Success snackbars show even if the model no-op'd or the save failed. In the save-failed case the unsaved banner is the only signal.
- `_isBusy` blocks re-entry while a mutation runs (FAB, empty-state button and other controls no-op).

**Celebration overlay (`:1547-1691`):**
- Duration 1600ms, linear controller (`:64-74`), resets and clears after completion.
- Whole thing is `IgnorePointer`.
- Tree: `Opacity(fade)` around a `DecoratedBox` scrim (`black @ 0.34 * fade`, so effective darkness is roughly 0.34 * fade squared), around a centered Stack of painter + card.
- `fade` = 1 while `v < 0.75`, then linear to 0 at `v = 1`.
- Card scale = `0.7 + 0.3 * easeOutBack(clamp(v, 0, 0.8) / 0.8)`.
  - Flutter `Curves.easeOutBack` is the cubic-bezier `(0.175, 0.885, 0.32, 1.275)`, which overshoots to about 1.03.
- Card: `GlowCard` padding 24, glow shadow (success, blur 40, alpha 0.35).
  - 72px success circle with glow (blur 28, alpha 0.55), containing a filled check icon at size 34 in `onAccent`.
  - 16pt gap, then "Goal complete" (goalTitle 18/700).
  - 6pt gap, then the goal name (13pt secondary, centered, no line limit).
- Painter, 18 dots:
  - Angle = `2π/18 * i`.
  - Distance = `44 + progress * 180`, centered on the body's center.
  - Radius = `3 + (i % 3) * 1.5`, giving 3, 4.5 and 6.
  - Alpha = `1 - progress`.
  - Even index = success color, odd index = accent color.
- Reduced motion (`MediaQuery.disableAnimationsOf`): no overlay, haptic still fires.

**Other:**
- `ProgressRing` (`widgets/progress_ring.dart`):
  - Track color: dark `#1B1B2C`, light `#E9E9F1`.
  - Arc starts at 12 o'clock with butt caps.
  - Inner disc is the card color at diameter `size - 2 * thickness`.
  - Outer glow: dark = shadow blur 28, alpha `glowAlpha * t`. Light = alpha 0.25, blur 16.8, offset (0, 4).
  - Animates 0 to value over 900ms with `easeInOutCubic` (cubic-bezier 0.645, 0.045, 0.355, 1).
  - A later value change animates from the current value to the new one.
  - Reduced motion skips the animation.
- `GlowFab` (`widgets/glow_fab.dart`): 54px accent circle, plus icon at size 26, glow + drop shadow.
  - Position: right 20, bottom `dockOffset + 72`.
  - Entry: scale-in over 300ms `easeOutBack`.
  - Press: scale 0.95.
  - Tap: 500ms burst (ping ring scales 1 to 1.7 with alpha `0.55 * (1 - t)`, glow flare, icon pop `1 + 0.22 * sin(πt)`), skipped under reduced motion.
- `GlowCard` (`widgets/glow_card.dart`): radius 26, fill card color, 1px border (dark white 7%, light `#101020` at 8%), no shadow.
- Colors and text sizes: see `N/Budgie/Views/Theme.swift` and the UI_SPEC tokens. Text uses Gabarito (weights 400-900) and Spline Sans Mono, bundled in `budget_app/assets/fonts`. Neither is in the Swift app yet.

### 1.4 Persistence side effects

- Every goal mutation writes only the `savingsGoals` section via `persistSections` (atomic, verified read-back).
- No widget sync, no transaction, no other section changes.
- Backup export and import include goals. `SavingsGoal.fromJson` in `backup.dart:205` requires finite amounts.
- Onboarding page 3 mentions Goals ("Goals keeps savings in view").

## 2. Layout summary (buildable)

Page background is Theme.background (`#0A0A12` dark, `#F9FAFB` light). Vertical order:

1. Header row "Goals" at padding `(20, 12, 20, 0)`, 26/800 with tracking -0.6, and a 36x36 empty trailing space.
2. Empty: card at `(20, 48, 20, 0)`. Content: summary card at top 24, then goal cards at 16 spacing, all with 20 side padding.
3. Bottom scroll inset is dock offset + 96.
4. FAB overlay at right 20, bottom dock offset + 72.

Key metrics:
- Card radius 26, padding 20 (empty 28).
- Rings: 84 (thickness 9), 72 (thickness 8).
- Buttons: height 44. Filled pill is capsule with an accent glow.
- More button: 44 circle.
- Fields: radius 14.
- Chips: capsule.
- Dialogs: max 500 (460 for allocation), inset h24 v32.

## 3. Swift today

- **Decode:** `SavingsGoalRecord.parse` (`Records.swift:469-495`) mirrors `fromJson`.
  - Rows with a non-object value, or a wrongly typed `id` or `name`, return nil and are dropped from `data.savingsGoals`. The raw section still holds them, so they are preserved only because nothing writes the section today.
  - Missing `id` becomes `newID()`, a fresh UUID per launch. That is fine in memory, but it would be persisted as a new id on first save.
- **Fields:** all `let`; no `raw`; no `make`, `Edit` or mutators.
- **Derived values present:** `remainingAmount`, `isCompleted` and `suggestedMonthlyContribution(now:)` only.
- **Safe-to-spend:** already correct.
  - `SafeToSpend.calculate` sums `suggestedMonthlyContribution(now: wallClock)` over non-completed goals (`SafeToSpend.swift:77-84`), gated by `!isBeforeMonth(month, asOfMonth)`.
  - Parity-tested (`DomainParityTests.swift:158-185, 235-251, 307-318`).
  - `SpendingView.swift:77` and `SpendingSafeToSpendSheet.swift:29` already use it.
- **AppModel:** no goal API and no goal case in `serialize`.
- **Missing:**
  - Goals tab and any goals UI.
  - `progress`, `progressPercent`, `isOverdue`, `status`, sort and summary helpers.
  - All four mutations.
  - Id generation.
  - The Goals UI, and typed section serialization (`StoredRow`).
  - Fonts.
  - A UI for the unsaved-changes flow specific to goals; the banner already exists.

## 4. Required BudgieCore additions

New file `Domain/SavingsGoal.swift`. Move `SavingsGoalRecord` out of `Records.swift`.

### 4.1 Record

```swift
public struct SavingsGoalRecord: Identifiable, Hashable, Sendable {
    public private(set) var id: String, name: String
    public private(set) var targetAmount: Double, currentAmount: Double
    public private(set) var targetDate: DartDateTime, createdAt: DartDateTime
    public private(set) var completedAt: DartDateTime?
    public private(set) var raw: JSONObject          // NEW: unknown keys survive
    static func parse(...) -> SavingsGoalRecord?     // keep semantics; keep raw
    public static func make(id:name:targetAmount:targetDate:now:) -> SavingsGoalRecord
    public struct Edit: Sendable, Hashable { name, targetAmount, currentAmount, targetDate }
    func applying(_ edit: Edit, now: DartDateTime) -> SavingsGoalRecord
    func allocating(_ amount: Double, now: DartDateTime) -> SavingsGoalRecord
    public static func makeID(now: DartDateTime, counter: Int) -> String   // savings_goal_<base36 µs>_<base36 n>
}
```

Byte compatibility:
- `make` builds `raw` with `JSONObject(ordered:)` in exactly this order: `id`, `name`, `targetAmount` (`.double`), `currentAmount` (`.double(0)`, giving `0.0`), `targetDate` (normalised to `calendar.date(y, m, d)`, then `toIso8601String()`), `createdAt` (`now.toIso8601String()`), `completedAt` (`.null`).
- `applying` and `allocating`:
  - Follow the Transaction pattern: change only the keys that changed.
  - Write `completedAt` always (a string or null; Dart always writes the key).
  - `name` = trimmed.
  - `current` = `max(current, 0)`.
  - `completedAt = current >= target ? (old.completedAt ?? now) : nil`.
  - If an int lexeme is present on `targetAmount` or `currentAmount`, rewrite it as `.double` (Dart would).
  - Do NOT touch `id`, `createdAt` or unknown keys.
- Cross-check with `Transaction.applying` at `Records.swift:137-165`.

### 4.2 Derived values (pure, use `DartDateTime` micros)

```swift
public var progress: Double            // clamp(cur/target, 0, 1), 0 if target <= 0
public var progressPercent: Int        // (progress * 100).rounded() (half away from zero)
public func isOverdue(now:, calendar:) -> Bool
public enum GoalStatus { onTrack, behind, complete }
public func status(now:, calendar:) -> GoalStatus
public static func sorted(_ goals: [SavingsGoalRecord]) -> [SavingsGoalRecord]  // incomplete first, targetDate asc, stable
public struct SavingsGoalsSummary { totalSaved, totalTarget, completedCount, count, progress, percent }
```

- `status`:
  - Milliseconds are `microseconds / 1000` (Int64 truncation).
  - `expected = clamp(Double(elapsedMs) / Double(spanMs), 0, 1)`; compare `progress + 1e-9 >= expected`.
  - `isOverdue` normalises both dates with `calendar.date(y, m, d)`.

### 4.3 FinancialData

- Replace `savingsGoals: [SavingsGoalRecord]` with `savingsGoalRows: [StoredRow<SavingsGoalRecord>]` and a computed `savingsGoals` (compactMap of records). `SafeToSpend` callers keep working.
- In `load`, map each row: parse success gives `.record`, failure gives `.unreadable(row)`. Non-array section gives an empty list.
- Add:

```swift
public func savingsGoalsSection() -> JSONValue
public mutating func addSavingsGoal(name:targetAmount:targetDate:id:now:) -> SavingsGoalRecord?
   // requires trimmed name non-empty, target > 0 and finite; targetDate normalised to midnight
public mutating func updateSavingsGoal(id:_ edit:now:) -> Bool
   // same name/target guards; all rows with matching id
public mutating func deleteSavingsGoal(id:) -> Bool
public struct AllocationResult { public let goal: SavingsGoalRecord; public let didComplete: Bool }
public mutating func allocateToSavingsGoal(id:amount:now:) -> AllocationResult?
   // amount == 0 or non-finite or missing id -> nil; didComplete = !wasCompleted && nowCompleted
public mutating func replaceSavingsGoals(_ rows: [StoredRow<SavingsGoalRecord>])   // for backup restore
```

### 4.4 Parity tests

- Extend the Dart harness. `ParityHarness/parity/logic_fixtures_test.dart` already builds `SavingsGoal` fixtures (lines 319-352, 412-437) with a pinned `parityNow()`.
  - Add a scenario that drives the real `TransactionModel.add/update/allocate/delete` over a scripted sequence with the clock pinned.
  - Dump `serializeSection(savingsGoals)` after each step.
  - Swift `savingsGoalsSection()` must encode to byte-identical `DartJSON.encode(..., .dartCanonical)` for each step.
- Add derived-value fixtures per TZ dir (`Fixtures/logic/tz/<zone>`):
  - Cover `progress`, `isOverdue`, `status` and `suggestedMonthlyContribution` at several pinned "now" values.
  - Include goals whose `createdAt` and target straddle a DST change.
  - Include edge cases: `target == 0`, `current > target`, target today, `createdAt` after target, negative and string-typed amounts, missing `targetDate` (falls back to now), int lexemes, unknown extra key.
- Swift unit tests (`BudgieCoreTests`):
  - Unreadable-row preservation.
  - Unknown-key survival through edit.
  - Duplicate-id behaviour (all rows updated or deleted).
  - `didComplete` transitions.
  - Negative allocation clears `completedAt`.
  - `make` id format.
  - Sort stability.
  - `verify_swift_output_test.dart` (`goals: raw N loaded N`) must still pass.

### 4.5 AppModel additions (`Budgie/App/AppModel.swift`)

```swift
var savingsGoals: [SavingsGoalRecord] { data?.savingsGoals ?? [] }   // views sort via Core helper

enum GoalMutation: Sendable { case rejected; case applied(saved: Bool, didComplete: Bool) }

func addSavingsGoal(name: String, targetAmount: Double, targetDate: DartDateTime) async -> GoalMutation
func updateSavingsGoal(id: String, _ edit: SavingsGoalRecord.Edit) async -> GoalMutation
func deleteSavingsGoal(id: String) async -> GoalMutation
func allocateToSavingsGoal(id: String, amount: Double) async -> GoalMutation
```

- Each mutates `data` first, then `await persist([Section.savingsGoals])`.
- `serialize(_:)` gets `case Section.savingsGoals: return data.savingsGoalsSection()`.
- Because `persist` already goes through `PersistenceTracker`, `hasUnsavedChanges` and the banner are handled.
- Existing methods return one Bool for both "rejected" and "not saved". The enum lets the UI show a success toast whenever applied, exactly as Flutter does.
- Guard `amount.isFinite` in every method.
- `serialize` must also serve `retrySaves()`.
- The `@Observable` `data` var makes SpendingView's safe-to-spend recompute automatically.
- Keep a private goal-id counter for `makeID`.

## 5. SwiftUI view breakdown and build sequence

### 5.1 Files (`native/Budgie/Views/Goals/` unless noted)

| File | Contents |
|---|---|
| `GoalsView.swift` | Page: ScrollView, "Goals" header (26/800), empty vs content, FAB, celebration overlay, toast, sheet/dialog state enum (`add`, `edit(goal)`, `allocate(goal)`, `actions(goal)`, `confirmDelete(goal)`), `busy` flag, `@Environment(AppModel.self)`. Re-read `model.now` when the scene becomes active. |
| `GoalsSummaryCard.swift` | Summary ring plus aggregates. |
| `GoalCard.swift` | Card, `GoalStatusPill`, `GoalMoreButton`, Add money button. Complete style: gradient plus `onLongPressGesture`. |
| `GoalFormDialog.swift` | Add/edit form, validation, target-date tile. |
| `GoalAllocationDialog.swift` | Amount field, quick chips (`FlowLayout` or Layout for the wrap). |
| `GoalActionsSheet.swift` | Bottom sheet with a card and tiles. Use `.presentationBackground(.clear)` and a height detent. |
| `DeleteGoalDialog.swift` | Confirmation dialog (or reuse the shared dialog). |
| `GoalCelebrationOverlay.swift` | `TimelineView(.animation)` with `Canvas` for the 18 dots, plus the card view. |
| Shared (coordinate with other analysts) under `Views/Components/`: `GlowCard`, `ProgressRing`, `PillButton`, `PillChip`, `IconTile`, `BudgieHeader`, `GlowFab`, `BudgieDialog` presenter, `BudgieToast`, `BudgieTextField`, `DateTile`. | |
| `native/BudgieCore/.../Domain/SavingsGoal.swift` | Record, derived, summary, sort. |
| `native/BudgieCore/Tests/.../SavingsGoalTests.swift` | Tests. |

### 5.2 Implementation notes

- **Ring:**
  - Stroked `Circle` track, trimmed `Circle` with `.rotationEffect(-90°)`, `lineCap: .butt`, inner disc.
  - Animate `trim` with `.timingCurve(0.645, 0.045, 0.355, 1, duration: 0.9)`, from 0 on appear.
  - Glow: SwiftUI `.shadow(radius:)` at about `blurRadius / 2` (tune by eye). In dark, alpha = `glowAlpha * t`. In light, use the offset soft shadow.
  - Disable animation under Reduce Motion.
  - Key rows by `goal.id`. Flutter is unkeyed, so a sorted move makes a ring animate to another goal's value; keying fixes that.
- **Celebration:**
  - `TimelineView(.animation)`; `progress = clamp((t - start) / 1.6, 0, 1)`.
  - Dots via `Canvas` (`context.fill(Path(ellipseIn:), with: .color(...))`).
  - Card scale uses `UnitCurve.bezier(startControlPoint: .init(x: 0.175, y: 0.885), endControlPoint: .init(x: 0.32, y: 1.275))` (iOS 17) on `clamp(v, 0, 0.8) / 0.8`.
  - Fade after 0.75; scrim `0.34 * fade`.
  - `.allowsHitTesting(false)`.
  - Haptic: `.sensoryFeedback(.impact(weight: .medium), trigger:)`, always.
  - Skip the overlay when `accessibilityReduceMotion`.
  - Post an `AccessibilityNotification.Announcement` "Goal complete, {name}".
- **Dialogs:**
  - Flutter uses centered dialogs (barrier, fade/scale).
  - Faithful match: a shared centered dialog presenter with a scrim and keyboard avoidance. Recommend building this once in `Components/`, since other features use it too.
  - Cheaper alternative: `.sheet` with detents (native, keyboard-safe, less faithful).
  - Date picking: graphical `DatePicker` in a nested sheet or popover. Clamp the range to include the stored date (Flutter asserts here).
- **Text fields:** custom wrapper (chip-surface fill, radius 14, 1px stroke, accent 1.5 on focus). Emulate the floating Material label as a small secondary caption above the value. Show error text in danger color under the field.
- **Icons (Material to SF):**

| Material | SF Symbols |
|---|---|
| add_rounded | `plus` |
| flag_rounded | `flag.fill` |
| attach_money_rounded | `dollarsign` |
| edit_rounded | `pencil` |
| delete_rounded | `trash` |
| event_rounded | `calendar` |
| chevron_right_rounded | `chevron.right` |
| more_horiz_rounded | `ellipsis` |
| check_rounded | `checkmark` |
| savings_rounded | no piggy in SF Symbols; use a custom SF-style symbol asset or `banknote` |

- **Fonts:** bundle Gabarito and SplineSansMono via `UIAppFonts` and `project.yml`; use `Font.custom(_, size:, relativeTo:)` so Dynamic Type works.
- **Money:** `model.moneyFormatter.format(x, decimalDigits: 0)` for card and summary amounts, default 2 decimals for the chips. Dates with an en_US fixed formatter (`MMMd`, `yMMMd`), not device locale.
- **Amount parsing:** reuse `TransactionFormView.parseAmount` logic (locale decimal separator, finite, `> 0`) via a shared helper, with an `allowZero` variant for "Saved so far". Keep stored values exactly when the field text is unchanged (as `TransactionFormView.save` does at `:~275`). Do the same for the "Finish goal" chip: keep the exact `remainingAmount` unless the user edits the field.
- **Dates in the form:** picked day stored as `model.calendar.date(y, m, d)`. In edit mode keep the stored `targetDate` exactly unless the user picks a new day (`dayIsPicked` pattern as in `TransactionFormView`).
- **Accessibility:** combine each card into one VoiceOver element ("Vacation, 25 percent, On track, $1,250 of $5,000, Nov 30, $360 per month keeps you on pace") with actions Add money / Edit / Delete. Buttons need labels. Keep the existing "Add savings goal" and "More goal actions" labels.
- **Haptics:** light on buttons and the More tap, medium on long-press and completion, selection on chips and date pick.

### 5.3 Build order and effort

1. **BudgieCore record, mutations, derived values, summary, sort, id, typed section serializer, `StoredRow` conversion. Effort: M.**
2. **Core unit tests and Dart-harness goal-mutation and derived-value fixtures across time zones. Effort: M.**
3. **AppModel API + `serialize` case + `RehearsalSummary` scripted-edit hook and UpgradeTest add-on (edit goals in Swift, load in Flutter). Effort: S.**
4. **Shared components (`GlowCard`, `ProgressRing`, `PillButton`, `PillChip`, `IconTile`, header, dialog presenter, toast, text field, date tile) and fonts. Effort: M-L (shared cost).**
5. **`GoalsView` content: empty state, summary card, goal card, status pill, sort, hide-balances behaviour. Effort: M.**
6. **Goal form dialog (validation, date picker, edit-preserves-exact-values). Effort: M.**
7. **Allocation dialog, chips, actions sheet, delete dialog, toasts, busy guard. Effort: S-M.**
8. **Celebration overlay, haptics, reduced motion, VoiceOver announcement. Effort: S-M.**
9. **Tab wiring (depends on the shell decision), UI tests in `BudgieUITests`, screenshot comparison against Flutter. Effort: S-M.**

Overall: L.

## 6. Risks and open questions

1. **Tab shell.** Goals needs a slot. The 5-tab `TabView` cannot hold 6 without "More". Decide between a custom floating dock (matches Flutter) and folding Recurring/Goals differently.
2. **Success toast semantics.** Flutter shows "added/updated/deleted" even if the save failed. It relies on the banner for failures. Keep that, or change the toast when `saved == false`? Recommend: success toast when applied, and rely on the existing banner.
3. **Silent no-ops.** The model ignores invalid input (empty name, target `<= 0`, missing id, amount 0) without any message, but the form validators prevent those cases. Keep that split.
4. **Duplicate ids.** Flutter updates and deletes all rows with that id. Match that, or use first-match? Only matters for hand-edited or restored data.
5. **`createdAt` fallback.** A row missing `createdAt` or `targetDate` reads as "now" on every load until saved. Both apps have this drift. Swift should not persist the fallback until the row is edited.
6. **Timezone change and DST.** `targetDate` is stored as local midnight without offset, and status math uses elapsed ms. A DST crossing shifts the numbers by an hour; Dart does the same. Parity tests should pin this.
7. **Celebration on Edit.** Editing "Saved so far" to complete a goal gives no celebration or haptic in Flutter. Keep parity, or celebrate in both paths? Open.
8. **Decimal separator.** Flutter strips all commas, so "1,5" reads as 15 in comma-decimal locales. Swift should use locale-aware parsing (already the choice in `TransactionFormView`). Document it as a deliberate difference.
9. **Precision.** Flutter prefills 2 decimals, so editing without touching the field rounds sub-cent values. "Finish goal" can leave a fractional shortfall. Proposed: keep exact values when text is unchanged. Confirm this approved divergence.
10. **Non-finite input.** Flutter validators accept `NaN` and `Infinity`, which would poison the file (jsonEncode throws). Swift must require finite.
11. **Overdue edit crash.** Flutter's date picker asserts when the stored date is before `Jan 1 (year-1)`. Swift must clamp the picker range to include the stored date.
12. **Piggy-bank icon.** No SF Symbol. Custom asset or `banknote`; needs a design call.
13. **Fonts.** Gabarito and Spline Sans Mono are not bundled in the Swift app; the "close look" needs them, including licensing and `project.yml` changes.
14. **Snackbar text color** is unspecified in Flutter (Material default), so screenshot the real app before matching.
15. **Reduce Motion.** Ring animation, FAB burst and celebration should all honour it, as Flutter does.
16. **Name trim.** Dart `trim()` and Swift `.whitespacesAndNewlines` differ on a few characters (for example U+FEFF); the existing code already accepts this.
17. **Backup and insights coupling.** Insights ("goal behind schedule") needs `createdAt`, `progress` and `progressPercent` from the new API. Backup export needs `savingsGoalsSection()`, and restore needs `replaceSavingsGoals`. Coordinate with those analysts.
18. **Hide balances.** Money strings become `••••`, including chips and pace copy; make sure the layout tolerates that.

Key files:
- `W/budget_app/lib/savings_goals_page.dart`, `W/budget_app/lib/savings_goal.dart`
- `W/budget_app/lib/transaction_model.dart` (`:868-963`, `:1466`)
- `W/budget_app/lib/safe_to_spend.dart`
- `W/budget_app/lib/widgets/{glow_card,progress_ring,pill_chip,glow_fab,budgie_header}.dart`
- `W/native/BudgieCore/Sources/BudgieCore/Domain/{Records,FinancialData,SafeToSpend}.swift`
- `W/native/Budgie/App/AppModel.swift`, `W/native/Budgie/Views/{MainView,Theme,TransactionFormView}.swift`
- `W/native/ParityHarness/parity/logic_fixtures_test.dart`
