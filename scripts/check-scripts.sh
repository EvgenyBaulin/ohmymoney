#!/bin/bash
# Shell scripts of this repository stay readable by the bash macOS ships (3.2), where a
# variable written next to a non-ASCII character loses its name: the first byte of a character
# like the closing guillemet is read as part of the name, and under `set -u` the script dies
# with «NAME<0xC2>: unbound variable» — which is what happened to the signing script on 19.09.
# Braces settle it, so a name is always written in curly brackets there.
#
# Also runs `bash -n` over every script and every git hook, so a syntax error is found before
# the owner runs one.
#
# And a script that builds with `xcodebuild` builds the way the Makefile does: with Xcode's own
# toolchain named (`-toolchain com.apple.dt.toolchain.XcodeDefault`), so a `TOOLCHAINS` in the
# owner's shell cannot hand the release to another compiler, and never through
# the `Build.nosync` link: xcodebuild compares what it would delete with the root it was given
# as text, and reached through the link every stale intermediate stays behind with a warning.
# make-release.sh did both until 24.09.
#
# Usage: check-scripts.sh [--self-test]
set -u

here="$(cd "$(dirname "$0")" && pwd)"

# Prints every place a variable is written against a non-ASCII character. Exit 1 when it
# found any, so a caller can simply ask.
scan() {
  /usr/bin/perl -ne '
    if (/\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/) { print "$ARGV:$.: $_"; $bad = 1 }
    close ARGV if eof;
    END { exit($bad ? 1 : 0) }
  ' "$@"
}

# `/bin/bash`, by its full path: the whole point is the 3.2 macOS ships. The `bash` first on
# this Mac's PATH is Homebrew's 5.x (the owner's PATH puts Homebrew first for OpenSSL), and it
# parses things 3.2 never will.
syntax() {
  local status=0
  for file in "$@"; do
    /bin/bash -n "$file" || status=1
  done
  return $status
}

# Prints each build a script runs with `xcodebuild` (one that names a project, a workspace or a
# scheme) without Xcode's own toolchain, and each script with such a build that names the
# `Build.nosync` link other than to resolve it (`pwd -P`); exit 1 when there is any. Lines
# continued with a backslash are read as one, and comments are not read.
builds() {
  awk '
    function report(text) { print text; bad = 1 }
    FNR == 1 {
      if (link != "" && built) report(link)
      line = ""; link = ""; built = 0
    }
    { line = line $0 }
    /\\$/ { sub(/\\$/, "", line); next }
    {
      code = line; line = ""
      sub(/(^|[[:space:]])#.*$/, "", code)
      if (code ~ /(^|[^A-Za-z0-9_.-])xcodebuild[[:space:]]/ &&
          code ~ /[[:space:]]-(project|workspace|scheme)[[:space:]]/) {
        built = 1
        if (code !~ /[[:space:]]-toolchain[[:space:]]+com[.]apple[.]dt[.]toolchain[.]XcodeDefault([[:space:]]|$)/)
          report(FILENAME ":" FNR ": xcodebuild without Xcode'"'"'s own toolchain")
      }
      if (link == "" && code ~ /Build[.]nosync/ && code !~ /pwd -P/)
        link = FILENAME ":" FNR ": a script that builds names the link to the build root"
    }
    END {
      if (link != "" && built) report(link)
      exit bad
    }' "$@"
}

if [ "${1:-}" = "--self-test" ]; then
  bad="$here/fixtures/scripts/bad.sh.txt"
  good="$here/fixtures/scripts/good.sh.txt"
  found=$(scan "$bad" | wc -l | tr -d ' ')
  if [ "$found" != "3" ]; then
    echo "check-scripts self-test: expected 3 findings in bad.sh.txt, got $found"
    scan "$bad"
    exit 1
  fi
  if ! scan "$good" > /dev/null; then
    echo "check-scripts self-test: good.sh.txt should pass"
    scan "$good"
    exit 1
  fi
  found=$(builds "$here/fixtures/scripts/build-bad.sh.txt" | wc -l | tr -d ' ')
  if [ "$found" != "3" ]; then
    echo "check-scripts self-test: expected 3 findings in build-bad.sh.txt, got $found"
    builds "$here/fixtures/scripts/build-bad.sh.txt"
    exit 1
  fi
  if ! builds "$here/fixtures/scripts/build-good.sh.txt" > /dev/null; then
    echo "check-scripts self-test: build-good.sh.txt should pass"
    builds "$here/fixtures/scripts/build-good.sh.txt"
    exit 1
  fi
  echo "check-scripts self-test: ok"
  exit 0
fi

# The hooks are shell too, and they have no `.sh` in their names — git calls them by the name
# it knows (`commit-msg`). They are checked with the rest.
files=("$here"/*.sh)
for hook in "$here"/git-hooks/*; do
  [ -f "$hook" ] || continue
  files+=("$hook")
done

status=0
scan "${files[@]}" || status=1
syntax "${files[@]}" || status=1
builds "${files[@]}" || status=1
if [ "$status" != "0" ]; then
  echo "scripts: a variable stands against a non-ASCII character, a script does not parse, or one builds past the toolchain or through the link"
  exit 1
fi
echo "scripts: ok"
