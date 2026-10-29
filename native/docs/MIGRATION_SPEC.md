# Budgie native migration spec

Status: APPROVED 2026-09-28. All section 14 decisions resolved as recommended;
Q7 = option (a). See 14.0.

Source of truth: the Flutter app (`budget_app/`), removed from the tree and kept
at the `flutter-final` git tag (commit `a3641f5`). The research notes cite
`budget_app/` as it was at `b69008d` (3.4.0). Research notes backing every
claim are in `native/docs/archive/research/` (A-I). Where this spec and a research note
disagree, this spec wins; the disagreements are listed in section 15.

Notation: `MUST` is a hard compatibility requirement with a test in the risk
register (section 13). "Dart" means the shipped Flutter app.

---------------------------------------------------------------------------------

## 1. Goal and non-goals

The Swift app replaces the Flutter app in place (same bundle ID, App Store
update), loses nothing, and until the user approves otherwise stays
**bidirectionally compatible**: anything Swift writes, the Flutter build reads,
and vice versa. The MVP does not redesign any storage format.

---------------------------------------------------------------------------------

## 2. Identifiers (confirmed from the Xcode project, research F section 1)

| Item | Value |
|---|---|
| App bundle ID | `com.khatruong.budgetbuddy` (Debug/Release/Profile) |
| Widget extension bundle ID | `com.khatruong.budgetbuddy.BudgetWidgetsExtension` |
| Team | `TJ37GFZKW2` |
| App Group | `group.com.khatruong.budgetbuddy` (app + widget; no other entitlements, no keychain groups) |
| URL scheme | `budgetapp`, `CFBundleURLName` `com.khatruong.budgetbuddy`, role Editor |
| Display name | `Budgie` (`CFBundleDisplayName`) |
| Widget kinds | `BudgetQuickActions`, `BudgetVoiceAdd` (both `.systemSmall`) |
| Quick-action types | `action_add_expense`, `action_add_income`, `action_voice_add` (dynamic, registered at runtime) |
| Deep links | `budgetapp://add-income`, `add-expense`, `voice-add` (+ underscore variants) |
| Device family / orientation | iPhone only, portrait only |
| Category | `public.app-category.finance` |
| Current version | `3.4.0` build `1` (from `pubspec.yaml`), the last upload (section 14, Q6) |

MUST: the Swift app and widget use exactly these values. Changing a widget
`kind` blanks widgets users have already placed (research I section 2).

---------------------------------------------------------------------------------

## 3. Data inventory: every source that must survive

| # | Source | Location | Owner in Swift MVP |
|---|---|---|---|
| D1 | Primary store | `<container>/Library/Application Support/financial_store/financial_store_v2.json` | `FinancialStore` (read/write) |
| D2 | Backup store | same dir, `financial_store_v2.backup.json` | `FinancialStore` (read/write) |
| D3 | Staging leftovers | `financial_store_v2.json.tmp`, `financial_store_v2.backup.json.tmp` | ignored on load, overwritten on next commit (same as Dart) |
| D4 | Forensic copies | `*.corrupt-<epochMs>` | never read, never deleted |
| D5 | Legacy v1 envelope | `UserDefaults.standard` `flutter.financial_store_v1` (String) | legacy migrator (read-once, remove after verified commit) |
| D6 | Legacy v1 envelope backup | `flutter.financial_store_v1_backup` (String) | same |
| D7 | Legacy bare section keys | `flutter.transactions`, `flutter.net_worth_entries`, `flutter.net_worth_selected_month`, `flutter.category_budget_limits`, `flutter.savings_goals`, `flutter.recurring_transactions`, `flutter.categories_v1`, `flutter.transaction_tags_v1`, `flutter.categorization_rules_v1` (all String) | same |
| D8 | Settings mirror keys | `flutter.base_currency_code` (String), `flutter.locale_override` (String, absent = device), `flutter.app_lock_enabled` (Bool), `flutter.auto_lock_timeout_seconds` (Int), `flutter.hide_balances` (Bool) | read as fallback, dual-written like Dart, never removed |
| D9 | Real preferences | `flutter.themeMode` (String `light`/`dark`/`system`), `flutter.onboarding_completed` (Bool) | read/write same keys |
| D10 | Legacy starting balances | `flutter.starting_assets`, `flutter.starting_liabilities` (Double) | read-only, never removed (Dart behaviour, section 8.4) |
| D11 | Insight prefs | `flutter.local_insights_dismissed_v1` (StringList), `flutter.local_insights_snoozed_v1` (String JSON) | read and written by the Insights section on Flow, exactly as Flutter (PARITY_GAPS) |
| D12 | Widget data | App Group suite: `cashFlow` (Double), `cashFlowMonth` (String `yyyy-MM`), no prefix; Swift also writes `budgieHideBalances` (Bool, Flutter never reads it) | written after every verified transactions save and after load; the hide flag also on every Hide balances change |
| D13 | Permissions | Face ID consent, notification state (none requested) | carried by iOS; `NSFaceIDUsageDescription` kept verbatim |
| D14 | Placed widgets, quick actions | SpringBoard | preserved by keeping kinds and types (section 11) |

Not present (verified): Keychain items, files in `Documents/`, files in the App
Group container, local notifications, background modes.

