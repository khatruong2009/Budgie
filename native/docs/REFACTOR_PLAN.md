# Refactor plan: dead code, duplication, structure, docs

Source: a read-only audit of the whole repo on 2026-10-29 (eight agents,
spot-checked by grep). This plan turns every finding into an ordered, verifiable
task. It changes no user-visible behavior and no stored bytes; anything that
would is listed under "Excluded" at the end.

Read `AGENTS.md` and `FULL_APP_PLAN.md` section 3 before starting. Track the
work in beads (`bd prime`, `bd ready`); file one bead per phase under an epic
and claim each as you go.

## Ground rules for the implementing agent

1. **Branch.** Work on `claude/refactor-sweep` cut from `main`. One commit per
   task (the numbered items below), message `Refactor: <task id> <summary>`.
   Never amend, force push, or skip hooks.
2. **Line numbers drift.** Every location below is a starting point from the
   audit. Find the code by symbol name with grep, and re-confirm each
   "unused" claim with `grep -rn '<symbol>' native --include='*.swift'`
   (exclude `.build/`) immediately before deleting it.
3. **No behavior change.** Same output, ordering, rounding, layout,
   accessibility labels and identifiers, store bytes. Accessibility
   identifiers and XCUITest-visible strings must stay byte-identical. If a
   task turns out to need a visible change, stop, skip it, and file a bead.
4. **Parity code stays.** Dart number lexemes, `DartDateTime`/`DartCalendar`,
   `DartString` UTF-16 comparison, raw-JSON patching, replicated Flutter bugs
   (see `PARITY_GAPS.md`) are deliberate. Do not "simplify" them.
5. **Files.** After adding, removing or moving any Swift file:
   `cd native && xcodegen generate` and commit `project.pbxproj` with it.
   Match the surrounding indentation (the widget file uses 2 spaces).
6. **Simulators.** Follow the owner's rules: reuse an idle existing simulator,
   don't create new ones if one fits, shut down whatever you booted.
   `ui_flow.sh` creates and erases its own `Budgie-UITest` device; that is
   the existing workflow and is fine to use until Phase 9 changes it.
7. **Stop points.** Tasks marked **[OWNER]** need the owner's explicit OK
   before you do them. Ask once, in one message, at the start of the phase
   that contains them; do the rest of the phase meanwhile.

### Verification gates

Run the gate named in each phase before its last commit; a phase is done only
when its gate passes.

- **G-core:** `cd native/BudgieCore && swift test` passes.
- **G-build:** `cd native && xcodegen generate`, then build the `Budgie` scheme
  for an iOS simulator with zero warnings:
  `xcodebuild build -project Budgie.xcodeproj -scheme Budgie -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual 2>&1 | grep -E 'warning:|error:|BUILD'`
  (no `warning:` lines; `BUILD SUCCEEDED`).
- **G-app:** `xcodebuild test ... -only-testing:BudgieAppTests` passes.
- **G-ui:** the UI test classes for the touched screens pass, plus
  `native/scripts/ui_flow.sh` (needs the Flutter SDK). Also run
  `AccessibilityAuditUITests` when a view's structure changed.
- **G-dart:** `native/ParityHarness/run.sh` regenerates fixtures and
  `git status native/Fixtures` shows no change (byte-identical).
- **G-system:** `native/scripts/system_flow.sh <Flutter Runner.app>` when the
  widget, quick actions, deep links or scene delegate change.

**Baseline first (Phase 0).** Record which tests already fail on `main` so
you don't chase them: known failures include
`SettingsUITests.testNumberFormatSheetChangesHowAmountsAreWritten`
(bead budgie-dkr) and `InsightsUITests` after the Backup/CSV fixtures
(budgie-uia.63). Write the baseline into the epic bead's notes.

---

## Phase 0: setup and baseline

- 0.1 Create the branch and the beads epic plus one bead per phase.
- 0.2 Run G-core, G-build, G-app, G-ui, and G-dart if the Flutter SDK is
  available. Save the pass/fail list. Every later gate compares against it.

## Phase 1: dead code (low risk)

Re-grep each symbol first. Gate: G-core, G-build, G-app.

- 1.1 Delete `native/Budgie/Views/Theme.swift` (the `Theme` shim and
  `CategoryIcon`, no references).
