> Archived; paths refer to the `flutter-final` tag.

# A. Storage format of AtomicFinancialStore (byte-compatibility spec for the Swift port)

Scope: `budget_app/lib/storage/atomic_financial_store.dart` (call it ASF; 728 lines), plus `persistence_status.dart`, `protected_data_gate.dart`, `storage_keys.dart`, every caller, and `test/atomic_financial_store_test.dart`.

Legend: VERIFIED = read in code, or executed. INFERRED = reasoned from platform behavior, not directly observed. All paths are relative to `budget_app/` unless stated. Line numbers are 1-based in the working tree of this worktree (HEAD b69008d).

Scratch artifacts used for verification (outside the repo): `/private/tmp/claude-501/-Users-khatruong-Documents-GitHub-flutter-budget--claude-worktrees-swiftui-mvp-migration-71aa05/6495a492-0ede-40de-b1dd-d436c2cea23d/scratchpad/chk/` (`chk.dart`, `d.dart`, `e.dart`, `c.swift`). Dart 3.12.2 was used for all runs.

---

## 0. Headline compatibility hazards (read first)

1. **The checksum string is NOT plain unsigned hex.** It is FNV-1a 64 computed in Dart's *signed* 64-bit `int`, then `toRadixString(16).padLeft(16,'0')`. When the top bit of the hash is set (about 45% of all payloads; 901 of 2000 samples), the string is `"-"` + lowercase hex of the *absolute value of the signed int*, e.g. `-263aafe76414ed84`, which is 17 chars, not 16. In the rare case the magnitude has 14 or fewer hex digits, `padLeft` pads to the LEFT of the minus sign, giving strings like `0-c4187ddd60c398`. Dart verification is exact string equality, so Swift must reproduce this quirk both when writing and when verifying (section 3).
2. **Checksum covers the raw payload bytes** (everything after the first `0x0A`), not a re-encoding. Swift can write any valid JSON payload (byte-identical Dart formatting is not needed) as long as `payloadLength` and `payloadChecksum` match the bytes actually written and there is no trailing newline.
3. **Forward-version trap:** Dart rejects any file whose header `schemaVersion` is greater than 2 (ASF:574-575) as unreadable/corrupt. If the Swift app writes `schemaVersion: 3`, a Flutter build reading it treats it as corrupt (and, if both files are like that, moves them aside as `.corrupt-<ms>` and then starts EMPTY, section 7). Keep `schemaVersion` at 2 unless rollback to Flutter is explicitly abandoned.
4. **Header integer fields must be JSON integers.** `revision`, `schemaVersion`, `payloadLength` are checked with `is int`; a value written as `1.0` or `1e0` decodes to a Dart `double` and the whole file is rejected (verified: `jsonDecode('{"revision":1.0}')['revision']` is `double`). Swift's `JSONSerialization`/`NSNumber` will happily emit `1.0` in some paths; use integer types.
5. **Numbers in sections: int vs double distinction.** Dart writes `1200.0` for a double and `100` for an int. Dart model code reads amounts as `(json['amount'] as num).toDouble()` (transaction.dart:110, net_worth_entry.dart:97) so ints are tolerated for those fields, but other fields may not be. Swift should write doubles that Dart will read back as doubles (i.e. keep `.0`) where the Flutter model does `as double`. Also Swift's `JSONSerialization` escapes `/` as `\/` (harmless; valid JSON, Dart parses it) and cannot distinguish `1` from `1.0` on read; prefer Codable with explicit types or a custom parser to preserve int-vs-double when re-writing unknown sections.
6. **NaN/Infinity anywhere in the sections makes every commit fail permanently** with `JsonUnsupportedObjectError` (not a `FinancialStoreException`), and `PersistenceStatus` retries re-throw forever (section 8). Swift must never encode non-finite doubles.
7. **Load-time destructive-looking path:** if exactly one file exists and it is corrupt (or both are), ASF moves it to `<name>.corrupt-<epochMillis>`, falls through to legacy SharedPreferences migration, and if that finds nothing returns an EMPTY snapshot (revision 0, nothing written) (ASF:279-296). The user sees an empty ledger; data survives only in the `.corrupt-*` file. The comment at ASF:280 says "Both files exist" but the condition is OR. The Swift port should decide deliberately whether to reproduce or surface an error instead.
8. **Unknown sections must be preserved.** A commit is `sections = old sections + updates` (ASF:48-54), section-granular replace. Any section key the Swift app does not know must be re-emitted unchanged.
9. **Write-order in the class doc comment does not match the code.** The comment (ASF:102-108) lists "write .tmp, backup copy, rename". The code does: encode, read current primary, write backup atomically (its own tmp+rename), write primary atomically (its own tmp+rename), read back and verify (ASF:466-497; 676-687). See section 6.

---

## 1. File names and directory

| Item | Value | Source |
|---|---|---|
| Directory name | `financial_store` | ASF:116 `directoryName` (VERIFIED) |
| Primary file | `financial_store_v2.json` | ASF:117 (VERIFIED) |
| Backup file | `financial_store_v2.backup.json` | ASF:118 (VERIFIED) |
| Staging files | `<file>.tmp`, i.e. `financial_store_v2.json.tmp` and `financial_store_v2.backup.json.tmp` | ASF:680 (VERIFIED) |
| Quarantine files | `<file>.corrupt-<DateTime.now().millisecondsSinceEpoch>` (same stamp for both files) | ASF:282-287 (VERIFIED) |

**Base directory resolution** (ASF:623-637): unless `Platform.environment['FLUTTER_TEST'] == 'true'` (test-only memory backend, ASF:631-633), it calls `getApplicationSupportDirectory()` (path_provider) and appends `/financial_store` (ASF:634-635). Directory is created lazily with `directory.create(recursive: true)` on every `writeAtomically` (ASF:679). Loads never create it.

