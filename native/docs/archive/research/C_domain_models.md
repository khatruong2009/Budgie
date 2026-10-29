> Archived; paths refer to the `flutter-final` tag.

# C. Domain models: persisted shapes for the SwiftUI migration

Scope: every model in `budget_app/lib` that is serialized, and every `FinancialSections` section. Paths are relative to `budget_app/lib/` unless stated. Each claim is tagged VERIFIED (read in code/test at the cited line) or INFERRED (deduced from library behavior, not visible in this repo).

Tooling note: the `uuid` package is `^4.0.0` (pubspec.yaml:48), `intl` `^0.20.2` (pubspec.yaml:36).

---

## 0. Cross-cutting rules

### 0.1 Date encoding (applies to every DateTime field below)

- Every DateTime is written with bare `DateTime.toIso8601String()` and read with `DateTime.parse` / `DateTime.tryParse`. No `.toUtc()`, no `millisecondsSinceEpoch`, no date-only strings are used for persisted fields anywhere in the models. VERIFIED (transaction.dart:93,96,97; recurring_transaction.dart:46,47; net_worth_entry.dart:102,145; savings_goal.dart:86-88; atomic_financial_store.dart:552; transaction_model.dart:253).
- The DateTime values are created as local (`DateTime.now()`, `DateTime(y,m,d)`, date-picker results, `DateTime.parse` of a no-offset string). Nothing in the code calls `.toUtc()`. VERIFIED (grep of models; e.g. transaction_form.dart:41 `DateTime.now()`, transaction_form.dart:389-393 `showDatePicker`, net_worth_entry.dart:9-46 all use `DateTime(...)` constructors).
- Consequence: persisted strings are local wall-clock with NO offset and NO "Z", e.g. `2026-03-05T14:30:00.123456` or `2026-03-05T00:00:00.000`. Dart's format rule: fractional part is 3 digits when microsecond == 0, 6 digits when microsecond != 0; "Z" only for UTC values. INFERRED (Dart SDK behavior; the tests use literal `'2024-03-02T00:00:00.000'` at test/transaction_identity_test.dart:47,82 which matches).
- `DateTime.parse` on a string with no offset yields a LOCAL DateTime; with "Z" or +hh:mm it yields UTC/absolute. Swift must parse no-offset strings as device-local time (not UTC) and must tolerate both 3- and 6-digit fractions. INFERRED (Dart SDK behavior).
- Microsecond precision matters for identity: `updateTransaction` bumps `updatedAt` by 1 microsecond to force monotonic ordering (transaction_model.dart, updateTransaction, "existing.updatedAt.add(const Duration(microseconds: 1))", about line 461), and net worth snapshots are identified by exact `recordedAt` equality (`withSnapshot` net_worth_entry.dart:219, `deleteNetWorthSnapshot` transaction_model.dart:~670 `snapshot.recordedAt != recordedAt`). A Swift `Date` round-tripped through a millisecond-only formatter would break snapshot lookup/delete and updatedAt ordering. VERIFIED (code), risk INFERRED.
- Example strings per field are in each model table.

### 0.2 Numbers

- Money is `double`. `jsonEncode(12.0)` emits `12.0` (Dart keeps the ".0"), `jsonEncode(4.5)` emits `4.5`. INFERRED (Dart SDK). Swift's `JSONEncoder` emits `12` for `12.0`. Read tolerance differs per model (see hazards H1): Transaction/NetWorthSnapshot/SavingsGoal/budget limits accept any JSON number; `RecurringTransaction.amount` does NOT (recurring_transaction.dart:61 `amount: json['amount']`, assigns dynamic to `double`; an int would throw a TypeError). VERIFIED (code), throw behavior INFERRED.
- Non-finite doubles cannot be encoded by `jsonEncode` (backup.dart:180-184 comment says the same). VERIFIED (comment).

### 0.3 IDs

| Model | Generator | Format | Cite |
|---|---|---|---|
| Transaction | `Uuid().v4()` (`_uuid.v4()`), used when `id` is null/empty/whitespace | lowercase hyphenated UUID v4 (package `uuid` default; INFERRED) | transaction.dart:9,37,81-84 VERIFIED |
| RecurringTransaction | `const Uuid().v4()` when `id` null | UUID v4 | recurring_transaction.dart:35 VERIFIED |
| NetWorthEntry | `const Uuid().v4()` when `id` null | UUID v4 | net_worth_entry.dart:120 VERIFIED |
| TransactionTag | `const Uuid().v4()` when `id` null | UUID v4 | transaction_tag.dart:12 VERIFIED |
| CategorizationRule | `const Uuid().v4()` when `id` null | UUID v4 | categorization_rule.dart:30 VERIFIED |
| SavingsGoal | `_generateId()`: `'savings_goal_' + microsecondsSinceEpoch.toRadixString(36) + '_' + counter.toRadixString(36)` | e.g. `savings_goal_1kx9q2m3a4b_0` (shape only; value illustrative) | savings_goal.dart:130-134 VERIFIED |
| BudgetCategory | Not random for built-ins: `expense-<name lowercased, spaces->'-'>` / `income-<...>`. Custom: `<type>-<slug>` where slug = lowercase, runs of non `[a-z0-9]` -> `-`, trimmed of leading/trailing `-`, empty -> `category`; on collision `<type>-<uuid v4>` | e.g. `expense-eating-out`, `income-salary`, `expense-pet-food`, `expense-3f2c...` | category_provider.dart:231-242, 318, 329 VERIFIED |
| Budget limit | No id; keyed by category NAME string | n/a | transaction_model.dart:747,761 VERIFIED |