- 1.2 `DesignSystem/Typography/TextStyles.swift` "Legacy" block: delete the 13
  unused specs (`displayLarge/Medium/Small`, `headingMedium`,
  `labelLarge/Medium`, `buttonLarge/Medium/Small`, `captionSmall`,
  `numericLarge`, `numericMediumBold`, `numericSmall`). Keep the ones still
  used (`headingSmall`, `numericMedium`, `headingLarge`, `body*`,
  `labelSmall`). Fix the stale comment ("still used by forms, dialogs and the
  lock screen") and remove the Dart line-number annotations ("lines 14-216").
- 1.3 `DesignSystem/Tokens/Glow.swift`: delete `perfShadow` and the
  `PerfFlags.noGlow` flag it reads; remove the `BUDGIE_PERF_NO_GLOW` A/B
  switch from `docs/PERFORMANCE.md` (lines ~32, 73, 167), noting it was
  retired.
- 1.4 `DesignSystem/Tokens/Colors.swift`: delete `surface`, `incomeGradient`,
  `expenseGradient` and the private `gradient(light:dark:)` overload. Then
  check `incomeStops`/`expenseStops`; delete if now unused.
- 1.5 `DesignSystem/Tokens/Metrics.swift`: delete `spacingXXL`, `spacingXXXL`,
  `radiusXS`, `radiusS`, `radiusXL`, `radiusXXL`, `iconXS`, `iconM`, `iconL`,
  `iconXXL`. `Motion.swift`: delete `slow`, `verySlow`, `easeInOutCubic`.
  Keep single-use tokens.
- 1.6 `DesignSystem/Components/Progress.swift`: drop the `gradient` parameter
  of `GlowProgressBar` (only the gallery passes it); update
  `Debug/DesignGalleryView.swift`. Keep `showThumb` only if the gallery
  needs it; otherwise drop it too.
- 1.7 `Views/Home/HomeHero.swift` `RollingAmount`: remove the never-passed
  `alignment` parameter and the stale "Worth rolls heroMedium, leading" doc.
- 1.8 `App/AppModel.swift`: delete `carryNetWorthMonthForward` (keep the
  BudgieCore function and its tests).
- 1.9 `Views/Flow/TrendCard.swift`: delete `TrendValues.magnitudeSquared`.
- 1.10 BudgieCore, never used anywhere: `DirectoryFileSystem.applicationSupportStore`
  (`Store/StoreFileSystem.swift`), `CashFlowMath.Bar.badgeBoxLeft` and
  `badgeBoxWidth`, `CategoryBreakdown` slice `canHighlight`,
  `FinancialStore.isLoaded`.
- 1.11 Tests: delete `compactRows` (`BackupParityTests.swift`). In
  `DomainParityTests.swift` remove the no-op `_ = asOfText` and replace the
  `firstIndex { $0.value == result.value }` reverse lookup with the
  enumerated index (it is O(n^2) and wrong for equal values). In
  `AccessibilityAuditUITests.swift` remove the single-iteration
  `for theme in ["Light"]` loops (~lines 806, 828, 848).
- 1.12 `ParityHarness/run.sh`: remove the `has()` guard and its comment (all
  six guarded files exist). Gate: G-dart.

## Phase 2: test helpers and test hygiene

Gate: G-core, G-app, the UI test classes touched, G-dart for 2.8.

- 2.1 **Core test support.** Create `BudgieCore/Tests/BudgieCoreTests/TestSupport.swift`
  and move `J`, `loadExpected`, `launch`, `launchWithSnapshot` there from
  `DomainParityTests.swift`. Add `Fixtures.json(_:) -> J` and
  `Fixtures.zonePath(_ group:, _ zone:)` (the
  `replacingOccurrences(of: "/", with: "_")` path) to `Fixtures.swift`.
  Replace the private `fixture(...)` copies (18 files: HomeParity, SpendParity,
  GoalsParity, WorthParity, HomePageParity, TransactionMutationParity,
  FlowParity, LogicDSTParity, ...) and the 12 zone-path copies.
- 2.2 Move the identical `bits(_:)` (9 files) and the `same(...)`,
  `strings(_:)`, `units(_:)` helpers (CSVImportParity, InsightParity,
  HomePageParity, MonthListParity, VoiceRequestParity, ...) into
  `TestSupport.swift`. Keep signatures; if two copies differ, keep both under
  distinct names rather than changing what a test checks.
- 2.3 Add `TestDirectory.make(_ prefix:)` and replace the 14 hand-built
  `budgie-*-\(UUID())` temp paths in Core and App tests.
- 2.4 Add a `ForwardingStoreFileSystem` test base with overridable hooks;
  port the four fault decorators (DeepMigrationSafetyTests,
  MigrationAuditTests, PersistenceTrackerTests, StoreSafetyTests). Each must
  keep its exact fault behavior; if one doesn't fit cleanly, leave it.
- 2.5 Make the scenario `loadPrefs` accept `Data` so `loadPrefsJSON`
  (`ScenarioSupport.swift`, `StoreParityTests.swift`) stops writing a temp
  file.
- 2.6 **App tests.** Extract the shared scaffold (temp dir, suite
  `UserDefaults`, `OnboardingFlag.markCompleted`, teardown) and `stored()`
  from `InsightModelTests`, `RecurringOnboardingModelTests` and
  `DataTransferModelTests` into `BudgieAppTests/AppTestSupport.swift`.
- 2.7 **UI tests.** In `UITestSupport.swift` the helpers already exist; delete
  the per-class copies and call the shared ones:
  - `element(_:)` (8 files), `labelled(_:)` (6), `homeRoot()` (5; use
    `goToHomeRoot()`), `openSettings()` (MVPFlow, Backup),
    `showDollarAmounts()` (Worth), `waitUntil` (Categories, TagsRules,
    Backup; use the predicate waiter), `route(_:)` (RouteOverPresentation,
    Voice: move one copy into support).
  - Add `XCUIApplication.budgie(skipOnboarding:)` that sets
    `BUDGIE_SKIP_ONBOARDING`, launches and waits for the Home tab; use it in
    the 19 `setUp` blocks and 5 `launch()` helpers.
  - Update the comment in `UITestSupport.swift` that says per-class copies
    were left on purpose.
- 2.8 **Vacuous passes.** `DomainParityTests.parity` (~line 212) and
  `CategoryMaterializationTests.parity` (~line 18) `return` when the Dart data
  is missing. Make them fail (`Issue.record` / `#require`) instead. Then
  compare the two: if `CategoryMaterializationTests` is a strict subset of
  `assertDartSummary`, delete it; otherwise keep both and note why in a
  comment.
- 2.9 Merge the duplicate generator loop (`LogicDSTParityTests.checkGeneratorCases`
  vs `DomainParityTests.generator`) and the safe-to-spend zone tests
  (`DomainParityTests.safeToSpend`, `SafeToSpendRandomTests.random`,
  `LogicDSTParityTests` Beirut/DST cases) into one parameterized test each
  over a zone list. Every fixture file must still be read.
- 2.10 **Flaky waits.** `GoalsUITests.waitForTransient` busy-spins: replace
  with `waitForExistence` or a short-sleep poll. Replace fixed sleeps where an
  element wait works: `SystemIntegrationUITests` (~137, 155, 165),
  `VoiceUITests` (~349), `TagsRulesUITests` absence checks (~276, 313; use a
  `NSPredicate(format: "exists == false")` expectation), `InsightModelTests`
  fixed sleeps and 10 ms poll, `DataTransferModelTests` 5 ms poll. Leave
  `AuditSupport.swift`'s 0.8 s settle unless a wait for a specific element
  is clearly equivalent.
- 2.11 **AccessibilityAuditUITests relaunches.** Collapse the four relaunches
  in `cleanUp` into in-app navigation where the launch arguments are the
  same. Keep relaunches whose arguments differ (XXXL, lock, mic-denied).
  Run the full audit twice to check state doesn't leak.
- 2.12 Move `SwiftOutputForDart.swift` (fixture generator, gated by
  `BUDGIE_SWIFT_OUT`) into its own clearly named file group or test target
  only if `verify-swift-output-in-dart.sh` keeps working unchanged; otherwise
  leave it and add a header comment saying what it is.

## Phase 3: BudgieCore helpers

Gate: G-core and G-dart (fixtures byte-identical), then G-build and G-app.

- 3.1 **Calendar helpers.** In `Dates/DartCalendar.swift` add `startOfDay(_:)`,
  `addingMonths(_:_:)`, `isSameMonth(_:_:)` and `monthKey(_:)`; each reads
  `DartDateTime.fields` once. Replace the inline forms:
  - `year*12+month`: `DartCalendar.swift:87`, `LedgerIndex.swift:90`,
    `Insights.swift:176` (`Rules.key`).
  - `calendar.date(x.year, x.month, x.day)`: ~13 sites (Records,
    FinancialData, Insights, SafeToSpend, SavingsGoals, RecurringForm,
    `Budgie/Views/Goals/GoalForm.swift`).
  - `calendar.date(y, m ± n)`: ~8 sites; same-month tests: ~13 sites
    (SafeToSpend, CashFlowMath, Records, NetWorthMutations, CategoryBreakdown,
    `Budgie/Views/Spend/SpendMonthSheet.swift`).
  The helper must call exactly the same `DartCalendar` constructor as the
  inline code it replaces, so normalization is unchanged. Do not touch
  `netWorthDayKey`. Leave `netWorthMonthKey` as is.
- 3.2 **Record decoding.** Add `Read.optionalBool`, `optionalInt` (strict
  Dart int), `optionalNumber` (any number via `DartNumbers.toInt`),
  `optionalDate`, `stringArray` next to the existing `Read` helpers in
  `Domain/Records.swift`. Replace the 15 `case nil, .null?` switches and the 5
  local closures (`Categories.swift` `optionalBool`, `Categorization.swift`
  `optionalNumber`, `Records.swift` `optionalDate`, `optionalInt`,
  `readDouble`/`readDate`). The bad-row fixtures must still pass unchanged.
- 3.3 **UTF-16 trim.** Add `DartString.trimUnits(_:)` and replace the three
  copies (`CanonicalRecords.swift`, `CSVImport.swift`, `DartDoubleParse.swift`).
- 3.4 **Timestamps and hashes.** Add `DartDateFormat.yyyyMMdd_HHmmss` and use it
  in `BackupEnvelope.swift`, `CSVExport.swift`, `PreRestoreBackup.swift` (drop
  their private `pad`s; use `DartCalendar.pad`). Check whether
  `PreNativeMigrationBackup.swift`'s `DateFormatter` produces the identical
  string in every zone (the backup tests cover it); switch it only if so.
  Share one `sha256Hex` between `PreRestoreBackup` and
  `PreNativeMigrationBackup`.
- 3.5 **Dart helpers in one place.** Move `FinancialData.dartCompare`
  (`Budgets.swift`) and `dartClampExact` (`SavingsGoals.swift`) into
  `Domain/DartMath.swift`. Rename the nested `BackupError` in
  `PreNativeMigrationBackup.swift` if it collides in meaning with the
  top-level one; otherwise just document the difference. Leave the three
  Dart rounding helpers' behavior as is; co-locate them if that doesn't
  change any signatures callers depend on.
- 3.6 **Cheaper reads.** Add `count`/`first(where:)` paths that work on
  `*Rows` directly so `unreadableTransactionCount`, `netWorthEntry(id:)` and
  `savingsGoal(id:)` don't build whole arrays. `SettingsView`'s
  `data.transactions.count` should use the readable-row count without
  building the array (same semantics: count only readable rows).
- 3.7 **Test doubles out of the app.** Move `InMemoryFileSystem`
  (`Store/StoreFileSystem.swift`) and `InMemoryPreferences`
  (`Store/Preferences.swift`) into `Tests/BudgieCoreTests`. Confirm with grep
  that no app, widget or app-test target uses them first.
- 3.8 **Test-only oracle.** `FinancialData`'s `MonthTotals`, `monthLedger`,
  `totals(forMonth:)`, `availableMonths`, `transactionsNewestFirst` (both),
  `sortNewestFirst`, and `TransactionRecord.newestFirst` duplicate
  `LedgerIndex`. Repoint `Budgie/App/RehearsalSummary.swift`,
  `DomainParityTests` and `LedgerIndexTests` at `LedgerIndex`, then delete
  them. `DomainParityTests` still compares against Dart fixtures, which keeps
  the independent check.
- 3.9 **Test-only API.** For each of `HomeSummary.gaugeFraction`/`gaugeLabels`,
  `TransactionFilter.parseAmount`, `DartJSON.encodeIndentedString`,
  `CSVImport.Failure.flutterDescription`, `BackupRestore.keptSections`,
  `FinancialStore.resetInMemoryState`, `savingsGoal(id:)`,
  `trackedNetWorthEntryCount`, `staleNetWorthEntryCount`,
  `Insights.supportingValue`, `DonutGeometry.innerRadius`: if a Dart-fixture
  test depends on it, keep it and mark it `// Test-only: checked against <fixture>`.
  If its only test is a Swift-only test of the helper itself and the app
  doesn't use the concept anymore (`gaugeFraction`/`gaugeLabels` from before
  the redesign), delete it together with that test.
