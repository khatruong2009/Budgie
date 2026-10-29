> Archived; paths refer to the `flutter-final` tag.

# H. Existing Flutter tests: catalogue, classification, parity oracles, gaps

Source: `budget_app/test/` (37 files, 9170 lines, 390 test cases). Read-only research; nothing under `budget_app/` was modified.

## 1. Baseline run

Command: `cd budget_app && flutter test`.

**In the worktree it does not run at all.** Verbatim tail:

```
Error detected in pubspec.yaml:
No file or variants found for asset: .env.

Error: Failed to build asset bundle
```

Cause: `budget_app/.env` is gitignored (`budget_app/.env` in root `.gitignore`) and absent from the worktree; `pubspec.yaml` line 88 lists `- .env` as an asset. The main checkout has a `.env` (one `OPEN_AI_API_KEY` line); I did not copy its contents.

To get a real baseline I rsync'd `budget_app/` to the scratchpad (`.../scratchpad/ba`), created a stub `.env`, and ran there. Result: **390 tests, 389 pass, 1 fail** (`+389 -1`).

The single failure is an artifact of the copy, not a real regression:

```
privacy_configuration_test.dart: release configuration enables the explicitly accepted OpenAI flow
  PathNotFoundException: Cannot open file, path = '../.gitignore' (OS Error: No such file or directory, errno = 2)
  test/privacy_configuration_test.dart 22:45  main.<fn>
```

It reads `../.gitignore` relative to `budget_app/`, which the scratchpad copy lacks. In the worktree, with a `.env` present, it should pass. Treat the suite as green (390/390) once `.env` exists.

Important test-harness facts for parity work:
- Under `FLUTTER_TEST=true`, `AtomicFinancialStore` uses an in-memory backend (`_MemoryBackend`) unless a test passes `resetForTesting(directory:)`. Only `atomic_financial_store_test.dart` and 5 tests in `transaction_identity_test.dart` touch real files. Every other model test exercises the store logic (revision, sections) but not file IO.
- Store on-disk format (from source, not test-pinned by literals): file `financial_store_v2.json` + `financial_store_v2.backup.json`; line 1 is a JSON header `{format:"budgie-financial-store", schemaVersion:2, revision, payloadLength, payloadChecksum (FNV-1a 64-bit, 16 hex chars, over payload bytes), writtenAt}`, `\n`, then payload = `jsonEncode(sections)`. Staged write goes to `<name>.tmp` then rename. Legacy envelope (SharedPreferences) used schemaVersion 1 with checksum over `jsonEncode(payload)`.

## 2. Classification summary

| Category | Files | Test cases |
|---|---|---|
| (a) DATA/PERSISTENCE (port as Swift parity tests) | 7 | 44 |
| (b) LOGIC (port) | 6 | 47 |
| (c) UI-only / build-config (not ported; note behaviors to match) | 17 | 243 |
| (d) Out-of-MVP-scope feature | 7 | 56 |
| Total | 37 | 390 |

Per-file table:

