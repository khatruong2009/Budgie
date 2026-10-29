# Real-device checklists (beads budgie-uia.8 and budgie-uia.9)

Two pre-ship checks the simulator cannot do. Both need the owner's approval
and a **spare** physical iPhone with synthetic data only. Never run them on
the phone that holds real data; if a phone has any real Budgie data, export
a backup (Settings > Export backup) and keep it off the device first.

Simulator counterparts: UPGRADE_VERIFICATION.md (Test plan, S1-S6) and
`native/scripts/upgrade_rehearsal.py`. Results go in UPGRADE_VERIFICATION.md
(Results part) under a "Real device" heading, with the device model, iOS version, the two
build numbers and the date.

## Common setup (both checklists)

1. Spare iPhone on iOS 17 or later, a passcode set (App Lock and data
   protection need one), Developer Mode on, paired and trusted with this Mac.
   Note its identifier:
   ```bash
   xcrun devicectl list devices
   ```
2. Build the Swift app (Debug, so the rehearsal hooks exist; no OpenAI key
   needed, voice then shows "not configured"):
   ```bash
   cd native && xcodegen generate && xcodebuild -project Budgie.xcodeproj -scheme Budgie -configuration Debug -destination 'platform=iOS,id=<DEVICE>' -derivedDataPath /tmp/budgie-device -allowProvisioningUpdates build
   ```
   The app is `/tmp/budgie-device/Build/Products/Debug-iphoneos/Budgie.app`.
3. A synthetic backup file, made by the real Flutter encoder (the harness's
   `typical` store; its dates are around September 2026 and App Lock is on):
   ```bash
   python3 -c "import json;c=json.load(open('native/Fixtures/backup/tz/America_New_York/encode.json'))['cases'];open('/tmp/budgie-typical-backup.json','w').write(next(x['expected'] for x in c if x['store']=='typical'))"
   ```
   AirDrop it to the device and save it to Files > On My iPhone.
4. Commands used below (`<DEVICE>` from step 1):
   - install without launching:
     `xcrun devicectl device install app --device <DEVICE> /tmp/budgie-device/Build/Products/Debug-iphoneos/Budgie.app`
   - launch with a hook:
     `xcrun devicectl device process launch --device <DEVICE> --terminate-existing --environment-variables '{"BUDGIE_REHEARSAL_SUMMARY":"1"}' com.khatruong.budgetbuddy`
   - pull the app's data (only while a development-signed build is installed;
     a TestFlight build's container can't be read):
     `xcrun devicectl device copy from --device <DEVICE> --domain-type appDataContainer --domain-identifier com.khatruong.budgetbuddy --source Library --destination <dir>/Library`
     If devicectl refuses, use Xcode > Devices and Simulators > Budgie >
     Download Container instead.
   - device logs (after unlocking):
     `sudo log collect --device-udid <DEVICE> --last 2h --output /tmp/budgie.logarchive`, then
     `log show /tmp/budgie.logarchive --predicate 'subsystem == "com.khatruong.budgetbuddy"' --info`
5. Check a pull against the real Flutter models (the same code
   `upgrade_rehearsal.py` uses):
   ```bash
   native/scripts/upgrade_rehearsal.py --compare-pulled <dir> [<dir> ...]
   ```
   Each `<dir>` is a `devicectl copy from` destination (it holds `Library/`).
   The script runs the Flutter models over `Library/Application Support/financial_store`
   with the pulled preferences, reports any rejected, skipped or reset data,
   and compares with `Library/Caches/budgie-rehearsal.json` when the Swift
   app wrote one.

## budgie-uia.8: prewarm and locked launch

What it proves (MIGRATION_SPEC section 6, risks R4 and R20): when iOS starts
the app before the first unlock after a reboot, the app reads nothing,
writes nothing (no store write, no `pre-native-migration/` folder, no
preferences), and loads normally once the phone is unlocked.

Store files are `completeUntilFirstUserAuthentication`, so only launches
before the first unlock after a reboot are at risk. iOS decides when to
prewarm from usage; it can't be forced. The launch log tells you whether a
prewarm happened: each launch logs `launch prewarm=<0|1>
protectedData=<available|unavailable>` (subsystem `com.khatruong.budgetbuddy`,
category `launch`, level notice, so it persists), and bootstrap logs
`protected data available after <seconds>s` (only when it had to wait),
`pre-native snapshot <created|exists|failed>` and `store loaded revision=<n>`
(or `store load failed <kind>`). Read them with
`log show --predicate 'subsystem == "com.khatruong.budgetbuddy" AND category == "launch"'`
(or Console.app with the phone selected).

Steps:
1. [ ] Install the Flutter TestFlight build. Complete the tour, import the
   synthetic backup (Settings > Import backup), and use the app a few times
   over a day or so, so iOS learns to prewarm Budgie.
2. [ ] Install the Swift build over it (install command above). **Don't
   launch it.** Pull the container into `8-before/` and note the store file
   times: `ls -lT 8-before/Library/Application\ Support/financial_store`.
   There must be no `pre-native-migration/` folder yet.
3. [ ] Restart the phone. **Don't unlock it.** Leave it on charge, screen off,
   for at least 20 minutes. Note the time you unlock.
