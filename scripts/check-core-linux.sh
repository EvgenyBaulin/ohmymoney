#!/bin/bash
# AppCore builds on Linux (core-linux.yml, Swift 6.1 and 6.4), where Foundation is the open
# one and Apple's runtime is absent. A Mac cannot build for Linux, and a toolchain of
# swift.org cannot even build AppCore against the SDK of Xcode 27 (it does not know the flags of
# the newer driver), so what Linux would refuse is read here from the sources, before a push:
# the things that compiled on the Mac and broke the Linux job, or would.
#
#   - modules only Apple has: Darwin, os, ObjectiveC, Combine, CoreFoundation by name;
#   - the C library of Darwin: arc4random, uuid_t and UUID_NULL (a test of 1.9.1 used it and
#     the Linux job failed), CFAbsoluteTimeGetCurrent;
#   - the Objective-C runtime: @objc, NSClassFromString, autoreleasepool;
#   - Apple's logging: os_log, OSLog, Logger of os;
#   - URLSession without FoundationNetworking: on Linux it lives in a module of its own;
#   - NSPredicate and NSExpression with a format, which the open Foundation does not parse;
#   - NSKeyedArchiver and NSKeyedUnarchiver, partial there.
# A line inside `#if canImport(Darwin)`, `#if os(macOS)` or `#if os(iOS)` is Apple-only by
# its own word and is not read; a line may also say why it is fine with `// linux-ok: <why>`.
#
# Usage: check-core-linux.sh [<folder>…]   (default: Packages/AppCore/Sources and Tests)
#        check-core-linux.sh --self-test
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/.." && pwd)"

# Extended regular expressions of awk, which has no \b: a word is bounded by hand, and a
# parenthesis is a class, since `awk -v` eats one level of backslashes.
pattern='^[[:space:]]*import[[:space:]]+(Darwin|os|ObjectiveC|Combine|CoreFoundation)([[:space:]]|$)'
pattern="${pattern}|arc4random|(^|[^A-Za-z0-9_])uuid_t([^A-Za-z0-9_]|$)|UUID_NULL|CFAbsoluteTimeGetCurrent"
pattern="${pattern}|@objc|NSClassFromString|autoreleasepool"
pattern="${pattern}|(^|[^A-Za-z0-9_])(os_log|OSLog)([^A-Za-z0-9_]|$)"
pattern="${pattern}|NSPredicate[(]format|NSExpression[(]format|NSKeyedArchiver|NSKeyedUnarchiver"

# Prints file:line: text of every line that Linux would refuse; exit 1 when there is any.
scan() {
  local file status=0
  while IFS= read -r file; do
    /usr/bin/awk -v file="${file}" -v pattern="${pattern}" '
      function strip(s) { sub(/\/\/.*$/, "", s); return s }
      /^[[:space:]]*#if/ {
        apple = ($0 ~ /canImport\(Darwin\)|os\((macOS|iOS)\)/ && $0 !~ /!/) ? 1 : 0
        stack[++depth] = apple; next
      }
      # The other branch of an Apple-only condition is the one Linux compiles.
      /^[[:space:]]*#else/ { if (depth) stack[depth] = 0; next }
      /^[[:space:]]*#endif/ { if (depth) depth--; next }
      {
        guarded = 0
        for (i = 1; i <= depth; i++) if (stack[i]) guarded = 1
        if (guarded || $0 ~ /linux-ok:/) next
        if ($0 ~ /^[[:space:]]*(\/\/|\*|\/\*)/) next
        code = strip($0)
        if (code ~ pattern) { print file ":" FNR ": " $0; bad = 1 }
        if (code ~ /URLSession/) { session = session file ":" FNR ": " $0 "\n" }
        if ($0 ~ /FoundationNetworking/) networking = 1
      }
      END {
        if (session != "" && !networking) {
          printf "%s", session
          print file ": URLSession without `#if canImport(FoundationNetworking)` / `import FoundationNetworking`"
          bad = 1
        }
        exit bad
      }' "${file}" || status=1
  done
  return "${status}"
}

if [ "${1:-}" = "--self-test" ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-core-linux-test.XXXXXX")"
  cat > "${tmp}/good.swift" << 'EOF'
import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(Darwin)
  import Darwin
  let n = arc4random()
#endif
// arc4random in a comment is not code.
let s = URLSession.shared
let id = UUID()  // linux-ok: not Darwin's uuid_t
EOF
  cat > "${tmp}/bad.swift" << 'EOF'
import Foundation
import os
let n = arc4random_uniform(6)
let empty = UUID(uuid: UUID_NULL)
@objc final class Thing: NSObject {}
let s = URLSession.shared
EOF
  status=0
  printf '%s\n' "${tmp}/good.swift" | scan > /dev/null ||
    { echo "check-core-linux self-test: good.swift was refused:"; printf '%s\n' "${tmp}/good.swift" | scan; status=1; }
  found="$(printf '%s\n' "${tmp}/bad.swift" | scan | wc -l | tr -d ' ')"
  [ "${found}" = "6" ] ||
    { echo "check-core-linux self-test: expected 6 lines for bad.swift, got ${found}:"; printf '%s\n' "${tmp}/bad.swift" | scan; status=1; }
  rm -rf "${tmp}"
  [ "${status}" = "0" ] && echo "check-core-linux self-test: ok"
  exit "${status}"
fi

if [ "$#" -eq 0 ]; then
  set -- "${root}/Packages/AppCore/Sources" "${root}/Packages/AppCore/Tests"
fi
if ! find "$@" -name '*.swift' -type f | sort | scan; then
  echo "core on Linux: the lines above build on the Mac and not on Linux (core-linux.yml)"
  exit 1
fi
echo "core on Linux: nothing Apple-only in AppCore"
