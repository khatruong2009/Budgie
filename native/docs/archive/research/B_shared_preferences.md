> Archived; paths refer to the `flutter-final` tag.

# B. Legacy / SharedPreferences migration research

Scope: everything the Flutter app persists outside the v2 financial file, how legacy
SharedPreferences data flows into `AtomicFinancialStore`, exactly how the iOS plugin
encodes values in `NSUserDefaults`, and every other persistence surface on iOS.

Paths are relative to the worktree root. `budget_app/lib/...` is the Flutter source.
"VERIFIED" = read in source (or executed) this session. "INFERRED" = follows from code
or platform knowledge but was not directly observed. "UNKNOWN" = could not be determined.

Bundle id of the app: `com.khatruong.budgetbuddy` (VERIFIED,
`budget_app/ios/Runner.xcodeproj/project.pbxproj:532,724,757`). Widget extension:
`com.khatruong.budgetbuddy.BudgetWidgetsExtension` (pbxproj:449,786,813).
App Group: `group.com.khatruong.budgetbuddy` (VERIFIED, `ios/Runner/Runner.entitlements:7`,
`ios/BudgetWidgets/BudgetWidgets.entitlements:7`).

---------------------------------------------------------------------------------------

## 1. Complete key inventory

### 1.0 How keys reach disk (context for the tables)

- The app uses only the legacy API `SharedPreferences.getInstance()` (VERIFIED: every
  use is in `budget_app/lib/app_settings_provider.dart:33,62,73,87,96,105,131`,
  `onboarding_tutorial.dart:31,44`, `categorization_provider.dart:33`,
  `theme_provider.dart:16,31,49`, `category_provider.dart:33`,
  `transaction_model.dart:345`, `storage/atomic_financial_store.dart:303,360`,
  `widgets/local_insights_section.dart:37,76,84`). There is NO use of
  `SharedPreferencesAsync`, `SharedPreferencesWithCache`, `setPrefix`, or
  `setMockInitialValues` in `lib/` (VERIFIED by grep of `lib/` and `ios/`). The only
  `setMockInitialValues` use is in `test/`.
- There are no dynamically built keys. Every `get*/set*/remove/containsKey` call uses a
  `StorageKeys.*` constant or one of the two literals in section 1.3 (VERIFIED by
  grepping every `SharedPreferences`/`prefs.`/`preferences.` reference in `lib/`).
- Key strings below are the Dart-side names. On disk each is prefixed with `flutter.`
  (section 3).
- The header of `storage_keys.dart:1-4` claims "every persisted value must have its key
  declared here". That is false: two keys live in `local_insights_section.dart` (1.3).

### 1.1 `StorageKeys` (`budget_app/lib/storage/storage_keys.dart`)

Legend for "Class": FIN = financial data now owned by `AtomicFinancialStore`; the
bare key is read only for one-time migration. PREF = real preference, lives on in
NSUserDefaults. HYBRID = real preference that is ALSO mirrored into the store file.

