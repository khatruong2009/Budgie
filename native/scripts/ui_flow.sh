#!/usr/bin/env bash
# Runs the XCUITest MVP flow on a fresh "Budgie-UITest" simulator (created
# if missing; no other simulator is touched), then loads the store it wrote
# through the real Flutter models (ParityHarness verify mode). The simulator
# is shut down on exit, whether the run passed or failed.
set -euo pipefail
. "$(dirname "$0")/lib/sim.sh"
NATIVE="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/native"
WORK="${TMPDIR:-/tmp}/budgie-ui-flow"
UDID=$(xcrun simctl list devices | grep "Budgie-UITest (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)
if [ -z "$UDID" ]; then
  RUNTIME=$(sim_runtime "iPhone 17 Pro")
  UDID=$(xcrun simctl create Budgie-UITest "iPhone 17 Pro" "$RUNTIME")
fi
trap 'xcrun simctl shutdown "$UDID" 2>/dev/null || true' EXIT
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"
cd "$NATIVE" && xcodegen generate >/dev/null
# SystemIntegrationUITests needs the Flutter-prepared simulator of
# system_flow.sh, so only the app tests, the Categories flow (its moves,
# archive / restore and rename cascade; it deletes its expense and archives
# its category), the Insights flow, the MVP flow, the onboarding tour and
# the recurring flow run here. Classes run in name order, so the Insights
# flow (it needs a store without transactions and deletes the six rows it
# adds; its snooze and dismissal stay in preferences only) runs before the
# MVP flow leaves its rows. The tour tests write no financial data; the
# recurring flow deletes its templates and generated rows, leaving an empty
# recurringTransactions section it wrote itself. So the store pulled below
# holds the earlier flows' data plus that Swift-written section.
xcodebuild test -project Budgie.xcodeproj -scheme Budgie -destination "id=$UDID" \
  -only-testing:BudgieAppTests -only-testing:BudgieUITests/CategoriesUITests \
  -only-testing:BudgieUITests/InsightsUITests \
  -only-testing:BudgieUITests/MVPFlowUITests \
  -only-testing:BudgieUITests/OnboardingUITests \
  -only-testing:BudgieUITests/RecurringUITests \
  -derivedDataPath "$WORK/derived" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual | grep -E "Test Case|\*\* TEST"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
CONTAINER=$(xcrun simctl get_app_container "$UDID" com.khatruong.budgetbuddy data)
rm -rf "$WORK/out" && mkdir -p "$WORK/out/ui-flow"
cp -R "$CONTAINER/Library/Application Support/financial_store" "$WORK/out/ui-flow/"
echo '{}' > "$WORK/out/ui-flow/prefs.json"
xcrun simctl shutdown "$UDID"
SWIFT_OUT="$WORK/out" "$NATIVE/ParityHarness/run.sh" verify
echo "Store written by the UI flow: $WORK/out/ui-flow"
