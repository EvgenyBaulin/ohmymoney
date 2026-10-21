#!/bin/bash
# Fails when a height taken from the screen comes back into the layout.
#
# On 19.09 the window of Transactions hung and the app died on an `NSGenericException`:
# the selection bar measured its own height into `@State` and fed it back into the padding
# of the same column, and with the inspector open the window never converged. Hence the rule
# this script enforces: a size taken off the screen (`onGeometryChange`, `GeometryReader`)
# never comes back into the layout of the same branch.
#
# Only a HEIGHT is judged, not a width, and that is on purpose. A view's height is decided by
# its content, from the bottom up: a height sent back down can propose a new height, which is
# a loop with no end. A width in this app is imposed from the top down — the window gives it
# to the scene — so a view that reflows by a measured width settles in one pass. Four places
# do exactly that and are right to (`WindowWidthReader`, `OverviewView`, `AnalyticsSections`,
# `PlanningView`); a rule that also caught them would be four waivers of noise.
#
# Two shapes are flagged:
#
#   1. Out through a binding. A view measures its own height and hands it to its parent
#      through `@Binding var x: CGFloat` or a `(CGFloat) -> Void`. This is the shape the main
#      window had: `EntryBar` measured three heights and wrote them into
#      `@Binding var clearance`, and `MainWindow` put that into `.safeAreaPadding(.bottom,)`.
#      The two halves sit in different files, so nothing that reads one file alone can see it.
#   2. Back into the branch. A name assigned inside an `onGeometryChange` that reads a height
#      or a frame, then read inside a modifier that decides a size — `safeAreaPadding`,
#      `padding`, `frame`, `offset`, `position` — in the same file.
#
# The room a floating element needs is `safeAreaInset(edge:)`; its height is not measured.
#
# A place that must go on doing this says so on the line above:  // geometry: <why>
#
# Usage: scripts/check-geometry.sh [dir…]   (default: Apps)
#        scripts/check-geometry.sh --self-test
set -u

here="$(cd "$(dirname "$0")" && pwd)"

scan() {
  local status=0 out
  out=$(find "$@" -name '*.swift' -o -name '*.swift.txt' | sort | while read -r file; do
    awk -v file="$file" '
      function report(line, text, why) {
        sub(/^[[:space:]]+/, "", text)
        printf "%s:%d: %s: %s\n", file, line, why, text
      }
      # A waiver on the line above, or on the line itself.
      function waived(i,   j) {
        for (j = i - 1; j <= i; j++)
          if (j >= 1 && kept[j] ~ /\/\/[[:space:]]*geometry:/) return 1
        return 0
      }
      function code(i,   c) { c = kept[i]; sub(/\/\/.*$/, "", c); return c }
      { kept[NR] = $0 }
      END {
        measuresHeight = 0
        measuredCount = 0
        # Pass one: every `onGeometryChange` that reads a height or a whole frame, and the
        # names its action writes. The action follows the reader within a few lines:
        #   .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { name = $0 }
        for (i = 1; i <= NR; i++) {
          if (code(i) !~ /onGeometryChange\(/ && code(i) !~ /GeometryReader/) continue
          kind = ""
          for (j = i; j <= i + 8 && j <= NR; j++) {
            c = code(j)
            if (c ~ /\$0\.size\.height/ || c ~ /\$0\.frame\(/ || c ~ /\.size\.height/) kind = "height"
          }
          if (kind != "height") continue
          measuresHeight = 1
          if (measureLine == 0) measureLine = i
          for (j = i; j <= i + 10 && j <= NR; j++) {
            c = code(j)
            if (c !~ /=[[:space:]]*\$0/) continue
            sub(/=[[:space:]]*\$0.*$/, "", c)
            gsub(/[[:space:]]/, "", c)
            if (c ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { measured[c] = 1; measuredCount++ }
            # Shape 3: the measurement is written into a property of an object. Whoever reads
            # that property is laid out again every time the size changes, and the object is
            # shared — so the reader can be the very view that produced the size. That is the
            # same loop with one hop more, and it is what took the window of
            # Transactions down on 21.09 (`actions.barFrame`). A dotted target
            # never matched the name above, so the rule stopped at the dot.
            else if (c ~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$/) {
              if (!waived(j))
                report(j, kept[j], "a measured size leaves the view through an object: whoever reads that property lays out again on every frame")
            }
          }
        }
        # Shape 1: the measured height leaves the view through a binding or a closure.
        if (measuresHeight) {
          for (i = 1; i <= NR; i++) {
            c = code(i)
            if (c ~ /@Binding[[:space:]]+var[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*CGFloat/ ||
                c ~ /var[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*\(CGFloat\)[[:space:]]*->/) {
              if (!waived(i))
                report(i, kept[i], "a measured height leaves the view: use safeAreaInset")
            }
          }
        }
        # Shape 2: a measured height reaches a modifier that decides a size, in this file.
        if (measuredCount > 0) {
          for (i = 1; i <= NR; i++) {
            c = code(i)
            if (c !~ /\.(safeAreaPadding|padding|frame|offset|position)\(/) continue
            for (name in measured) {
              if (c !~ ("[^A-Za-z0-9_]" name "[^A-Za-z0-9_]") && c !~ ("[^A-Za-z0-9_]" name "$")) continue
              if (!waived(i))
                report(i, kept[i], "a measured height comes back into the layout")
              break
            }
          }
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
  bad="$here/fixtures/geometry/bad.swift.txt"
  good="$here/fixtures/geometry/good.swift.txt"
  found=$(scan "$bad" | wc -l | tr -d ' ')
  if [ "$found" != "4" ]; then
    echo "check-geometry self-test: expected 4 findings in bad.swift.txt, got $found"
    scan "$bad"
    exit 1
  fi
  if ! scan "$good" > /dev/null; then
    echo "check-geometry self-test: good.swift.txt should pass"
    scan "$good"
    exit 1
  fi
  echo "check-geometry self-test: ok"
  exit 0
fi

if [ $# -eq 0 ]; then set -- Apps; fi
if ! scan "$@"; then
  echo "geometry: a measured height feeds the layout"
  exit 1
fi
echo "geometry: no measured heights in the layout"