| File | Cases | Cat |
|---|---|---|
| atomic_financial_store_test.dart | 12 | a |
| backup_test.dart | 12 | a |
| transaction_model_backup_restore_test.dart | 2 | a |
| recurring_transaction_model_backup_restore_test.dart | 2 | a |
| transaction_identity_test.dart | 9 | a |
| app_settings_provider_test.dart | 3 | a |
| category_provider_test.dart | 4 | a (partial; custom-category editing may be out of MVP) |
| recurring_transaction_test.dart | 9 | b |
| safe_to_spend_test.dart | 6 | b |
| transaction_ordering_test.dart | 3 | b |
| transaction_model_csv_import_test.dart | 15 | b |
| transaction_model_net_worth_test.dart | 9 | b |
| transaction_model_budget_reports_test.dart | 5 | b |
| accessibility_test.dart | 56 | c |
| dark_mode_test.dart | 28 | c |
| design_system_test.dart | 55 | c |
| empty_state_test.dart | 13 | c |
| floating_dock_test.dart | 2 | c |
| glow_fab_test.dart | 6 | c |
| loading_shimmer_test.dart | 18 | c |
| micro_interactions_test.dart | 4 | c |
| modern_transaction_list_item_test.dart | 6 | c |
| net_worth_page_widget_test.dart | 2 | c |
| platform_enhancements_test.dart | 32 | c |
| safe_to_spend_sheet_test.dart | 2 | c |
| transaction_form_prefill_test.dart | 13 | c |
| transaction_page_test.dart | 1 | c |
| history_pagination_test.dart | 1 | c |
| widget_test.dart | 1 | c |
| privacy_configuration_test.dart | 3 | c (build/Info.plist/pubspec config checks) |
| voice_expense_service_test.dart | 40 | d |
| voice_recording_sheet_navigator_test.dart | 1 | d |
| insight_engine_test.dart | 7 | d |
| categorization_rule_test.dart | 2 | d |
| categorization_settings_page_test.dart | 1 | d |
| onboarding_tutorial_test.dart | 4 | d |
| app_privacy_gate_test.dart | 1 | d (App Lock; out of MVP unless app lock is in scope) |

## 3. (a) DATA / PERSISTENCE, detail

### atomic_financial_store_test.dart (12)
Helper `legacyEnvelope(revision, sections)` builds a schema-1 envelope `{schemaVersion:1, revision, sections, checksum}` where checksum = FNV-1a64 hex(16) of `jsonEncode({schemaVersion, revision, sections})` bytes. Reusable fixture generator.
1. fresh install reads empty: revision 0, sections `{}`, neither file created (read writes nothing).
2. commit reports write metrics (bytes>0, succeeded, total>=write); an observer that throws does not break durability (revision 2 after second commit).
3. commits survive relaunch; each commit keeps the previous as backup: after 1 `updateSection` + 1 `updateSections` (2 sections at once), reload -> revision 2, 2 transactions, savingsGoals `[{name:'Emergency fund'}]`, backup file exists. (Two commits = revision 2; multi-section update is one revision.)
4. verification reads back from disk: unwritable directory -> `FinancialStoreException`.
5. corrupt primary ('garbage') is recovered from backup on load: returns the OLDER revision's data (`[{description:'Last known good'}]`), and primary is rebuilt so a second relaunch is clean.
6. a corrupt primary never overwrites a good backup: after recovery + new write + garbage again, fallback is still a valid earlier state (`'Good'`).
7. newest readable revision wins between primary and backup: swapped files (old primary, new backup) -> revision 2, 2 rows.
8. unreadable store (primary replaced by a directory) is an error, never an empty ledger: `read()` throws `FinancialStoreException`, `isLoaded == false`.
9. migration: imports previous envelope (revision 7) + clears bulky keys; `categoryBudgetLimits {'Eating Out':100}` preserved; `appSettings.baseCurrencyCode == 'EUR'` pulled from prefs; envelope key and `StorageKeys.transactions` removed from prefs; real preference `baseCurrencyCode` stays; new file store exists; survives relaunch.
10. migration: legacy per-feature keys (`transactions`, `recurring_transactions`) with no envelope -> sections created only for keys present (`savingsGoals` absent).
11. migration: malformed primary envelope (`{"corrupt":true}`) falls back to backup envelope (revision 3, savingsGoals kept) AND overlays the newer `transactions` mirror key (`[{id:old},{id:newest}]` in order).
12. nothing to migrate: prefs untouched, no file written.