| Const (line) | Literal | Dart type written | Class | Writer (today) | Reader (today) | Removed? |
|---|---|---|---|---|---|---|
| `transactions` (22) | `transactions` | String (JSON list) | FIN | none. Historically `TransactionModel.saveTransactions` mirrored it on every save (`git show c05f9eb^:budget_app/lib/transaction_model.dart` ~L243). c05f9eb "Stop mirroring the ledger to legacy preference keys" | `AtomicFinancialStore._readLegacySections` (`atomic_financial_store.dart:420`) migration only | Yes, after verified migration: `_removeMigratedPreferenceKeys` (`atomic_financial_store.dart:359-366`), list at 129-141 |
| `netWorthEntries` (26) | `net_worth_entries` | String (JSON list) | FIN | none (historically `_saveNetWorthEntries`) | migration only (`:421-422`) | Yes, same list |
| `netWorthSelectedMonth` (30) | `net_worth_selected_month` | String (ISO-8601, see 1.4) | FIN | none (historically `selectNetWorthMonth`, c05f9eb^ ~L189) | migration only (`:423-424`), read RAW (`getString`, not JSON-decoded) | Yes, same list |
| `categoryBudgetLimits` (34) | `category_budget_limits` | String (JSON object `{category: double}`) | FIN | none | migration only (`:425-426`) | Yes |
| `savingsGoals` (37) | `savings_goals` | String (JSON list) | FIN | none | migration only (`:427`) | Yes |
| `recurringTransactions` (41) | `recurring_transactions` | String (JSON list) | FIN | none (historically `RecurringTransactionModel`, c05f9eb^ L74-75) | migration only (`:428-429`) | Yes |
| `themeMode` (44) | `themeMode` | String: `'light'` \| `'dark'` \| `'system'` | PREF | `ThemeProvider.setThemeMode` (`theme_provider.dart:50`); `toggleTheme` writes only `'dark'`/`'light'` (34,37) | `ThemeProvider._loadTheme` (`:17-27`); unknown string => system | NEVER |
| `onboardingCompleted` (48) | `onboarding_completed` | bool (only ever written `true`) | PREF | `_completeTutorial` (`onboarding_tutorial.dart:45`) | `_loadCompletionState` (`:33`), default false; read error => show tour (`:35-38`) | NEVER |
| `categories` (52) | `categories_v1` | String (JSON list) | FIN | none (historically `CategoryProvider._persist`, c05f9eb^ L265-266) | `CategoryProvider.load` uses it as FALLBACK when the store section is not a List (`category_provider.dart:36-38`) and migration (`:430`) | Yes |
| `baseCurrencyCode` (56) | `base_currency_code` | String (3-letter uppercase) | HYBRID | `AppSettingsProvider.setBaseCurrencyCode` (`app_settings_provider.dart:63`) and `restoreFromBackup` (132) | `AppSettingsProvider.load` FALLBACK (`:38-40`), migration builds `appSettings` from it (`atomic_financial_store.dart:438`) | NEVER (not in `migratedPreferenceKeys`, and the test asserts it survives: `test/atomic_financial_store_test.dart:255-256`) |
| `localeOverride` (60) | `locale_override` | String (e.g. `en_US`); key ABSENT means follow device | HYBRID | `setLocaleOverride` (`:77`) / `restoreFromBackup` (136) set; `preferences.remove` (`:75`, `:134`) when cleared | `load` fallback (`:41-42`); migration (`:439-440`) | Only removed by the user clearing the override (`:75,134`) |
| `appLockEnabled` (64) | `app_lock_enabled` | bool | HYBRID | `setAppLockEnabled` (`:88`), `restoreFromBackup` (138) | `load` fallback (`:43-45`); migration (`:441-442`) | NEVER |
| `autoLockTimeoutSeconds` (65) | `auto_lock_timeout_seconds` | int | HYBRID | `setAutoLockTimeoutSeconds` (`:97`), restore (139-142) | `load` fallback (`:46-49`); migration (`:443-444`, default 60) | NEVER |
| `hideBalances` (66) | `hide_balances` | bool | HYBRID | `setHideBalances` (`:106`), restore (143) | `load` fallback (`:50-52`); migration (`:445-446`) | NEVER |
| `transactionTags` (69) | `transaction_tags_v1` | String (JSON list) | FIN | none (historically `CategorizationProvider`, c05f9eb^ L176-177) | `CategorizationProvider.load` fallback (`categorization_provider.dart:40`); migration (`:431-432`) | Yes |
| `categorizationRules` (70) | `categorization_rules_v1` | String (JSON list) | FIN | none (historically c05f9eb^ L189-190) | fallback (`categorization_provider.dart:49`); migration (`:433-434`) | Yes |
| `legacyStartingAssets` (76) | `starting_assets` | double | LEGACY | none in this codebase (pre-v2 app) | `TransactionModel._migrateLegacyNetWorthIfNeeded` (`transaction_model.dart:1476-1477`) | NEVER (see hazard H4) |
| `legacyStartingLiabilities` (80) | `starting_liabilities` | double | LEGACY | none | same (`:1478-1479`) | NEVER |

Notes on the table (all VERIFIED unless marked):
- HYBRID means dual-write. Every settings setter writes the pref key AND then
  `_persistAtomic()` writes the `appSettings` section into the store file
  (`app_settings_provider.dart:63-64,77-79,88-89,97-98,106-107,132-144`).
  On load the file section wins per field, with the pref key as per-field fallback
  (`:38-52`). Because a `null` `localeOverride` in the section falls through to the
  pref key (`:41-42`), and the setter removes the pref key at the same time (`:75`),
  the two stay consistent in normal operation.
- Only the 11 keys in `migratedPreferenceKeys` (`atomic_financial_store.dart:129-141`;
  2 envelope keys plus 9 bare keys) are ever bulk-removed: `financial_store_v1`,
  `financial_store_v1_backup`, `transactions`, `net_worth_entries`,
  `net_worth_selected_month`, `category_budget_limits`, `savings_goals`,
  `recurring_transactions`, `categories_v1`, `transaction_tags_v1`,
  `categorization_rules_v1`.
- `storage_keys.dart:14-18` comment says the keys "from here to the theme key" are
  read-only. Real behaviour: the theme key and the five settings keys are still
  written; only the six financial bare keys plus categories/tags/rules are read-only.

### 1.2 Envelope keys (not in `StorageKeys`)

| Const | Literal | Type | Writer | Reader | Removed? |
|---|---|---|---|---|---|
| `AtomicFinancialStore.legacyPreferencesPrimaryKey` (`atomic_financial_store.dart:123`) | `financial_store_v1` | String (JSON envelope, below) | Written only by builds before c05f9eb (`git show c473af9:budget_app/lib/storage/atomic_financial_store.dart` `_commit`) | migration only (`:304-306`) | Yes (`:130`) |
| `legacyPreferencesBackupKey` (`:124`) | `financial_store_v1_backup` | String (previous primary, copied verbatim before each commit) | same old `_commit` | migration only (`:307-309`) | Yes (`:131`) |

v1 envelope JSON shape (VERIFIED: encode/decode at c473af9 `_encode/_decode`, mirrored
by current `_decodeLegacyEnvelope` `atomic_financial_store.dart:370-397`):

```
{"schemaVersion":1,"revision":<int>,"sections":{...},"checksum":"<hex>"}
```
Key order as written: `schemaVersion`, `revision`, `sections`, `checksum` (spread of the
payload map, then checksum appended). The checksum is FNV-1a 64 over the UTF-8 bytes of
`jsonEncode({"schemaVersion","revision","sections"})` i.e. the envelope with `checksum`
removed and re-encoded by Dart (`_decodeLegacyEnvelope` L375-378). Decoding rejects
`schemaVersion > 1` (L383-384). See hazard H2 for what this means for a Swift port.