- 3.10 **Id comparison.** Use `DartString.equal` for id comparisons in
  `FinancialData.swift` (~281, 291, 395, 410, 421, 436, 441) and
  `Categories.swift` (~287), as plan section 3 requires.
- 3.11 **App re-implements Core.** Make `RecurringForm.normalizedAmount`
  public and delete `TransactionFormView.normalizedAmount`. Move the pure
  parsing in `Budgie/DesignSystem/AmountInput.swift` into BudgieCore next to
  `MoneyFormatter` with tests copied from its current behavior; leave the
  SwiftUI part in the app.
- 3.12 **File splits (moves only).** Split `Domain/Records.swift` into
  `Read.swift`, one file per record type, and `DartNumbers.swift`. Move the
  template mutations out of `FinancialData.swift` into
  `FinancialData+Templates.swift`. Move `BackupEnvelope`,
  `PreRestoreBackup`, `PreNativeMigrationBackup` into `Backup/` and
  `CSVImport`, `CSVParser`, `CSVExport` into `CSV/`. SwiftPM picks up new
  folders automatically; no `Package.swift` change should be needed.

## Phase 4: AppModel

Gate: G-build, G-app, G-ui (full `ui_flow.sh`).

- 4.1 **Mutation helper.** Add one private helper, e.g.
  `mutate(_ sections: [String], _ body: (inout FinancialData) -> Bool, after: () -> Void = {}) async -> Bool`,
  and `mutateNetWorth(...)` that bumps `netWorthRevision` in exactly one
  place. Replace the 21 `guard data != nil ... data!.x(...)` blocks
  (transactions, templates, budgets, net worth, goals). Keep the `isFinite`
  pre-guards at the call sites. Do **not** move the revision bump into
  `data.didSet` (it would invalidate `worthCache` on every transaction edit).