Identity logic (transaction_model.dart:342-390, test/transaction_identity_test.dart):
- On load, a row with missing/blank `id` gets a fresh UUID; a duplicate `id` (second and later occurrence) also gets a fresh UUID; if any id was backfilled, or `createdAt`/`updatedAt` is not a String, the whole list is re-saved ("needsIdentityMigration") but ONLY if zero rows were unreadable. VERIFIED (transaction_model.dart:363-384; test lines 61-115).
- Rows that throw in `fromJson` are skipped, not fatal; the raw rows remain on disk because no rewrite happens when any row was skipped. VERIFIED (transaction_model.dart:358-368,383; test lines 231-272 "an unreadable stored row is skipped").
- Restore from backup de-duplicates transaction ids the same way (transaction_model.dart:1204-1211) and CSV import always assigns a new id (transaction_model.dart:~1187). VERIFIED.
- Delete is by id (`deleteTransactionById`; test lines 148-166). No other natural key exists for transactions. VERIFIED.
- `Transaction.compareNewestFirst` orders by calendar day desc, then `createdAt` desc, then `id` string desc (transaction.dart:70-76). VERIFIED.

### 0.4 Enum encodings

| Enum | Written as | Read behavior | Cite |
|---|---|---|---|
| `TransactionTyp` (income, expense) in Transaction | `'expense'` or `'income'` via ternary | `json['type'] == 'expense' ? expense : income`, so ANY other value (null, "Expense", "EXPENSE") becomes **income** | transaction.dart:89,106-108 VERIFIED |
| `TransactionTyp` in RecurringTransaction | same ternary | same fallback to **income** | recurring_transaction.dart:41,57-59 VERIFIED |
| `TransactionTyp` in CategorizationRule.transactionType | `transactionType?.name` -> `'expense'`/`'income'`/`null` | null -> null (no type filter); unknown string -> **expense** | categorization_rule.dart:63,42-47 VERIFIED |
| `RecurrencePattern` | `pattern.name` -> `'weekly'`/`'biweekly'`/`'monthly'` | `firstWhere` with NO `orElse`: unknown/missing pattern throws `StateError` | recurring_transaction.dart:45,63-65 VERIFIED |
| `NetWorthEntryType` | `'asset'`/`'liability'` via ternary | `(json['type'] as String) == 'liability' ? liability : asset`; unknown -> **asset**; null/non-String throws | net_worth_entry.dart:144,128-130 VERIFIED |
| `BudgetCategoryType` | `type.name` -> `'expense'`/`'income'` | `== 'income' ? income : expense`; anything else -> **expense** | category_definition.dart:44,30-32 VERIFIED |
| `MerchantMatchType` | `matchType.name` -> `'contains'`/`'startsWith'`/`'exact'` | `firstWhere` with `orElse: contains` | categorization_rule.dart:62,38-41 VERIFIED |
| `ThemeMode` (backup only) | `'light'`/`'dark'`/`'system'`/`null` | unknown -> null (do not change) | backup.dart:259-283 VERIFIED |

---

## 1. Store envelope and sections

### 1.1 File layout (VERIFIED, atomic_financial_store.dart)

- Directory `<ApplicationSupport>/financial_store/`, primary `financial_store_v2.json`, backup `financial_store_v2.backup.json` (lines 114-118, 505-510 `_resolveBackend`).
- Bytes = `jsonEncode(header)` + `\n` (0x0A) + payload (lines 544-560).
- Payload = `utf8.encode(jsonEncode(snapshot.sections))`, i.e. a single JSON OBJECT whose keys are section names (line 545).
- Header keys in insertion order: `format` ("budgie-financial-store", line 120), `schemaVersion` (int, 2, line 115), `revision` (int), `payloadLength` (int, byte length), `payloadChecksum` (16-char lowercase hex FNV-1a 64, zero-padded, over the exact payload bytes, lines 611-618), `writtenAt` (local ISO string, line 552).
- Header validation on read: format must equal tag, `schemaVersion` int and `<= 2`, revision/payloadLength ints, checksum String, payload length and checksum must match, else the file is treated as unreadable (lines 567-600). Newest revision of primary/backup wins (lines 226-244).
- Sections map key order: `copyWithSections` does `Map.from(sections)..addAll(updates)`, so existing keys keep position and new keys append (lines 48-54). Order is not semantically significant to any reader in this repo.

### 1.2 Section table (VERIFIED)

Section names are `FinancialSections` constants (atomic_financial_store.dart:14-27). Every value is stored as plain JSON.

