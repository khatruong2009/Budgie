#!/bin/bash
# Performance lane (docs/PERFORMANCE.md): builds the Debug configuration with
# optimisation forced on (Debug is needed for the BUDGIE_SKIP_ONBOARDING
# hook; -Onone would make the numbers meaningless),
# seeds the 10,000-row store on ONE simulator, and runs PerformanceUITests.
#
# Usage:
#   perf_run.sh build  <udid> <derived-data-dir>
#   perf_run.sh run    <udid> <derived-data-dir> <result-dir> <name> [only-testing ...]
#
# `run` installs the built app, seeds the store, sets the appearance, and
# runs the tests without building. Environment:
#   PERF_APPEARANCE=light|dark   (default light)
#   PERF_ITERATIONS=10
#   PERF_ROWS=400                a smaller store (perf_seed.py --rows)
# Results: <result-dir>/<name>.xcresult and <name>.metrics.json.
# Needs the simulator booted by you (xcrun simctl boot <udid>). One
# xcodebuild at a time; check `sysctl -n vm.loadavg` first.
set -euo pipefail

mode="${1:?build|run}"
udid="${2:?simulator udid}"
derived="${3:?derived data dir}"
here="$(cd "$(dirname "$0")" && pwd)"
native="$(dirname "$here")"

load="$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print int($1)}')"
while [ "$load" -gt 150 ]; do
  echo "load $load > 150, waiting"
  sleep 60
  load="$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print int($1)}')"
done

common=(
  -project "$native/Budgie.xcodeproj" -scheme Budgie
  -configuration Debug
  -destination "id=$udid"
  -derivedDataPath "$derived"
  -collect-test-diagnostics never
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
  SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s ONLY_ACTIVE_ARCH=YES
)

case "$mode" in
build)
  xcodebuild "${common[@]}" build-for-testing
  ;;
run)
  results="${4:?result dir}"
  name="${5:?result name}"
  shift 5
  mkdir -p "$results"
  app="$(find "$derived/Build/Products" -maxdepth 2 -name Budgie.app | head -1)"
  [ -n "$app" ] || { echo "no Budgie.app under $derived"; exit 1; }
  xcrun simctl install "$udid" "$app"
  if [ -n "${PERF_ROWS:-}" ]; then python3 "$here/perf_seed.py" --rows "$PERF_ROWS" "$udid"; else python3 "$here/perf_seed.py" "$udid"; fi
  xcrun simctl ui "$udid" appearance "${PERF_APPEARANCE:-light}"
  only=()
  for t in "$@"; do only+=(-only-testing "$t"); done
  rm -rf "$results/$name.xcresult"
  export TEST_RUNNER_BUDGIE_PERF=1
  export TEST_RUNNER_BUDGIE_PERF_ITERATIONS="${PERF_ITERATIONS:-10}"
  set +e
  xcodebuild "${common[@]}" -resultBundlePath "$results/$name.xcresult" "${only[@]}" test-without-building
  status=$?
  set -e
  xcrun xcresulttool get test-results summary --path "$results/$name.xcresult" > "$results/$name.summary.json" || true
  xcrun xcresulttool get test-results metrics --path "$results/$name.xcresult" > "$results/$name.metrics.json" || true
  exit $status
  ;;
*)
  echo "usage: $0 build|run ..."
  exit 2
  ;;
esac