- 4.2 **Delete/update outcome.** Have `deleteTransaction` and
  `updateTransaction` return `SaveOutcome` (`.rejected` when the row is
  missing), matching the goals API. Delete `hasTransaction(id:)` and its
  six pre-checks (Home `TransactionsView`, Spend `CategoryTransactionsView`,
  Flow `FlowTransactionsView`, `TransactionFormView` x2). Toast mapping stays
  identical (missing row behaves as it does today).
- 4.3 **One outcome type.** Replace `CategoryOutcome` and `TagRuleOutcome`
  with a generic `EditOutcome<E: Error>` and share one copy-edit-persist
  routine between `editCategories` and `editTagsAndRules`. Update callers
  (CategoriesView, CategoryEditorDialog, TagDialogs, TagsRulesView,
  RuleEditorDialog). Leave `Bool` returns elsewhere as they are.
- 4.4 **Small duplicates.**
  - `syncSaveState()` for the three `hasUnsavedChanges`/`lastSaveError`
    mirror blocks and the post-restore reset.
  - `nonisolated static func makeID()`; `newID()` calls it; the three
    detached tasks pass it instead of inline UUID closures.
  - `waitForUnlock()` for the two copies of the protected-data wait.
  - One `route(forName:)` shared by `open(_ url:)` and `handleShortcut`,
    normalising `-` and `_`. Accepted inputs must be exactly the union of
    today's.
  - `AppModel.appLockEnabled` used by `AppLockWindow.enabled`, `isLocked`,
    and `SettingsView`.
  - `DeviceAuth` exposes `LABiometryType`; `LockScreen` stops comparing the
    "Face ID" string.
  - Rename the gated `suggestion(...)` overload to `gatedSuggestion(...)`.
  - Inline `StatusScreen` (`RootView.swift`) into its single use.