`sections` keys (`FinancialSections`, `atomic_financial_store.dart:14-27`):
`transactions, netWorthEntries, selectedNetWorthMonth, categoryBudgetLimits,
savingsGoals, recurringTransactions, categories, transactionTags, categorizationRules,
appSettings`. Note these are camelCase, different from the bare key strings.

### 1.3 Keys NOT in `StorageKeys` (VERIFIED, `budget_app/lib/widgets/local_insights_section.dart`)

| Literal (line) | Dart type | Meaning | Writer | Reader | Removed? |
|---|---|---|---|---|---|
| `local_insights_dismissed_v1` (21) | `List<String>` via `setStringList` (L77), sorted | Set of dismissed insight ids | `_dismiss` (L74-78) | `_loadPreferences` (L38) | NEVER |
| `local_insights_snoozed_v1` (22) | String: JSON object `{insightId: ISO-8601 string}` via `jsonEncode` (L85-92) | Snooze-until timestamps, snooze = 30 days (L23,82) | `_snooze` (L80-93) | `_loadPreferences` (L39-53); malformed JSON silently ignored | NEVER (expired entries are never pruned) |

Insight id formats (`budget_app/lib/insights/insight_engine.dart`): `budget-pace:<slug>:<Y>-<M>`
(129), `monthly-change:<Y>-<M>` (166), `unusual:<slug>:<yyyy-MM-dd>:<amount.2dp>` (205),
`savings-rate:<Y>-<M>` (240), `recurring-change:<slug>:<Y>-<M>` (279),
`under-budget:<slug>:<Y>-<M>` (320), `goal-behind:<slug(goalId)>` (346),
`negative-flow:<Y>-<M>` (376), `duplicate:<type>|<slug(desc)>|<amount.2dp>...` (411; key
assembled L399-403). `_slug` = trim, lowercase, `[^a-z0-9]+` -> `-`, strip leading and
trailing `-` (L457-461). `<M>` is not zero-padded.
These are UI preferences only. If the native app does not carry them over, previously
dismissed insights reappear; nothing financial is lost.

### 1.4 JSON shapes inside the string values

All shapes are the same whether they sit in a bare key (JSON string) or in a store
section (already-decoded JSON value). VERIFIED by reading each `toJson`:

- `transactions`: list of `Transaction.toJson` (`transaction.dart:87-99`):
  `id, type ("expense"|"income"), description, amount (num), category (display string),
  date (ISO-8601), recurringTemplateId (nullable), tagIds ([String]), createdAt,
  updatedAt`. `fromJson` (L101-118) tolerates missing `id/createdAt/updatedAt/tagIds`
  (older data); `TransactionModel.getTransactions` regenerates duplicate/missing ids and
  rewrites (`transaction_model.dart:365-390`).
- `net_worth_entries`: list of `NetWorthEntry.toJson` (`net_worth_entry.dart:141-147`):
  `id, name, type ("asset"|"liability"), createdAt, snapshots:[{recordedAt, amount}]`.
  `NetWorthSnapshot.fromJson` (L71-98) also accepts an older snapshot shape with
  `monthKey`/`updatedAt` and no `recordedAt`; native must keep that fallback.
- `net_worth_selected_month`: raw string from `DateTime(y, m).toIso8601String()`
  (`transaction_model.dart:252-253`), i.e. local time with no zone suffix, e.g.
  `2026-09-01T00:00:00.000` (INFERRED from Dart `toIso8601String` semantics for a local
  `DateTime`). Read back with `DateTime.tryParse` then normalised to (year, month)
  (`transaction_model.dart:404-411`).
- `category_budget_limits`: JSON object `{"<category name>": <num>}`; loader coerces with
  `(value as num).toDouble()` and drops values `<= 0` (`transaction_model.dart:413-420`).
- `savings_goals`: `SavingsGoal.toJson` (`savings_goal.dart:81-89`): `id, name,
  targetAmount, currentAmount, targetDate, createdAt, completedAt (nullable)`; lenient
  `fromJson` (L91-105).
- `recurring_transactions`: `RecurringTransaction.toJson` (`recurring_transaction.dart:39-52`):
  `id, type, description, amount, category, pattern ("weekly"|"biweekly"|"monthly" =
  enum `.name`), startDate, nextOccurrence, dayOfMonth, dayOfWeek, isActive`.
  Note `fromJson` does `amount: json['amount']` with no `num` coercion (L61), so an
  integer-valued JSON `amount` would be a type error in Dart. Not a native concern
  unless the native decoder is stricter or looser than Dart.
- `categories_v1`: list of `BudgetCategory.toJson` (`category_definition.dart:42-51`):
  `id, type (enum name "income"|"expense"), name, iconIdentifier, colorToken,
  sortOrder, isArchived, isBuiltIn`.
- `transaction_tags_v1`: `TransactionTag.toJson` (`transaction_tag.dart:23-27`): `id, name,
  colorToken`.
- `categorization_rules_v1`: `CategorizationRule.toJson` (`categorization_rule.dart:59-70`):
  `id, merchantPattern, matchType (enum name), transactionType (enum name|null),
  minimumAmount, maximumAmount, category, tagIds, priority, isEnabled`.
- `appSettings` store section (not a bare key): `{baseCurrencyCode, localeOverride,
  appLockEnabled, autoLockTimeoutSeconds, hideBalances}` (`app_settings_provider.dart:160-166`).

### 1.5 Keys written to the App Group suite (separate from the above)

