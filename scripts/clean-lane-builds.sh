#!/bin/sh
# Frees disk by deleting only the temporary build folders the parallel lanes leave behind in
# ~/Library/Developer/OhMyMoney/: DerivedData-<lane>, spm-<lane>, logs-<lane>.
# Never touched: DerivedData, SourcePackages, logs, pyenv, release, xcodegen.cache,
# spm-appcore, spm-appdatabase, spm-appcore-release, spm-appdatabase-release, test-times.tsv,
# and anything outside that folder (the repository, backups, the owner's data).
#
#   scripts/clean-lane-builds.sh             delete them
#   scripts/clean-lane-builds.sh --dry-run   only list them with their sizes
#
# Run it between lanes, not while a lane is building: a lane that loses its folder fails and is
# restarted from the journal.
set -eu

root="${BUILD_ROOT:-$HOME/Library/Developer/OhMyMoney}"
dry=0
[ "${1:-}" = "--dry-run" ] && dry=1

[ -d "$root" ] || { echo "clean-lane-builds: no build folder at $root"; exit 0; }

keep() {
  case "$1" in
    DerivedData | SourcePackages | logs | pyenv | release | xcodegen.cache | test-times.tsv) return 0 ;;
    spm-appcore | spm-appdatabase | spm-appcore-release | spm-appdatabase-release) return 0 ;;
  esac
  return 1
}

found=0
for path in "$root"/DerivedData-* "$root"/spm-* "$root"/logs-*; do
  [ -e "$path" ] || continue
  name="$(basename "$path")"
  keep "$name" && continue
  found=1
  size="$(du -sh "$path" 2>/dev/null | cut -f1)"
  if [ "$dry" = 1 ]; then
    echo "would delete $name ($size)"
  else
    rm -rf "$path"
    echo "deleted $name ($size)"
  fi
done

[ "$found" = 1 ] || echo "clean-lane-builds: nothing to delete"
df -h "$root" | tail -1
