#!/bin/bash
# Runs the tests in several time zones and says which tests fail in which zone.
#
# Tests that build their data in a calendar of their own (UTC) while the code reads the zone of
# the Mac pass on one Mac and fail on another (the release of 2.3 failed six tests on a Mac in
# Asia/Baku). The app tests pin the zone of the process themselves (OHMYMONEY_TEST_TZ; UTC when
# it is not set: Apps/macOS/Tests/TestTimeZone.swift); the package tests read the zone of the
# process, which `TZ` sets on macOS. This script sets both, zone by zone.
#
# Usage: scripts/test-zones.sh [--zones "UTC Asia/Baku"] [--only core|db|app] [--classes "A B"]
#   --zones    zones to run in (default: UTC Europe/Moscow Asia/Baku America/Los_Angeles
#              Pacific/Auckland Asia/Kolkata)
#   --only     one part only: AppCore, AppDatabase or the app (default: all three)
#   --classes  app only: classes of OhMyMoneyTests to run (`make test-one`, one after another)
#              instead of the whole bundle (`make test`)
# The build folders are the ones of the Makefile; a lane sets BUILD_ROOT, DERIVED, LOGS and
# SPM_SCRATCH in the environment, DERIVED and the like in MAKE_ARGS ("DERIVED=... SPM_SCRATCH=...").
# Not part of `make verify`: it runs the whole suite once per zone.
set -u

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here" || exit 1

zones="UTC Europe/Moscow Asia/Baku America/Los_Angeles Pacific/Auckland Asia/Kolkata"
only="core db app"
classes=""
while [ $# -gt 0 ]; do
  case "$1" in
    --zones) zones="$2"; shift 2 ;;
    --only) only="$2"; shift 2 ;;
    --classes) classes="$2"; shift 2 ;;
    *) echo "test-zones: unknown argument $1" >&2; exit 2 ;;
  esac
done

root="${BUILD_ROOT:-$HOME/Library/Developer/OhMyMoney}"
scratch="${SPM_SCRATCH:-$root}"
logs="${LOGS:-$root/logs}/zones"
mkdir -p "$logs"
swift=(xcrun --toolchain default swift)
summary="$logs/summary.txt"
: > "$summary"

# Prints the failing tests of one log, whatever the runner (Swift Testing, XCTest).
failures() {
  grep -E "^test-parallel: failed: |✘ Test .* recorded an issue|^Test Case '.*' failed" "$1" 2>/dev/null |
    sed -E 's/^test-parallel: failed: //; s/^.*✘ Test (.*) recorded.*$/\1/; s/^Test Case .-\[(.*)\]. failed.*$/\1/' |
    sort -u
}

record() { # zone part status log
  if [ "$3" -eq 0 ]; then
    echo "ok    $1  $2" | tee -a "$summary"
  else
    echo "FAIL  $1  $2  (log: $4)" | tee -a "$summary"
    failures "$4" | sed 's/^/        /' | tee -a "$summary"
  fi
}

for zone in $zones; do
  tag="${zone//\//_}"
  case " $only " in *" core "*)
    log="$logs/core-$tag.log"
    TZ="$zone" "${swift[@]}" test --package-path Packages/AppCore --scratch-path "$scratch/spm-appcore" \
      --skip PerformanceTests > "$log" 2>&1
    record "$zone" AppCore $? "$log" ;;
  esac
  case " $only " in *" db "*)
    log="$logs/db-$tag.log"
    TZ="$zone" "${swift[@]}" test --package-path Packages/AppDatabase --scratch-path "$scratch/spm-appdatabase" \
      --skip PerformanceTests > "$log" 2>&1
    record "$zone" AppDatabase $? "$log" ;;
  esac
  case " $only " in *" app "*)
    # TEST_RUNNER_ hands the variable to the test host; the bundle sets the zone from it.
    export OHMYMONEY_TEST_TZ="$zone" TEST_RUNNER_OHMYMONEY_TEST_TZ="$zone"
    if [ -n "$classes" ]; then
      for class in $classes; do
        log="$logs/app-$tag-$class.log"
        make test-one T="OhMyMoneyTests/$class" LOGS="$logs/app-$tag" ${MAKE_ARGS:-} > "$log" 2>&1
        record "$zone" "app $class" $? "$log"
      done
    else
      log="$logs/app-$tag.log"
      make test LOGS="$logs/app-$tag" ${MAKE_ARGS:-} > "$log" 2>&1
      record "$zone" "app" $? "$log"
    fi
    unset OHMYMONEY_TEST_TZ TEST_RUNNER_OHMYMONEY_TEST_TZ ;;
  esac
done

echo
echo "test-zones: summary in $summary"
! grep -q '^FAIL' "$summary"
