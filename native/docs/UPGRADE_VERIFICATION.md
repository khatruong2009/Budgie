# Upgrade verification

How the Flutter-to-Swift upgrade (same bundle ID, installed over the Flutter
app with no uninstall) is proven to lose nothing, and the evidence so far.
Three parts, merged from the former `UPGRADE_TEST_PLAN.md`,
`UPGRADE_TEST_RESULTS.md` and `MIGRATION_SAFETY_AUDIT.md` (text unchanged
apart from heading levels and cross-references between the parts):

1. Test plan: how to run the rehearsal, scenarios S1-S6 and their checklists.
2. Results: every rehearsal run, UI flow, Home screen integration and the
   differential corpus, with the run directories under `rehearsal/`.
3. Migration safety audit (2026-09-30): fixes, evidence, remaining release
   requirements. Source hashes and suite results are in
   `DEEP_MIGRATION_AUDIT_EVIDENCE.json`.

Device steps are in `REAL_DEVICE_CHECKLISTS.md`.

## Test plan

Proves on a simulator that installing the Swift app over the Flutter app
(same bundle ID, no uninstall) loses nothing, and that the Flutter build can
be installed back over the Swift app. Synthetic data only; never a physical
device.

### How to run

```bash
native/scripts/upgrade_rehearsal.py            # builds both apps, runs s1 s3 s4 s5 s6
native/scripts/upgrade_rehearsal.py --skip-build s1
python3 native/scripts/verify_upgrade_preservation.py native/docs/rehearsal/<run>
```

Output: `native/docs/rehearsal/<timestamp>/` with `report.json`, screenshots
and the pulled app state of every step. Results are written up in
the Results part below.

The script only touches the simulator named `Budgie-Rehearsal` (created if
missing, erased between scenarios). The Flutter app is built from a
`git archive` copy of `budget_app` with a stub `.env`; `budget_app/` itself
is never modified. The Swift app is the Debug build, whose rehearsal hooks
(environment variables, Debug only) are:

| Variable | Effect |
|---|---|
| `BUDGIE_REHEARSAL_SUMMARY=1` | writes what the app shows to `Library/Caches/budgie-rehearsal.json` |
| `BUDGIE_REHEARSAL_EDIT=1` | makes one of each MVP edit through the app model after launch |
| `BUDGIE_SIMULATE_LOCKED_SECONDS=N` | reports protected data unavailable for N seconds |

"What the Flutter app shows" is computed by the real Flutter models
(`native/ParityHarness` verify mode) over the exact files pulled from the
simulator, so the comparison is number-for-number, not by eye. Screenshots
of both apps are kept for a visual check.

Data is seeded from `native/Fixtures`, which the real Flutter code produced.
Preferences are injected by editing the app's defaults plist while the
simulator is shut down (`simctl spawn defaults write` cannot reach an app's
container).

### Scenarios and checklist

#### S1: typical store, upgrade and downgrade

1. Erase; install the Flutter build; inject `store/typical` files and
   `flutter.themeMode = dark`, `flutter.onboarding_completed = true`.
2. Launch Flutter (it generates due recurring rows); screenshot; pull state.
3. Install the Swift build over it; launch; screenshot; pull state.
   - [ ] Every month's income, expenses and transaction count, net worth
     per month, recurring cursors and settings equal the Flutter models'
     values on the step 2 files.
   - [ ] `pre-native-migration/<stamp>/` exists, is complete, and its store
     files are byte-identical to the step 2 files.
   - [ ] Theme is dark; onboarding flag unchanged.
   - [ ] App Group `cashFlow`/`cashFlowMonth` written (widget value).
4. Launch Swift with scripted edits (add, edit, delete, add template,
   pause, currency, theme); pull state.
5. Install the Flutter build over it; launch; screenshot; pull state.
   - [ ] No `.corrupt-*` files: Flutter accepted the Swift-written store.
   - [ ] The Flutter models load every row (no skipped, reset or unsaved
     data) and show the same numbers as Swift did in step 4.

#### S3: legacy-only SharedPreferences (a user who skipped updates)

1. Erase; install the Flutter build without launching it; inject every
   bare legacy key, both v1 envelopes, settings, starting balances, theme,
   onboarding and insight keys.
2. Install the Swift build; launch; pull state.
   - [ ] A verified `financial_store_v2.json` exists; the 11 migrated keys
     are removed; settings, theme, onboarding, starting-balance and insight
     keys remain.
   - [ ] The pre-native snapshot's `preferences.plist` still holds every
     legacy key.
   - [ ] Numbers equal the Flutter models' on the same files.