| Section key | Owner | Payload shape | Writer cite | Reader cite |
|---|---|---|---|---|
| `transactions` | TransactionModel | JSON array of Transaction objects (order = in-memory list order, append order; not sorted) | transaction_model.dart:249,303-304 | transaction_model.dart:348-390 (only decoded if non-empty List; otherwise `[]`) |
| `netWorthEntries` | TransactionModel | JSON array of NetWorthEntry objects (each with nested `snapshots` array) | transaction_model.dart:251 | transaction_model.dart:392-402 (if missing or empty: falls to legacy `starting_assets`/`starting_liabilities` prefs migration, lines 1473-1514) |
| `selectedNetWorthMonth` | TransactionModel | a single JSON STRING: `_selectedNetWorthMonth.toIso8601String()`, e.g. `"2026-07-01T00:00:00.000"` (always normalized to day 1 midnight) | transaction_model.dart:237,252-253 | transaction_model.dart:404-411 (`DateTime.tryParse`, then normalized to `DateTime(y,m)`; ignore if not a non-empty String) |
| `categoryBudgetLimits` | TransactionModel | JSON object `{ "<categoryName>": <number> }`; name -> monthly limit; values `> 0` only in memory | transaction_model.dart:254-255 | transaction_model.dart:413-420 (`(value as num).toDouble()`, drops `<= 0`; a non-num value throws) |
| `savingsGoals` | TransactionModel | JSON array of SavingsGoal objects | transaction_model.dart:256-257 | transaction_model.dart:422-429 (only `is List`; else `[]`) |
| `recurringTransactions` | RecurringTransactionModel | JSON array of RecurringTransaction objects | recurring_transaction_model.dart:70 | recurring_transaction_model.dart:90-98 (only if non-empty List; **no per-row try/catch**) |
| `categories` | CategoryProvider | JSON array of BudgetCategory objects (list order = `_categories` order; NOT sorted by sortOrder) | category_provider.dart:261-269 | category_provider.dart:32-69 |
| `transactionTags` | CategorizationProvider | JSON array of TransactionTag objects | categorization_provider.dart:169-174 | categorization_provider.dart:35-43,183-199 |
| `categorizationRules` | CategorizationProvider | JSON array of CategorizationRule objects (written in `_rules` insertion order, not priority order) | categorization_provider.dart:176-181 | categorization_provider.dart:44-52 |
| `appSettings` | AppSettingsProvider | JSON object (5 keys, see 2.10) | app_settings_provider.dart:158-169 | app_settings_provider.dart:32-56 |

Not in the store (SharedPreferences, not financial): `themeMode` (`'light'|'dark'|'system'`, theme_provider.dart:17-28, storage_keys.dart:44), `onboarding_completed` bool (storage_keys.dart:48), `local_insights_dismissed_v1` (string list) and `local_insights_snoozed_v1` (JSON object id -> local ISO string, 30-day snooze) (widgets/local_insights_section.dart:21-23,38-47,84-92). Backup also carries `themeMode` (backup.dart:70). VERIFIED.

Legacy pre-envelope: `SharedPreferences` keys `financial_store_v1`, `financial_store_v1_backup`, and per-feature keys (`transactions`, `net_worth_entries`, `net_worth_selected_month`, `category_budget_limits`, `savings_goals`, `recurring_transactions`, `categories_v1`, `transaction_tags_v1`, `categorization_rules_v1`, plus the 5 app-setting keys, `starting_assets`, `starting_liabilities`) are migrated once into the file then removed (atomic_financial_store.dart:281-343 area, storage_keys.dart). A native app that reads the Flutter file does not need these unless it must import from a never-migrated install. VERIFIED.

---

## 2. Per-model tables

### 2.1 Transaction (transaction.dart) -> section `transactions`

toJson (transaction.dart:87-98), keys in insertion order:

| # | Key | JSON type | Source / encoding | Example |
|---|---|---|---|---|
| 1 | `id` | string | UUID v4 | `"6f1c2a4e-8d3b-4c1a-9e57-2b0d4f6a7c11"` |
| 2 | `type` | string | `'expense'` if expense else `'income'` | `"expense"` |
| 3 | `description` | string | as-is (may be empty) | `"Coffee"` |
| 4 | `amount` | number (double) | `double`, positive magnitude; sign given by `type` (INFERRED: nothing in the model enforces > 0; the form validates > 0 in the UI) | `4.5` |
| 5 | `category` | string | category NAME (display string), not an id | `"Eating Out"` |
| 6 | `date` | string | local `toIso8601String()`, time-of-day inconsistent: `DateTime.now()` (with micros) from the add form default (transaction_form.dart:41), midnight from date picker (transaction_form.dart:389-397) and voice parsing (voice_expense_service.dart:~172-205), recurring uses template `nextOccurrence` | `"2026-03-05T14:30:00.123456"` or `"2026-03-05T00:00:00.000"` |
| 7 | `recurringTemplateId` | string or null | always present as a key, `null` when not generated | `null` / `"<uuid>"` |
| 8 | `tagIds` | array of string | `TransactionTag.id` values; always present | `[]` |
| 9 | `createdAt` | string | local ISO, `DateTime.now()` at construction | `"2026-03-05T14:30:00.123456"` |
| 10 | `updatedAt` | string | local ISO; = createdAt at creation; on update `max(now, old+1us)` | `"2026-03-05T14:31:07.000001"` |

fromJson (transaction.dart:101-120):