- 4.5 **Safe-to-spend memo.** `PERFORMANCE.md` measured 2.9 ms and decided no
  change; leave it. (Listed so the agent doesn't redo the analysis.)
- 4.6 **Split the file.** Move AppModel into extensions by area, no behavior
  change:
  `AppModel.swift` (state, init, bootstrap, persistence, widget sync),
  `AppModel+Transactions.swift` (transactions, recurring, budgets),
  `AppModel+Worth.swift`, `AppModel+Goals.swift`, `AppModel+Settings.swift`,
  `AppModel+Categorization.swift`, `AppModel+Insights.swift`,
  `AppModel+DataTransfer.swift`, `AppModel+Routing.swift`, and
  `AppModelTypes.swift` (AddRoute, ThemeMode, AppIdentifiers, outcome enums,
  DueGeneration, DataTransferError, RestoreOutcome, BackgroundWork).
  Relax only the members the extensions need from `private` to internal
  (`persist`, `newID`, `transactionsChanged`, `store`, `tracker`,
  `preferences`, `storeDirectory`, `applicationSupport`, `isRestoring`,
  `editedDuringRestore`, `data`'s setter to `internal(set)`). Stored
  properties stay in the class body. Do this last in the phase so the diff
  of 4.1-4.4 stays reviewable.

## Phase 5: shared design-system components

Each new component lands with its first adopter in the same commit; the
remaining adopters follow in Phase 6. Gate: G-build, the UI tests for each
touched screen, `AccessibilityAuditUITests`, plus a before/after screenshot
of each touched screen in light and dark (store them under the scratchpad,
not the repo) to confirm no visual change.

- 5.1 `budgiePushedTitle(_ title:, style: TextSpec = .cardTitle, scales: Bool = false)`
  in `Components/Chrome.swift`: navigation title, inline display mode,
  visible toolbar, both `toolbarBackground`s, principal header with
  `.isHeader`. `scales: true` reproduces RecurringView's
  `lineLimit(1)+minimumScaleFactor(0.8)`. TransactionsView and
  FlowTransactionsView pass `.sectionHeader` with no `singleLine`; add a
  parameter if needed rather than changing them.
- 5.2 `TransactionRowLayout(tile:title:titleLines:isRecurring:subtitle:amount:amountColor:)`:
  presentational only (HStack 12, tile, title + `RecurrenceGlyph(size: 16)`,
  subtitle, `.amountSmall` amount with `layoutPriority(1)`, padding 12).
  Buttons, accessibility and data stay at the call site.
- 5.3 `OptionRow(title:selected:boldWhenSelected:hidesCheckFromVoiceOver:identifier:)`
  and `OptionListCard` (GlowCard padding 0 with Hairlines).
- 5.4 `DialogTitle` (rename `TagsRulesDialogTitle`, move from
  `TagDialogs.swift`) and `DialogButtons(cancelId:submitTitle:submitId:color:symbol:busy:submit:)`
  (HStack 12, two `PillButton(height: 44)`, top padding 24).
- 5.5 `PillButton(loading:)`: the spinner-over-capsule state now
  hand-built in `BudgetLimitSheet` and `AccountEditorDialog`.
- 5.6 `HapticButton(action:label:)` that owns the `taps` counter and the
  light-impact `sensoryFeedback`.
- 5.7 `.floatingActionInset { }` for the bottom `safeAreaInset` FAB block.
- 5.8 Text styles: add `.note` (Regular 13 / 1.25 / footnote) and
  `.noteStrong` (Semibold 13 / 1.25 / footnote) to `TextStyles.swift`.
  Merge only the two sheet "blurb" specs that are identical (14pt, 1.3).
- 5.9 `Motion.animate(_:reduceMotion:_:)` for the
  `if reduceMotion {...} else { withAnimation }` idiom. `MonthStrip` reads
  `accessibilityReduceMotion` from the environment itself; drop its
  parameter.
- 5.10 `FieldErrorLabel` (from `Fields.swift`) and `FieldCaption(_:isHeader:hidden:)`.
- 5.11 Move `BudgetSheetLayout.handleHeight` from `BudgetsSection.swift` to
  `Chrome.swift` next to `budgieSheetChrome`. Move `RollingAmount`,
  `DigitReel`, `ReelOffset` out of `HomeHero.swift` into DesignSystem and
  give `RollingAmount` a `hidden:` flag that renders the hidden-balance text.
- 5.12 `Binding<Bool>(isPresent: Binding<T?>)` extension; `uniqueKeys(_:id:)`
  on `Collection` for the `#n`-suffixed row keys (must produce identical
  keys; UI tests use them).
- 5.13 Token cleanup with no visual change: fold `border` into `cardBorder`
  and `donutRemainder` into `trackSecondary` (identical values); use
  `accent`/`income`/`danger`/`warning` directly instead of the four `chart*`
  aliases. Replace literal paddings, spacings and corner radii in Views
  with tokens **only where the value is exactly equal** (padding 2/4/8/16/24,
  radius 16 -> `radiusL`). Do not snap 12, 14 or 18 to other values and do
  not add new tokens for them.

## Phase 6: adopt the components in views

One commit per component. Gate per commit: G-build plus the UI tests for the
touched screens; at the end of the phase, full G-ui and
`AccessibilityAuditUITests`.

- 6.1 `budgiePushedTitle` in all ten pushed pages: SettingsView,
  RecurringView, CategoryTransactionsView, FlowTransactionsView,
  DiagnosticsView, CategoriesView, TagsRulesView, LicencesView,
  Home/TransactionsView, Worth/AccountHistoryView.
- 6.2 `TransactionRowLayout` in Home `RecentRow`, Home `TransactionRow`,
  Spend `ExpenseRow`, Flow `FlowTransactionRow`, Flow `ResultRow`.
  Check truncation with a very long description and a huge amount.
- 6.3 `.deleteTransactionAlert(pending:)` modifier (alert, action from 4.2,
  heavy-impact haptic) in Home TransactionsView, Spend
  CategoryTransactionsView, Flow FlowTransactionsView. Leave
  TransactionFormView's own delete as is. Replace the six
  `deleteAlertBinding`-style shims with `Binding(isPresent:)`.
- 6.4 `OptionRow`/`OptionListCard` in `RangeSheet`, Flow `PickerSheet`,
  `SpendMonthSheet`, `SettingsChoiceSheet`. Keep each sheet's own detent
  maths, bold-when-selected setting and VoiceOver check-hiding.
- 6.5 `DialogTitle`/`DialogButtons` in CategoryEditorDialog (also replace its
  inline title), NewTag and DeleteTag dialogs, RuleEditorDialog,
  DataImportDialog, GoalForm, AllocationDialog, DeleteGoalDialog,
  AccountEditorDialog. After 4.3, add one `handle(_ outcome:)` used by the
  category/tag/rule dialogs if their outcome switches are identical.
- 6.6 `PillButton(loading:)` in BudgetLimitSheet and AccountEditorDialog.
- 6.7 `HapticButton` at all `taps += 1` sites (23).
- 6.8 `.floatingActionInset` in HomeView, WorthView, GoalsView,
  DesignGalleryView.
- 6.9 `.note`/`.noteStrong` replacing the per-file specs (HomeHero,
  TransactionsView, HomeView x2, AllocationDialog, YearOverYearCard,
  GoalText.caption, WorthStyle.note, AccountHistoryText.note, FlowView,
  FlowTransactionsView, SettingsRows).
- 6.10 `Motion.animate` at HomeHero, Progress x2, GlowFab, Chrome; remove the
  `reduceMotion` environment reads in TransactionsView and WorthView that only
  fed `MonthStrip`.
- 6.11 `uniqueKeys` in TagsRulesView, CategoriesView, GoalsView.
- 6.12 `TagChip(showsCheck:)` in RuleEditorDialog (leave Flow's filter chip,
  a different design).
- 6.13 `FieldErrorLabel` in RecurringFormView; `FieldCaption` in
  RecurringFormView, CategoryEditorDialog, RuleEditorDialog x2.
- 6.14 `ChipWrap` -> `FlowLayout(spacing: 8)` in FlowTransactionsView.
  `FlowLayout` shrinks over-wide chips where `ChipWrap` overflows: test with
  a 60-character tag name. If it looks different, keep `ChipWrap` and skip.
- 6.15 Small items: `Hairline().padding(.leading, 64)` in QuickExpenseSheet;
  one `AccountEditorRequest` builder for WorthView and AccountHistoryView;
  `NetWorthEntryType.tint` for the three `asset ? income : danger` sites;
  `SettingsRow(identifier:)` instead of the five `AnyView` wrappers;
  `Toast.error(_:)` for the five danger toasts; remove the double blank line
  in BudgetsSection.
- 6.16 Shared `CategoryChoices` for the category loading duplicated between
  TransactionFormView and RecurringFormView, only if the voice-prefill path
  stays untouched; otherwise skip and note it.
- 6.17 One `YearStepper(year:range:size:)` for `HomeMonthPanel` and
  `AccountEditorDialog`'s `BalanceMonthGrid`, with the two sizes as
  parameters. Screenshot-compare both.
- 6.18 `MonthChip` (MonthStrip.swift): diff its styling against
  `MonthPill`/`PillChip`; reuse one only if identical.
- 6.19 `Home/TransactionsView`: cache `dayGroups` and `newestFirst(inMonth:)`
  in `@State` keyed on (month, `ledgerRevision`), as FlowTransactionsView
  does. `Spend/CategoryTransactionsView.currentStyle()`: key on
  `ledgerRevision`. Add a name-to-`CategoryInfo` dictionary for
  `AppModel.categoryInfo(named:type:)` if it keeps the same
  case-insensitive match.
- 6.20 Hardcoded `.font(.system(size:))` SF Symbol sizes (42 sites): leave as is unless a size exactly equals an existing `Metrics.icon*`
  token.

## Phase 7: view file splits (moves only)

Gate: G-build, G-ui.

- 7.1 `Worth/AccountHistoryParts.swift`: trend plot, `ChartTouch`,
  `ScrubPress`, `TooltipLayout` -> `AccountTrendChart.swift`.
- 7.2 `Home/HomeView.swift`: `FlowChip`, `Sparkline`, `SafeToSpendCard`,
  `RecentActivityCard`, `RecentRow` -> `HomeCards.swift`.
- 7.3 `Home/BudgetsSection.swift`: picker sheets and `BudgetCategoryTile` ->
  `BudgetPickerSheet.swift`.
- 7.4 `SettingsView.swift`: data transfer (DataTask, ImportKind,
  Confirmation, export, share, pick, preview, decode, confirmation dialog) ->
  `Settings/SettingsView+Data.swift`, or an `@Observable` controller if
  private `@State` can't cross files cleanly.
- 7.5 Test files: split `AccessibilityAuditUITests` (screen bodies ->
  `AccessibilityAuditScreens.swift`, seed/cleanUp -> its own file),
  `DataTransferModelTests` (one file per type), `VoiceEntryModelTests`
  (fakes -> `VoiceFakes.swift`), `VoiceDraftParserTests` (by MARK), and the
  multi-suite files `BackupParityTests`, `CSVImportTests`,
  `FlowParityTests`, `DomainParityTests` (one suite per file).

## Phase 8: widget extension

Gate: G-build, the widget renders in the simulator gallery, G-system.

- 8.1 Create `native/Shared/` with the palette hex constants, `Color(hex:)`,
  the App Group ID, the shared keys (`cashFlow`, `cashFlowMonth`,
  `budgieHideBalances`) and the month-key format. Add it to `sources` for
  both the `Budgie` and widget targets in `project.yml`. Make `BudgieColor`
  and `WidgetPalette` read the shared hex values; delete the duplicates in
  `BudgetWidgets.swift` and `AppModel.swift`. The widget keeps not linking
  BudgieCore.
- 8.2 Merge `BudgetQuickActionsEntry`/`BudgetVoiceAddEntry` and their
  providers into one. Widget `kind` strings must not change (existing
  users' home screens use them).

## Phase 9: scripts and ParityHarness

Gate: G-dart (fixtures byte-identical), each changed script run once.

- 9.1 ParityHarness: move `local(List c)` (6 files; keep the 5-field
  `voice_request` variant separate), `bitsHex` (11 files) and
  `writeCompactJson` (flow, insight) into `harness_support.dart`.
- 9.2 `run.sh`: turn the 22 `if wants X; for tz ...; flutter test` blocks
  into one table-driven loop. Regenerate everything and confirm
  `git status native/Fixtures` is clean.
- 9.3 Add `native/scripts/lib/sim.sh` (and the Python equivalent if needed)
  with one simulator lookup rule (highest iOS runtime) used by `ui_flow.sh`,
  `system_flow.sh`, `sim_seed.py`, `upgrade_rehearsal.py`.
  **[OWNER]** Whether to change these scripts to reuse existing stock
  simulators instead of creating `Budgie-UITest`/`Budgie-System`/
  `Budgie-Rehearsal` and erasing them, per the owner's simulator rules.
  Default if no answer: keep the dedicated devices, but make every script
  shut down what it boots.
- 9.4 One helper for "copy a store into the app container" (`sim_seed.py`,
  `upgrade_rehearsal.py`, `perf_seed.py`), and one export-from-tag mode in
  `ParityHarness/run.sh` that `upgrade_rehearsal.py` calls (keep the dummy
  `.env` key used today by whichever path the fixtures depend on).
- 9.5 `system_flow.sh`: remove `|| true` after the build-for-testing pipe so
  a failed build fails the script (keep tolerating grep finding nothing by
  checking `PIPESTATUS`). Fix the comment that says `Runner.app` comes from
  `upgrade_rehearsal.build_flutter()` by adding a build-only entry point to
  `upgrade_rehearsal.py` (e.g. `--build-only`) or documenting the manual
  build from the tag.
- 9.6 Resolve the `perf_seed.py:193` vs `system_flow.sh:32-37` contradiction
  about `simctl spawn defaults write`: test which is true on the current
  simulator runtime and fix the wrong one.
- 9.7 Document `stage_import_fixtures.sh` (required by BackupUITests and
  CSVImportUITests) in `AGENTS.md`'s test section, or call it from
  `ui_flow.sh` if those classes are meant to run there.
- 9.8 Do not edit `verify_upgrade_preservation.py`; its SHA256 is pinned in
  `docs/DEEP_MIGRATION_AUDIT_EVIDENCE.json`.

## Phase 10: project.yml

Gate: G-build; review the `project.pbxproj` diff for unintended changes.

- 10.1 **[OWNER]** Remove the `SpringBoardProbe` target, scheme and
  `native/SpringBoardProbe/` (nothing references it). Default if no
  answer: keep.
- 10.2 Use XcodeGen `targetTemplates` for the repeated `platform: iOS`,
  `GENERATE_INFOPLIST_FILE: YES` and `bundle.ui-testing` settings. Keep the
  per-target version keys.

## Phase 11: docs

Gate: every relative link in `native/docs` and `AGENTS.md` resolves (write a
small link check in the scratchpad and run it).

- 11.1 Fix drift:
  - `AGENTS.md`: "on the App Store as 4.0.0" -> current version from
    `project.yml` (4.1.0); describe what's on the store only if confirmed.
  - `MIGRATION_SPEC.md:6`: source of truth is the `flutter-final` tag (at
    `b69008d` if that's the tagged commit; check with `git rev-parse flutter-final`).
  - `MIGRATION_SPEC.md` Q7 block (~632-647): mark resolved as option (a),
    pointing at section 14.0.
  - `IPHONE_DUO_PLAN.md:45`: find the real toast inset (grep `ToastHost`,
    `MainView`) and correct or remove the claim.
  - `ParityHarness/README.md:3`: say the harness exports from the
    `flutter-final` tag.
- 11.2 Archive to `native/docs/archive/` with `git mv` (history kept):
  `full-app/` (incl. `KICKOFF_PROMPT.md`), `research/`,
  `redesign/REDESIGN_PLAN.md` (leave a 10-line status note in its place if
  anything still links to it). Rewrite the links from `UI_SPEC.md`,
  `PARITY_GAPS.md`, `MIGRATION_SPEC.md` section 15 to the new paths. Add a
  one-line banner to each archived file: "Archived; paths refer to the
  `flutter-final` tag."
- 11.3 Merge `UPGRADE_TEST_PLAN.md`, `UPGRADE_TEST_RESULTS.md` and
  `MIGRATION_SAFETY_AUDIT.md` into `UPGRADE_VERIFICATION.md`. Keep every
  result row and the cited rehearsal run directories;
  `DEEP_MIGRATION_AUDIT_EVIDENCE.json` may cite these files by path, so
  check and update it only if it holds paths (not hashes) of the doc.
- 11.4 Condense `MIGRATION_SPEC.md` section 14.1 (resolved Q&A) to the
  decisions only.
- 11.5 `AGENTS.md`: replace the restated persistence/date/number rules with a
  five-line summary linking `FULL_APP_PLAN.md` section 3, add a "doc owners"
  table (rules: FULL_APP_PLAN s3; store format: MIGRATION_SPEC s4; prefs:
  MIGRATION_SPEC s3/s8; differences: PARITY_GAPS; screens: UI_SPEC;
  verification: UPGRADE_VERIFICATION; device tasks: REAL_DEVICE_CHECKLISTS),
  and a "read first" list. Remove duplicated rule text from the per-area
  docs that remain.
- 11.6 Separate pass over `UI_SPEC.md` (1,239 lines) and `PARITY_GAPS.md`
  (1,469 lines) for repeated per-item prose; condense only text that is
  duplicated verbatim, keep every gap entry.
- 11.7 Archive or delete this plan once every phase is done.

## Phase 12: repository hygiene

- 12.1 `git rm --cached` the four tracked `.DS_Store` files and add
  `.DS_Store` to `.gitignore`.
- 12.2 **[OWNER]** Untrack `native/Marketing/Budgie-AppStore-4.0.zip`
  (13 MB, a copy of `AppStore-4.0/`). Default: keep.
- 12.3 **[OWNER]** Decide which of `native/docs/appstore/` and
  `native/Marketing/AppStore-4.0/` is canonical and remove the other copy.
  Default: keep both.
- 12.4 **[OWNER]** Move the five uncited `docs/rehearsal/20260928-18xxxx`/
  `19xxxx` runs (~13 MB) and the `docs/duo/baseline/` PNGs out of the repo.
  Check `DEEP_MIGRATION_AUDIT_EVIDENCE.json` and every doc for references
  first. Default: keep.
- 12.5 **[OWNER]** Outside git: delete the leftover `budget_app/` directory
  (its `.env` may hold a real key; the owner should rotate the key) and
  prune stale `.claude/worktrees/` (38 entries). Never do this without an
  explicit yes.

## Final verification

Run every gate (G-core, G-build, G-app, full G-ui, G-dart, G-system,
`AccessibilityAuditUITests`) and compare with the Phase 0 baseline: no new
failures. Report the line-count delta (`git diff --stat main`), every
skipped task with its reason, and every [OWNER] decision taken. Shut down
any simulator you booted. Do not push or open a PR unless asked.

## Excluded on purpose (do not do)

- Swapping `DartNumbers.tryParseDouble` for `DartDouble.tryParse`: changes
  how odd goal amount strings parse. File a bead with a parity note instead.
- Snapping `RecurringCard`'s `0.65` and `DataImportDialog`'s `0.4` opacity
  literals to tokens, and mapping spacing 12/14/18 to other tokens: visible
  change.
- Memoising Home's `SafeToSpend.calculate`: measured at 2.9 ms and declined
  in `PERFORMANCE.md`; feeding it `LedgerIndex` rows would change float
  summation order.
- Merging `ChartLongPress`/`ScrubPress`, `AccountsToggle`/`SegmentedPills`,
  the Flow filter chip and the Flow field components: deliberately different.
- Changing `netWorthMonthKey`/`netWorthDayKey`, or making the widget link
  BudgieCore.
- Any change to store bytes, `flutter.`-prefixed preference handling, widget
  `kind`s, accessibility identifiers or user-visible strings.
