#!/usr/bin/env bash
# Runs the Dart parity harness against an exported copy of budget_app.
#
# budget_app/ was removed from the tree after 4.0.0 shipped; the copy is
# taken from the `flutter-final` tag (git archive), the last commit that has
# it, so fixtures are tied to that commit.
#
# In the copy, and only there:
#   - a stub .env is added (budget_app bundles .env as an asset; its tests
#     cannot build without one). It holds a dummy key.
#   - every `DateTime.now()` in lib/ becomes `parityNow()` and every
#     `Uuid().v4()` becomes `parityUuidV4()` (lib/parity_clock.dart). Both
#     behave exactly as before unless a test pins the clock or seeds UUIDs.
#     These are the only changes to app code and they are mechanical.
#   - the harness tests are copied to test/parity/.
#
# Usage: native/ParityHarness/run.sh <mode> [flutter test args...]
#   mode = export <dir> -> only the export step: <dir>/budget_app is the
#                       `flutter-final` copy with the stub .env (no seam
#                       rewrite, no harness tests); upgrade_rehearsal.py
#                       builds the Flutter app from it
#   mode = generate  -> writes native/Fixtures/
#   mode = verify    -> loads Swift-written files from $SWIFT_OUT (default
#                       native/Fixtures/swift-written) through the Dart store
#
# PARITY_ONLY="a_test.dart b_test.dart" limits `generate` to those harness
# files (each run under every zone it normally uses), so adding a fixture
# does not rewrite the rest of the corpus.
set -euo pipefail

MODE="${1:?usage: run.sh generate|verify [args]}"
shift || true

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
HARNESS="$REPO_ROOT/native/ParityHarness"
FIXTURES="$REPO_ROOT/native/Fixtures"
if [ "$MODE" = export ]; then
  WORK="${1:?usage: run.sh export <dir>}"
  shift
else
  WORK="${PARITY_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/budgie-parity.XXXXXX")}"
fi
COPY="$WORK/budget_app"
FLUTTER_REF="flutter-final"
COMMIT="$(git -C "$REPO_ROOT" rev-parse "$FLUTTER_REF^{commit}")"

rm -rf "$COPY"
mkdir -p "$WORK"
git -C "$REPO_ROOT" archive --format=tar "$FLUTTER_REF" budget_app | tar -x -C "$WORK"

printf 'OPENAI_API_KEY=parity-harness-dummy-key\n' > "$COPY/.env"
if [ "$MODE" = export ]; then
  echo "exported $FLUTTER_REF ($COMMIT) to $COPY"
  exit 0
fi

cp "$HARNESS/parity_clock.dart" "$COPY/lib/parity_clock.dart"
count=0
while IFS= read -r file; do
  n=$(grep -cE 'DateTime\.now\(\)|Uuid\(\)\.v4\(\)|_uuid\.v4\(\)' "$file" || true)
  count=$((count + n))
  perl -0pi -e 's/DateTime\.now\(\)/parityNow()/g; s/(const )?Uuid\(\)\.v4\(\)/parityUuidV4()/g; s/_uuid\.v4\(\)/parityUuidV4()/g' "$file"
  perl -0pi -e "s/\A/import 'package:budget_app\/parity_clock.dart';\n/" "$file"
done < <(grep -rlE 'DateTime\.now\(\)|Uuid\(\)\.v4\(\)|_uuid\.v4\(\)' "$COPY/lib" | grep -v parity_clock.dart)
if grep -rqE 'DateTime\.now\(\)|Uuid\(\)\.v4\(\)|_uuid\.v4\(\)' "$COPY/lib" --exclude=parity_clock.dart; then
  echo "clock/uuid rewrite incomplete" >&2; exit 1
fi
echo "seams: rewrote $count DateTime.now()/Uuid().v4() call sites"

mkdir -p "$COPY/test/parity"
cp "$HARNESS"/parity/*.dart "$COPY/test/parity/"

cd "$COPY"
flutter pub get --offline >/dev/null 2>&1 || flutter pub get >/dev/null 2>&1

export PARITY_FIXTURES="$FIXTURES"
export PARITY_COMMIT="$COMMIT"
case "$MODE" in
  generate)
    mkdir -p "$FIXTURES"
    wants() { [ -z "${PARITY_ONLY:-}" ] || [[ " $PARITY_ONLY " == *" $1 "* ]]; }
    # One line per generator: test file | fixture dir wiped first (blank =
    # none) | zones, run in this order. Each runs under the zones it needs;
    # see the test files. Notes on particular rows:
    #   logic: Santiago and Beirut have a DST change at midnight (a missing
    #     and a repeated hour at the start/end of a day).
    #   backup, csv_import: New York first, it also writes the
    #     zone-independent files.
    #   home_page: writes home/tz/<zone>/page.json; home_fixtures_test.dart
    #     keeps home/tz.
    # (fd 3 so that flutter keeps the script's own stdin.)
    while IFS='|' read -r -u 3 file wipe zones; do
      wants "$file" || continue
      [ -z "$wipe" ] || rm -rf "$FIXTURES/$wipe"
      for tz in $zones; do
        TZ="$tz" PARITY_TZ="$tz" flutter test "test/parity/$file" "$@"
      done
    done 3<<'TABLE'
logic_fixtures_test.dart||America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago Asia/Beirut
format_fixtures_test.dart||UTC
store_fixtures_test.dart||America/New_York
legacy_fixtures_test.dart||America/New_York
home_fixtures_test.dart||America/New_York
spend_fixtures_test.dart||America/New_York
worth_fixtures_test.dart|worth|America/New_York America/Santiago Australia/Lord_Howe Asia/Kolkata UTC
goals_fixtures_test.dart|goals|America/New_York America/Santiago Australia/Lord_Howe Asia/Kolkata UTC
settings_fixtures_test.dart||America/New_York
categories_fixtures_test.dart||America/New_York
tags_fixtures_test.dart||America/New_York
recurring_fixtures_test.dart|recurring|America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago
flow_fixtures_test.dart|flow|America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago
backup_fixtures_test.dart|backup|America/New_York Australia/Lord_Howe UTC America/Santiago
csv_import_fixtures_test.dart|csvimport|America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago
insight_fixtures_test.dart|insights|America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago
voice_fixtures_test.dart|voice|America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago Asia/Beirut
launch_fixtures_test.dart|launch|America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago Asia/Beirut
transactions_fixtures_test.dart|transactions|America/New_York America/Santiago Australia/Lord_Howe
recurring_form_fixtures_test.dart|recurring_form|America/New_York America/Santiago Australia/Lord_Howe
home_page_fixtures_test.dart|home/tz|America/New_York America/Santiago
month_list_fixtures_test.dart|monthlist|America/New_York America/Santiago
voice_request_fixtures_test.dart|voicerequest|America/New_York America/Santiago
TABLE
    ;;
  verify)
    export SWIFT_OUT="${SWIFT_OUT:-$FIXTURES/swift-written}"
    # The zone the Swift side wrote its stores in (BUDGIE_SWIFT_ZONE).
    VERIFY_TZ="${VERIFY_TZ:-America/New_York}"
    TZ="$VERIFY_TZ" PARITY_TZ="$VERIFY_TZ" flutter test test/parity/verify_swift_output_test.dart "$@"
    ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