### backup_test.dart (12) - user-facing JSON export/import (`encodeBackup`/`decodeBackup`)
Envelope oracle: `schemaVersion: 3`, `app: 'budgie'`, `appVersion` string, `exportedAt` = `DateTime.toIso8601String()`, `data` has exactly 14 keys: transactions, netWorthEntries, categoryBudgetLimits, savingsGoals, recurringTransactions, themeMode, categories, transactionTags, categorizationRules, baseCurrencyCode, localeOverride, appLockEnabled, autoLockTimeoutSeconds, hideBalances.
1. round-trips every field of every section (values: 1234.56 income w/ recurringTemplateId 'rec-2'; 19.99 expense 'Book "Dart", 2nd ed'; net-worth asset snapshots 5000.0/5250.5; goals 10000/10000 completed + 3000/500; recurring weekly dayOfWeek 4, biweekly dayOfWeek 5, monthly dayOfMonth 1; baseCurrencyCode 'CAD', locale 'en_CA', autoLock 30, appLock+hideBalances true).
2. themeMode round-trips light/dark/system/null.
3. schema-1 transactions without identity remain importable: id non-empty, `createdAt == updatedAt == date`, recurringTemplateId kept.
4. decode rejects with FormatException: '', 'not json', '[]', '{}', schemaVersion as string, schemaVersion 999, missing `data`, `transactions:"oops"`, transaction with `amount:"NaN-ish"`.
5. rejects non-finite numbers (`1e999`) in budget limits, transaction amount, goal targetAmount, net-worth snapshot amount (-1e999), recurring amount.
6. rejects unrecognized type strings rather than coercing: 'Expense', 'transfer', 'Asset', 'EXPENSE' (case-sensitive; strict enums).
7. monthly recurring `dayOfMonth` must be int 1..31: null, 0, -30, 32 rejected; 31 accepted; weekly may have null dayOfMonth.
8. absent sections -> empty collections, null theme.
9. null sections -> empty collections, null theme.
10. unknown extra keys at top level and in `data` ignored (themeMode 'light' still decoded).
11. leading UTF-8 BOM stripped.
12. unknown themeMode string ('neon') -> null.

### transaction_model_backup_restore_test.dart (2)
1. restore replaces all four owned sections in ONE store revision (`after == before + 1`); persisted sections equal the models' `toJson()`; a limit of 0.0 ('Dropped') is dropped on restore -> `{'Groceries':650.0,'Transport':250.0}`; in-memory equals restored; fresh model reloads identical.
2. restore with empty backup wipes everything and persists empty.

### recurring_transaction_model_backup_restore_test.dart (2)
1. restore replaces templates, persists, reload equal.
2. generator after restore fills occurrences since restored cursor: weekly template with startDate=nextOccurrence = today-10 days -> exactly 2 transactions (day -10 and day -3), all with `recurringTemplateId == 'rec-restored'`, template `nextOccurrence` afterwards is after now.

### transaction_identity_test.dart (9)
1. new transactions get non-empty unique id; `createdAt == updatedAt`; JSON round-trip preserves id/createdAt/updatedAt.
2. legacy JSON (no id/createdAt/updatedAt): id generated; createdAt and updatedAt fall back to `date`; recurringTemplateId preserved.
3. loading legacy + duplicate IDs (3 rows: one no id, two sharing 'duplicate') backfills unique IDs (3 distinct) AND persists (each stored row has string id/createdAt/updatedAt); reload gives same ids in same order.
4. `updateTransaction(id, copy)` is atomic: preserves id, createdAt, recurringTemplateId; `updatedAt` strictly later; returns true.
5. identical transactions deleted independently by id; `deleteTransactionById('missing')` -> false.
6. failed write (real dir replaced by a file) keeps the row in memory, `add` returns false, `hasUnsavedChanges`, `unsavedSections` contains 'transactions', `lastSaveError` set, listeners notified >=2; after storage returns `retryPendingSaves()` -> true, flags cleared, reload has ['Groceries','Coffee'].
7. a later successful save also carries earlier unsaved sections (budget limit 300 set while failing, then a transaction add succeeds; reload has both).
8. unreadable stored row (missing date/amount) is skipped without dropping neighbors (ids ['first','newest']); loading does NOT rewrite storage while a row was unreadable (raw section still has 3 rows).
9. model loads the recovered atomic backup instead of stale legacy prefs keys: primary corrupted after a later import -> recovered single row 'original' (the newer imported 'newest' row is lost, by design); store section length 1.