The Flutter prefs plugin stores into `UserDefaults.standard`, reading with
`persistentDomain(forName: bundleID)`. Swift MUST read through the same
persistent domain (not `object(forKey:)`, which would also see the argument and
registration domains). Encoding (research B section 3, identical in plugin
versions 2.2.2 to 2.5.6): String -> NSString, List<String> -> NSArray of
NSString, int -> NSNumber (`q`), double -> NSNumber (`d`), bool -> CFBoolean.
MUST: Swift distinguishes Bool by `CFGetTypeID(value) == CFBooleanGetTypeID()`,
not `as? Bool` (which also matches 0/1). Swift-owned native-only keys use the
prefix `native.` so the Flutter plugin (which filters on `flutter.`) never sees
them.

---------------------------------------------------------------------------------

## 4. The v2 store file, byte level

Verified against `atomic_financial_store.dart` by me and research A.

### 4.1 Layout

```
<header JSON, UTF-8, one line> 0x0A <payload bytes>
```
No trailing newline. No BOM. The header is `jsonEncode` of, in this key order:

| Key | Type | Rule |
|---|---|---|
| `format` | string | exactly `budgie-financial-store` |
| `schemaVersion` | JSON integer | `2`. Dart rejects `> 2` and any non-int (e.g. `2.0`) |
| `revision` | JSON integer | see 4.4 |
| `payloadLength` | JSON integer | byte count of the payload |
| `payloadChecksum` | string | section 4.2 |
| `writtenAt` | string | local ISO (section 7.2). Never read by Dart |

Dart validates by: first `0x0A` must be at index > 0; header must decode as a
JSON object; the six checks above; `payload.length == payloadLength`;
checksum string equality. Extra header keys are ignored by Dart, but Swift MUST
NOT add any (keeps the format identical; see 14 Q5).

Payload = `utf8(jsonEncode(sections))`, a JSON object keyed by section name.

### 4.2 Checksum (exact)

FNV-1a 64 over the payload bytes: offset basis `0xcbf29ce484222325`, prime
`0x100000001b3`, wrapping 64-bit multiply. Formatting reproduces Dart's signed
`int.toRadixString(16).padLeft(16, '0')`:

```
let s = Int64(bitPattern: hash)
var text = s < 0 ? "-" + String(s.magnitude, radix: 16) : String(s, radix: 16)   // lowercase
if text.count < 16 { text = String(repeating: "0", count: 16 - text.count) + text }
```
Verified vectors (Dart, run this session): `""` -> `-340d631b7bdddcdb`,
`{}` -> `08f44b07b5901a25`, `a` -> `-509c23b379fe1374`,
`{"transactions":[]}` -> `72b86e4d16d871bc`; the padding puts zeros before the
sign: a hash of `-1` formats as `00000000000000-1`; `Int64.min` as
`-8000000000000000`. MUST: Swift writes this exact string and verifies by exact
string comparison (like Dart).

### 4.3 JSON encoding rules (Dart `jsonEncode`)

Dart's `jsonEncode` output is canonical and Swift MUST reproduce it for every
value it creates, and MUST reproduce input bytes for every value it did not
touch:

- No whitespace anywhere. Object keys in insertion order.
- Strings: escape `"` and `\` with a backslash; `\b \t \n \f \r` for those
  controls; other code units `< 0x20` as `\u00XX` (lowercase hex); lone UTF-16
  surrogates as `\udXXX` (lowercase). Everything else raw UTF-8, including
  `/`, U+2028, U+2029, U+007F, non-ASCII, emoji.
- Integers (Dart `int`): decimal, no exponent.
- Doubles (Dart `double.toString`): ECMAScript shortest round-trip digits, with
  exponent form when the decimal exponent is `< -6` or `>= 21`
  (`1e-7`, `1e+21`, `1.7976931348623157e+308`), plain otherwise
  (`0.000001`, `0.00001`, `123456789012345680000.0`), and `.0` appended when
  the result has no `.` and no `e` (`1.0`, `-3.0`, `100.0`). `-0.0` prints
  `-0.0`. NaN/Infinity are unencodable (Dart throws; Swift MUST refuse to
  write them, see risk R14).
- `null`, `true`, `false` as literals.

Vectors verified in Dart this session: `1.0, 100.0, 0.30000000000000004, 1e+21,
100000000000000000000.0, 123456789012345680000.0, 1e-7, 0.000001, 0.000001234,
0.00001, 123456789.12, -0.0, 5e-324, 1.7976931348623157e+308, 12.5, -3.0,
1.5e+300, 0.000025`.

Why not `JSONSerialization`/`JSONEncoder`: they reorder keys, print `1200.0` as
`1200`, use `1e-05` style exponents, escape `/`, and cannot hold lone
surrogates. Dart reads `RecurringTransaction.amount` with an implicit `double`
cast (`recurring_transaction.dart:61`), and `dayOfMonth`/`dayOfWeek` with an
implicit `int?` cast, so an int-vs-double slip makes the Flutter app throw on
load and abort startup. MUST: numbers written into a double field carry a
double lexeme, into an int field an int lexeme.

### 4.4 Revision and section merge

- `revision` is a monotonically increasing int. Every commit writes
  `current.revision + 1` (both `updateSections` and `replace`).
- Section merge on commit = Dart `Map.from(sections)..addAll(updates)`:
  existing keys keep their position, new keys append, unknown sections pass
  through untouched.
- MUST: Swift never reorders, drops, or re-types a section it did not change.

### 4.5 Load algorithm (mirror of Dart `_load`, exact precedence)

1. Wait for the protected-data gate (section 6).
2. `readIfPresent(primary)`, `readIfPresent(backup)`. "Not present" only when
   the file does not exist. Any other failure throws; a read error is never
   an empty store.
3. Decode each (header check + checksum + UTF-8 decode + payload is a JSON
   object). A file that passes the checksum but fails UTF-8/JSON decode is
   "unreadable" for load purposes (Dart `_decodeBytes`), but still counts as
   "intact" for the backup copy in 4.6 step 2 (Dart `_verifyBytes`).
4. If either decoded: if primary decoded and (no backup or
   `primary.revision >= backup.revision`) return primary. Otherwise restore:
   write the backup's snapshot (same revision, fresh header) to the primary
   atomically, verify on disk, return it. The backup file itself is not
   touched.
5. If neither decoded but at least one file exists: rename each existing file
   to `<name>.corrupt-<epochMs>` (same stamp for both), then continue.
   **Divergence proposal, see 14 Q3.**
6. Legacy migration (section 8). If it yields nothing, return the empty
   snapshot (revision 0, no sections) and write nothing.
7. Otherwise commit the migrated snapshot (4.6) and, only after that commit is
   verified, remove the 11 migrated legacy keys.

`.tmp` files are never read. A load never writes except in steps 4 (restore),
5 (rename aside) and 7 (migration).

### 4.6 Commit protocol (mirror of Dart `_commit`)

Serialized: one commit at a time, in call order (Dart `_writeQueue`; Swift: an
actor). For `next`:

1. Encode `next` fully in memory.
2. Read the current primary bytes. If present and intact (header + checksum
   valid), write those exact bytes to the backup via `writeAtomically`.
3. `writeAtomically(primary, encoded)`.
4. Read the primary back from disk; header + checksum must verify and
   `revision == next.revision`, else throw. Only now is the commit successful
   and the in-memory snapshot replaced.

`writeAtomically(name, bytes)`: create `financial_store/` if needed, write
`<name>.tmp` (truncate), flush to stable storage, `rename(2)` over `<name>`.
Swift uses `fcntl(F_FULLFSYNC)` (stronger than Dart's `fsync`) and also
fsyncs the directory after rename; both are invisible to Dart. File
protection: `NSFileProtectionCompleteUntilFirstUserAuthentication`, which is
what Dart's files get by default (no explicit attribute in Dart).

A failure at any step throws; the caller keeps the change in memory, flags it
unsaved, and retries later (section 9).

### 4.7 Crash-point analysis (what a reader sees)

| Crash after | Primary | Backup | Load result |
|---|---|---|---|
| step 1 | rev N | rev N-1 | N (no change lost that was ever reported saved) |
| partial backup `.tmp` write | rev N | rev N-1 (+ partial `.tmp`) | N |
| backup rename | rev N | rev N | N |
| partial primary `.tmp` write | rev N | rev N | N |
| primary rename | rev N+1 | rev N | N+1 (not yet verified, but valid) |
| torn primary (should not happen with rename) | corrupt | rev N | restore N from backup |

---------------------------------------------------------------------------------

## 5. Lossless in-memory model (rule 3)

- `JSONValue` (Swift enum) produced by a hand-written parser that keeps:
  object key order (array of pairs), **number lexemes verbatim**, and
  **string lexemes verbatim** (the escaped source text between the quotes) with
  a lazily decoded value. Duplicate keys: last one wins on read (Dart
  `jsonDecode` behaviour) but encoding emits what Dart would emit, i.e. the key
  once at its first position with the last value (INFERRED Dart
  `LinkedHashMap` semantics; pinned by a test against Dart output).
- The encoder emits untouched nodes from their lexemes and new/changed nodes
  with the Dart rules in 4.3. Consequence: load -> save of a Dart-written file
  reproduces the payload byte-for-byte.
- Every section is held as a `JSONValue`. Typed views (`TransactionView`,
  `RecurringTemplateView`, ...) are read-only projections over the raw array.
  An edit patches only the keys it changes inside the existing raw object
  (keeping unknown keys and their order). A new record is built in the exact
  Dart `toJson` key order (research C section 2) with every key Dart writes
  (including `null`s it always writes, e.g. `recurringTemplateId`,
  `dayOfMonth`, `completedAt`).
- Rows a typed view cannot parse are kept in the raw array, hidden from the UI,
  and written back unchanged. (Dart drops them on its next save; keeping them
  is strictly safer and still compatible.)

v1 envelope verification (section 8.2) is the one place where Swift must
re-encode parsed JSON the way Dart would after a decode/encode round trip. For
that path the encoder canonicalizes numbers (parse the lexeme as Dart would:
integer lexeme -> Dart int text; any lexeme with `.`/`e` -> Dart double text)
and re-escapes strings from their decoded values.

---------------------------------------------------------------------------------

## 6. Protected data / prewarm gate (rule 6)

Dart: `ProtectedDataGate.waitUntilAvailable()` before any storage access,
driven by `UIApplication.shared.isProtectedDataAvailable` and
`protectedDataDidBecomeAvailableNotification`; no timeout (research F 3).

Swift MUST:

1. Not touch D1-D12 until `isProtectedDataAvailable == true`. The app shows a
   neutral "Unlock your iPhone to continue" state and waits for the
   notification. No timeout (a timeout that proceeds would be the exact hazard).
2. Re-check availability immediately before load and before every commit; if
   unavailable, the operation throws (becomes an unsaved change), it never
   proceeds.
3. Treat `UserDefaults` as untrustworthy until the gate opens (it reads back
   empty during prewarm without error, research I). The legacy migrator and the
   preference reader run only after the gate.
4. `BudgieCore` takes the gate as an injected protocol
   (`ProtectedDataAvailability`) so tests can simulate locked -> unlocked, and
   locked forever. The simulator cannot reproduce prewarm (research I 4);
   a real-device check is on the pre-ship list (section 16).

---------------------------------------------------------------------------------

## 7. Dates and times

### 7.1 Representation

Dart stores every date as an offset-less local wall-clock ISO string and holds
it as a local `DateTime` (instant + local zone, microsecond precision). Swift
holds dates as `DartDateTime { microsecondsSinceEpoch: Int64, isUtc: Bool }`
(not `Date`, whose `Double` loses microseconds at current epochs) and converts
through `TimeZone.current` exactly where Dart does.

Untouched date strings are never re-formatted (lossless model). Only dates
Swift creates or changes are formatted.

Consequence in a DST gap (pinned by `BackupParityTests`, `shiftingGapDates`):
a stored string such as `2026-09-06T00:00:00.000`, which does not exist in
America/Santiago, stays byte-identical in a Swift-written store. Dart
re-encodes every row whenever it rewrites the section (restore, most
mutations), so the same row comes out as `T01:00:00.000`. Both parse to the
same instant, so no value differs and either app reads the other's file.
Only the section bytes differ.

### 7.2 Format and parse (Dart `toIso8601String` / `DateTime.parse`)

- Format local: `yyyy-MM-ddTHH:mm:ss.mmm` when microsecond-of-second is 0,
  `.mmmuuu` (6 digits) otherwise. UTC adds `Z`. Years outside 0..9999 use
  Dart's `-yyyyyy`/`+yyyyyy` form (not reachable from the UI; pinned by test).
- Parse: date-only, `T` or space separator, optional fraction (truncated to 6
  digits), optional `Z`/`+hh:mm` (-> UTC), hour 24 accepted. No offset ->
  local. Nonexistent local time (DST gap) resolves like Dart (shift forward by
  the gap: NY `02:30` on 2026-03-08 -> `03:30`); ambiguous time resolves to the
  first (earlier-offset) instant. Out-of-range fields normalise
  (`2026-02-30` -> 2026-03-02). MUST match Dart on the vector table in
  research D section 6, run under several `TZ` values.

### 7.3 Calendar helpers (exact Dart semantics)

- `DateTime(y, m, d, ...)` lenient normalisation (month 13, day 0, day 31 of a
  short month) implemented explicitly, not via `Calendar.date(from:)`.
- `netWorthMonthKey` `yyyy-MM`, `netWorthDayKey` `yyyy-MM-dd` with ASCII
  digits (Dart `DateFormat` runs as en_US; the app never sets a locale).
- `endOfNetWorthMonth(m)` = `DateTime(m.year, m.month + 1)` minus 1 ms elapsed.
- `Duration(days: n)` arithmetic = `n * 86_400_000_000` microseconds elapsed
  (not calendar days). `difference().inDays` = elapsed microseconds / 86.4e9
  truncated toward zero.
- Weekday: Dart Monday=1..Sunday=7 in JSON (`dayOfWeek`).

### 7.4 Recurring generator (Dart `TransactionGenerator`, research D 3)

Pinned exactly, including its quirks, unless 14 Q1 says otherwise:

- Due: `isActive && (nextOccurrence < now || sameLocalDay(nextOccurrence, now))`.
- `maxLookback = now - 90 * 24h` (elapsed). Loop while `current < now ||
  sameDay(current, now)`; generate when `current > maxLookback ||
  sameDay(current, maxLookback)`; always advance.
- Advance: weekly `+7*24h`, biweekly `+14*24h` elapsed (DST drift reproduced);
  monthly: next calendar month, day = `min(template.dayOfMonth, daysInMonth)`,
  time 00:00:00.000 local. First occurrence is `startDate` verbatim.
- Generated transaction: new UUID v4 (lowercase), `date = current`,
  `createdAt = updatedAt = now`, `recurringTemplateId = template.id`,
  `tagIds = []`, description/amount/category/type copied.
- Improvement that is invisible to Dart (proposed, 14 Q2): Swift commits the
  generated rows and the advanced cursor in **one** atomic write, so a crash
  cannot duplicate rows.
- Clock injected for tests.

---------------------------------------------------------------------------------

## 8. Legacy migration (rule 4)

### 8.1 When

Only on load step 6, i.e. when neither v2 file decodes. If a v2 file decodes,
legacy keys are ignored and left in place (Dart behaviour; research B 2.3).

### 8.2 Precedence (mirror of Dart `_migrateFromPreferences`)

1. Decode D5 and D6 as v1 envelopes: JSON object with a string `checksum`;
   remove `checksum`; the remaining object (key order preserved) is
   re-encoded Dart-canonically (section 5) and FNV-checksummed (4.2 format);
   must equal. Then `schemaVersion` int `<= 1`, `revision` int, `sections`
   object. Anything else -> treated as absent.
2. Bare keys D7 via `getString` + JSON decode; empty or malformed -> absent;
   `net_worth_selected_month` is taken as the raw string.
   `appSettings` is synthesised from D8 only if at least one D8 key exists,
   with defaults `USD`, `null`, `false`, `60`, `false`.
3. If no envelope decodes and no bare value exists -> nothing to migrate.
4. Chosen envelope = primary if it decoded and (no backup or
   `primary.revision >= backup.revision`), else backup (may be none).
5. Sections = copy of chosen envelope sections. If the primary envelope was
   not chosen and bare `transactions` decoded to a list (even `[]`), it
   replaces `sections.transactions`.
6. Every other bare section fills only keys absent from `sections`.
7. Migrated snapshot: schema 2, revision = chosen revision or 0.
8. Commit (4.6). Only after a verified commit, remove the 11 keys
   `flutter.financial_store_v1`, `flutter.financial_store_v1_backup` and the 9
   D7 keys. D8, D9, D10, D11 are never removed.

The pre-native backup (section 10) runs before any of this, so the removed
keys are preserved in `pre-native-migration/`.

### 8.3 Model-level legacy handling (Dart models, reproduced)

- `NetWorthSnapshot` without `recordedAt`: legacy `monthKey` (`yyyy-MM`) +
  optional `updatedAt` ladder (research C 2.4). Legacy keys are never written.
- Transactions with blank or duplicate `id`: regenerate ids (second and later
  duplicates), and non-string `createdAt`/`updatedAt` fallbacks; re-save only
  when zero rows were unreadable (Dart `needsIdentityMigration`).

### 8.4 Starting balances (D10)

When the `netWorthEntries` section is missing or an empty list and
`starting_assets > 0` or `starting_liabilities > 0`, Dart creates "Starting
Assets"/"Starting Liabilities" entries (single snapshot at now) and saves.
Swift reproduces this exactly (including that it re-fires if the user later
deletes every entry; that is the Flutter behaviour and a PARITY_GAPS item).

---------------------------------------------------------------------------------

## 9. Save semantics and the unsaved-changes banner

Mirror of Dart `PersistenceStatus`:

- A mutation updates memory first, then awaits a commit that includes the
  changed sections **plus every section still flagged unsaved**.
- Success only after 4.6 step 4. Failure flags the sections, records the
  error, shows the retry banner above the tabs.
- Retry: banner button, and automatically when the app moves to background.
- A success clears only the sections it carried.
- A change that spans sections is one commit: a category edit writes the
  definition and its rename cascade (`categories`, `transactions`,
  `categoryBudgetLimits`, `recurringTransactions`, `categorizationRules`,
  only those that changed) together; on failure all of them are flagged.
- The widget's `cashFlow` is updated only after a verified transactions save.

---------------------------------------------------------------------------------

## 10. Pre-native-migration backup (rule 1)

Before the first load in a Swift install (after the gate, before anything else
reads or writes D1-D12):

1. Create `Library/Application Support/pre-native-migration/<yyyyMMdd-HHmmss>-<rand>/`.
2. Copy (byte-for-byte, `copyItem`) every file in `financial_store/` (primary,
   backup, `.tmp`, `.corrupt-*`).
3. Write `preferences.plist`: the complete `persistentDomain(forName: bundleID)`
   dictionary (every key, not only `flutter.*`), binary plist.
4. Write `app-group.plist`: the App Group suite's persistent domain.
5. Write `manifest.json`: file names, sizes, SHA-256, app version, OS version,
   timestamp.
6. fsync, then write `COMPLETE` last. A snapshot without `COMPLETE` is ignored
   and a new one is taken.

A new snapshot is also taken whenever the store on disk was written by
someone other than this Swift install since its last commit (primary checksum
differs from `native.lastCommittedChecksum`), which covers a round trip to the
Flutter build. The folder is never deleted automatically. The backup failing
(for example disk full) blocks the Swift app from writing, with a visible
error; it never proceeds without the copy.

---------------------------------------------------------------------------------

## 11. Surfaces

### 11.1 Widget

The existing `BudgetWidgets.swift` is reused verbatim where possible (same
kinds, families, display names, `Link`/`widgetURL`s, USD formatting). Contract:
App Group keys `cashFlow` (Double) and `cashFlowMonth` (`%04d-%02d`), written
by the app as the current calendar month's income minus expenses (Dart
`_syncWidgetCashFlow`, `transaction_model.dart:311-337`), followed by
`WidgetCenter.shared.reloadAllTimelines()`.

`BudgetVoiceAdd` stays registered (removing it would blank placed widgets);
its `budgetapp://voice-add` opens the voice recording sheet (Phase 4), so the
gallery text "Speak a transaction and review it before saving." is true
again.