VERIFIED, `budget_app/ios/Runner/AppDelegate.swift:153-155`:
suite `group.com.khatruong.budgetbuddy`, key `cashFlow` (Swift `Double`), key
`cashFlowMonth` (String `"YYYY-MM"`, from Dart `DateTime.now()` in
`transaction_model.dart:333`). NO `flutter.` prefix (written by Swift directly, not by
the plugin). Read by the widget at `ios/BudgetWidgets/BudgetWidgets.swift:11-16`.
Written after every successful `saveTransactions` (`transaction_model.dart:306`, also 820 and 1236) and at
the end of `getTransactions` (L431). Never removed.

---------------------------------------------------------------------------------------

## 2. Migration path: legacy SharedPreferences -> AtomicFinancialStore

Source of truth: `budget_app/lib/storage/atomic_financial_store.dart`. All VERIFIED.

### 2.1 Where migration is triggered

`AtomicFinancialStore.read()` (L199-206) -> `_load()` (L254-300). `_load` is called once
per process, on first `read()`. In the app that is `_initializeApp` in `main.dart:252-272`,
after `ProtectedDataGate.waitUntilAvailable()` (L261). Sequence inside `_load`:

1. Read `financial_store/financial_store_v2.json` and `.../financial_store_v2.backup.json`
   from `getApplicationSupportDirectory()` (L634-636; names at L116-118). Decode both
   (`_decodeBytes` L594-608, checksum-verified).
2. If either decodes (L262-277): pick primary when `primary != null && (backup == null ||
   primary.revision >= backup.revision)`, else restore primary from backup. RETURN.
   **No SharedPreferences key is read for financial data and none is deleted.**
3. If files exist but neither decodes (L279-291): rename each to `<name>.corrupt-<epochMs>`
   and fall through to legacy migration ("rather than silently starting over").
   A read failure other than not-found throws `FinancialStoreException` (L670-672) and
   `_load` fails; it never falls through to migration on an I/O error.
4. `_migrateFromPreferences()` (L302-357). If it returns null (nothing legacy found)
   the store returns `FinancialSnapshot.empty` and writes nothing (L294-296; test
   `atomic_financial_store_test.dart:63`, `:325-334`).
5. Otherwise `_commit(migrated)` (writes + verifies the v2 file, L297), and only after
   that succeeds `_removeMigratedPreferenceKeys()` (L298). If `_commit` throws, the
   exception propagates out of `read()`, the keys are NOT removed, and the next launch
   retries the migration.

### 2.2 Precedence inside `_migrateFromPreferences` (L302-357)

Inputs: `financial_store_v1` (decoded -> `envelopePrimary`), `financial_store_v1_backup`
(-> `envelopeBackup`), and `_readLegacySections` (bare keys, L401-450).
`hasLegacyData` = any bare-section value non-null (L311). Return null iff no envelope
decodes AND no legacy data (L313-315).

1. Choose `chosen` envelope: primary if it decoded and (`backup == null` or
   `primary.revision >= backup.revision`), else the backup (may be null) (L317-326).
2. Start `sections` = a copy of `chosen.sections` (L328-330).
3. If the PRIMARY envelope was NOT usable (`!chosePrimary`) and the bare `transactions`
   key decoded to a `List`, that list REPLACES `sections['transactions']` (L335-338).
   Rationale in the comment: the old store mirrored the ledger to the bare key after
   every envelope commit, so it is at least as new as the backup envelope. Test:
   `atomic_financial_store_test.dart:290-323`.
4. For every other bare section with a non-null value, fill it ONLY if
   `!sections.containsKey(section)` (L341-345). Because a v1 envelope written by
   `_readLegacy` always populated every section key (c473af9 `_readLegacy`), in practice
   an envelope that decoded makes the bare keys irrelevant for those sections; bare keys
   matter when there is no envelope, or when an envelope is partial.
5. `appSettings`: built from the 5 pref keys only when at least one of them exists
   (`containsKey`, L412-417), with defaults `'USD'`, `null`, `false`, `60`, `false`
   (L435-447). If the chosen envelope already has an `appSettings` section, the bare
   keys do not override it here (step 4 `containsKey`), but `AppSettingsProvider.load`
   still falls back to the pref keys per field (`app_settings_provider.dart:38-52`).
6. `revision` of the migrated snapshot = `chosen?.revision ?? 0` (L349). Schema is set to
   2 (`AtomicFinancialStore.schemaVersion`, L115).
7. Bare keys go through `jsonDecode`; empty string or malformed JSON becomes "absent"
   (L402-410). `net_worth_selected_month` is taken as a raw String (L423-424).
   The bare `themeMode`, `onboarding_completed`, `starting_assets`, `starting_liabilities`
   and the two `local_insights_*` keys are NOT consulted by the store migration.

### 2.3 Mixed states, decision table

| State on device | Result |
|---|---|
| v2 primary and/or backup decodes; bare/envelope keys also present | v2 wins. Legacy keys ignored AND left in place forever (cleanup only happens on the migration branch, L293-299). Verified by control flow; no test covers it. |
| v2 files absent; `financial_store_v1` decodes, bare keys present | Envelope sections win; bare keys fill only sections missing from the envelope (test `:223-265`). Then all 11 migrated keys are removed. |
| v2 absent; primary envelope corrupt, backup envelope decodes, bare `transactions` present | Backup envelope + bare `transactions` list overrides its `transactions` (test `:290-323`). NOTE: any decoded `List`, including `[]`, overrides (H3). |
| v2 absent; both envelopes corrupt/missing; bare keys present | Bare keys alone (L419-449); `revision` 0. |
| v2 absent; nothing legacy | `FinancialSnapshot.empty`, nothing written, no prefs touched (test `:325-334`). |
| v2 both files present but neither decodes | Files renamed `*.corrupt-<ms>`, then legacy path above. If legacy is also empty the store starts EMPTY (the corrupt files are set aside, not surfaced as an error). |
| Only `base_currency_code` (etc.) present | `hasLegacyData` is true (appSettings non-null), a v2 file with only `appSettings` is created (revision 0) and the migrated keys removed (none of which existed). |