### app_settings_provider_test.dart (3)
1. defaults for existing users: `baseCurrencyCode == 'USD'`, `localeOverride == null`, `locale == null`.
2. currency and locale persist: `setBaseCurrencyCode('eur')` normalizes to 'EUR'; locale 'de_DE' -> languageCode 'de'; `MoneyFormatter.format(1234.5)` contains '€'.
3. privacy prefs persist: appLock true, autoLockTimeoutSeconds 300, hideBalances true; when hidden `MoneyFormatter.format(42) == '••••'` and `formatSigned(-42) == '••••'`.

### category_provider_test.dart (4)
1. seeds stable built-ins and persists: first expense category id `'expense-general'`, name `'General'`; `expenseCategories.keys.first == 'General'`; persisted list non-empty, first id `'expense-general'`.
2. custom categories keep id through edits and reload (name/icon/color updated; global map updated).
3. legacy transaction category 'Freelance' (income) gets a new category with id `'income-freelance'` without mutating the transaction.
4. cannot archive the last active category of a type (StateError).

## 4. (b) LOGIC, detail (parity oracles)

### recurring_transaction_test.dart (9)
- create: id non-empty, `isActive` default true.
- toJson/fromJson round trip (id,type,description,amount,category,pattern,startDate,nextOccurrence,dayOfMonth,isActive).
- `calculateNextOccurrence()`: weekly 2024-01-01 -> 2024-01-08; biweekly 2024-01-01 -> 2024-01-15; monthly day 15: 2024-01-15 -> 2024-02-15; monthly day 31 from 2024-01-31 -> 2024-02-29 (leap-year clamp); 2024-12-15 -> 2025-01-15 (year rollover).
- `generateTransaction(DateTime(2024,2,1))`: copies type/description/amount/category, date = arg, `recurringTemplateId == template.id`.
- `copyWith` keeps id.

### safe_to_spend_test.dart (6) - `SafeToSpendCalculator().calculate(...)`, month 2026-07, asOf 2026-07-15
1. Income 3000 (Jul 1), expense 200 Groceries (Jul 4), recurring monthly Groceries 100 on Jul 20 and General 80 on Jul 22, Groceries limit 500: `actualIncome 3000`, `actualExpenses 200`, `upcomingRecurringExpenses 180`, `flexibleBudgetReserve 200` (= 500 limit - 200 spent - 100 upcoming grocery), `safeToSpend 2420` (= 3000 - 200 - 180 - 200), `daysRemaining 17` (Jul 15..31 inclusive).
2. biweekly recurring income 1500 (start/next Jul 20): `expectedIncome 1500` included; with `includeExpectedIncome:false` -> 0.
3. active goal (target 600, current 0, target 2026-12-01, created 2026-07-01) with income 1000: `plannedGoalContributions > 0`, `safeToSpend < 1000` (exact formula not pinned; read `safe_to_spend.dart`).
4. future-dated (Jul 25) expense not counted: `actualExpenses 0`.
5. over-committed: income 1000, expense 1850 -> `safeToSpend -850`, `isOverCommitted`, `overCommitment 850`, `dailyAllowance 0`, `daysRemaining 17`.
6. healthy: income 1700 -> `dailyAllowance ~= 100` (1700 / 17), `overCommitment 0`.

### transaction_ordering_test.dart (3) - `Transaction.compareNewestFirst`
1. same day ordered by when recorded, newest first: Groceries(date 18:05) > Lunch(date midnight, createdAt 12:40) > Coffee(date 09:15). So sort key is a combination of the date's day, then effective time (a midnight `date` falls back to `createdAt` time).
2. different days order newest first regardless of time component (Today 00:00 before Yesterday 23:30).
3. identical timestamps: order deterministic regardless of input order (tie-break by id).