| Key | Missing/invalid behavior |
|---|---|
| `date` | `DateTime.parse(json['date'])`. Missing -> throws (null passed to parse: TypeError); malformed string -> FormatException. Row is skipped by TransactionModel (transaction_model.dart:358-368). VERIFIED |
| `id` | `json['id'] as String?`; null/empty/whitespace -> new UUID (transaction.dart:37, 81-82). Non-String (e.g. int) throws. VERIFIED. TransactionModel additionally regenerates blank/duplicate ids and re-saves (transaction_model.dart:369-381) |
| `type` | `== 'expense'` else income (never throws) |
| `description` | `json['description']` assigned to `String`; missing/null -> TypeError -> row skipped. VERIFIED (code), throw INFERRED |
| `amount` | `(json['amount'] as num).toDouble()`; missing/non-num throws -> row skipped. int accepted. VERIFIED |
| `category` | `json['category']` to `String`; missing -> throws -> skipped |
| `recurringTemplateId` | `as String?` (non-String throws) |
| `tagIds` | `(as List? ?? [])`, `whereType<String>()` silently drops non-strings. Missing -> `[]` |
| `createdAt` | `_parseDate` = `value is String ? DateTime.tryParse : null`; fallback = parsed `date` |
| `updatedAt` | `_parseDate`; fallback = resolved `createdAt` |
| Legacy names | none accepted |

Derived/ignored: `isRecurring` getter is derived, not persisted. No field is persisted-but-ignored. Unknown extra keys are dropped on next write (no passthrough). VERIFIED.

### 2.2 RecurringTransaction (recurring_transaction.dart) -> section `recurringTransactions`

toJson (recurring_transaction.dart:39-51), key order:

| # | Key | JSON type | Encoding | Example |
|---|---|---|---|---|
| 1 | `id` | string | UUID v4 | `"a1b2..."` |
| 2 | `type` | string | `'expense'`/`'income'` | `"expense"` |
| 3 | `description` | string | as-is | `"Rent"` |
| 4 | `amount` | number (double) | double, encoded with `.0` when whole | `1200.0` |
| 5 | `category` | string | category name | `"Housing"` |
| 6 | `pattern` | string | `pattern.name`: `weekly`/`biweekly`/`monthly` | `"monthly"` |
| 7 | `startDate` | string | local ISO; form default `DateTime.now()` (with time) or date-picker midnight (recurring_transaction_form.dart:34,~481-504) | `"2026-03-05T00:00:00.000"` |
| 8 | `nextOccurrence` | string | local ISO; = startDate at creation; advanced by generator (`add(7d)`, `add(14d)`, or `DateTime(y,m,day)` midnight for monthly) | `"2026-04-05T00:00:00.000"` |
| 9 | `dayOfMonth` | int or null | 1-31, always written (null if unset) | `5` / `null` |
| 10 | `dayOfWeek` | int or null | 1-7 (Mon-Sun) per comment; always written | `3` / `null` |
| 11 | `isActive` | bool | | `true` |

fromJson (recurring_transaction.dart:54-72):

| Key | Behavior |
|---|---|
| `id` | `json['id']` passed as `String?`; missing/null -> new UUID; **a non-String throws** |
| `type` | ternary; unknown -> income |
| `description` / `category` | untyped assign to String; missing -> throws |
| `amount` | **`json['amount']` with no `num` coercion**; int in JSON throws TypeError (see H1) |
| `pattern` | `firstWhere` no `orElse`: unknown/missing -> StateError |
| `startDate`, `nextOccurrence` | `DateTime.parse(json[...])` strict; missing -> throws (nextOccurrence has NO fallback to startDate when reading) |
| `dayOfMonth`, `dayOfWeek` | assigned directly to `int?`; a double (e.g. `5.0`) throws; missing -> null |
| `isActive` | `json['isActive'] ?? true` |
| Whole-load behavior | `loadRecurringTransactions` maps with no try/catch (recurring_transaction_model.dart:93-96); an exception propagates to `_initializeApp` catch (main.dart:~297) which aborts the remaining startup (recurring generation is skipped). VERIFIED (code) |

Semantics needed by native: monthly templates require non-null `dayOfMonth` (generator does `dayOfMonth!`, transaction_generator.dart, `recurring.dayOfMonth!`; backup validates 1..31 at backup.dart:218-221). `dayOfWeek` is written and round-tripped but never used by the generator or `calculateNextOccurrence` (VERIFIED: grep shows only the form and model reference it). Generator: runs on launch, due = active and `nextOccurrence` is before now or same day; 90-day lookback (transaction_generator.dart:~28-60); `copyWith` cannot set a nullable field back to null (`dayOfMonth ?? this.dayOfMonth`), so nulls stick (recurring_transaction.dart:125-141). VERIFIED.

### 2.3 NetWorthEntry (net_worth_entry.dart:107-227) -> section `netWorthEntries`

toJson (net_worth_entry.dart:141-147), key order:

| # | Key | JSON type | Encoding | Example |
|---|---|---|---|---|
| 1 | `id` | string | UUID v4 | |
| 2 | `name` | string | trimmed on creation by model (transaction_model.dart:597-599), not by class | `"Checking"` |
| 3 | `type` | string | `'asset'`/`'liability'` | `"asset"` |
| 4 | `createdAt` | string | local ISO of `DateTime.now()` at construction | `"2026-03-05T14:30:00.123456"` |
| 5 | `snapshots` | array of NetWorthSnapshot | order = kept sorted ascending by `recordedAt` only after `withSnapshot`; initial single-snapshot list otherwise | see 2.4 |