### 2.4 When legacy keys are deleted

Only inside `_load`, only on the migration branch, only after `_commit` (write +
read-back verification) succeeds (L297-298). Deleted set = `migratedPreferenceKeys`
(L129-141). Deletion is `containsKey` then `remove`, one key at a time, each awaited
(L359-366). A crash between commit and cleanup leaves the keys; the next launch takes
branch 2 (v2 decodes) and ignores them, so they then linger forever. Never deleted: the
5 settings keys, `themeMode`, `onboarding_completed`, `starting_assets`,
`starting_liabilities`, both `local_insights_*` keys, `flutter.`-prefixed anything else.

### 2.5 Other legacy behaviour outside the store

- `starting_assets` / `starting_liabilities` (doubles): `getTransactions` reads them
  whenever the stored `netWorthEntries` section is not a non-empty list
  (`transaction_model.dart:392-402`). If `> 0` they synthesise "Starting Assets" /
  "Starting Liabilities" entries with a fresh uuid and `DateTime.now()` (`transaction_model.dart:1486` onward) and
  save them (`_saveNetWorthEntries`). The keys are never removed (H4).
- Category/tag/rule providers fall back to their bare key only when the store section is
  not a `List` (`category_provider.dart:36-38`, `categorization_provider.dart:38-52` via
  `_encodedSection` L192-194). After a normal migration the bare keys are gone, so the
  fallback only matters for an existing-but-partial v2 file.
- `CategoryProvider.load` re-writes the store if the loaded categories differ from the
  stored JSON (`category_provider.dart:44-48`).

### 2.6 v2 file format (what the native app must read first)

VERIFIED, `atomic_financial_store.dart:544-618`. Location:
`<Application Support>/financial_store/financial_store_v2.json` and
`financial_store_v2.backup.json` (temp: `<name>.tmp`, forensic: `<name>.corrupt-<ms>`).
On iOS `getApplicationSupportDirectory` returns the first result of
`NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)`
(VERIFIED, `path_provider_foundation-2.5.1/.../PathProviderPlugin.swift:57-58,71-79`), i.e.
`<app container>/Library/Application Support/` with no extra subfolder.
Layout: one JSON header line, `\n` (0x0A), then the payload = `jsonEncode(sections)`.
Header keys: `format` = `"budgie-financial-store"` (L120), `schemaVersion` (2),
`revision`, `payloadLength` (bytes), `payloadChecksum`, `writtenAt`. Checksum = FNV-1a 64
(offset `0xcbf29ce484222325`, prime `0x100000001b3`) over the exact payload bytes. Loader
rejects `schemaVersion > 2` (L575).
CHECKSUM FORMATTING HAZARD (VERIFIED by running Dart this session, and consistent with
project memory `sim-driving-tips.md`): Dart's `int` is signed 64-bit and the code calls
`hash.toRadixString(16).padLeft(16, '0')` (L617). When the top bit of the hash is set the
result is `-` followed by the hex of the NEGATED value. Output observed:
`utf8("a") -> -509c23b379fe1374`, `"abc" -> -18e05de6fabea8b5`,
`"[]" -> 09612b07b5ecb5a5`, `"{\"x\":1}" -> -422c2ac3c5f4c02a`. A Swift verifier must
format identically (signed Int64, `String(x, radix: 16)` of the signed value, left-pad to 16
including the sign character). `padLeft` counts the `-` as a character, so a negative hash
whose magnitude has fewer than 15 hex digits would produce a zero-padded string with `-` in
the middle of the padding; a Swift port should just compare by parsing both sides as
Int64 rather than string equality. (The exact `padLeft`-with-sign output for short
magnitudes was reasoned, not run: INFERRED.)

---------------------------------------------------------------------------------------

## 3. How `shared_preferences` stores values on iOS

Versions: `pubspec.lock` pins `shared_preferences 2.5.4` (lock L635-642) and
`shared_preferences_foundation 2.5.6` (L651-658); `shared_preferences_platform_interface
2.4.1`. `path_provider_foundation` is pinned to 2.5.1 by `dependency_overrides`
(`pubspec.yaml:68`). All VERIFIED.

### 3.1 API used, prefix, suite

- API: legacy `SharedPreferences.getInstance()` (section 1.0). This calls
  `SharedPreferencesStorePlatform.instance` = `SharedPreferencesFoundation`
  (`shared_preferences_foundation-2.5.6/lib/src/shared_preferences_foundation.dart:15,44-48`)
  which talks to the native `LegacySharedPreferencesPlugin` (`LegacyUserDefaultsApi`).
- Key prefix: `flutter.`. Two independent definitions, both VERIFIED:
  `shared_preferences-2.5.4/lib/src/shared_preferences_legacy.dart:22`
  (`static String _prefix = 'flutter.'`; applied in `_setValue` L177-186 and `remove`
  L172-174) and the platform default `shared_preferences_foundation.dart:22`
  (`_defaultPrefix`). Native never sees unprefixed keys: `set(key: "flutter.transactions")`.
  Dart strips the prefix when it builds its cache (`shared_preferences_legacy.dart:259-263`).
  So in the native app: `UserDefaults.standard` key = `"flutter." + dartKey`
  (`flutter.themeMode`, `flutter.onboarding_completed`, `flutter.base_currency_code`,
  `flutter.local_insights_dismissed_v1`, `flutter.financial_store_v1`, ...).
