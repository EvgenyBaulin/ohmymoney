#!/bin/sh
# Frees disk by deleting only the temporary build folders the parallel lanes leave behind in
# ~/Library/Developer/OhMyMoney/: DerivedData-<lane>, spm-<lane>, logs-<lane>, and the scratch-*
# folders of fresh builds and of lanes trying things out (a scratch-<pid> of a build that is still
# running is kept).
# Never touched: DerivedData, SourcePackages, logs, pyenv, release, xcodegen.cache,
# spm-appcore, spm-appdatabase, spm-appcore-release, spm-appdatabase-release, spm-sources,
# test-times.tsv,
# and anything outside that folder (the repository, backups, the owner's data).
#
#   scripts/clean-lane-builds.sh             delete them
#   scripts/clean-lane-builds.sh --dry-run   only list them with their sizes
#   KEEP_LANES="laneB lane29" scripts/clean-lane-builds.sh   spare the folders of lanes still running
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
    # The sources of GRDB every fresh `swift test` starts from without a network (make packages).
    spm-sources) return 0 ;;
  esac
  return 1
}

# A fresh build names its folder scratch-<pid>: while that process lives, the folder is in use.
running() {
  case "$1" in
    scratch-*) pid="${1#scratch-}" ;;
    *) return 1 ;;
  esac
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2> /dev/null
}

found=0
for path in "$root"/DerivedData-* "$root"/spm-* "$root"/logs-* "$root"/scratch-*; do
  [ -e "$path" ] || continue
  name="$(basename "$path")"
  keep "$name" && continue
  spared=0
  for lane in ${KEEP_LANES:-}; do
    case "$name" in *-"$lane" | *-"$lane"-*) spared=1 ;; esac
  done
  if [ "$spared" = 1 ]; then
    echo "kept $name (its lane is running)"
    continue
  fi
  if running "$name"; then
    echo "kept $name (its build is running)"
    continue
  fi
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