fromJson (net_worth_entry.dart:124-139):

| Key | Behavior |
|---|---|
| `id` | `json['id'] as String` (non-null cast): missing throws. NO fallback UUID on read |
| `name` | `as String`; missing throws |
| `type` | `(json['type'] as String) == 'liability'` else asset; missing/null throws (null is not String) |
| `createdAt` | `DateTime.parse(json['createdAt'] as String)`: missing throws. Does NOT fall back |
| `snapshots` | `as List? ?? []`, each item `as Map<String,dynamic>`; a bad item throws and the whole entry list load throws (transaction_model.dart:394-396 has no try/catch). VERIFIED (code) |

NOTE: `getTransactions` reads netWorthEntries with no error isolation; a throw here aborts the whole `getTransactions` after transactions were already loaded, and everything after (budgets, goals) is not loaded (transaction_model.dart:392-431). VERIFIED (code).

### 2.4 NetWorthSnapshot (net_worth_entry.dart:48-105), nested in `snapshots`

toJson (net_worth_entry.dart:101-104), key order:

| # | Key | JSON type | Encoding | Example |
|---|---|---|---|---|
| 1 | `recordedAt` | string | local ISO; default for "current" month = `DateTime.now()` (with micros), for other months `endOfNetWorthMonth` = last-day 23:59:59.999 (net_worth_entry.dart:38-41; transaction_model.dart:1441-1450) | `"2026-02-28T23:59:59.999"` |
| 2 | `amount` | number (double) | | `15230.5` |

fromJson (net_worth_entry.dart:71-99), including legacy names:
- `recordedAt` (non-empty String) -> `DateTime.parse`.
- else legacy `monthKey` (`"yyyy-MM"`): month = `DateTime(y,m)`; if legacy `updatedAt` parses AND falls in that same year/month, use it; else the month start.
- else if legacy `updatedAt` non-empty: `DateTime.parse(updatedAt)` (strict).
- else `DateTime.now()`.
- `amount`: `(json['amount'] as num).toDouble()`, missing throws.
- The legacy keys are read-only; they are never written back (toJson emits only `recordedAt`, `amount`). VERIFIED.

Derived (NOT persisted): `monthKey` = `DateFormat('yyyy-MM')` and `dayKey` = `yyyy-MM-dd` getters (net_worth_entry.dart:52-53). The "month-keyed" semantics of AGENTS.md are computed at read time, not stored. VERIFIED.

Semantics: a snapshot is identified by exact `recordedAt` equality (withSnapshot, deleteNetWorthSnapshot). "Amount for month" = latest snapshot with `recordedAt <= endOfMonth` (net_worth_entry.dart:181-203). Multiple snapshots per month are allowed. VERIFIED.

### 2.5 SavingsGoal (savings_goal.dart) -> section `savingsGoals`

toJson (savings_goal.dart:81-89), key order:

| # | Key | JSON type | Encoding | Example |
|---|---|---|---|---|
| 1 | `id` | string | `savings_goal_<micros base36>_<counter base36>` | `"savings_goal_1abc2def_0"` |
| 2 | `name` | string | trimmed | `"Vacation"` |
| 3 | `targetAmount` | number | double, clamped to >= 0 by constructor | `5000.0` |
| 4 | `currentAmount` | number | double, clamped to >= 0 | `1250.0` |
| 5 | `targetDate` | string | local ISO; model normalizes to `DateTime(y,m,d)` midnight on add (transaction_model.dart:~880-884) | `"2026-12-31T00:00:00.000"` |
| 6 | `createdAt` | string | local ISO `DateTime.now()` | `"2026-03-05T14:30:00.123456"` |
| 7 | `completedAt` | string or null | key always present; null until reached | `null` / `"2026-06-01T09:00:00.000123"` |

fromJson (savings_goal.dart:91-107), the most tolerant model:
- `id`: `as String?`; missing -> generated.
- `name`: `(json['name'] as String?)?.trim()` non-empty else the literal `'Savings Goal'`.
- `targetAmount`/`currentAmount`: `_readDouble` accepts num, or String via `double.tryParse` (else 0.0); anything else 0.0; constructor then clamps negatives to 0.0 (lines 136-144, 23-24).
- `targetDate`, `createdAt`: `_readDate` (String non-empty via `tryParse`, else null) with fallback `DateTime.now()` (so a missing date silently becomes "now" and will be persisted as such).
- `completedAt`: `_readDate`, nullable.
- Never throws for a Map input; a non-Map list element throws in the caller (`goal as Map<String,dynamic>`, transaction_model.dart:425).

Derived, NOT persisted: `progress`, `progressPercent`, `remainingAmount`, `isCompleted`, `isOverdue`, `daysRemaining`, `suggestedMonthlyContribution` (savings_goal.dart:27-79). Persisted but derived-in-effect: `completedAt` is set by the model when `currentAmount >= targetAmount` (`goal.completedAt ?? now`) and cleared (null) otherwise, in `updateSavingsGoal` and `allocateToSavingsGoal` (transaction_model.dart:~911, ~953). It is not recomputed on load. `allocateToSavingsGoal` does NOT create a Transaction; savings goal amounts are standalone. VERIFIED.