- Suite: NONE. The legacy plugin writes to `UserDefaults.standard`
  (`SharedPreferencesPlugin.swift:33,37,41,45,49`, 2.5.6) and reads via
  `UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier)`
  (L161-162, `SharedPreferencesPigeonOptions()` with nil suiteName at L61-62). So the data
  is in `<container>/Library/Preferences/com.khatruong.budgetbuddy.plist`.
  `suiteName` (which on iOS must start with `group.`, L91-97) exists only for
  `SharedPreferencesAsync`, which the app does not use. A native app with the same bundle
  id reads it with plain `UserDefaults.standard`. A different bundle id cannot see it
  (INFERRED from sandboxing; would need an explicit migration through some other channel).
- `SharedPreferences.getInstance()` caches the whole map once per process
  (`shared_preferences_legacy.dart:79-97`, `_preferenceCache`); reads afterwards do not hit
  NSUserDefaults. This is why the app comment (`atomic_financial_store.dart:93-99`) says
  write "verification" never observed disk. Irrelevant to a native reader, which reads
  live.

### 3.2 Encoding per Dart type

Dart setters map to native calls (`shared_preferences_foundation.dart:24-40`, identical in
2.2.2, 2.3.x, 2.5.x; checked):

| Dart | Plugin call | Swift value handed to `UserDefaults.set(_:forKey:)` | Stored NSUserDefaults type |
|---|---|---|---|
| `setString` | `setValue` | `String` | `NSString` (plist `<string>`) |
| `setStringList` | `setValue` (`List<String?>`) | `[Any]` of `String` | `NSArray` of `NSString` (plist `<array>`) |
| `setInt` | `setValue` (`int`) | `Int`/`NSNumber` (Pigeon standard codec, signed 64-bit) | `NSNumber` integer (`objCType` `q`) |
| `setDouble` | `setDouble` (`Double`) | `Double` | `NSNumber` double (`objCType` `d`, plist `<real>`) |
| `setBool` | `setBool` (`Bool`) | `Bool` | `NSNumber` boolean (`CFBoolean`, `objCType` `c`, plist `<true/>`/`<false/>`) |

- There is NO special string prefix/marker for lists, doubles or big ints on iOS
  (VERIFIED: the Android markers `VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu` /
  `...BigInteger` / `...Double.` appear only in the Android plugin and in a doc comment of
  `shared_preferences_legacy.dart:157-162`; a grep of `shared_preferences_foundation-2.5.6`
  found no occurrence). Strings, lists and numbers are stored natively, not wrapped.
- Native read semantics (VERIFIED by running Swift against a scratch defaults suite on
  macOS Foundation this session, then deleting it; iOS shares the same Foundation
  bridging):

  | Stored via plugin | `object(forKey:)` is | `as? Bool` | `as? Int` | `as? Double` |
  |---|---|---|---|---|
  | `true` / `false` | NSNumber, `objCType c`, `CFGetTypeID == CFBooleanGetTypeID` | true/false | 1/0 | 1.0/0.0 |
  | `5.0` (double) | NSNumber `d` | nil | 5 | 5.0 |
  | `1234.56` (double) | NSNumber `d` | nil | nil | 1234.56 |
  | `60` (int) | NSNumber `q` | nil | 60 | 60.0 |
  | `1` (int) | NSNumber `q` | true | 1 | 1.0 |
  | `"hello"` | String | nil | nil | nil |
  | `["a","b"]` | `[String]` | | | |

  Consequence: a Swift reader must use the typed accessors with the known key type
  (`string(forKey:)`, `stringArray(forKey:)`, `bool(forKey:)`, `integer(forKey:)`,
  `double(forKey:)`) and `object(forKey:) != nil` for presence. Do NOT infer type from
  `as? Bool` / `as? Int` on `object(forKey:)`: an int `0`/`1` (e.g.
  `auto_lock_timeout_seconds` = 0 or 1) is indistinguishable from a bool that way.
  The stored double `5.0` remains a real in the plist and reads back as `as? Int == 5`.

### 3.3 How the plugin (Dart side) tells int/double/bool apart on read (for reference)

`getAll` returns `[String: Any]` from `persistentDomain(...)` filtered to values where
`isTypeCompatible` (Bool, Double, String, Int, or an array of those; anything else, e.g.
`Data`, `Date`, dictionaries, is silently dropped) (`SharedPreferencesPlugin.swift:149-192`).
The values then cross the Pigeon `StandardMessageCodec`, which serialises an `NSNumber` as
bool if it is a `CFBoolean`, as int32/int64 for integer `CFNumberType`s, and as float64
for floating `CFNumberType`s. I could not read the engine's `FlutterStandardCodec.mm`
(the Flutter engine source is not in the pub cache; only prebuilt frameworks exist), so
this codec dispatch is INFERRED. The observable app behaviour is consistent: `getInt`,
`getDouble`, `getBool` are plain casts of the cached value
(`shared_preferences_legacy.dart:117-129`), so a wrong type would throw, and the app has
run for years.

### 3.4 Older plugin versions a user might still have data from