### transaction_model_csv_import_test.dart (15) - `parseTransactionsCsv`
Export format: header `Date,Type,Category,Description,Amount`; rows sorted by date ascending; date `yyyy-MM-dd`; type `Income`/`Expense`; amount `toStringAsFixed(2)`; CRLF line endings via `ListToCsvConverter`; RFC-4180 quoting (embedded comma, quote, newline).
1. round-trip of 4 rows incl. `Salary, bonus`, `Book "Dart"`, `line1\nline2`; 0 dups, 0 errors.
2. re-import of an export of existing data -> 0 new, `duplicateCount == 4`.
3. multiset dedupe: file has 2 copies of an existing row -> 1 duplicate, 1 imported.
4. three-decimal amount 3.005 re-import still a duplicate (dedupe key uses `toStringAsFixed(2)` rounding, not `(x*100).round()`).
5. dedupe trims text: existing 'Lunch ' matches exported 'Lunch'.
6. LF-only file parses same as CRLF.
7. leading BOM stripped.
8. lowercase header accepted (`date,type,...`; type 'income' accepted, amount 1000.00).
9. empty content and wrong header -> FormatException.
10. row errors: bad date ("abc"), bad type ('Transfer'), bad amount ('xyz'), wrong column count; error strings contain `Row N` (1-based incl. header, so first data row is Row 2), plus 'date' / 'type' / 'amount' / 'column'; valid rows still imported (2 imported: 1000.00 and 3.50; 4 errors: Row 3,4,5,6).
11. impossible dates (2026-02-30, 2026-13-05) are row errors, not rolled over.
12. European decimal comma rejected: '1.234,56' and '12,34' errors; '1,234.56' -> 1234.56.
13. currency-formatted '$1,234.56' -> 1234.56.
14. `importTransactions` persists; fresh model loads all 4.
15. `importTransactions([])` is a no-op (nothing written).

### transaction_model_net_worth_test.dart (9)
1. totals for a selected month: assets 1000, liabilities 400 -> netWorth 600; income 250, expenses 100 (month totals).
2. carry forward: Jan Brokerage 200000 asset + Mortgage 150000 liability; `carryNetWorthMonthForward(Feb)` true; update mortgage to 149500 in Feb -> assets 200000, liabilities 149500, net worth 50500, tracked count 2, updated count 2, stale count 0.
3. `getNetWorthAvailableMonths()` newest-first `[current, previous, older]` even when an older month is selected.
4. carried balances create no synthetic month-end history points: entry recorded 2026-01-20 09:00 carried into Feb -> `hasNetWorthDataForMonth(Feb)` true, updated count 0; history has 1 point dated `2026-01-20` (day-truncated), netWorth 5000; `getNetWorthChangeForMonth(Feb)` null.
5. monthly change uses recorded balances from previous month: June 200000 -> July 210000 => change 10000.
6. same-month updates create separate history points: 2026-03-10 (1000) and 2026-03-25 (1400), returned newest-first, dates truncated to the day, `assetCount [1,1]`, `liabilityCount [0,0]`, granularity `day`; `getNetWorthForMonth(March) == 1400`.
7. history compression with `limit: 4`: after snapshots Jan 2/10/20 (1000/1100/1200), Feb 5/18 (1300/1400), Mar 8 (1500): result 4 points = Mar 8 (day), Feb 18 (day), Feb 5 (day), then January collapsed to a single `month` point dated `2026-01-31 23:59:59.999` with netWorth 1200 (last value in month).
8. delete individual snapshot (by entryId + recordedAt) leaves account; history becomes [1500.0].
9. legacy migration: prefs `starting_assets: 3200.0`, `starting_liabilities: 900.0` -> 2 tracked entries, assets 3200, liabilities 900, netWorth 2300.