3. Install the Flutter build over it; launch; pull state.
   - [ ] Flutter loads the Swift-migrated store without errors.

#### S4: locked / prewarmed launch

1. Erase; install Flutter; inject `store/typical` and
   `flutter.onboarding_completed = true` (so the data, not the tour, shows);
   install Swift.
2. Launch Swift with `BUDGIE_SIMULATE_LOCKED_SECONDS=12`; after 4 s:
   - [ ] Store files unchanged (mtimes), no `pre-native-migration/`, no
     summary written, "Unlock your iPhone" on screen.
3. After the simulated unlock:
   - [ ] Data loads normally.

The simulator cannot produce a real prewarm or a real locked container
(research I section 4); this checks the app's gate logic. A real-device
test is on the pre-ship list.

#### S5: damaged files

1. `store/primary_truncated` (onboarding flag preset as in S4): Swift
   restores the primary from the backup
   (same revision Dart restores), shows the data.
2. `store/both_corrupt`: Swift sets both files aside as `.corrupt-<ms>`,
   shows "Your data couldn't be read", writes nothing else. Currency settings
   are present: these must never bypass the corruption gate. Starting without
   recovery requires a second explicit confirmation.

#### S6: malformed legacy-only preferences

Run once with a truncated transaction preference, once with a truncated v1
envelope, both with valid currency and onboarding preferences. The app must
block, retain the original preference, make a complete pre-native copy, and
write no financial store or ready-state summary.

#### Full preservation verification

`verify_upgrade_preservation.py` additionally checks every original financial
section and value after S1, original category rows (launch may append a
definition), byte-identical safety copies, the Swift file retained by the
Flutter rollback, and every safety-copy manifest hash. It exits nonzero for
missing evidence or preservation failures. The rehearsal itself now exits
nonzero for scenario errors or Dart/Swift mismatches.

### Re-run at the end

The same script runs again on the finished MVP (Phase 4). Results of both
runs go in the Results part below.

## Results

Plan: the Test plan part above. Every run's raw evidence (report.json,
screenshots, pulled container state) is under `native/docs/rehearsal/<run>/`.
Simulator: dedicated `Budgie-Rehearsal` (iPhone 17 Pro, iOS 27.0).
Synthetic fixture data only.

### Migration safety audit — 2026-09-30

See the Migration safety audit part below for the new
regressions, fixes, evidence and remaining release requirements. Fresh run
`20260930-142713` on the separate `Budgie-Migration-Audit` simulator:
S1/S3/S4/S5 passed, no Dart problems or Swift/Dart differences; 52 full-data
and safety-copy hash checks passed. Automated suites: 379 Swift tests,
67 Swift-written Flutter compatibility cases, 390 Flutter tests, clean
Flutter analysis. Physical-device and signed-release verification remain
outstanding.
Follow-up run `20260930-144200`: S5 with real currency preferences and the
new S6 malformed ledger/envelope cases passed inside the installed app;
original legacy values and their safety copies remained intact.

Additional local audit on base `f38383f` plus local safety changes:
`20260930-195723` passed S1/S3/S4/S5/S6 with no Dart problems or Swift/Dart
differences. All 66 extended record-preservation and safety-copy hash
checks passed. Final suites: 398 core tests in Debug and Release, 124
app-model tests, 390 Flutter tests, and clean Flutter analysis. Three-zone
compatibility passed 198 stored-data cases plus six insight-view
comparisons; optimized Release output also passed Flutter loading and
Swift comparison. See `DEEP_MIGRATION_AUDIT_EVIDENCE.json` and the expanded
safety audit for the newly reproduced gaps, source hashes and limits.

"Numbers" below means: per-month income, expenses and transaction count,
net worth (assets, liabilities) per month, recurring cursors and pause
state, and the five app settings. "Flutter's numbers" are computed by the
real Flutter models over the exact files pulled from the simulator.

### Run 1: 20260928-180731 (shell app, before the MVP screens)