### 2.6 BudgetCategory ("CategoryDefinition") (category_definition.dart) -> section `categories`

Class is `BudgetCategory` with enum `BudgetCategoryType { expense, income }` (category_definition.dart:3,6). toJson (lines 42-51), key order:

| # | Key | JSON type | Encoding | Example |
|---|---|---|---|---|
| 1 | `id` | string | slug id (see 0.3) | `"expense-eating-out"` |
| 2 | `type` | string | `type.name` | `"expense"` |
| 3 | `name` | string | display name; THE key transactions reference | `"Eating Out"` |
| 4 | `iconIdentifier` | string | key into `categoryIconRegistry` (common.dart:4-23) | `"asterisk_circle"` |
| 5 | `colorToken` | string | design token name | `"orange"` |
| 6 | `sortOrder` | int | per-type dense 0..n-1 (normalized on load and on every change) | `1` |
| 7 | `isArchived` | bool | | `false` |
| 8 | `isBuiltIn` | bool | | `true` |

fromJson (lines 27-40): `id` `as String` (missing throws), `name` `as String` (missing throws), `type` `== 'income'` else expense, `iconIdentifier` default `'square_grid_2x2'`, `colorToken` default `'accent'`, `sortOrder` `(as num?)?.toInt() ?? 0`, `isArchived` default false, `isBuiltIn` default false. No legacy names.

Load rules (category_provider.dart:32-69): missing/empty/corrupt/empty-list -> seed the built-in list (below); a throw anywhere in decoding also seeds defaults (blanket `catch (_)`), which discards a malformed stored list on the next write (persist occurs when `stored is! List || jsonEncode(stored) != jsonEncode(_serialize())`, line 47; that comparison is key-order and formatting sensitive, so a differently ordered file would trigger a harmless rewrite). After decode: `_normalizeSortOrders` re-sequences per type. VERIFIED.

Unknown `iconIdentifier` values are stored as-is on load (only new/edited categories are validated against the registry, category_provider.dart:132-135, 189-192); rendering falls back to `square_grid_2x2` (category_provider.dart:277-278). VERIFIED.

### 2.7 TransactionTag (transaction_tag.dart) -> section `transactionTags`

toJson (lines 23-27): `id` (string, UUID v4), `name` (string, trimmed), `colorToken` (string). fromJson (lines 15-21): `id as String?` (missing -> new UUID), `name as String? ?? ''`, `colorToken` default `'accent'`. The load path wraps the whole list in a blanket catch returning `[]` (categorization_provider.dart:187-198), so ONE bad element empties ALL tags (and likewise all rules; next write persists the empty list). VERIFIED.
Tags are referenced by `Transaction.tagIds` and `CategorizationRule.tagIds` by id. Deleting a tag removes it from rules (categorization_provider.dart:71-91) but NOT from transactions' `tagIds`, so dangling ids are possible in the ledger. VERIFIED.

### 2.8 CategorizationRule (categorization_rule.dart) -> section `categorizationRules`

toJson (lines 59-70), key order:

| # | Key | JSON type | Notes | Example |
|---|---|---|---|---|
| 1 | `id` | string | UUID v4 | |
| 2 | `merchantPattern` | string | trimmed; empty pattern never matches | `"starbucks"` |
| 3 | `matchType` | string | `contains`/`startsWith`/`exact` | `"contains"` |
| 4 | `transactionType` | string or null | `expense`/`income`/`null` | `null` |
| 5 | `minimumAmount` | number or null | | `null` |
| 6 | `maximumAmount` | number or null | | `20.0` |
| 7 | `category` | string | category NAME | `"Eating Out"` |
| 8 | `tagIds` | array of string | | `[]` |
| 9 | `priority` | int | higher first (`rules` sorts by priority desc, categorization_provider.dart:26-30) | `0` |
| 10 | `isEnabled` | bool | | `true` |

fromJson (lines 33-57): `id as String?`; `merchantPattern` default `''`; `matchType` `orElse: contains`; `transactionType` null -> null else `orElse: expense`; `minimumAmount`/`maximumAmount` `(as num?)?.toDouble()`; `category` default `'General'`; `tagIds` `whereType<String>` default `[]`; `priority` `(as num?)?.toInt() ?? 0`; `isEnabled` default true. Matching semantics (lines 72-89): case-insensitive on `description.trim().toLowerCase()` vs `merchantPattern.toLowerCase()`; min/max inclusive; first enabled match in priority-desc order wins, ties keep insertion order (Dart `List.sort` is not guaranteed stable in the general case; INFERRED, practical impact is on equal priorities only).
Rule `category` renames follow category renames (categorization_provider.dart:128-150). VERIFIED.

### 2.9 Budgets (category budget limits) -> section `categoryBudgetLimits`