### transaction_model_budget_reports_test.dart (5)
1. category budget limit persists; `getCategoryBudgetProgressForMonth(2026-06)`: only 'Eating Out' (limit 400, spent 125, remaining 275; 'Transportation' spend 40 without limit excluded); stored section `{'Eating Out': 400.0}`.
2. cached monthly totals refresh after edit/delete: `getMonthlySummary(month)['expenses']` 5 -> 8 -> 0; `getCategorySpendingForMonth` tracks; `getRecentTransactions(3)`.
3. legacy pref key `category_budget_limits` `{'Groceries':600,'Ignored':0}` loads: Groceries 600, Ignored null (non-positive dropped).
4. year-over-year (2026-01 vs 2025-01): current 1600, previous 1400, difference 200, percentChange ~14.285 (200/1400), current Housing 1300, previous Groceries 200, `categories.first == 'Housing'` (ordered by size).
5. savings goals: allocate 1250 to 5000 goal -> progress 0.25; allocate 3750 -> complete, `completedAt` set; persists after reload.

## 5. (c) UI-only tests (not ported); behaviors the SwiftUI MVP should match
- transaction_page_test (1): July 2026 seed (Paycheck 4120 income Salary 07-01 09:00; Rent 2150 Housing 07-01 10:00; Whole Foods Market 86.20 Groceries 07-02 18:00) renders all 3 rows under title "Transactions". History list lists only the selected month.
- net_worth_page_widget_test (2): Add account dialog has "Balance month" field and Cancel. Percent semantics: Brokerage 1000 -> 1500, Savings 400 => brokerage label "78.9% of assets" (1500/1900 allocation), and "+50.0%" as change (not the allocation number).
- safe_to_spend_sheet_test (2): breakdown sheet scrolls on small screens, hosted on root navigator above dock. With income 4400 and expenses 7176.93 the sheet shows "Projected shortfall" and "Add income or reduce planned spending", and NO "Trim ..." suggestion (shortfall must not produce a daily trim).
- history_pagination_test (1): 60 transactions; history search "SEE ALL" shows "60 of 60" and page size 50, with a "Load more transactions" control revealing the rest.
- transaction_form_prefill_test (13): form prefill fills description/category/amount (amount blank when 0.0); date row formatted `MMM dd, yyyy`, defaults to today; merchant rule applies category/tags; edit updates in place and preserves recurring identity; "Make this recurring" link absent when prefilled or editing, present on manual add; barrier tap dismisses only for manual add; `initialCategory` preselects category.
- modern_transaction_list_item_test (6): expense/income rendering, category icon, date format, recurrence indicator only for recurring rows.
- floating_dock_test (2), glow_fab_test (6: default 54x54 icon 26; size 44), micro_interactions (4), loading_shimmer (18), empty_state (13), design_system (55: tokens, AppButton, AnimatedMetricCard), dark_mode (28: light/dark color tokens, WCAG AA 4.5:1), accessibility (56: touch targets >=44, semantic labels, VoiceOver formatters `formatMoneyForScreenReader`, `formatCountForScreenReader` singular/plural/zero, reduced motion, contrast, large text), platform_enhancements (32), widget_test (1 smoke), privacy_configuration (3: Info.plist has `NSMicrophoneUsageDescription`, `NSCameraUsageDescription` text "Budgie uses the camera only when you choose to capture a file for importing financial data."; .env gitignored). SwiftUI equivalents: 44pt tap targets, Dynamic Type, VoiceOver money/date/count labels, Reduce Motion, dark-mode contrast.