| Scenario | Result |
|---|---|
| Build | First attempt failed: `flutter build ios --simulator` requires an x86_64 slice this Flutter engine no longer ships. Fixed by building arm64 only (`--config-only` + `xcodebuild ARCHS=arm64`). Not a data issue. |
| S1 upgrade | PASS. Swift shows exactly Flutter's numbers (0 differences). `pre-native-migration/<stamp>/` complete; its store files are byte-identical to Flutter's. Theme dark and onboarding flag carried over. App Group `cashFlow`/`cashFlowMonth` written. |
| S1 downgrade | PASS on data: the Flutter build loaded the Swift-written store (its backup = Swift's revision 200 byte for byte; it wrote revision 201 adding one category definition, its normal launch behaviour). Flutter models: no problems; numbers equal Swift's. The downgrade screenshot was a black frame; reproduced with longer waits and console capture, it is Flutter's slower first launch after a reinstall (the app then renders normally). Waits were lengthened. |
| S3 legacy-only | PASS. Swift migrated the bare keys + v1 envelopes into a verified v2 store; the 11 migrated keys were removed; settings, theme, onboarding, starting-balance and insight keys kept; the pre-native snapshot's `preferences.plist` holds every legacy key. Numbers equal Flutter's on the same files; the Flutter build then loaded the Swift-migrated store without problems. |
| S4 locked launch | NOT RUN: script error (a cached container path; reinstalling moves the data container). Fixed. |
| S5 damage | PASS. Truncated primary: restored from the backup (145 transactions, same revision Dart restores). Both damaged: set aside as `.corrupt-<ms>`, "Your data couldn't be read" shown, nothing else written. |

Screens: the Flutter screenshots show Flutter's App Lock screen because the
fixture enables App Lock and the simulator had no enrolled biometrics;
later runs enroll simulated Face ID.

### Run 2: 20260928-181915 (same binaries, script fixes)

| Scenario | Result |
|---|---|
| S1 | PASS (0 differences both directions). Note: the pulled `3-swift-edited` preferences did not yet show `flutter.base_currency_code` although the app had set it; the plist on disk is written asynchronously by cfprefsd. The store's `appSettings` (authoritative) had GBP, and the key was present in the later pull. Not a data issue. |
| S3, S5 | PASS, as run 1. |
| S4 | Reported FAIL ("store changed / pre-native folder exists while locked"). Investigated before accepting: timestamps showed the writes at 18:26:49, i.e. when the simulated 15 s lock ended, while the "during lock" check had run after a `simctl io screenshot` call that wrote its file at 18:26:43 but returned late. A standalone 0.5 s poll confirmed no read or write until 16.8 s after launch (15 s lock + startup). Root cause: the measurement, not the app. S4 now polls the whole window and takes its screenshot without blocking. |

### Run 3: 20260928-183853 (finished MVP, fresh builds of both apps)

| Scenario | Result |
|---|---|
| S1 | Data PASS (0 differences both directions, Flutter models no problems). **UI FAIL on downgrade:** the Flutter build showed a black screen after the Swift app had run, although it loaded and saved the data. |
| S3, S5 | PASS. |
| S4 | PASS: first write 18.8 s after launch with a 15 s simulated lock; nothing read or written while locked. |

Investigation of the S1 black screen (not accepted as a timing artefact the
second time): reproduced deterministically only when the Swift app had run
before the Flutter install. The app's `KnownSceneSessions` held a scene
session whose delegate class was `SwiftUI.AppSceneDelegate` (the SwiftUI
`App` lifecycle); iOS restores a saved session with its stored class
without consulting the app, and the Flutter binary has no such class.
Deleting the saved session made Flutter render immediately: cause
confirmed. Fix (commit 81fc729): the Swift app uses the UIKit lifecycle with
module `Runner`, a `SceneDelegate` and the `Default Configuration` scene
manifest, exactly as the Flutter app declares (MIGRATION_SPEC 11.5, R23).
The same rehearsal also showed that the earlier run-1 black frame was this
bug, not only a slow launch.

### Run 4: 20260928-185629 (after the scene fix, fresh builds)

| Scenario | Result |
|---|---|
| S1 upgrade | PASS: 0 differences; pre-native copy byte-identical; theme and onboarding carried; widget App Group value written. |
| S1 downgrade | PASS: Flutter renders (its App Lock prompt), loads the Swift-written store (backup = Swift's last revision byte for byte), Flutter models report no problems, numbers equal Swift's. |
| S3 legacy-only | PASS: migrated, 11 legacy keys removed and preserved in the pre-native snapshot, numbers equal Flutter's; Flutter then loads the Swift-migrated store. |
| S4 locked launch | PASS: first write 18.1 s after launch with a 15 s simulated lock. |
| S5 damage | PASS: truncated primary restored from backup (145 transactions); both damaged set aside and blocked without writing. |

The report's `sceneDelegateClasses` field was empty in this run because the
extractor looked only for class names; with the Info.plist manifest iOS
stores the configuration by name. Fixed and re-run in run 5.

### Run 5: 20260928-190549 (S1 only, extractor fixed)

PASS. The persisted scene configuration is `Default Configuration` after
every step, whichever app wrote it last (Flutter, Swift, Swift after edits,
Flutter after downgrade). 0 differences; no Dart-side problems; both apps
render after each switch.

### UI flow (XCUITest, `native/scripts/ui_flow.sh`)

PASS on a fresh install (`Budgie-UITest` simulator, 66 s): add expense,
edit its amount from History, add a monthly recurring template (today's
occurrence generated immediately, as Flutter does), pause it, Net Worth
empty state, switch theme to Dark, add and delete an income. The store it
wrote was loaded by the real Flutter models with no problems: amounts are
Dart doubles (`20.0`, `900.0`), the template is `isActive: false`, the
deleted row is gone, `flutter.themeMode` is `dark`.

The script now also runs `CategoriesUITests` before the MVP flow (add,
move up / down, archive / restore, rename cascade, the last active
category refusing Archive; its tearDown deletes the added expense and
archives the added category). 2026-09-29: all PASS, and the Dart
verification loaded the store (the archived "UI Brew" category, the
restored built-in income categories) with no problems.

It now also runs `InsightsUITests` (after Categories, before the MVP flow
leaves its rows): six rows give three duplicate cards, one is snoozed and
one dismissed, both stay hidden after a relaunch, and the rows are deleted.
Its descriptions carry a per-run suffix, so a second run on the same
simulator the same day passes (the first run's snooze and dismissal stay in
preferences; the app has no way to undo them). 2026-09-30, on an erased
simulator: all PASS, Insights passed again on a second run without an
erase, and the Dart verification loaded the pulled store with no problems.

### Home screen integration (`native/scripts/system_flow.sh`, SpringBoard via XCUITest)

Run on a fresh `Budgie-System` simulator: the Flutter build installed and
launched once, then the Swift build installed over it (not launched).
All four tests PASS:

| Test | Result |
|---|---|
| Leftover Flutter quick action | Before the Swift app's first launch, SpringBoard still offers the Flutter build's three items (Add Expense, Add Income, Add by Voice); "Add by Voice" opens Swift's Add Expense form. |
| Swift quick actions | After a launch, exactly "Add Expense" and "Add Income"; both open the right form. |
| `budgetapp://` links | `add-income`, `add-expense`, `voice-add`, `add_income` through the system "Open in Budgie?" prompt open the right form. |
| Widget | The Swift extension appears in the widget gallery as "Budget Quick Add" with the Flutter description; placed on the home screen it shows the App Group value the app wrote (`cashFlow -12`, `cashFlowMonth 2026-09`); its Income and Expense links open the matching forms. |

Widget survival across app replacement (SpringBoard probe, a UI test with
no app under test, so it does not reinstall anything). With the widget
placed: installing the Flutter build over Swift keeps the widget on the
home screen, still showing -$12, and its Expense link opens Flutter's Add
Expense dialog; reinstalling Swift keeps it again and the link opens
Swift's form. Screenshots: `rehearsal/system-20260928/`.

### Safe-to-spend differential corpus

1600 random scenarios (400 per time zone) generated by the real Dart
calculator: Swift matches every field of every case (`SafeToSpendRandomTests`).
A one-line change to the same-day rule produces 210 mismatches.

### Not verified on the simulator

- Real prewarm / locked-container behaviour: the simulator cannot prewarm or
  lock the container; the gate logic is covered by S4 and unit tests. Needs
  a spare physical device (pre-ship item, not done without approval).
- App Lock re-lock after the auto-lock timeout and a failed Face ID match:
  not driven (simulated biometrics cannot be scripted from inside XCUITest).
- Face ID prompts in screenshots: simulated matches were not always
  delivered in time, so several screenshots show the passcode fallback.

## Flutter to Swift migration safety audit — 2026-09-30

Status: automated checks passed; **release sign-off still requires a physical
iPhone upgrade test and verification of the actual distribution archive**.
No test suite can establish a 100% guarantee for every device or recover
data that was already unrecoverably damaged.

Audited source: `claude/swiftui-mvp-migration-71aa05`, base commit
`41139b5ea1720d37fe6799bebc47b4e0162d130f`, plus the local changes from
this audit. The Swift code is in that worktree, not the main Flutter checkout.
All test data was synthetic. No real user data or physical device was altered.

### Three checks

1. **Identity and source review.** Flutter and Swift project configurations
   use `com.khatruong.budgetbuddy`, team `TJ37GFZKW2`, and App Group
   `group.com.khatruong.budgetbuddy`. Both use
   `Library/Application Support/financial_store/financial_store_v2.json`
   and its backup. Preference reads use the Flutter `flutter.` keys in the
   same persistent domain. Module `Runner` and the scene configuration are
   retained. This verifies source configuration, not a signed release IPA.
2. **Automated fault and compatibility tests.** Full Swift suite: 379 tests
   passed, including seven new migration audit tests and the enabled
   Swift-output corpus. Flutter loaded all 67 Swift-written cases with no
   reported problems. Flutter analysis: no issues; full Flutter suite: 390
   tests passed. Flutter commands ran in a git-archive copy with a dummy
   voice key; the copy also included the parent `.gitignore` required by
   its configuration test. Original Flutter source was unchanged.
3. **Installed-app upgrade and rollback.** Fresh Flutter and Swift Debug
   builds were installed over one another without uninstalling on the
   dedicated `Budgie-Migration-Audit` simulator (iOS 27).
   Evidence: `rehearsal/20260930-142713/report.json` and
   `preservation-audit.json`. S1, S3, S4 and S5 passed; every Dart problem
   list and every Swift/Dart comparison was empty. All 52 additional
   preservation checks passed. Every original value in all 10 financial
   sections survived; the only addition was a category definition for an
   existing padded category label. Original Flutter files were preserved
   byte for byte in the pre-native copy, and Flutter rollback retained
   Swift's saved file byte for byte. Every safety-copy manifest hash verified.
   The simulated lock lasted 15 seconds; first observed writes were at
   20.6 seconds, after unlock.

Additional installed-app regression run `rehearsal/20260930-144200`:
S5 with valid GBP currency preferences and S6 with malformed ledger/envelope
preferences both passed. Damaged v2 files remained blocked; malformed legacy
values were retained unchanged both in preferences and in the SHA-256-verified
safety copy. No replacement store or ready-state summary was written for
these failures. The recovered S5 backup still matched the Flutter reader.

### Gaps reproduced and fixed

- With both v2 files damaged, currency settings or stale bare keys could
  bypass the blocking screen and create a replacement empty/older ledger.
  Corrupt files now block before any preference fallback, including after
  a relaunch. The originals remain set aside and in the safety copy.
- Malformed legacy section keys could be deleted after a settings-only or
  partial migration. The app now blocks before committing or deleting
  keys if it cannot recover their sections. An unreadable/unsupported v1
  envelope with no valid envelope backup also blocks, even when unrelated
  bare sections/settings are readable.
- When no primary file existed, an old safety copy could be reused after
  legacy preferences changed. Reuse now checks source files and both
  preference exports. It also detects a changed recovery backup and verifies
  the saved copy's manifest hashes rather than trusting its COMPLETE marker.
- Successful writes checked checksum/revision but not exact intended bytes.
  They now read back and compare the full file; a valid different payload
  with the same revision is a failed save.
- Safety-copy file flush failures were ignored. Copies and metadata now
  verify reads and require successful full-sync or fsync before completion.
- The unreadable-data screen allowed starting without recovery with one tap.
  It now offers Retry and requires a second confirmation to proceed.

The first three new regression tests failed against the original code
(25 recorded issues) and passed after the fixes. Existing parity tests now
explicitly assert the safer blocking behavior for damaged inputs, while
continuing to compare successful migrations against Flutter.

### Additional local audit requested before device testing

Audited base: `f38383f6aa2894854617bb2ca29f7928f9faad6d`, plus the
changes in this audit. This pass used scratch storage and the dedicated
`Budgie-Migration-Audit` simulator only. No physical device or personal
financial data was accessed.

Nine new core tests and two app-bootstrap tests extend the previous audit.
Before the fixes, four core regressions failed with 17 recorded issues;
the app-bootstrap test also failed for all ten known section container types.
The reproduced gaps and fixes are:

- Repeated corruption at the same clock time could replace previous
  `.corrupt-*` files through POSIX rename. Unique suffixes now preserve every
  original across repeated incidents, including when the clock repeats.
- A primary with a valid header/checksum but an undecodable payload could
  overwrite a usable backup on the next commit. Backup replacement now
  requires a successfully decoded primary, preserving the usable backup.
- If both files disappeared after a verified native save, settings-only
  fallback could silently create a replacement empty store. The existing
  native save marker now blocks this path. Explicitly choosing to start
  fresh after acknowledged corruption clears the marker while retaining
  the set-aside files; that intentional recovery flow is separately tested.
- Protection availability was checked before staging but not before the
  rename. A new check after staging blocks either backup or primary rename
  if protection becomes unavailable. The typed protected-data error survives
  so startup can wait/retry rather than misreporting a successful save.
- Valid JSON with unsupported known-section container types could load as
  empty and later be overwritten by model defaults or startup migrations.
  App bootstrap now blocks before model loading or automatic writes. The
  original primary and complete migration copy remain byte-identical for
  all ten tested section types. Missing/null sections still receive normal
  Flutter-compatible defaults; individual unreadable array rows stay raw.
- `ENOTDIR` is now a read failure, rather than being reported as absence.
  A real filesystem test verifies the misplaced file is unchanged.

Additional tests cover all six injected initial-migration interruptions and
all six backup-recovery interruptions (crash, partial write and full disk at
staging/rename). Original preferences or recovery backup remain intact,
and a subsequent launch recovers the expected complete snapshot. A real
disk ledger containing 20,000 records preserves every record, numeric
lexeme, Unicode description, unknown record field and unknown section;
the previous primary becomes an exact-byte backup. App-level tests confirm
unreadable rows in all seven list sections survive startup, editing and two
relaunches, while unknown settings/budget/feature values remain unchanged.

Completed suites: **398 core tests in Debug**, **398 in Release**, **124
app-model tests**, **390 Flutter tests**, and clean Flutter analysis.
Release here means optimized core tests, not a signed distribution app.

Local archive inspection found 55 matching Flutter archives. The latest
archive (2026-09-27, 3.4.0 build 1) reports the matching bundle identifier,
team, application identifier and App Group. Its local development signature
trust check returned `CSSMERR_TP_NOT_TRUSTED`; this is not verification of a
distributed Flutter binary or of the final Swift release candidate. Actual
distribution signing and physical-device update behavior remain unverified.

Compatibility rerun: **68 report cases per zone (204 total: 198 stored-data
cases and six insight-view comparisons)** passed through the real Flutter
models in New York, Santiago and Beirut. Each zone's Flutter
report had no problems, and Swift's comparison against that report passed.
Optimized Release output was also generated, loaded by Flutter (66 store
cases plus two insight-view comparisons), and compared successfully with
Release Swift's calculations. `DEEP_MIGRATION_AUDIT_EVIDENCE.json` records
suite results, source hashes, binary identity and the archive check.

Installed-app rerun: `rehearsal/20260930-195723` passed S1 (upgrade, edit,
Flutter rollback), S3 (v1/bare legacy preferences), S4 (simulated locked
startup), S5 (damaged files) and S6 (malformed legacy ledger/envelope).
Every Dart problem list and every Swift/Flutter comparison was empty.
All **66 independent preservation/hash checks passed**. The verifier now
also checks every original value in the chosen v1 envelope, allowing only
new due transactions and advancing recurring cursors. Existing template
fields and every original transaction remain intact. Both malformed
legacy values were retained with no replacement store or ready summary.

These finite checks substantially improve confidence;
they do not establish that every possible storage/device condition has
been covered or that no future code change could introduce a regression.

### Remaining release requirements (after the additional audit)

- Install the current shipping Flutter App Store/TestFlight build on a
  spare iPhone with synthetic data, then install the actual Swift release
  candidate over it. Compare every record and setting, add/edit data,
  terminate/relaunch, and verify persistence and rollback.
- Exercise a real reboot/launch before first unlock and inspect protected
  data behavior; a simulator's injected lock cannot establish this.
- Verify the signed archive's application identifier, team, App Group,
  bundle/version settings and association with the existing App Store
  listing. The source uses provisional version 4.0.0, build 1.
- Repeat against supported iOS versions, including the oldest supported
  Swift iOS version (17), and legacy-only installs from skipped updates.

See `REAL_DEVICE_CHECKLISTS.md` for device steps. Keep the installable Flutter
build and all pre-native copies. An update must be installed over the existing
app; do not instruct users to delete/reinstall to migrate. Apple's
[deployment guidance](https://support.apple.com/guide/deployment/distribute-proprietary-in-house-apps-depce7cefc4d/web)
also describes retaining the same bundle identifier and avoiding deletion
when preserving data across replacement.
