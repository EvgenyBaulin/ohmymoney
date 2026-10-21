#!/bin/bash
# Fails when a SwiftUI view could crash on a value missing from its environment.
# Three patterns trap at run time, inside SwiftUI, with none of the app's
# frames on the stack — the crash of 19.09 was the first one:
#
#   1. `@Environment(SomeType.self) var x` without `?`: SwiftUI's own
#      «No Observable object of type … found» when the object is not injected. Read it as
#      `var x: SomeType?`, or through a key of our own with a safe default.
#   2. `@EnvironmentObject`: the same trap for `ObservableObject`.
#   3. A `defaultValue` or an `@Entry` whose default traps: `fatalError`,
#      `preconditionFailure`, `assertionFailure`, `try!`, `as!` or a force unwrap.
#
# Usage: scripts/check-environment.sh [dir…]   (default: Apps)
#        scripts/check-environment.sh --self-test
set -u

here="$(cd "$(dirname "$0")" && pwd)"

scan() {
  local status=0 out
  # Joins an attribute standing alone on its line with the declaration below it, so a
  # wrapped `@Environment(X.self)\n  private var x` is judged as one line.
  out=$(find "$@" -name '*.swift' -o -name '*.swift.txt' | sort | while read -r file; do
    awk -v file="$file" '
      function report(line, text, why) { printf "%s:%d: %s: %s\n", file, line, why, text }
      {
        text = $0; line = NR
        kept[NR] = $0
        if (text ~ /^[[:space:]]*@Environment\([A-Z][A-Za-z0-9_.]*\.self\)[[:space:]]*$/ &&
            (getline next_line) > 0) { text = text " " next_line }
        code = text; sub(/\/\/.*$/, "", code)
        if (code ~ /@Environment\([A-Z][A-Za-z0-9_.]*\.self\)/ &&
            code !~ /:[[:space:]]*[A-Za-z0-9_.]+\?[[:space:]]*(=.*)?$/)
          report(line, text, "non-optional @Environment(Type.self) traps when missing")
        if (code ~ /@EnvironmentObject/)
          report(line, text, "@EnvironmentObject traps when missing")
        if (code ~ /defaultValue|@Entry/) { watching = 4 }
        if (watching > 0) {
          watching--
          if (code ~ /fatalError|preconditionFailure|assertionFailure|try!|as!|[A-Za-z0-9_)\]]![^=]|[A-Za-z0-9_)\]]!$/)
            report(line, text, "environment default traps")
        }
      }
      # A host of its own (NSHostingView, NSHostingController) is laid out outside the
      # environment of its window, so the dependencies are handed to its content
      # by hand. Anything within eight lines counts: the root is often built just above. A
      # host meant to go without says so in a dependencies: comment.
      END {
        for (i = 1; i <= NR; i++) {
          if (kept[i] !~ /NSHosting(View|Controller)\(/) continue
          handed = 0
          for (j = i - 8; j <= i + 8; j++) {
            if (j < 1 || j > NR) continue
            if (kept[j] ~ /\.appDependencies\(|\.handingOver\(|AppScenes\.root\(|dependencies:/)
              handed = 1
          }
          if (!handed)
            report(i, kept[i], "a host of its own without the dependencies")
        }
      }' "$file"
  done)
  if [ -n "$out" ]; then
    echo "$out"
    status=1
  fi
  return $status
}

if [ "${1:-}" = "--self-test" ]; then
  bad="$here/fixtures/environment/bad.swift.txt"
  good="$here/fixtures/environment/good.swift.txt"
  found=$(scan "$bad" | wc -l | tr -d ' ')
  if [ "$found" != "7" ]; then
    echo "check-environment self-test: expected 7 findings in bad.swift.txt, got $found"
    scan "$bad"
    exit 1
  fi
  if ! scan "$good" > /dev/null; then
    echo "check-environment self-test: good.swift.txt should pass"
    scan "$good"
    exit 1
  fi
  echo "check-environment self-test: ok"
  exit 0
fi

if [ $# -eq 0 ]; then set -- Apps; fi
if ! scan "$@"; then
  echo "environment: a view can trap on a missing value"
  exit 1
fi
echo "environment: no traps"
