#!/bin/bash
# A test file that builds its data in a UTC calendar and records an operation with
# `materialize()` without a `timeZone:` writes the zone of the Mac into the operation (0491), so
# the ledger reads its day in the Mac's zone, not in the test's calendar: the test passes in one
# zone and fails in another (the release of 2.3, six tests in Asia/Baku).
#
# This check fails on such a file unless it is named in scripts/test-zones-allow.txt — the files
# that `scripts/test-zones.sh` ran green in every zone. Say `timeZone: calendar.timeZone` in the
# call, or, when the file is zone-independent for a reason, run the zones and add it to the list.
#
# Usage: check-test-zones.sh
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
allow=scripts/test-zones-allow.txt
status=0
files=$(grep -rlE 'CalendarContext\.utc|secondsFromGMT: 0|TimeZone\(identifier: "(UTC|GMT)"\)' \
  Apps/macOS/Tests Apps/iOS/Tests Packages/*/Tests --include='*.swift' 2>/dev/null)
for file in $files; do
  grep -v "^#" "$allow" 2>/dev/null | grep -qxF "$file" && continue
  hits=$(/usr/bin/perl -0777 -ne '
    while (/\.materialize\((?!transactionId)((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)/g) {
      my $args = $1;
      next if $args =~ /timeZone:/;
      my $line = 1 + (substr($_, 0, $-[0]) =~ tr/\n//);
      print "$ARGV:$line\n";
    }' "$file")
  if [ -n "$hits" ]; then
    echo "$hits" | sed 's/$/: materialize() without timeZone: in a file with a UTC calendar/'
    status=1
  fi
done
[ $status -eq 0 ] && echo "check-test-zones: ok"
exit $status