Foundation versions in the pub cache: 2.2.2, 2.3.1, 2.3.4, 2.3.5, 2.5.2, 2.5.3, 2.5.4,
2.5.5, 2.5.6. I diffed the Swift and Dart sources:

- 2.2.2 (`ios/Classes/SharedPreferencesPlugin.swift`, `lib/shared_preferences_foundation.dart`):
  same prefix `flutter.` (Dart `_defautPrefix`, L15), same `UserDefaults.standard`, same
  setter mapping (Bool/Double via typed calls; Int/String/StringList via `setValue`).
  Only difference: `getAllWithPrefix`/`clearWithPrefix` API names, no `allowList`, and no
  type-compatibility filter on read.
- 2.3.1 / 2.3.4 / 2.3.5: adds `allowList`; identical write encoding.
- 2.5.2 - 2.5.5: identical to 2.5.6 apart from a copyright line (2.5.3-2.5.5) and, for
  2.5.2, a `[String?: Any?]` vs `[String: Any]` return signature (`diff` clean otherwise).
  The `SharedPreferencesAsync` (`suiteName`) class was added in this era but is unused.
- The app's historical `pubspec.lock` snapshots (checked with `git show <rev>:budget_app/pubspec.lock`)
  show `shared_preferences_foundation 2.2.2` at e89bc35 (2023-06-25) and a953e9c
  (2024-06-14), and `2.5.6` from d5c4f6a (2025-12-18) to HEAD. The old Obj-C plugin
  `shared_preferences_ios` never appears in the sampled locks, so no data written by it
  is expected (I did not sample every revision: partially INFERRED).
- Conclusion (VERIFIED for the versions above): the on-disk encoding has not changed
  across any plugin version this app has shipped with. One key difference between eras
  is only the app-side data format: before c473af9 (envelope) there are only bare keys;
  c473af9..c05f9eb^ wrote BOTH envelope and bare mirror keys; c05f9eb+ writes the v2 file
  and no financial pref keys.
- Which app versions correspond to those commits was not verified (no git tags exist;
  `git tag` is empty). The commit dates are: c473af9 = 2026-07-27, c05f9eb = 2026-09-12
  (from `git show --stat`), HEAD b69008d "Bump version to 3.4.0". Whether App Store
  builds shipped between them is UNKNOWN; assume users may exist in all three states.

---------------------------------------------------------------------------------------

## 4. Other persistence surfaces on iOS

### 4.1 Confirmed

| Surface | Detail | Evidence |
|---|---|---|
| Standard NSUserDefaults, domain `com.khatruong.budgetbuddy`, `flutter.` keys | Section 1 | above |
| v2 financial store files | `Library/Application Support/financial_store/*` | `atomic_financial_store.dart:634-636` |
| App Group `UserDefaults(suiteName: "group.com.khatruong.budgetbuddy")` | `cashFlow` (Double), `cashFlowMonth` (String) for widgets; unprefixed | `ios/Runner/AppDelegate.swift:153-155`, `ios/BudgetWidgets/BudgetWidgets.swift:6-16` |
| Temp exports | Backup JSON and CSV written to `getTemporaryDirectory()` then shared | `settings_page.dart:328-334`, `transaction_model.dart:1022-1034`; voice audio `widgets/voice_recording_sheet.dart:136`. On iOS the plugin maps `.temp` to `cachesDirectory` (`PathProviderPlugin.swift` `fileManagerDirectoryForType`), so it is `Library/Caches`, disposable |
| Method channels the native host owns (not storage, but a native rewrite must keep parity) | `budget_app/deeplink`, `budget_app/widget_data`, `budget_app/protected_data` | `AppDelegate.swift:76-155` (deeplink also re-implemented in `SceneDelegate.swift:63`) |
| URL scheme `budgetapp://` | `CFBundleURLSchemes` | `ios/Runner/Info.plist:34-36` |
| `NSFaceIDUsageDescription` present (local_auth) | | `ios/Runner/Info.plist:81` |

### 4.2 Confirmed absent

- No Keychain use anywhere. `grep -rE "Keychain|SecItem|UserDefaults|suiteName"` over
  `budget_app/ios/Runner`, `ios/BudgetWidgets`, `ios/RunnerTests`, `ios/scripts` found only
  the App Group lines above. Over the plugin sources actually linked into the app
  (`quick_actions_ios 1.2.3`, `local_auth_darwin 1.6.1`, `package_info_plus 8.3.1`,
  `path_provider_foundation 2.5.1`, `share_plus 10.1.4`, `file_picker 11.0.2`,
  `record_ios 1.2.1`, plus `shared_preferences_foundation 2.5.6`; list from
  `ios/Runner/GeneratedPluginRegistrant.m:10-67`) no plugin references `UserDefaults`,
  `Keychain` or `SecItem` other than shared_preferences itself. `flutter_secure_storage`
  is not a dependency (`pubspec.yaml`, `pubspec.lock`). `home_widget` is not a dependency;
  widget data goes through the app's own channel.
- `local_auth` stores nothing; app-lock enablement and timeout live in the `appSettings`
  section plus the `flutter.app_lock_enabled` / `flutter.auto_lock_timeout_seconds` prefs
  (section 1). Lock authentication is a runtime `LocalAuthentication` call
  (`widgets/app_privacy_gate.dart:4,14,28`).
- `quick_actions` shortcut items are registered at runtime with `setShortcutItems`
  (`lib/main.dart`, around L155-200) and held by iOS, not by app storage.
