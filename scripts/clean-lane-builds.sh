#!/bin/sh
# Frees disk by deleting only the temporary build folders the parallel lanes leave behind in
# ~/Library/Developer/OhMyMoney/: DerivedData-<lane>, spm-<lane>, logs-<lane>, and the scratch-*
# folders of fresh builds and of lanes trying things out (a scratch-<pid> of a build that is still
# running is kept).
# With --builds it also deletes the incremental build folders: every build and test run starts
# from scratch in a folder of its own (scripts/fresh-build.sh), so DerivedData, spm-appcore,
# spm-appdatabase and their -release twins only serve `make run`, `sample`, `demo` and
# REUSE_BUILD=1, which rebuild them when asked; plus the logs older than three days and the
# .xcresult bundles in logs. Not while a release check runs (logs/verify-running).
# Never touched: SourcePackages and spm-sources (the packages, so no network is needed), pyenv,
# release, xcodegen.cache, test-times.tsv, the recent logs, and anything outside that folder
# (the repository, backups, the owner's data).
#
#   scripts/clean-lane-builds.sh             delete the lanes' folders
#   scripts/clean-lane-builds.sh --builds    and the incremental builds and old logs too
#   scripts/clean-lane-builds.sh --dry-run [--builds]   only list them with their sizes
#   KEEP_LANES="laneB lane29" scripts/clean-lane-builds.sh   spare the folders of lanes still running
#
# Run it between lanes, not while a lane is building: a lane that loses its folder fails and is
# restarted from the journal.
set -eu

root="${BUILD_ROOT:-$HOME/Library/Developer/OhMyMoney}"
dry=0
builds=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    --builds) builds=1 ;;
    *) echo "usage: clean-lane-builds.sh [--dry-run] [--builds]" >&2; exit 2 ;;
  esac
done

[ -d "$root" ] || { echo "clean-lane-builds: no build folder at $root"; exit 0; }

keep() {
  if [ "$builds" = 1 ]; then
    case "$1" in
      DerivedData | spm-appcore | spm-appdatabase | spm-appcore-release | spm-appdatabase-release) return 1 ;;
    esac
  fi
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

if [ "$builds" = 1 ] && [ -f "$root/logs/verify-running" ]; then
  echo "clean-lane-builds: a release check is running (logs/verify-running); --builds waits for it" >&2
  exit 1
fi

delete() {
  found=1
  size="$(du -sh "$1" 2>/dev/null | cut -f1)"
  if [ "$dry" = 1 ]; then
    echo "would delete ${1#"$root"/} ($size)"
  else
    rm -rf "$1"
    echo "deleted ${1#"$root"/} ($size)"
  fi
}

found=0
if [ "$builds" = 1 ] && [ -d "$root/logs" ]; then
  # Not a pipe into `while`: delete must run in this shell, where `found` is counted.
  old_logs="$(find "$root/logs" -mindepth 1 -maxdepth 1 \( -name '*.xcresult' -o \( -type f -mtime +3 \) \) \
    ! -name verify-running ! -name 'stop-tests.*')"
  IFS='
'
  for old in $old_logs; do delete "$old"; done
  unset IFS
fi
for path in "$root"/DerivedData "$root"/DerivedData-* "$root"/spm-* "$root"/logs-* "$root"/scratch-*; do
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
  delete "$path"
done

[ "$found" = 1 ] || echo "clean-lane-builds: nothing to delete"
df -h "$root" | tail -1