**What that resolves to on iOS (VERIFIED from source):**
- `pubspec.yaml:46` `path_provider: ^2.1.1`; `pubspec.lock` resolves `path_provider` 2.1.5; `pubspec.yaml:67-68` `dependency_overrides: path_provider_foundation: 2.5.1`; `pubspec.lock` `path_provider_foundation` 2.5.1.
- `~/.pub-cache/hosted/pub.dev/path_provider-2.1.5/lib/path_provider.dart:77-85`: `getApplicationSupportDirectory` returns `Directory(path)` from `_platform.getApplicationSupportPath()`.
- `path_provider_foundation-2.5.1/lib/path_provider_foundation.dart:35-43`: calls native `getDirectoryPath(.applicationSupport)` then `Directory(path).create(recursive: true)`.
- `path_provider_foundation-2.5.1/darwin/.../PathProviderPlugin.swift:57-58,69-74`: `.applicationSupport` maps to `NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first`. The macOS-only bundle-id suffix (lines 27-39) is `#if os(macOS)` and does NOT apply on iOS.
- Therefore on iOS: `<app data container>/Library/Application Support/financial_store/financial_store_v2.json`. Bundle id is `com.khatruong.budgetbuddy` (ios/Runner.xcodeproj/project.pbxproj:532,724,757). A Swift app shipped under the same bundle id as an update sees the same container.
- Confirmed against a real file on disk: `~/Library/Developer/CoreSimulator/Devices/5B13D5E8-6929-4C77-A662-0958F0CEBAB2/data/Containers/Data/Application/97E239C0-.../Library/Application Support/financial_store/financial_store_v2.json` exists (only the primary file; no backup, no .tmp; revision 1; its only section was `categories`). I recomputed its checksum independently (Python) and it matched, and the length matched (VERIFIED).
- This is the app's own container, NOT the app-group container (`group.com.khatruong.budgetbuddy`, `ios/Runner/Runner.entitlements`). The widget extension never reads the store: `grep financial_store ios/` finds nothing; the widget gets a single cash-flow number over the `budget_app/widget_data` channel into app-group UserDefaults (transaction_model.dart:314-341) (VERIFIED by grep).

**Subdirectories:** only `financial_store/` itself. No other directories are created.