No model class. Shape: JSON object `{ "<expense category name>": <double> }`. Written from `Map<String,double>.from(_categoryBudgetLimits)` (transaction_model.dart:254-255), so whole limits serialize as e.g. `300.0`. Only expense categories (income names are never keys; rename only touches limits when `type == expense`, transaction_model.dart:803-810). Keys are trimmed on set (line 750-755). Limits `<= 0` are removed on set (757-759) and dropped again on load (415-417) and on restore (1214-1215). Load throws (whole `getTransactions` aborts here) if any value is not a num (line 416). `ensureLegacyCategoryNames` in main.dart:~285-289 creates category definitions for any budget key that lacks one. The budget is a flat monthly limit per category; there is no per-month map. VERIFIED.

### 2.10 AppSettings (app_settings_provider.dart) -> section `appSettings`

Persisted object (lines 158-169), key order:

| # | Key | JSON type | Default when missing | Notes |
|---|---|---|---|---|
| 1 | `baseCurrencyCode` | string | falls back to SharedPreferences `base_currency_code`, then `'USD'` (lines 38-40) | 3 letters uppercase (setter normalizes, lines 58-66) |
| 2 | `localeOverride` | string or null | prefs `locale_override`, else null | e.g. `"en_US"`; empty/blank -> null; `Locale` split on `[-_]` |
| 3 | `appLockEnabled` | bool | prefs, else `false` | |
| 4 | `autoLockTimeoutSeconds` | int | prefs, else `60` | `(as num?)?.toInt()`; setter rejects `< 0` |
| 5 | `hideBalances` | bool | prefs, else `false` | |

Read side: section used only if `is Map<String,dynamic>`, else defaults; each key uses `as String?`/`as bool?` typed casts (a wrong type throws). Every setter ALSO writes the SharedPreferences key (redundant mirror; the file is authoritative on read when the key is present). VERIFIED. The `theme` mode is NOT in this section.

### 2.11 Backup envelope (informational; not a store section) (backup.dart)