### 11.2 Quick actions and deep links

Types `action_add_expense`, `action_add_income`, `action_voice_add` registered
in Flutter's order ("Add Expense" `minus.circle.fill`, "Add Income"
`plus.circle.fill`, "Add by Voice" `mic.circle.fill`). `action_voice_add`,
`voice-add` and `voice_add` open the voice flow (`AddRoute.voice`); deep
links `add-income`, `add-expense` (+ `add_income`, `add_expense`) open the
add form; all others ignored. Actions arriving before the gate opens are
queued. Once it is open the route opens on top of whatever is presented, as
Flutter's `showTransactionForm` / `startVoiceExpenseFlow` on the root
navigator do (UI_SPEC "Shell", `AddFormPresenter`). A voice route arriving
while a voice flow is up is dropped (Flutter's `_voiceFlowActive`). The Home
mic button sets the same route.

### 11.3 Face ID lock

`appSettings.appLockEnabled`, `autoLockTimeoutSeconds` (0/30/60/300/900),
privacy cover on backgrounding when enabled. `NSFaceIDUsageDescription` text
kept verbatim.

### 11.4 Info.plist / privacy

Keep: display name, URL type, Face ID string, category, portrait/iPhone.
Drop: `UIMainStoryboardFile`. `NSMicrophoneUsageDescription` is back for
voice entry (Phase 4, reversing the earlier "voice out of scope" drop): the
Flutter string, "Budgie uses the microphone so you can add transactions by
speaking." No speech-recognition string (transcription is server-side).
Add `PrivacyInfo.xcprivacy` (UserDefaults reason `CA92.1`; file timestamp
reason if needed). No `.env`, no API keys in the repo; see "Voice (OpenAI) key".

#### Voice (OpenAI) key

Info.plist carries `OPENAI_API_KEY = $(OPENAI_API_KEY)`. The build setting
comes from the committed `native/Config/Budgie.xcconfig` (target
configuration file for Debug and Release), which declares an empty default and
then `#include?`s the gitignored `native/Config/Secrets.xcconfig`; the include
comes last because later assignments win. Copy `Secrets.example.xcconfig` to
`Secrets.xcconfig` and set a restricted, budget-capped key from a dedicated
OpenAI project (FULL_APP_PLAN section 6). Debug builds work without a key
(voice reports "not configured"). The "Check OpenAI key" build phase fails
Release builds when the value is empty or the placeholder; it reads only the
build-setting environment variable, so it works with user-script sandboxing,
and it never prints the key (`showEnvVars: false` keeps Xcode from echoing the
exported settings, key included, into that phase's log). The key still ends up
in the built Info.plist, so treat archives and IPAs as containing it.

App Store privacy label and `PrivacyInfo.xcprivacy`: the recording (Audio
Data) and its transcript (Other User Content) are sent to OpenAI for
transcription and parsing. Both are declared collected for App Functionality,
not linked to the user, not used for tracking. No other data types change.

### 11.5 Scene sessions (found in the Phase 3 rehearsal)

iOS persists every scene session with its configuration, including the
delegate class name, in `Library/Saved Application State/<bundle>.savedState/
KnownSceneSessions`, and restores it at the next launch without consulting
the app. The Flutter app stores `Runner.SceneDelegate` under
`Default Configuration`. MUST: the Swift app uses the UIKit lifecycle with
module name `Runner`, a `SceneDelegate` class and the same configuration
name and Info.plist scene manifest, so either binary can restore a session
the other saved. (With the SwiftUI `App` lifecycle the stored class is
`SwiftUI.AppSceneDelegate`, and a Flutter build installed afterwards shows a
black screen.) The rehearsal records the persisted class after every step.

---------------------------------------------------------------------------------

## 12. Business logic parity (MVP subset)

| Feature | Rule | Oracle |
|---|---|---|
| Monthly totals | bucket by local year*12+month of `date`; sum in list order | Dart fixtures |
| Ordering | `compareNewestFirst`: local calendar day desc, `createdAt` desc, `id` desc | `transaction_ordering_test` |
| Net worth | carry-forward `amountAt(endOfNetWorthMonth)`; snapshot identity by exact `recordedAt`; `withSnapshot` replace-equal + sort asc; default snapshot date = now (current month) else end-of-month; history compression | `transaction_model_net_worth_test` + fixtures |
| Safe-to-spend | research E 1.2 formula verbatim, including the same-day and DST quirks unless 14 Q1 says otherwise | `safe_to_spend_test` values + fixtures |
| CSV export | header `Date,Type,Category,Description,Amount`; CRLF between rows, no trailing newline, no BOM; quote iff field contains `,` `"` CR LF, `"` doubled; date `yyyy-MM-dd`; `Income`/`Expense`; amount = Dart `toStringAsFixed(2)` (exact binary value, ties away from zero; NOT `%.2f`); rows sorted by full `date` ascending; file `transactions_yyyyMMdd_HHmmss.csv` | Dart-generated CSV fixtures |
| Money display | intl algorithm (research E 6.4): floor, `(frac*10^d)` rounded half away from zero on the double product, carry; symbol table by currency; pattern by locale; "Match device" = en_US; `-0.0` rules | Dart-generated vectors |
| Template edit | see 14 Q2 | |
| Category management | `CategoryProvider` add/update/setArchived/move and the Categories page's rename cascade (`Domain/CategoryEditing.swift`): Flutter's validation order and copy, `_uniqueId` slugs, sortOrder renumbering, exact UTF-16 renames with `updatedAt` = now, budget key moved to the end (`putIfAbsent`); rules restricted by type (D6) | Fixtures/categories (real providers and page, byte-compared) |

---------------------------------------------------------------------------------

## 13. Risk register

| ID | Risk | Mitigation | Proving test |
|---|---|---|---|
| R1 | Swift writes a file Dart rejects (checksum format, int header fields) | 4.1/4.2 implementation; exact Dart vectors | `ChecksumTests` (vectors), Dart harness `verify_swift_output` loads every Swift-written fixture through the real `AtomicFinancialStore` + models |
| R2 | Int/double lexeme drift crashes Dart on load (`RecurringTransaction.amount`, `dayOfMonth`) | Dart number encoder; typed writers emit field-typed lexemes | `NumberFormatTests` (vectors), Dart harness loads Swift-edited recurring fixtures |
| R3 | Unknown sections/fields/rows lost on Swift save | lossless `JSONValue`, patch-in-place | `RoundTripTests`: every fixture load -> save byte-identical payload; `UnknownDataTests` edits a typed field and diffs everything else |
| R4 | Empty read while locked written back as "no data" | gate before any I/O; re-check before commit; read errors throw | `ProtectedDataGateTests` (locked -> no reads/writes; locked forever -> nothing written; unlock -> normal load) |
| R5 | Corrupt primary + good backup, good primary + corrupt backup, both corrupt, truncated, `.tmp` leftovers | 4.5 precedence | `LoadPrecedenceTests` over Dart-produced corrupt fixtures, same expected revision as Dart |
| R6 | Crash mid-commit loses a saved change | 4.6 protocol; newest valid revision wins | `FaultInjectionTests`: backend fails/crashes after each step, reload picks newest valid revision; disk-full on each write |
| R7 | Legacy-only users lose data | 8.2 precedence ported exactly | `LegacyMigrationTests` over Dart-produced prefs fixtures (v1, v1 backup, bare, mixed, corrupt envelope + bare transactions override) + simulator rehearsal with injected plist |
| R8 | v1 envelope checksum needs Dart re-encoding | canonical re-encode path | v1 fixtures produced by the pre-c05f9eb encoder; Swift accepts valid ones, rejects tampered ones |
| R9 | Date round trip loses microseconds or shifts zone | `DartDateTime`, lossless strings | `DartDateTimeTests` vectors under several `TZ` (incl. DST gap/overlap), snapshot delete by exact `recordedAt` |
| R10 | Generator output differs (DST, day 31, 90-day cap) | 7.4 port | `GeneratorTests` against Dart expected outputs for fixed `now` values and zones |
| R11 | Legacy removal destroys the only copy | pre-native backup first; remove only after verified commit | `PreMigrationBackupTests`; rehearsal checks folder contents vs originals by SHA-256 |
| R12 | Placed widgets or quick actions break | identical kinds/IDs/types; voice routes to the voice flow (`.voice`); the quick-action list matches Flutter's three | rehearsal step (widget shows the right value after upgrade) |
| R13 | Preferences mis-typed (bool vs int) or lost | typed CFBoolean check; same `flutter.` keys and types | `PreferencesTests` read plists produced by the Flutter plugin on the simulator |
| R14 | NaN/Infinity reaches the encoder | validation on every numeric input; encoder throws | `EncoderTests`; UI input tests |
| R15 | Concurrent writes interleave | single actor queue | `ConcurrencyTests` (many concurrent edits -> sequential revisions, all present) |
| R16 | Swift and Flutter disagree on totals | shared fixtures + Dart expected outputs | `ParityTests` (totals, safe-to-spend, net worth, CSV bytes) |
| R17 | Random edit sequences corrupt data | property tests | `PropertyTests`: random edits -> save -> load equal; Dart harness loads a sample |
| R18 | Pre-native backup fails silently | blocks writes on failure | test with an unwritable directory |
| R19 | Raising deployment target strands iOS 15/16 users | see 14 Q4 | n/a (decision) |
| R20 | Prewarm cannot be rehearsed on the simulator | injected gate tests + real-device check before ship | section 16 |
| R21 | Duplicate transactions after template edit (existing Flutter bug) | 14 Q2 | `TemplateEditTests` |
| R22 | CFBundleVersion not greater than uploaded build | 14 Q6 | release checklist |
| R23 | Persisted scene session names a delegate class the other binary lacks (black screen after switching apps) | UIKit lifecycle, `Runner.SceneDelegate`, same configuration (11.5) | rehearsal S1 downgrade screenshot + `sceneDelegateClasses` in report.json |

---------------------------------------------------------------------------------

## 14. Decisions

### 14.0 Resolutions (approved 2026-09-28)

| Q | Decision |
|---|---|
| Q1 | Replicate Dart date math exactly (DST drift, same-day safe-to-spend exclusion, `inDays` truncation). Fix later in both apps; tracked in PARITY_GAPS. |
| Q2 | Swift preserves `nextOccurrence`/`isActive` on edit (cursor recomputed only when schedule fields change, never backwards); pause = `isActive=false`; generated rows + cursor in one commit. |
| Q3 | Both files unreadable: set aside like Dart, then a blocking "data could not be read" screen; no write until the user chooses "Start fresh". |
| Q4 | Deployment target iOS 17.0. |
| Q5 | No extra header keys; use `native.lastCommittedChecksum`. |
| Q6 | Marketing version 4.0.0 (full rewrite), build 1 (resolved 2026-09-30). The last upload is 3.4.0 (1): every local Flutter archive of this bundle ID uses build 1, and build numbers only have to increase within a version. Raise the build for each re-upload of 4.0.0. |
| Q7 | Option (a): `native/ParityHarness/` against a `git archive` copy of `budget_app` in scratch. Nothing in `budget_app/` changes. |
| Q8 | Beads set up (prefix `budgie`, local-only, no remotes). |
| Q9 | XcodeGen; commit `project.yml` and the generated `Budgie.xcodeproj`. |

### 14.1 Questions as asked

**Q1. Bug-compatible or fixed date math?** Dart advances weekly/biweekly
templates by 168/336 elapsed hours, so after a DST change they drift an hour
(and a midnight template moves to 23:00 the previous day). Safe-to-spend drops
expenses dated today (compares a timestamp against midnight) and counts
`daysRemaining` one short in spring-forward months.
*Recommendation:* replicate exactly in the MVP. Both apps generate from the
same cursor, parity tests can assert against Dart output, and the user sees
the same numbers after the upgrade. Fix later in both apps together (tracked
in PARITY_GAPS).

**Q2. Template edits.** Dart's edit form resets `nextOccurrence` to
`startDate` and `isActive` to true, so the next launch re-generates up to 90
days of duplicates (confirmed in code; a fix task chip is open for the Flutter
app). Dart also has no pause UI; you asked for pause in the MVP.
*Recommendation:* Swift preserves `nextOccurrence` and `isActive` on edit
(recomputing the cursor only if the schedule fields change, never backwards
past the last generated occurrence), implements pause as `isActive = false`
(Dart already honours it), and commits generated rows + cursor in one write.
All invisible to the Dart reader.

**Q3. Both store files unreadable.** Dart sets them aside and, with no legacy
data, opens an empty ledger; the next save starts over at revision 1.
*Recommendation:* same set-aside, but Swift shows a blocking "Your data could
not be read" screen (with the `pre-native-migration` and `.corrupt` files
intact) instead of an empty ledger, and does not write until the user chooses
"Start fresh". Divergence from Dart, safer.

**Q4. Deployment target.** Flutter ships at iOS 15.0. `@Observable` needs
iOS 17 (Swift Charts needs 16). Users on iOS 15/16 would stay on the last
Flutter version. *Recommendation:* iOS 17.0 as you specified; confirm.

**Q5. Header extras.** Adding a `writer` header key would make "last written
by Flutter" detection trivial, and Dart ignores it. *Recommendation:* no;
use the native-only `native.lastCommittedChecksum` instead, keeping the file
identical.

**Q6. Build numbers.** What is the highest `CFBundleVersion` uploaded for
3.4.0, and should the Swift MVP ship as 3.5.0 or 4.0.0? (Only matters at
submission time; no upload will happen without asking.)

**Q7. Fixture harness (rule 8).** *Resolved: option (a); see 14.0.* I need Dart to produce the fixture corpus
and to verify Swift-written files. Proposal, least invasive first:
(a) a Flutter test package `native/ParityHarness/` that drives the real
models, `AtomicFinancialStore` (via `resetForTesting(directory:)`) and
`SharedPreferences.setMockInitialValues`, emits fixtures + expected outputs,
and has a second test that loads Swift-written files through the same code.
A script (`native/ParityHarness/run.sh`) exports `budget_app/` at the current
commit (`git archive`) into the scratch directory, adds a stub `.env` there
(dummy key; `budget_app` bundles `.env` as an asset, so its tests cannot build
without one), and points the harness's `path:` dependency at that copy.
**Nothing inside `budget_app/` is created or changed, tracked or untracked.**
(Research G already had a stub `.env` inside `budget_app/` blocked, and built
from a scratch copy the same way.)
(b) Fallback if (a) hits a tooling wall: the same tests under
`budget_app/test/parity/`, skipped unless a `--dart-define` is set, plus a
gitignored stub `budget_app/.env`. Approve (a), (b), or neither?

**Q8. Issue tracking.** The repo has no `.beads/`. This is multi-session work
with real dependencies; want me to set it up with your usual config?

**Q9. Project format.** XcodeGen (`project.yml`, installed at
`/opt/homebrew/bin/xcodegen`, Tuist is not installed). Reason: the project is
a reviewable text file, no `pbxproj` merge noise, deterministic regeneration.
I'd commit `project.yml` and the generated `Budgie.xcodeproj` so the app
builds without XcodeGen. Confirm.

---------------------------------------------------------------------------------

## 15. Corrections to the research notes

- Research I 7 says integer-valued doubles are fine because Dart reads via
  `as num`. Wrong: `RecurringTransaction.fromJson` assigns `json['amount']`
  directly to a `double` field (`recurring_transaction.dart:61`).
- Research C H9 says Swift need not reproduce Dart key order/spacing. True for
  the checksum; irrelevant in practice because Swift reproduces bytes anyway
  (section 5), and required for the v1 envelope path.
- Research B marks short-magnitude checksum padding as inferred; verified here
  (`-1` -> `00000000000000-1`).
- Research E's safe-to-spend same-day finding is agent-reproduced in Dart and
  independently visible in research G's simulator screenshot (sheet shows
  "$0 recorded" next to a non-zero month); my own read of
  `safe_to_spend.dart` was blocked by the permission classifier.