**File-protection attributes:** none are set explicitly. `grep -i "protect\|NSFileProtection\|DataProtection"` over `ios/` finds only the `isProtectedDataAvailable` channel (AppDelegate.swift:98-130); `Runner.entitlements` contains only the app-group entry; ASF passes no attributes to `File`. So files get the iOS default data-protection class for new files, which is Complete Until First User Authentication (INFERRED from Apple's documented default; not observed). The `ProtectedDataGate` exists precisely because files are unreadable after reboot until first unlock (section 8). The directory is not marked `isExcludedFromBackup` anywhere (VERIFIED by grep), so it is included in device/iCloud backups (INFERRED from default Application Support behavior).

**ProtectedDataGate** (`lib/storage/protected_data_gate.dart`), channel `budget_app/protected_data`:
- On non-iOS/web returns immediately (line 27). On iOS: registers a handler for the native push `protectedDataDidBecomeAvailable` (lines 32-37), invokes `isAvailable` (line 41); `MissingPluginException` and `PlatformException` are treated as available (lines 42-49); if not available, awaits the completer (line 60).
- Native side: AppDelegate.swift:106-129 answers `isAvailable` with `UIApplication.shared.isProtectedDataAvailable` and posts `protectedDataDidBecomeAvailable` from `UIApplication.protectedDataDidBecomeAvailableNotification`.
- Called at the top of `_initializeApp` (main.dart:261), before the first `AtomicFinancialStore.instance.read()` (main.dart:264). Swift equivalent: do not touch the store until `UIApplication.shared.isProtectedDataAvailable` is true or the notification fires.

---

## 2. On-disk layout

A file is: **one header JSON line, `0x0A`, then the payload JSON. No trailing newline.** (ASF:540-542, 544-559). VERIFIED by code and by inspecting a real file (payload does not end in `\n`).

Building code (ASF:544-559):
```dart
Uint8List _encode(FinancialSnapshot snapshot) {
  final payload = utf8.encode(jsonEncode(snapshot.sections));
  final header = jsonEncode(<String, dynamic>{
    'format': _formatTag,
    'schemaVersion': snapshot.schemaVersion,
    'revision': snapshot.revision,
    'payloadLength': payload.length,
    'payloadChecksum': _checksumBytes(payload),
    'writtenAt': DateTime.now().toIso8601String(),
  });
  final builder = BytesBuilder(copy: false)
    ..add(utf8.encode(header))
    ..addByte(0x0A)
    ..add(payload);
  return builder.takeBytes();
}
```

Header fields, in emission order (Dart map insertion order):

| Key | Type | Value / meaning | Validated on read? |
|---|---|---|---|
| `format` | string | constant `"budgie-financial-store"` (ASF:120) | Yes, must equal exactly (ASF:573) |
| `schemaVersion` | int | `2` (ASF:115); must be `int` and `<= 2` (ASF:574-575) | Yes |
| `revision` | int | monotonically increasing commit counter (section 5) | Yes, must be `int` (ASF:576) |
| `payloadLength` | int | byte length of the payload (UTF-8 bytes, not chars) | Yes, must equal `bytes.length - newline - 1` (ASF:582) |
| `payloadChecksum` | string | see section 3 | Yes, exact string equality (ASF:583) |
| `writtenAt` | string | `DateTime.now().toIso8601String()`: LOCAL time, no offset/`Z`, 6 fractional digits on iOS/macOS, e.g. `2026-09-28T16:59:00.679897` | No; never read anywhere (`grep writtenAt` finds only ASF:552) |

Extra header keys are ignored (VERIFIED: `_verifyBytes` reads only the five keys above). The header is parsed with `jsonDecode(utf8.decode(bytes.sublist(0, newline)))` (ASF:566): it must be a JSON object; malformed UTF-8 throws, caught, file rejected. `newline <= 0` (no LF, or LF at index 0) rejects (ASF:564). The FIRST `0x0A` splits header from payload (`bytes.indexOf(0x0A)`); JSON encoding never emits a raw LF inside strings (escaped as `\n`), so this is unambiguous for Dart-written data.

Payload = `jsonEncode(snapshot.sections)`: a JSON object mapping section name to that section's value. It is NOT nested under a `sections` key in the v2 file (contrast with the legacy v1 envelope, section 4). Top level must decode to `Map<String, dynamic>` (ASF:599).

Real header from a device file (VERIFIED):
```
{"format":"budgie-financial-store","schemaVersion":2,"revision":1,"payloadLength":2692,"payloadChecksum":"3ded82e3a65af323","writtenAt":"2026-09-23T23:15:05.822075"}
```

Section names (ASF:14-27, `FinancialSections`) and what stores them:

| Section key | Value shape written | Writer |
|---|---|---|
| `transactions` | list of `Transaction.toJson()` | TransactionModel (transaction_model.dart:249, 302-304) |
| `netWorthEntries` | list of `NetWorthEntry.toJson()` | TransactionModel:250 |
| `selectedNetWorthMonth` | string, `DateTime.toIso8601String()` of month start (local, no offset) | TransactionModel:252 |
| `categoryBudgetLimits` | object category name -> double | TransactionModel:254 (read back with `(value as num).toDouble()`, dropping `<= 0`, transaction_model.dart:413-420) |
| `savingsGoals` | list of `SavingsGoal.toJson()` | TransactionModel:256 |
| `recurringTransactions` | list of `RecurringTransaction.toJson()` | RecurringTransactionModel:69-77 |
| `categories` | list of `BudgetCategory.toJson()` | CategoryProvider (category_provider.dart:264-268) |
| `transactionTags` | list | CategorizationProvider (categorization_provider.dart:169-174) |
| `categorizationRules` | list | CategorizationProvider:176-181 |
| `appSettings` | object `{baseCurrencyCode:String, localeOverride:String?, appLockEnabled:bool, autoLockTimeoutSeconds:int, hideBalances:bool}` | AppSettingsProvider (app_settings_provider.dart:158-169) |

(Model-level field layouts are out of scope for this file; other research tasks cover them.) Absent sections are simply absent keys (a fresh store has no keys at all; ASF:42-46 `empty`). Keys like `localeOverride` may be JSON `null`.

Key order in the payload is Dart map insertion order: loaded order for existing keys, new keys appended (ASF:52 `Map.from(sections)..addAll(updates)`). Order is irrelevant to verification.

---

## 3. Checksum

Code (ASF:610-618), VERIFIED:
```dart
String _checksumBytes(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
```

What actually happens in the Dart VM (all VERIFIED by running Dart 3.12.2, `chk.dart`):
- Algorithm: **FNV-1a, 64-bit**. Offset basis `0xcbf29ce484222325`, prime `0x100000001b3` (1099511628211), XOR the byte first, then multiply. Standard.
- Input: **UTF-8 bytes** of the payload (the exact bytes between the first LF and end of file). Not UTF-16 code units. Not a re-encoding.
- Dart VM `int` is a signed 64-bit two's-complement integer. The literal `0xcbf29ce484222325` evaluates to `-3750763034362895579`. The mask literal `0xFFFFFFFFFFFFFFFF` evaluates to `-1` (all ones), so `& 0xFFFFFFFFFFFFFFFF` is a **no-op**; multiplication simply wraps mod 2^64.
- Hence the accumulator is the standard unsigned FNV-1a value reinterpreted as `Int64`. Output formatting: `Int64.toRadixString(16)`; for a negative value Dart prints `"-"` followed by the lowercase hex of `-value`. Then `padLeft(16,'0')` prepends `'0'` characters until length 16, **counting the minus sign**.
- Result classes:
  - hash top bit clear: 16-digit lowercase hex, zero-padded (identical to the standard unsigned FNV-1a hex).
  - hash top bit set: `"-"` + lowercase hex of `2^64 - u` (u = the standard unsigned hash; magnitude is at most 2^63). Total length is 17 when the magnitude has 16 hex digits (the common case, about 7/8 of negatives), 16 when it has 15 digits, and when it has 14 or fewer digits `padLeft` inserts `0`s BEFORE the minus sign (`0-c4187ddd60c398`, about 1/128 of negatives). All three forms were observed.
  - Empty payload: `-340d631b7bdddcdb` (offset basis itself, negative).
- The stored value is a JSON string, compared with Dart `!=` string equality (ASF:583).

**Worked examples** (input string = exact payload bytes; all computed by executing the Dart function above; the Swift function below reproduces every one of them, VERIFIED by compiling and running `c.swift`):

| Payload (UTF-8) | Length | Checksum string |
|---|---|---|
| `{}` | 2 | `08f44b07b5901a25` |
| `{"transactions":[]}` | 19 | `72b86e4d16d871bc` |
| `{"transactions":[{"description":"Rent"}]}` | 41 | `42efd28523f97b6b` |
| `{"transactions":[{"description":"Rent","amount":1200.0}]}` | 57 | `247b960e48b7b412` |
| `{"transactions":[{"description":"Coffee"}]}` | 43 | `-263aafe76414ed84` (negative case) |
| `{"a":1}` | 7 | `-63c17d229035174f` |
| `{"n":1550}` | 10 | `0-c4187ddd60c398` (negative, short magnitude: pad-before-minus case) |
| (empty) | 0 | `-340d631b7bdddcdb` |

Full worked file for the 57-byte payload (header line produced by the real `_encode` logic; `writtenAt` varies):
```
{"format":"budgie-financial-store","schemaVersion":2,"revision":1,"payloadLength":57,"payloadChecksum":"247b960e48b7b412","writtenAt":"2026-09-28T16:59:00.679897"}⏎
{"transactions":[{"description":"Rent","amount":1200.0}]}
```
(`⏎` = one `0x0A` byte; nothing follows the final `}`.)

Swift reference implementation (matches Dart bit-for-bit on the table above):
```swift
func storeChecksum(_ bytes: [UInt8]) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in bytes { h ^= UInt64(b); h = h &* 0x100000001b3 }
    let s = Int64(bitPattern: h)
    var out = s < 0 ? "-" + String(s.magnitude, radix: 16) : String(h, radix: 16)
    while out.count < 16 { out = "0" + out }   // pad on the left of the "-" too, exactly like padLeft
    return out                                   // radix-16 output is already lowercase
}
```
A Swift reader that only wants leniency could instead parse both the string and its own hash into `Int64` and compare, but a Swift WRITER that must be readable by Flutter has to emit this exact string.

Cross-check against the project's own note (memory `sim-driving-tips.md`): "FNV-1a 64 formatted the Dart way: signed 64-bit, so negative hashes render as `-xxxxxxxxxxxxxxx`" is CONFIRMED. The memory note's "signed FNV" is not FNV-1a 32; it is 64-bit.

---

## 4. The legacy "re-encoding" checksum path

Two distinct checksum styles exist:

**(a) v2 file (current): hash the raw payload bytes.** `_verifyBytes` (ASF:562-592). The comment at ASF:540-542 states the design reason: verification must not depend on JSON re-encoding being byte-stable.

**(b) v1 SharedPreferences envelope (legacy, migration only): hash a re-encoding.** `_decodeLegacyEnvelope` (ASF:370-397), used only inside `_migrateFromPreferences` (ASF:304-309). VERIFIED steps:
1. `jsonDecode(encoded)`; must be a `Map<String, dynamic>` (ASF:373-374).
2. `decoded.remove('checksum')`; must be a `String` (ASF:375-376).
3. Compare `_checksumBytes(utf8.encode(jsonEncode(decoded)))` with the stored string (ASF:377). I.e. re-encode the decoded map (minus the `checksum` key) with `jsonEncode` and hash the UTF-8 bytes. This relies on Dart preserving key order (LinkedHashMap) and reproducing the same number formatting as the original writer.
4. Then require `schemaVersion` int and `<= 1`, `revision` int, `sections` a `Map<String,dynamic>` (ASF:380-388).

How the v1 writer built it (git `c473af9:budget_app/lib/storage/atomic_financial_store.dart`, VERIFIED): `payload = {schemaVersion, revision, sections}`, `canonicalPayload = jsonEncode(payload)`, stored value `jsonEncode({...payload, 'checksum': _checksum(canonicalPayload)})`. So the v1 string in SharedPreferences was `{"schemaVersion":1,"revision":N,"sections":{...},"checksum":"<hex>"}` under key `flutter.financial_store_v1` (backup: `flutter.financial_store_v1_backup`), the same signed-FNV formatting as section 3 (the same `_checksum` code, over `utf8.encode(string)`).

Why it exists / when used: only for the first launch after upgrading from a pre-file-store build, when no v2 file decodes (section 7). The v2 format dropped the re-encode approach because it is fragile. A Swift port that wants to keep the migration must replicate Dart's `jsonEncode` output byte-for-byte after parsing (double formatting rules in section 9, key order preserved). Given that the current release (3.4.0) has already migrated existing users and removes those keys after migration, this path is likely unreachable for real users; the decision to drop it belongs to the porting plan (INFERRED: physical-device state is not inspectable here).

The same signed-hex `_fnv1a` is reimplemented in the test (test/atomic_financial_store_test.dart:26-33), confirming the formatting is contractually stable.

---

## 5. Revision semantics

- `FinancialSnapshot.empty`: `schemaVersion 2`, `revision 0`, no sections (ASF:42-46).
- Every commit through `updateSections`/`updateSection` is `next = current.copyWithSections(updates)` with `revision = current.revision + 1` (ASF:48-54, 212-219). `replace` (ASF:221-232) also uses `current.revision + 1` (ignores the passed snapshot's revision); it has zero callers (VERIFIED by grep).
- Revision is a global counter for the whole file (all sections), not per section. A restore-from-backup in Settings performs one multi-section commit (settings_page.dart:421-446) followed by several more (each model's `restoreFromBackup` persists again), so it consumes multiple revisions.
- `current` is the in-memory `_snapshot` (loaded once, updated only after a successful commit, ASF:213-217). The store never re-reads disk after the initial load. After a failed commit `_snapshot` is unchanged, so the next attempt reuses the same `revision + 1` number (even if a failed commit's file did land on disk, e.g. verification read failed after a successful rename; then disk and the retry share a revision number, and load prefers primary on ties).
- Migration preserves the legacy revision rather than incrementing: `revision: chosen?.revision ?? 0` (ASF:349).
- `_load` picks the newest valid copy (ASF:262-277): both files are fully verified+decoded (`_decodeBytes`); if primary is valid and (backup missing/invalid or `primary.revision >= backup.revision`) primary wins (ties go to primary). Otherwise backup wins ("primary missing, unreadable, or older"). "Valid" = header + length + checksum + JSON-object payload all check out; it does not compare content, only revision numbers.
- When primary and backup differ and backup is newer or primary invalid: the primary file is rewritten from the backup snapshot (section 7). Note `_encode(restored)` re-serializes the decoded map, so the restored primary's payload bytes and `writtenAt` may differ from the backup's bytes (same revision, same logical content; number text can change, e.g. `1e2` -> `100.0`).

---

## 6. Commit protocol, step by step (`_commit`, ASF:455-523)

Preconditions: called from the serialized queue (`_enqueue`, below) or from the migration path in `_load`.

1. `_resolveBackend()` (section 1).
2. **Encode** `next` to bytes: `_encode(next)` (ASF:468). Errors here (e.g. NaN in a section) throw `JsonUnsupportedObjectError` before any file is touched.
3. **Backup step** (ASF:477-479): `currentBytes = readIfPresent(primary)`. If non-null AND `_verifyBytes(currentBytes) != null` (header/length/checksum valid; the payload is NOT JSON-decoded here), then `writeAtomically(backup, currentBytes)`. So the backup is a **byte-for-byte copy of the previous primary file** (same header, same `writtenAt`, same revision), written via its own tmp+rename. If the current primary is missing or invalid, the backup is left untouched (so a corrupt primary never clobbers a good backup; pinned by tests, section 10). Consequence: after the very first commit there is no backup file (real device file confirms this); a backup first appears with the second commit, and always holds revision N-1 (or the same revision as primary after a load-time restore).
4. **Primary write** (ASF:487): `writeAtomically(primary, encoded)`.
5. **Verify** (ASF:495, `_verifyOnDisk`, ASF:525-535): re-read the primary from disk via `readIfPresent`; `_verifyBytes` must succeed (header, length, checksum) and `header.revision == next.revision`, else throw `FinancialStoreException('Financial snapshot verification failed (expected revision X, found Y)')`. The payload is not decoded or compared to memory; verification is checksum + revision only.
6. On success `_snapshot = next` (ASF:217), done. `finally` emits a timeline event and calls `onWriteMetrics` (errors in the observer swallowed; test-only hook).

`writeAtomically` (ASF:676-687), VERIFIED:
```dart
await directory.create(recursive: true);
final staged = File('$path.tmp');
await staged.writeAsBytes(bytes, flush: true);
await staged.rename(path);   // rename(2) replaces the target atomically
```
Only `FileSystemException` is caught and wrapped into `FinancialStoreException('Could not write $path', error)`.
- `writeAsBytes(..., flush: true)` uses `FileMode.write` (create + truncate; existing `.tmp` from a crashed prior attempt is simply overwritten), writes all bytes, then `RandomAccessFile.flush()` (dart-sdk `lib/io/file_impl.dart:723-737`), then closes (VERIFIED in the Dart SDK source). The native flush is `fsync(2)` on POSIX (INFERRED: native runtime code not shipped in the SDK). On Darwin `fsync` does not force the drive cache (`F_FULLFSYNC` would); ASF does not use `F_FULLFSYNC` (INFERRED). The parent directory is not fsynced after rename (VERIFIED: no such call).
- `rename` -> POSIX `rename(2)` (Dart `File.rename`, file_impl.dart:367-379), atomic replace on the same filesystem (INFERRED for the native call).

Order of files touched in one commit: `backup.tmp` created -> flushed -> renamed to backup; then `primary.tmp` created -> flushed -> renamed to primary; then read primary.

Failure at each step:
| Step fails | State left behind | Result |
|---|---|---|
| Encode | nothing touched | exception (`JsonUnsupportedObjectError` etc.) |
| Read current primary (I/O error, permission, directory in its place) | nothing touched | `FinancialStoreException('Could not read ...')` |
| Backup tmp write/rename | backup unchanged or fully replaced (atomic); a `backup.tmp` may linger | `FinancialStoreException`; primary untouched |
| Primary tmp write/rename | backup already updated (== old primary); primary unchanged; `primary.tmp` may linger | `FinancialStoreException` |
| Verify read/checksum/revision | primary already replaced with the new file (which may be good); `_snapshot` NOT updated | `FinancialStoreException` (or raw exception from `readIfPresent` wrapper) |

Stale `*.tmp` files are never read on load and never deleted; they are overwritten on the next write to that name (VERIFIED: `.tmp` appears only in `writeAtomically`).

**Serialization against concurrent writes** (ASF:151-155, 234-249): an in-process FIFO chain. `_writeQueue` is the tail future (nullable). `_enqueue(op)` runs `op` immediately if idle, else `previous.then((_) => op())`; the tail future swallows errors (`onError: (_, __) {}`) so a failed write does not block later ones, while the returned `result` future still delivers the error to that op's caller. The tail clears itself when it is still the latest (ASF:244-246). Only `updateSections`/`replace` are queued; `read()` is not queued but is deduplicated with `_loading ??=` (ASF:199-206). There is no cross-process lock or file lock (the widget extension does not use this file). Swift equivalent: a single actor or serial queue that owns the snapshot.

---

## 7. Load precedence and every branch (`_load`, ASF:254-300)

`read()` (ASF:199-206) returns the cached snapshot if any; otherwise runs `_load()` once (shared via `_loading`), stores `_snapshot`, clears `_loading` in `whenComplete` (also on error, so a failed load can be retried and `isLoaded` stays false; pinned by test, section 10).

Order of evaluation:

1. `backend.readIfPresent(primary)` and `readIfPresent(backup)`. Returns `null` only when `FileSystemEntity.type(path) == notFound` (ASF:667-668); any other failure (a directory in its place, permissions, protected data unavailable) throws `FinancialStoreException` and aborts the whole load (ASF:664-673). A read error is never treated as an empty store.
2. Each present file goes through `_decodeBytes` = `_verifyBytes` + `utf8.decode(payload)` + `jsonDecode` requiring a JSON object (ASF:594-608). Failure gives `null` for that file.
3. **Branch A: at least one valid** (ASF:262-277):
   - A1 primary valid and (backup null-or-invalid or `primary.revision >= backup.revision`): return primary. **Nothing is written.** The backup is NOT healed from the primary at load (a missing/corrupt/older backup stays that way until the next commit copies the primary over it).
   - A2 otherwise (primary missing/invalid/older than a valid backup): `debugPrint`; `writeAtomically(primary, _encode(backup snapshot))`; `_verifyOnDisk(backend, backup.revision)`; return the backup snapshot. The backup file is left as is. Either the write or the verify throwing aborts the load with that exception (app shows the init-error screen, section 8). Revision is NOT bumped.
4. **Branch B: neither decodes but at least one file exists** (condition is `primaryBytes != null || backupBytes != null`, ASF:279): stamp = now in ms; rename each existing file to `<name>.corrupt-<stamp>` via `setAside` (ASF:283-288; a rename failure throws `FinancialStoreException('Could not set aside ...')`). Then fall through to migration. Note: a single corrupt primary with no backup goes here too.
5. **Branch C: no files, or fell through** -> `_migrateFromPreferences()` (ASF:302-357):
   - Reads `SharedPreferences` (iOS `UserDefaults.standard`, keys prefixed `flutter.`, VERIFIED in shared_preferences-2.5.4 `shared_preferences_legacy.dart:22` and shared_preferences_foundation-2.5.6 `SharedPreferencesPlugin.swift:24-40`; the app uses `SharedPreferences.getInstance()` legacy API): envelope primary `financial_store_v1`, envelope backup `financial_store_v1_backup` (both via the section 4 decoder), plus the legacy per-feature keys (ASF:401-450).
   - Per-feature legacy keys (`StorageKeys`, storage_keys.dart): `transactions`, `net_worth_entries`, `net_worth_selected_month` (plain string, not JSON), `category_budget_limits`, `savings_goals`, `recurring_transactions`, `categories_v1`, `transaction_tags_v1`, `categorization_rules_v1` (each a JSON string, decoded with `jsonDecode`, empty/invalid -> null), and `appSettings` synthesized only if any of `base_currency_code`, `locale_override`, `app_lock_enabled`, `auto_lock_timeout_seconds`, `hide_balances` exists (defaults `'USD'`, `null`, `false`, `60`, `false`).
   - If no envelope decodes and there is no legacy data at all: return `null` -> `_load` returns `FinancialSnapshot.empty` (revision 0) **without writing anything** (ASF:293-296; test "does not touch preferences when there is nothing to migrate").
   - Chosen envelope: primary if valid and (backup null or `primary.revision >= backup.revision`), else backup (ASF:319-326). Sections start as the chosen envelope's sections. If the primary envelope was NOT chosen and a legacy `transactions` key parsed to a list, that list REPLACES the envelope's transactions (the old store mirrored transactions to that key after each commit, so it's at least as new as the backup envelope; ASF:332-338). Then any legacy section not already present is filled in (ASF:341-345). Revision = chosen envelope's revision or 0.
   - Then `_commit(migrated)` (full commit protocol incl. verify; no backup step because no primary exists), then `_removeMigratedPreferenceKeys()` (ASF:359-366) removes, only if `containsKey`, the keys in `migratedPreferenceKeys` (ASF:129-141): `financial_store_v1`, `financial_store_v1_backup`, `transactions`, `net_worth_entries`, `net_worth_selected_month`, `category_budget_limits`, `savings_goals`, `recurring_transactions`, `categories_v1`, `transaction_tags_v1`, `categorization_rules_v1`. Removal happens strictly after a verified commit; a commit failure throws before any removal.
   - NOT removed (still used as real preferences or fallbacks): `base_currency_code`, `locale_override`, `app_lock_enabled`, `auto_lock_timeout_seconds`, `hide_balances` (AppSettingsProvider keeps mirroring them into prefs on every setter, app_settings_provider.dart:60-140), `themeMode`, `onboarding_completed`, and the ancient `starting_assets` / `starting_liabilities` (read by `_migrateLegacyNetWorthIfNeeded`, transaction_model.dart:1473-1505, only when `netWorthEntries` is empty).

Does load ever write? Yes, in three cases only: A2 (restore primary from backup), B (rename to `.corrupt-*`), C-with-data (migration commit + key removal). A normal load (A1) and a fresh install (no files, no legacy data) write nothing at the store level. But at the APP level, a fresh launch does write immediately: `CategoryProvider.load()` seeds the built-in categories and calls `_persist()` when the stored section is not a list (category_provider.dart:45-48), producing revision 1 with only a `categories` section. That matches the real simulator file (VERIFIED).

Provider-level fallbacks that read SharedPreferences when a section is absent (these run after the store loads): CategoryProvider (`categories_v1`, category_provider.dart:36-39), CategorizationProvider (`transaction_tags_v1`, `categorization_rules_v1`, categorization_provider.dart:32-51), AppSettingsProvider (the five settings keys, app_settings_provider.dart:35-56). Since migration removes the bulky keys, these fallbacks only matter for stores that never ran the migration.

Other providers' load-time write-backs: `TransactionModel.getTransactions` writes if it had to backfill row ids/timestamps (transaction_model.dart:385-386) and if it migrated legacy net worth (transaction_model.dart:398-401). These are model concerns.

---

## 8. Failure branches, error types, and how callers surface them

Error types thrown by ASF:
- `FinancialStoreException(message, cause)` (ASF:58-67; `toString()` = `message (CauseType: cause)`): file read failure (ASF:672), write failure (ASF:685), set-aside failure (ASF:696), verification failure (ASF:530-534). Only `FileSystemException` is wrapped.
- Not wrapped (propagate raw): `JsonUnsupportedObjectError` (NaN, Infinity, non-string map keys, unencodable object) from `_encode`; `MissingPlatformDirectoryException` from `getApplicationSupportDirectory`; SharedPreferences/platform errors during migration; `StateError` from `storageDirectory()` when not directory-backed (unused in app code, VERIFIED by grep).
- Load never produces "empty because unreadable": read errors throw (ASF:645-647 doc, tests).

Caller behavior:
- **Startup** (`_initializeApp`, main.dart:255-308): `ProtectedDataGate.waitUntilAvailable()` then `AtomicFinancialStore.instance.read()` inside a try; on any error logs and `rethrow`s (main.dart:299-303); the `FutureBuilder` shows `_InitializationErrorScreen` ("Budgie couldn't read your data ... Unlock your phone if it is locked, then try again.", main.dart:411-465) with Retry that resets `_initFuture`. The app never renders on top of empty models. Deep links/quick actions wait on `_initializationCompleter`, which is only completed on success.
- **PersistenceStatus mixin** (persistence_status.dart), used by `TransactionModel` (transaction_model.dart:146) and `RecurringTransactionModel` (recurring_transaction_model.dart:9):
  - `persistSections(sections)` builds `payload = {every currently-unsaved section, serialized fresh via serializeSection, unless overridden by an explicit entry} + sections` (lines 36-41) and calls `updateSections(payload)`.
  - On ANY thrown error (`catch (error, stackTrace)`, line 44): `debugPrint`, adds all payload keys to `_unsavedSections`, sets `_lastSaveError = error.toString()`, `notifyListeners()`, returns `false` (lines 44-51). Never throws.
  - On success: removes the payload keys from `_unsavedSections`; if it had been non-empty and is now empty, clears `_lastSaveError` and notifies (lines 53-58); returns `true`.
  - `hasUnsavedChanges` = unsaved set non-empty (line 19); `lastSaveError` string; `unsavedSections` for diagnostics.
  - `retryPendingSaves()` (lines 64-70): if nothing unsaved return true; otherwise `persistSections` with each flagged section freshly serialized.
  - Consequence: in-memory state already changed (memory-first), the row stays visible; a later successful save of any section also carries the flagged sections ("one working write heals everything").
  - Permanent-failure hazard: if a section value contains NaN/Infinity, `_encode` throws every time; every save (of any section) fails since the flagged section is always re-included.
- **Retry triggers**: unsaved-changes banner Retry button (widgets/unsaved_changes_banner.dart:46-50, shown from home_page.dart:99 when either model `hasUnsavedChanges`); snackbar Retry in transaction_form.dart:142-146 (text "Couldn't save to this device. The entry is kept in memory until Retry succeeds."); and automatically on lifecycle `inactive`/`paused` once initialization has completed (main.dart:204-213).
- **Direct writers not using PersistenceStatus** (CategoryProvider._persist, CategorizationProvider._persistTags/_persistRules, AppSettingsProvider._persistAtomic, Settings restore): exceptions propagate to their callers/UI with no flagged state and no banner. The restore flow's `updateSections` is inside a try/catch in `settings_page.dart` that shows a red snackbar "Could not import backup: $e" (settings_page.dart:481-505). CategoryProvider.load can throw during startup (it writes when seeding), which surfaces via the init-error screen.
- Widget cash-flow push is only attempted after a verified save (`if (saved) await _syncWidgetCashFlow()`, transaction_model.dart:306).

---

## 9. JSON encoding details (dart:convert `jsonEncode`, no `toEncodable`, no indent)

All VERIFIED by execution (`chk.dart`, `e.dart`, Dart 3.12.2, native VM as on iOS):

- Compact output: no spaces after `:` or `,`, no newlines. Map key order = insertion order.
- **Doubles** print via Dart's shortest-round-trip `double.toString()`:
  - Always contains `.` or `e`: `1200.0`, `100.0`, `12.5`, `0.1`, `-0.0`, `4294967296.0`.
  - `0.1 + 0.2` -> `0.30000000000000004`.
  - Switches to exponent form at >= 1e21 and < 1e-6: `1e+21`, `1.5e+300`, `1e-7`, `5e-324`; but `1e20` -> `100000000000000000000.0`, `123456789012345680000.0`, `0.000001` -> `0.000001`, `1e15` -> `1000000000000000.0`, `1e16` -> `10000000000000000.0`.
  - Exponent form has an explicit `+` for positive exponents (`1e+21`) and no leading zeros.
- **Ints** print with no fractional part: `1`, `100`, `9007199254740993`, `9223372036854775807`.
- **NaN / Infinity / -Infinity**: `jsonEncode` throws `JsonUnsupportedObjectError` ("Converting object to an encodable object failed: NaN"), including when nested. There is no lossy fallback.
- **Strings**: non-ASCII is written raw as UTF-8 (`café`, `😀`, ` ` literal U+2028 char, DEL 0x7F raw). `/`, `<`, `>`, `&` are NOT escaped. Escapes emitted: `\"`, `\\`, `\b`, `\t`, `\n`, `\f`, `\r`, and all other code points below 0x20 as lowercase `\u00xx` (e.g. `\u0000`, `\u0001`, `\u000b`, `\u001f`). Lone UTF-16 surrogates are escaped as lowercase `\udXXX` (e.g. `\ud83d`); valid surrogate pairs are emitted as the raw 4-byte UTF-8 character. Payload bytes are `utf8.encode` of the whole string.
- **Map keys** must be strings (`{1: 'x'}` throws).
- **Dates**: model code stores `DateTime.toIso8601String()` (local time, no offset, e.g. `2026-09-01T00:00:00.000`; microseconds print as 6 digits if non-zero: `2026-09-01T00:00:00.005007`; UTC values would end in `Z`). Not done by `jsonEncode` itself. Note `selectedNetWorthMonth` and possibly other date fields are local-time strings without offset; the Swift side must parse/format with local-time semantics.
- **Decoding** (`jsonDecode`): a number token with `.` or exponent -> `double` (`1.0`, `1e2` -> `100.0`); integer tokens -> `int` (64-bit); integer literals beyond int64 -> `double` (e.g. `12345678901234567890` -> `1.2345678901234567e19`); `1E400` -> `Infinity`; `-0` -> int `0`; `-0.0` -> `-0.0`. Round-trip through decode+encode changes `1e2` to `100.0`, `0.10` to `0.1`, but preserves `1.0`, `100`. Relevant to the load-time restore (section 7 A2) which re-encodes.
- Header line goes through the same `jsonEncode`; the only string with non-trivial characters is `writtenAt` (digits, `-`, `:`, `.`, `T`).
- For Swift: Swift's `JSONSerialization` differs from all of the above (escapes `/`, prints `1200` for `1200.0` unless the NSNumber is a real double and even then may print `1200`, uses different exponent formatting, sorts keys only if asked). None of this breaks Dart reading, because Dart parses standard JSON and checks the checksum over the raw bytes it receives. It DOES matter if Swift re-reads a Dart-written double as an integer and writes it back as `100`, and Dart then does `as double` on a field (see hazard 5), and it matters for the v1 legacy-envelope re-encode check (section 4).

---

## 10. What `test/atomic_financial_store_test.dart` pins

Test setup (lines 43-55): each test uses a fresh temp directory, `resetForTesting(directory:)`, mock SharedPreferences; `relaunch()` = `resetForTesting` again (drops memory, keeps files). The test file also carries its own copy of the signed-FNV function (lines 26-33) and a legacy-envelope builder (lines 11-24) that writes `{schemaVersion:1, revision, sections, checksum}` with checksum LAST.

1. **Fresh install reads empty and writes nothing** (63-70): revision 0, empty sections, neither file exists.
2. **Commit metrics** (72-90): `onWriteMetrics` receives one event with bytes > 0, succeeded true, total >= write; a throwing observer does not break the save; two commits give revision 2.
3. **Commits survive relaunch; each keeps the previous as backup** (92-117): after 2 commits (second is multi-section) a relaunch loads revision 2 with both sections, and the backup file exists.
4. **Verification reads from disk, not memory** (119-136): after the directory is replaced with a plain file, the next `updateSection` throws `FinancialStoreException` (directory create failure surfaces as a store exception).
5. **Corrupt primary recovered from backup on load** (138-157): with garbage in the primary, load returns the backup's (older) revision content; the primary is rebuilt from the backup so a second relaunch is clean.
6. **Corrupt primary never overwrites a good backup** (159-184): after recovery the next commit succeeds; a later corruption of the primary again falls back to a good backup (revision-1 content), proving the backup step copies only intact primaries.
7. **Newest readable revision wins** (186-206): swapping the files so the primary is older than the backup makes load return the higher revision (2).
8. **Unreadable store is an error, never an empty ledger** (208-220): primary replaced by a directory makes `read()` throw `FinancialStoreException` and `isLoaded` stays false.
9. **Migration: imports the v1 envelope, clears the bulky keys** (223-265): revision preserved (7); envelope sections kept; `appSettings` synthesized from legacy `base_currency_code`; v2 primary written; `financial_store_v1` and `transactions` prefs removed; `base_currency_code` pref stays; relaunch reads from file.
10. **Migration: legacy per-feature keys, no envelope** (267-288): transactions and recurring templates imported; absent sections stay absent (e.g. no `savingsGoals` key).
11. **Migration: malformed primary envelope falls back to its backup plus the newer transactions mirror** (290-323): revision 3 from the backup envelope; transactions taken from the legacy `transactions` key (`old`, `newest`); other backup-only sections (`savingsGoals`) kept.
12. **No preferences touched when nothing to migrate** (325-336): unrelated pref (`onboarding_completed`) untouched; no primary file created.

Not covered by tests (behavior described above but unpinned): `.corrupt-<stamp>` quarantine branch (section 7 B), tie-breaking on equal revisions, A2's verify-after-restore, `payloadLength`/`schemaVersion > 2` rejection, the negative-checksum formatting on the v2 path (the test's signed helper only feeds the v1 envelope), header field validation, the `.tmp` mechanics, and the write-queue ordering/error-isolation.

---

## Appendix: quick Swift-port checklist derived from the above

- Path: `Library/Application Support/financial_store/{financial_store_v2.json, financial_store_v2.backup.json}`; staging `<name>.tmp`; create directory on write; do not read before protected data is available.
- Read: split at first LF; parse header (require exact `format`, int `schemaVersion <= 2`, int `revision`, int `payloadLength`, string `payloadChecksum`); check payload length and the signed-FNV string; parse payload as a JSON object.
- Write: header key order as above, `schemaVersion` 2, no trailing newline, checksum string per section 3, write to `.tmp` + fsync + atomic rename, backup = byte copy of previous VALID primary written first, then primary, then re-read and verify revision.
- Load: newest revision wins, tie to primary, restore primary from backup when primary invalid/older, decide policy for the `.corrupt-*` fall-through, do not write on a clean load.
- Preserve unknown sections; keep revisions monotonic; single serial writer.