Pretty-printed (2-space) JSON: `schemaVersion` (int, currently 3, `kBackupSchemaVersion`, line 15), `app` (`"budgie"`), `appVersion`, `exportedAt` (local ISO), `data` object with keys in order: `transactions`, `netWorthEntries`, `categoryBudgetLimits`, `savingsGoals`, `recurringTransactions`, `themeMode`, `categories`, `transactionTags`, `categorizationRules`, `baseCurrencyCode`, `localeOverride`, `appLockEnabled`, `autoLockTimeoutSeconds`, `hideBalances` (lines 58-82). Uses the same per-model toJson/fromJson; decode is stricter (type strings must be exactly `expense`/`income`/`asset`/`liability`; amounts finite; monthly recurring `dayOfMonth` 1..31; ids unique; rules' tagIds must exist; must contain an active category of each type when `categories` non-empty) (lines 191-223, 123-151). A missing `data.<section>` is treated as empty. Restore is full-replace (settings_page.dart:~418-445). VERIFIED.

---

## 3. Categories (common.dart + category_provider.dart)

Transactions, recurring templates, rules and budget limits reference categories BY NAME STRING (transaction.dart:15; recurring_transaction.dart:15; categorization_rule.dart:14; transaction_model.dart:156). The definition `id` is only used for CRUD/ordering inside `CategoryProvider`. A rename rewrites the string in transactions (bumping `updatedAt`), recurring templates, rules and budget keys (transaction_model.dart:786-828; recurring_transaction_model.dart:40-56; categorization_provider.dart:128-150). Categories cannot be deleted, only archived (category_provider.dart:198-209); archived categories drop out of the `expenseCategories`/`incomeCategories` picker maps (category_provider.dart:271-290) but old transactions keep the name. On every launch, any name used by a transaction/template/budget with no matching definition (case-insensitive, per type) gets a new non-built-in definition with icon `square_grid_2x2`, color `accent` (category_provider.dart:74-112, main.dart:273-290). Name uniqueness is case-insensitive per type (category_provider.dart:226-229). The same name may exist in both types (e.g. "Gift"). VERIFIED.

`common.dart` default maps (lines 28-49) are only the boot-time compatibility maps; `CategoryProvider` overwrites them after load. The authoritative seed list is `_builtInCategories()` (category_provider.dart:293-339). Icon code points come from Flutter's `CupertinoIcons` (font family `CupertinoIcons`, package `cupertino_icons`), read from the local Flutter SDK at `/Users/khatruong/Documents/flutter/packages/flutter/lib/src/cupertino/icons.dart` (SDK-version dependent; VERIFIED locally, cupertino_icons lock 1.0.9).

Expense defaults (order = sortOrder; id = `expense-` + lowercase name with spaces -> `-`):

| sortOrder | id | name | iconIdentifier | CupertinoIcons member | code point | colorToken |
|---|---|---|---|---|---|---|
| 0 | expense-general | General | square_grid_2x2 | square_grid_2x2 | 0xf804 | accent |
| 1 | expense-eating-out | Eating Out | asterisk_circle | asterisk_circle | 0xf572 | orange |
| 2 | expense-groceries | Groceries | cart | cart | 0xf3f7 | green |
| 3 | expense-housing | Housing | house | house | 0xf447 | blue |
| 4 | expense-transportation | Transportation | car | car_detailed | 0xf2c1 | purple |
| 5 | expense-travel | Travel | airplane | airplane | 0xf4d4 | cyan |
| 6 | expense-clothing | Clothing | bag | bag | 0xf57e | pink |
| 7 | expense-gift | Gift | gift | gift | 0xf689 | purple |
| 8 | expense-health | Health | heart | heart | 0xf442 | red |
| 9 | expense-entertainment | Entertainment | film | film | 0xf66b | orange |
| 10 | expense-pets | Pets | paw | paw | 0xf479 | green |
| 11 | expense-family | Family | people | person_2 | 0xf740 | blue |
| 12 | expense-loan-payment | Loan Payment | money | money_dollar | 0xf8e9 | red |

Income defaults (id prefix `income-`):

| sortOrder | id | name | iconIdentifier | CupertinoIcons member | code point | colorToken |
|---|---|---|---|---|---|---|
| 0 | income-salary | Salary | money | money_dollar | 0xf8e9 | green |
| 1 | income-investment | Investment | chart | chart_bar | 0xf5c5 | blue |
| 2 | income-gift | Gift | gift | gift | 0xf689 | purple |
| 3 | income-other | Other | square_grid_2x2 | square_grid_2x2 | 0xf804 | accent |

All built-ins: `isArchived:false`, `isBuiltIn:true`. Remaining registry-only icons (available to custom categories, common.dart:4-23): `book` -> `book` 0xf3e7, `phone` -> `device_phone_portrait` 0xf8cf, `wrench` -> `hammer` 0xf6a9, `leaf` -> `leaf_arrow_circlepath` 0xf6d5. The registry has 18 entries total. Note the identifier-to-member mapping is not 1:1 by name (`car`->`car_detailed`, `people`->`person_2`, `money`->`money_dollar`, `chart`->`chart_bar`, `phone`->`device_phone_portrait`, `wrench`->`hammer`, `leaf`->`leaf_arrow_circlepath`). VERIFIED.

Color tokens observed: `accent, orange, green, blue, purple, cyan, pink, red` (seed list only; the full allowed set lives in the category settings UI, not audited here: INFERRED that other tokens exist).
`Transaction` defaults: a categorization rule with no category uses literal `'General'` (categorization_rule.dart:50).

---

## 4. Round-trip hazards (ranked)

- H1 Integer-valued doubles. Flutter writes whole doubles as `1200.0`; Swift `JSONEncoder` writes `1200`. Reads are OK for Transaction/NetWorthSnapshot/SavingsGoal/budget limits/rule bounds (`as num`), but `RecurringTransaction.amount` (recurring_transaction.dart:61) is an uncoerced assignment, and `dayOfMonth`/`dayOfWeek` must be JSON ints (`5`, not `5.0`). If Swift-written data is ever read by the Flutter app, a recurring template amount of `1200` throws in `loadRecurringTransactions` and aborts startup init (main.dart catch). Also make sure Swift decodes `12.0` and `12` interchangeably.
- H2 Date format/timezone. No-offset local strings, 3 vs 6 fractional digits, microsecond identity for `updatedAt` and net worth `recordedAt` equality. Use a custom formatter that emits Dart's exact shape and parses local when there is no offset; store/compare at microsecond precision.
- H3 Unknown-enum fallbacks are inconsistent: transaction and recurring `type` fall back to INCOME, rule `transactionType` to EXPENSE, category `type` to EXPENSE, net worth `type` to ASSET, `pattern` throws.
- H4 Load-time throwing vs skipping: transactions skip bad rows; net worth entries, savings goals, budget values and recurring templates throw and abort a multi-section load (transaction_model.dart:392-431, recurring_transaction_model.dart:93-96); categories/tags/rules swallow errors and reset to seeds/empty, which then overwrite the stored list on the next write.
- H5 Dropping unknown keys/legacy keys on rewrite: Swift must not rely on passthrough; legacy snapshot keys `monthKey`/`updatedAt` are read but never re-written.
- H6 `tagIds` can dangle (tag deletion does not scrub transactions). Category names are the join key, so renames must rewrite four places.
- H7 Sections are independent arrays with no foreign-key enforcement; `recurringTemplateId` can dangle if a template is deleted (recurring_transaction_model.dart:34-38 does not touch transactions).
- H8 `Transaction.date` time-of-day is inconsistent; month bucketing uses local year/month of `date` (net worth uses `recordedAt` the same way), so a device timezone change shifts nothing in storage but changes displayed months only if a "Z" string is present (none are written by the Flutter app).
- H9 The store checksum is over the exact payload bytes, so a native writer need not reproduce Dart's key order or spacing; only the header/payload byte-length and FNV-1a-64 must be correct (atomic_financial_store.dart:544-560, 611-618).

## 5. Unverified / not determined

- Exact set of allowed `colorToken` strings beyond the eight in the seed list (not traced through category settings UI).
- Dart `toIso8601String` fractional-digit rule and `uuid` v4 casing are library behavior (INFERRED); no on-disk sample from a real device was inspected in this task (memory notes a seeded simulator store exists but it was not opened here).
- `voice_expense_service.dart` transaction date handling (lines ~170-205) was read only for the date-normalization piece; its LLM JSON contract is not persisted and was not documented.
- CSV export/import column format (transaction_model.dart:~1023-1176) is not a persisted model and was not documented here.
- Whether the Flutter `TransactionModel.selectedMonth` (spending tab) is persisted: it is not (transaction_model.dart:151 in-memory only; no section), VERIFIED by absence in `serializeSection`.