4. [ ] Unlock, but don't open Budgie. Collect logs. Look for a Budgie
   `launch prewarm=1 protectedData=unavailable` line before your unlock time.
   - If none: iOS didn't prewarm. Repeat from step 3, after opening the Swift
     app a few times first (so it's the recently used app). Record how many
     tries it took, or that it never happened.
5. [ ] When a prewarm happened before the unlock, check in the log and in a new
   pull (`8-after-unlock/`, still without opening Budgie):
   - [ ] no `store loaded` line and no `pre-native snapshot` line timed before the unlock;
   - [ ] the store files' times and bytes equal `8-before/`
     (`cmp` each file), or they changed only after the unlock time;
   - [ ] any `pre-native-migration/<stamp>/` folder is stamped after the unlock time.
6. [ ] Open Budgie. The Flutter data shows (same totals as Flutter showed),
   no "couldn't be read" screen, no unsaved-changes banner. A
   `pre-native-migration/<stamp>/COMPLETE` folder now exists (pull
   `8-opened/`). Run `--compare-pulled 8-opened` and expect no problems.
7. [ ] Repeat steps 3-6 once with the Swift app already migrated (a second
   prewarm must also write nothing before the unlock).
8. [ ] Optional sanity run of the gate on device (Debug only): launch with
   `{"BUDGIE_SIMULATE_LOCKED_SECONDS":"15"}`. "Unlock your iPhone to continue"
   shows for 15 s, then the data loads.

## budgie-uia.9: upgrade and downgrade rehearsal (Flutter TestFlight, Swift, Flutter)

What it proves: the Swift app installed over the Flutter App Store build
keeps everything, and the Flutter build installed back over the Swift app
reads what Swift wrote. It also covers the home-screen widget and the quick
actions across the switches. This is simulator scenario S1 (plus the
widget checks of `system_flow.sh`) on hardware.

Steps:
1. [ ] Delete Budgie from the spare phone if present. Install the latest
   Flutter build from TestFlight. Complete the tour. Import the synthetic
   backup. Then, in Flutter, make one of each: an expense, an income, a
   monthly recurring template, a budget limit, a savings goal with an
   allocation, a net worth account with this month's value, a category
   rename, a tag and a rule; set theme Dark and currency GBP.
2. [ ] Put both widgets on the home screen (Budget Quick Add and Voice Add).
   Long-press the icon: Add Expense, Add Income and Add by Voice are offered.
3. [ ] Screenshot every tab (Home, Worth, Goals, Spend, Flow, Settings). Then
   Settings > Export backup, save it as `flutter-before.json`, and AirDrop it
   to the Mac.
4. [ ] Install the Swift build over it. **Don't delete the app first.**
   Before launching, pull the container into `9-1-flutter/`.
5. [ ] Launch Swift with `BUDGIE_REHEARSAL_SUMMARY=1`. Then check:
   - [ ] no tour, theme Dark, currency GBP, and every tab shows the same
     numbers as the step 3 screenshots;
   - [ ] the widget still sits on the home screen, shows this month's cash
     flow, and its Income and Expense buttons open Swift's forms; the Voice
     Add widget opens the voice sheet;
   - [ ] the quick actions (after this first launch) are Add Expense, Add
     Income and Add by Voice, and each opens the right screen;
   - [ ] Safari `budgetapp://add-expense` opens the expense form.
6. [ ] Pull into `9-2-swift/`. Check:
   - [ ] `pre-native-migration/<stamp>/COMPLETE` exists;
   - [ ] its store files are byte-identical to `9-1-flutter/`'s (`cmp`).
   Then run `--compare-pulled 9-1-flutter 9-2-swift` and expect 0
   differences and no problems.
7. [ ] Settings > Export backup in Swift. `swift-after-upgrade.json` must
   equal `flutter-before.json` except `exportedAt` (and `appVersion`):
   ```bash
   diff <(grep -v -e exportedAt -e appVersion flutter-before.json) <(grep -v -e exportedAt -e appVersion swift-after-upgrade.json)
   ```
8. [ ] Make Swift-side edits: launch with `BUDGIE_REHEARSAL_EDIT=1`, then by
   hand add a transaction, edit one, delete one, change a budget, allocate
   to a goal, update a net worth value, rename a category, add a tag and a
   rule. Relaunch with `BUDGIE_REHEARSAL_SUMMARY=1` and pull `9-3-swift-edited/`.
   Run `--compare-pulled 9-3-swift-edited` and expect no problems.
9. [ ] Downgrade: install the Flutter build from TestFlight over the Swift app.
   Launch it:
   - [ ] it renders (no black screen) and shows the Swift edits;
   - [ ] no "couldn't be read" or reset data; the widget and its buttons
     still work (they open Flutter's dialogs); the quick actions work.
   - [ ] Flutter's Settings > Export backup, `flutter-after-downgrade.json`,
     must equal a Swift export taken just before the downgrade, except
     `exportedAt` and `appVersion`.
10. [ ] Reinstall the Swift build over it without launching, pull
    `9-4-flutter-back/`, and check:
    - [ ] no `.corrupt-*` files in `financial_store/`;
    - [ ] `--compare-pulled 9-4-flutter-back` reports no problems.
11. [ ] Launch Swift again. A second `pre-native-migration/<stamp>/` is
    taken (the store was written by Flutter since Swift's last commit).
    The data is intact.
12. [ ] Record the results in UPGRADE_VERIFICATION.md ("Real device").