- Nothing is written to `Documents/` by the app (grep for `getApplicationDocuments`,
  `Documents` in `lib/`: none).
- `flutter_dotenv` loads `.env` bundled as an asset (`pubspec.yaml:88`,
  `voice_expense_service.dart:27-28`); it reads `OPEN_AI_API_KEY` from the bundle and
  persists nothing. Per project memory the shipped key is a placeholder (I did not open
  the `.env` file; UNKNOWN whether the working tree has a real one, and I did not read it
  deliberately).
- `SceneDelegate.swift` and the widget target contain no other storage
  (`grep` for UserDefaults/Keychain/FileManager found nothing there; SceneDelegate
  handles the deeplink channel and quick-action shortcut items, L43-94).

### 4.3 Not determinable from the repo

- Whether any historical build (Amplify, removed in commit 4931fb7, 2023-07-10; the
  Amplify commit ec1079b is 2023-06-24) ever shipped and left `amplify_secure_storage`
  Keychain items. The plugin sources are in the pub cache but the current lock and
  pubspec do not reference Amplify, and no Runner code touches Keychain. UNKNOWN whether
  any App Store build had it; if it did, those items would be unreadable/ignorable
  leftovers, not financial data.

---------------------------------------------------------------------------------------

## 5. Hazards for the native migration (summary)

- **H1. v2 file is the authoritative source; bare keys are stale.** Any user who has run
  a build with the file store (c05f9eb+) has a v2 file and possibly leftover legacy keys
  (only if a crash hit between commit and cleanup, or from `themeMode`-style keys that
  are never removed). Native must implement "read v2 primary/backup, newest revision wins,
  restore primary from backup" first (2.1 step 2) and touch legacy keys only if no v2
  file decodes. Do not merge legacy keys into a decodable v2 file.
- **H2. Legacy envelope checksum requires Dart-identical re-encoding.** Verifying
  `financial_store_v1` means re-serialising the decoded map exactly as Dart `jsonEncode`
  would (key insertion order, doubles as `5.0`, `1e+21`, no `\u007f`/` ` escaping,
  `/` unescaped; VERIFIED by running Dart: `{"a":5.0,"b":1e+21,"c":"é/<DEL><LS>\"",...}`).
  A Swift `JSONSerialization` round trip will not reproduce that. Safer: hash the
  original substring, or skip verification and use structural sanity checks; note that
  Dart would REJECT an envelope whose checksum fails and fall back to the backup /
  bare keys, so skipping verification can change which copy wins.
- **H3. Empty bare `transactions` overrides the backup envelope.** In the
  "primary envelope unusable" case any decoded `List`, even `[]`, replaces
  `sections['transactions']` (L336-338).
- **H4. `starting_assets` / `starting_liabilities` are never deleted.** If netWorthEntries
  is empty or absent when they are `> 0`, "Starting Assets/Liabilities" entries are
  regenerated (also after a user deletes all net-worth entries), each time with a new
  uuid. If the native app reproduces this legacy fallback it should mark it done.
- **H5. App settings are stored twice.** `appSettings` file section (wins per field) and
  five `flutter.*` prefs (fallback, never removed). A native app that stops writing one
  copy will leave the other stale; if the user later downgrades/rolls back to the Flutter
  build the stale copy can resurface field-by-field.
- **H6. `themeMode` and `onboarding_completed` exist only in NSUserDefaults**
  (`flutter.themeMode`, `flutter.onboarding_completed`). `themeMode` may legitimately be
  absent (never chosen) -> system. `ThemeProvider` reads prefs at provider construction
  (`main.dart:36`) i.e. BEFORE the protected-data gate; the store's own comment says
  NSUserDefaults can read back empty during a prewarmed launch (`atomic_financial_store.dart:93-99`,
  INFERRED, not reproduced), so "absent" is not fully trustworthy in that one situation.
- **H7. Unregistered keys** `local_insights_dismissed_v1` (StringList) and
  `local_insights_snoozed_v1` (JSON String) are outside `StorageKeys` and never cleaned.
- **H8. Type disambiguation in Swift** (3.2): use typed accessors; `as? Bool` matches int
  0/1, `as? Int` matches integral doubles.
- **H9. Dates are local-time ISO-8601 without zone** (INFERRED from Dart semantics for
  `DateTime.toIso8601String()` on non-UTC values). Native decoders must treat zoneless
  strings as local time and must preserve the month-normalisation rules
  (`DateTime(year, month)`) for `selectedNetWorthMonth`.
- **H10. Widget/App Group keys are separate** (`cashFlow`, `cashFlowMonth`, no prefix).
  A native app that keeps the widget must keep writing both keys in the same format
  (`"%04d-%02d"`, Double).
- **H11. Bundle id must stay `com.khatruong.budgetbuddy`** (and keep the App Group
  entitlement) or the container, `Library/Preferences` plist and Application Support file
  are all inaccessible. INFERRED from iOS sandbox rules.

## 6. Unverified / open items

- Exact `FlutterStandardWriter` NSNumber dispatch (3.3): engine source not available.
- Behaviour of `NSUserDefaults` on a locked, prewarmed launch (H6): taken from the repo's
  own comments, not reproduced.
- Which App Store versions map to the c473af9 and c05f9eb layouts (3.4): no tags in git.
- Whether any user still has only pre-envelope bare keys (older than c473af9). The
  migration code handles it, but no evidence about the real population.
- Short-magnitude negative checksum formatting (2.6): reasoned, not executed.
- I did not open `budget_app/.env`.