## 6. (d) Out-of-MVP-scope
- voice_expense_service_test (40): OpenAI JSON post-processing clamps (type default expense; category exact-match else 'General' expense / 'Other' income; amount coercion, negative -> 0.0; description falls back to transcript; date default today, future clamped to today, 90-day lookback boundary; markdown fence stripping; `VoiceExpenseException` carries transcript).
- voice_recording_sheet_navigator_test (1).
- insight_engine_test (7): category pace warning at 80% usedRatio; duplicate detection with stable id; changed recurring amount; 3 consecutive negative cash-flow months = urgent; goal behind schedule; exclusions/limit; sparse data gives no change insights.
- categorization_rule_test (2): match is case-insensitive substring on merchant + type + min/max amount (10..200 inclusive of 52, exclusive of 250); JSON round trip (id, matchType exact, tagIds, priority 3). Note: `categorizationRules` and `transactionTags` are still in the backup schema and store sections, so unknown-section preservation matters even if the feature is dropped.
- categorization_settings_page_test (1), onboarding_tutorial_test (4: first-launch tour; completion persisted via pref `onboarding_completed`), app_privacy_gate_test (1: cover 'App preview hidden' only when App Lock enabled).

## 7. Gaps: behaviors the migration needs pinned that no existing test covers

Data / persistence
1. Byte-level store format is never asserted: no test checks the header line JSON keys (`format`, `payloadLength`, `payloadChecksum`, `writtenAt`), the `\n` separator, the FNV-1a constants, or that Swift can read a file produced by Dart (and vice versa). Need golden fixtures: a real `financial_store_v2.json` from the simulator (memory notes it holds ~357 seeded fake transactions; physical device has real data) read by the Swift store.
2. On-disk tests only cover the Dart directory backend in `atomic_financial_store_test.dart`; every model test runs on `_MemoryBackend`.
3. Leftover `<name>.tmp` after a crash (staged write not renamed, or renamed-but-unverified) - untested. Also a leftover `.tmp` must not be read as data and must be overwritten by the next commit.
4. Both files unreadable -> files set aside as `.corrupt-<stamp>` then fall through to legacy migration - untested (only the "primary corrupt + good backup" path is).
5. Header validation branches untested: wrong `format` tag, `schemaVersion > 2` (forward-compat file must be rejected/unreadable, not downgraded), `payloadLength` mismatch (truncated write), checksum mismatch with valid JSON, payload not a JSON object.
6. Backup-rotation semantics: backup is the previous primary bytes copied before each write; no test asserts the backup holds revision N-1 byte-for-byte, or the ordering (copy backup -> stage tmp -> rename -> verify).
7. Prewarm / protected-data: `ProtectedDataGate` has no test. Nothing pins "empty read on locked device must not become an empty ledger or trigger a write" beyond the unreadable-store-is-error test; the Swift app needs an equivalent gate (`UIApplication.isProtectedDataAvailable` / `protectedDataDidBecomeAvailable`) and a test that no commit occurs before it.
8. Unknown-section preservation: no test that a store containing extra sections (e.g. `transactionTags`, `categorizationRules`, `selectedNetWorthMonth`, or a future section) survives a read-modify-write of another section. Store source keeps all sections in the map, but it is unverified by tests, and the Swift store must preserve them since MVP drops those features.
9. Unknown-field preservation on each model is untested and probably not implemented in Dart: `Transaction`/`NetWorthEntry`/`SavingsGoal`/`RecurringTransaction` `fromJson` -> `toJson` drops unknown keys. Decide whether Swift must preserve them (round-trip a JSON row with an extra key through load-edit-save). Test both "tolerated on read" and "preserved on write".
10. Missing-key fallbacks per model (AGENTS.md rule "handle the case where the key is missing") are only tested for `Transaction` identity fields and backup sections. Not tested: `SavingsGoal` (e.g. missing `completedAt`), `RecurringTransaction` (missing `isActive`, `dayOfWeek`, `dayOfMonth`), `NetWorthEntry` (missing `snapshots`, `createdAt`), `BudgetCategory`, `appSettings` keys.
11. Legacy SharedPreferences migration coverage is thin: tested = envelope, per-feature keys `transactions`/`recurring_transactions`, malformed envelope + mirror, `baseCurrencyCode`, `starting_assets/liabilities`. Not tested: legacy `net_worth_entries`, `net_worth_selected_month`, `savings_goals`, `category_budget_limits` (only via model, not store migration), `categories_v1`, `locale_override`, app lock keys, `themeMode`; legacy-envelope checksum failure with both envelope keys bad; migration idempotence when the migration crashes midway (file written, prefs not yet cleared). Swift app cannot read Flutter's `shared_preferences` plist keys (they are prefixed `flutter.` in NSUserDefaults) - the prefix handling is not specified by any test and needs a Swift test with a fixture defaults suite.
12. `selectedNetWorthMonth` section and `appSettings` section shape: only `baseCurrencyCode` is asserted in the store test; the other appSettings keys' persisted names (`localeOverride`, `appLockEnabled`, `autoLockTimeoutSeconds`, `hideBalances`) are asserted only through provider reload, never as store JSON literals.
13. Date/number encoding: no test pins how dates are serialized in store rows (local ISO-8601 without timezone, e.g. `2024-03-02T00:00:00.000`) or that whole-number doubles round-trip as `10.0` vs `10`. Swift `Codable` must read both and write the Dart-compatible form.
14. Concurrent write ordering: `_writeQueue` serialization and revision monotonicity under rapid successive `updateSection` calls are untested (only sequential).
15. Import/restore apply path for `BackupData` -> store (settings restore flow: appSettings, categories, tags, rules, theme, and recurring generator after restore) is only tested for the transaction and recurring models, not for categories/appSettings restore. Also no test that restore of a schema-2 or schema-3 file differ (only schema 1 explicit + current 3).

