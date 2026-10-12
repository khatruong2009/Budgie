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
WORK="${PARITY_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/budgie-parity.XXXXXX")}"
COPY="$WORK/budget_app"
FLUTTER_REF="flutter-final"
COMMIT="$(git -C "$REPO_ROOT" rev-parse "$FLUTTER_REF^{commit}")"

rm -rf "$COPY"
mkdir -p "$WORK"
git -C "$REPO_ROOT" archive --format=tar "$FLUTTER_REF" budget_app | tar -x -C "$WORK"

printf 'OPENAI_API_KEY=parity-harness-dummy-key\n' > "$COPY/.env"

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
    # Each generator runs under the zones it needs; see the test files.
    if wants logic_fixtures_test.dart; then
      # Santiago and Beirut have a DST change at midnight (a missing and a
      # repeated hour at the start/end of a day).
      for tz in America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago Asia/Beirut; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/logic_fixtures_test.dart "$@"
      done
    fi
    if wants format_fixtures_test.dart; then
      TZ=UTC PARITY_TZ=UTC flutter test test/parity/format_fixtures_test.dart "$@"
    fi
    if wants store_fixtures_test.dart; then
      TZ=America/New_York PARITY_TZ=America/New_York flutter test test/parity/store_fixtures_test.dart "$@"
    fi
    if wants legacy_fixtures_test.dart; then
      TZ=America/New_York PARITY_TZ=America/New_York flutter test test/parity/legacy_fixtures_test.dart "$@"
    fi
    if wants home_fixtures_test.dart; then
      TZ=America/New_York PARITY_TZ=America/New_York flutter test test/parity/home_fixtures_test.dart "$@"
    fi
    if wants spend_fixtures_test.dart; then
      TZ=America/New_York PARITY_TZ=America/New_York flutter test test/parity/spend_fixtures_test.dart "$@"
    fi
    if wants worth_fixtures_test.dart; then
      rm -rf "$FIXTURES/worth"
      for tz in America/New_York America/Santiago Australia/Lord_Howe Asia/Kolkata UTC; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/worth_fixtures_test.dart "$@"
      done
    fi
    if wants goals_fixtures_test.dart; then
      rm -rf "$FIXTURES/goals"
      for tz in America/New_York America/Santiago Australia/Lord_Howe Asia/Kolkata UTC; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/goals_fixtures_test.dart "$@"
      done
    fi
    if wants settings_fixtures_test.dart; then
      TZ=America/New_York PARITY_TZ=America/New_York flutter test test/parity/settings_fixtures_test.dart "$@"
    fi
    if wants categories_fixtures_test.dart; then
      TZ=America/New_York PARITY_TZ=America/New_York flutter test test/parity/categories_fixtures_test.dart "$@"
    fi
    if wants tags_fixtures_test.dart; then
      TZ=America/New_York PARITY_TZ=America/New_York flutter test test/parity/tags_fixtures_test.dart "$@"
    fi
    if wants recurring_fixtures_test.dart; then
      rm -rf "$FIXTURES/recurring"
      for tz in America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/recurring_fixtures_test.dart "$@"
      done
    fi
    if wants flow_fixtures_test.dart; then
      rm -rf "$FIXTURES/flow"
      for tz in America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/flow_fixtures_test.dart "$@"
      done
    fi
    if wants backup_fixtures_test.dart; then
      rm -rf "$FIXTURES/backup"
      # New York first: it also writes the zone-independent files.
      for tz in America/New_York Australia/Lord_Howe UTC America/Santiago; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/backup_fixtures_test.dart "$@"
      done
    fi
    if wants csv_import_fixtures_test.dart; then
      rm -rf "$FIXTURES/csvimport"
      # New York first: it also writes the zone-independent files.
      for tz in America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/csv_import_fixtures_test.dart "$@"
      done
    fi
    if wants insight_fixtures_test.dart; then
      rm -rf "$FIXTURES/insights"
      for tz in America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/insight_fixtures_test.dart "$@"
      done
    fi
    if wants voice_fixtures_test.dart; then
      rm -rf "$FIXTURES/voice"
      for tz in America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago Asia/Beirut; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/voice_fixtures_test.dart "$@"
      done
    fi
    # Generators owned by later Phase 5.1 chunks. A missing file is skipped so
    # the script works on a branch that does not have it yet.
    has() { [ -f "$HARNESS/parity/$1" ]; }
    if has launch_fixtures_test.dart && wants launch_fixtures_test.dart; then
      rm -rf "$FIXTURES/launch"
      for tz in America/New_York UTC Australia/Lord_Howe Asia/Kolkata America/Santiago Asia/Beirut; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/launch_fixtures_test.dart "$@"
      done
    fi
    if has transactions_fixtures_test.dart && wants transactions_fixtures_test.dart; then
      rm -rf "$FIXTURES/transactions"
      for tz in America/New_York America/Santiago Australia/Lord_Howe; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/transactions_fixtures_test.dart "$@"
      done
    fi
    if has recurring_form_fixtures_test.dart && wants recurring_form_fixtures_test.dart; then
      rm -rf "$FIXTURES/recurring_form"
      for tz in America/New_York America/Santiago Australia/Lord_Howe; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/recurring_form_fixtures_test.dart "$@"
      done
    fi
    if has home_page_fixtures_test.dart && wants home_page_fixtures_test.dart; then
      # Writes home/tz/<zone>/page.json; home_fixtures_test.dart keeps home/tz.
      rm -rf "$FIXTURES/home/tz"
      for tz in America/New_York America/Santiago; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/home_page_fixtures_test.dart "$@"
      done
    fi
    if has month_list_fixtures_test.dart && wants month_list_fixtures_test.dart; then
      rm -rf "$FIXTURES/monthlist"
      for tz in America/New_York America/Santiago; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/month_list_fixtures_test.dart "$@"
      done
    fi
    if has voice_request_fixtures_test.dart && wants voice_request_fixtures_test.dart; then
      rm -rf "$FIXTURES/voicerequest"
      for tz in America/New_York America/Santiago; do
        TZ="$tz" PARITY_TZ="$tz" flutter test test/parity/voice_request_fixtures_test.dart "$@"
      done
    fi
    ;;
  verify)
    export SWIFT_OUT="${SWIFT_OUT:-$FIXTURES/swift-written}"
    # The zone the Swift side wrote its stores in (BUDGIE_SWIFT_ZONE).
    VERIFY_TZ="${VERIFY_TZ:-America/New_York}"
    TZ="$VERIFY_TZ" PARITY_TZ="$VERIFY_TZ" flutter test test/parity/verify_swift_output_test.dart "$@"
    ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