- AGENTS.md describes five tabs; research G found six dock destinations
  (Home, Spend, Flow, Worth, Goals, Settings) and two coexisting visual
  generations. The MVP UI scope is mapped to these in Phase 4.
- Research G: recurring templates can only be created from "Make this
  recurring" in the transaction form (no add button on the Recurring page).
  The MVP adds one (you asked for add/edit/pause); it writes the same JSON.
- The `AtomicFinancialStore` class doc comment lists the backup copy after the
  `.tmp` write; the code writes the backup first. The spec follows the code.

---------------------------------------------------------------------------------

## 16. Before shipping to real users (not part of the MVP build)

Migration safety audit, 2026-09-30: see `MIGRATION_SAFETY_AUDIT.md`.
Safety takes precedence over reproducing Flutter's destructive corruption
fallback. Unacknowledged corrupt files always block, even with settings or
stale legacy keys. Unrecoverable legacy sections and envelopes also block
before a migration commit or preference removal. A valid v1 backup may still
recover a damaged primary envelope. Safety-copy reuse verifies all manifest
hashes and, for externally written/legacy-only data, all source files and
preference domains. Commits verify the complete intended bytes in addition
to revision and checksum. The empty-budget action requires confirmation.
The additional local audit blocks missing files after a previous native
save and unsupported known-section container types before app startup
writes. Backup replacement requires a decodable primary; recovery filenames
cannot replace earlier originals when timestamps repeat. Protection is
checked again between staging and rename. See the audit for the regression
tests and the Debug, optimized-core and installed-app verification results.

1. Real-device prewarm/locked-launch test on a spare device with synthetic
   data (the simulator cannot do it).
2. Real-device upgrade rehearsal: Flutter TestFlight build -> Swift build over
   it, spare device, synthetic data.
3. Confirm App Store Connect build numbers (Q6), privacy manifest, export
   compliance answer.
4. Decide the fate of D11 (insight prefs) and the Flutter-only features in
   PARITY_GAPS.
5. Keep the Flutter build archived and installable until the Swift app has
   been in users' hands long enough to trust.