Logic
16. `TransactionGenerator` has no direct test: the 90-day lookback cap, skipping inactive templates, monthly day-clamp catch-up (31 -> Feb 28/29 -> Mar 31 does the cursor restore day 31?), multiple missed occurrences, and idempotence on second launch are untested. Only a weekly 10-day catch-up is pinned (2 rows).
17. `calculateNextOccurrence` monthly clamp: only 31 -> Feb 29 (leap) tested; no non-leap February (Feb 28), no 30 -> Feb, no return-to-31 after a clamped month, no weekly with `dayOfWeek` mismatching startDate, no biweekly across DST.
18. Safe-to-spend exact goal contribution formula is not pinned (only `> 0`); expected-income weekly/biweekly projection counting, monthly recurring already generated this month (double counting), inactive templates, `asOf` on the last day of month (daysRemaining 1), and asOf outside `month` are untested.
19. Net worth: liabilities-only history, deleting the only snapshot, month with no data (`getNetWorthChangeForMonth` null path beyond one case), compression when `limit` is exceeded by multiple months, and timezone/DST at `endOfNetWorthMonth` (`23:59:59.999`) - untested. The 23:59:59.999 month-point sentinel is a load-bearing oracle for parity.
20. Money formatting parity: `MoneyFormatter` is only asserted for hidden balances and a '€' substring. No exact string oracles for USD/EUR/CAD formatting, negative amounts, or `formatSigned`.
21. CSV export itself (`exportTransactionsToCSV` on the model) is never called: tests rebuild the CSV with a copy of the algorithm (`buildExportCsv`), so drift between test helper and production is possible. Swift export needs its own test against the documented format (header, `yyyy-MM-dd`, `Income`/`Expense`, 2-decimal amount, CRLF, quoting, sort ascending by date; tie-order among same-day rows unspecified).
22. Dedupe key composition for CSV import (which fields are in the key) is only implied.
23. Month-boundary edge cases for `getMonthlySummary` / category spending: transactions at 23:59:59 on the last day or 00:00 on the first, and local time zone changes.
24. Ordering: `compareNewestFirst` exact rule for a midnight `date` with a later `createdAt` on a different calendar day is untested; tie-break by id direction unspecified beyond determinism.

Test infrastructure
25. `flutter test` cannot run in a fresh worktree because `.env` is a gitignored asset; a cross-worktree baseline requires copying or stubbing `.env`. `privacy_configuration_test` also depends on `../.gitignore` existing relative to cwd.
