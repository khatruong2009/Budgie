#!/usr/bin/env bash
# Home screen integration check on a dedicated "Budgie-System" simulator
# (created fresh; no other simulator is touched):
#   1. the Flutter build is installed and launched once (it registers its
#      three dynamic quick actions, including "Add by Voice"), then the
#      onboarding flag is preset so no tour holds the routes back;
#   2. SystemIntegrationUITests installs the Swift build over it, revokes its
#      microphone (SpringBoard launches cannot take launch environment, so
#      the voice sheet must reach its "Microphone access is off" error on its
#      own, with no system prompt and no recording) and drives SpringBoard:
#      leftover Flutter quick action, Swift quick actions, budgetapp:// links
#      through the system prompt (voice links open the voice sheet), and the
#      Quick Add widget.
# Usage: system_flow.sh <path/to/flutter/Runner.app>
# Build the Runner.app from the flutter-final tag (budget_app/ is no longer
# in the tree) with `upgrade_rehearsal.py --build-only`, which prints its path.
set -euo pipefail
. "$(dirname "$0")/lib/sim.sh"
FLUTTER_APP="${1:?path to the Flutter Runner.app}"
NATIVE="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/native"
WORK="${TMPDIR:-/tmp}/budgie-system-flow"
for old in $(xcrun simctl list devices | grep "    Budgie-System (" | grep -oE '[0-9A-F-]{36}'); do
  xcrun simctl shutdown "$old" 2>/dev/null || true; xcrun simctl delete "$old"
done
RUNTIME=$(sim_runtime "iPhone 17 Pro")
UDID=$(xcrun simctl create Budgie-System "iPhone 17 Pro" "$RUNTIME")
# Shut the simulator down on exit, whether the run passed or failed (the
# device and its xcresult stay for inspection).
trap 'xcrun simctl shutdown "$UDID" 2>/dev/null || true' EXIT
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$FLUTTER_APP"
xcrun simctl launch "$UDID" com.khatruong.budgetbuddy >/dev/null
sleep 15
xcrun simctl terminate "$UDID" com.khatruong.budgetbuddy || true
# Nobody finished the Flutter build's tour, so the onboarding flag is absent
# and the Swift app would keep every quick action and link queued behind its
# own tour. Preset it as for a user who finished the tour: a CFBoolean under
# flutter.onboarding_completed in the app container's plist. `simctl spawn
# defaults write` does not reach the container, and the plist is only read
# back reliably when edited with the simulator shut down.
PREFS="$(xcrun simctl get_app_container "$UDID" com.khatruong.budgetbuddy data)/Library/Preferences/com.khatruong.budgetbuddy.plist"
xcrun simctl shutdown "$UDID"
python3 - "$PREFS" <<'PY'
import os, plistlib, sys
path = sys.argv[1]
domain = {}
if os.path.exists(path):
    with open(path, "rb") as f:
        domain = plistlib.load(f)
domain["flutter.onboarding_completed"] = True
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "wb") as f:
    plistlib.dump(domain, f, fmt=plistlib.FMT_BINARY)
PY
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
cd "$NATIVE" && xcodegen generate >/dev/null
rm -rf "$WORK/result.xcresult"
# grep finding nothing is fine; a failed build is not (PIPESTATUS).
set +e
xcodebuild build-for-testing -project Budgie.xcodeproj -scheme Budgie -destination "id=$UDID" \
  -derivedDataPath "$WORK/derived" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual | grep -E "error:|\*\* TEST BUILD"
BUILD_STATUS=${PIPESTATUS[0]}
set -e
if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "build-for-testing failed (exit $BUILD_STATUS)" >&2
  exit "$BUILD_STATUS"
fi
# Install the Swift build over the Flutter one ourselves, so the first test
# sees exactly "Swift installed, not yet launched" (xcodebuild's own install
# of the app under test can land after the first test has started).
xcrun simctl install "$UDID" "$WORK/derived/Build/Products/Debug-iphonesimulator/Budgie.app"
# Every voice quick action and link opens the voice sheet; with the microphone
# denied it shows the same error each time, with no system prompt.
xcrun simctl privacy "$UDID" revoke microphone com.khatruong.budgetbuddy
set +e
xcodebuild test-without-building -project Budgie.xcodeproj -scheme Budgie -destination "id=$UDID" \
  -only-testing:BudgieUITests/SystemIntegrationUITests -resultBundlePath "$WORK/result.xcresult" \
  -derivedDataPath "$WORK/derived" 2>&1 | grep -E "Test Case|XCTAssert|error:|\*\* TEST"
STATUS=${PIPESTATUS[0]}
set -e
GROUP=$(xcrun simctl get_app_container "$UDID" com.khatruong.budgetbuddy groups | grep group.com.khatruong.budgetbuddy | awk '{print $2}')
echo "App Group widget data:"; plutil -p "$GROUP/Library/Preferences/group.com.khatruong.budgetbuddy.plist" || true
xcrun simctl io "$UDID" screenshot "$WORK/home-screen.png" >/dev/null 2>&1 || true
echo "UDID=$UDID result=$WORK/result.xcresult status=$STATUS home=$WORK/home-screen.png"
exit $STATUS
