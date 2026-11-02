#!/bin/bash
# Runs make in a build folder of its own, made for this run and deleted when it ends — on
# success, on a failure, on Ctrl-C and on a kill that bash can catch. Every build and every
# test run starts from nothing, the way a runner of CI starts: a warning is printed for every
# file, since every file is compiled (an incremental build repeats a warning only for the files
# it recompiles, and the warnings of untouched tests reached CI alone: actor isolation, an
# unused value, a needless `try`, a deprecated call), and a module or a file left over from an
# older tree cannot answer for one the tree no longer builds (the test target once compiled
# here against the module of the app's old name, and failed on the runner).
#
# What stays shared is what was downloaded: the packages Xcode fetched (SourcePackages, given
# to xcodebuild as -clonedSourcePackagesDirPath) and SwiftPM's own cache of repositories, so a
# build from scratch needs no network for them. `REUSE_BUILD=1` on the command line of make
# skips this script and builds incrementally in the folders of before, for debugging by hand.
#
# The folder is <build root>/scratch-<pid>. A run killed with SIGKILL cannot delete its own, so
# each run first deletes the scratch folders whose process is gone. `make verify` also says it
# is running with <build root>/logs/verify-running for as long as it runs: the lanes wait for it.
# The marker is taken only when nobody holds it, removed only by the run that wrote it (its pid
# is the first word), and never touched by a dry run (`make -n`), which runs this script too.
#
# Usage: fresh-build.sh <make> <goal>…   (from the Makefile; OHMYMONEY_BUILD_ROOT is the root)
#        fresh-build.sh --self-test
set -u

root="${OHMYMONEY_BUILD_ROOT:-${HOME}/Library/Developer/OhMyMoney}"
# Below this many GB free a build from scratch may run out of room half-way: it says so first.
least_free_gb="${OHMYMONEY_LEAST_FREE_GB:-15}"

# Deletes the scratch folders of runs whose process is gone. A folder of a live process is kept.
sweep() {
  local dir pid
  for dir in "$1"/scratch-*; do
    [ -d "${dir}" ] || continue
    pid="${dir##*/scratch-}"
    case "${pid}" in '' | *[!0-9]*) continue ;; esac
    # `kill -0` fails on a live process of another user as well, so `ps` is asked too (it is
    # not there inside the sandbox of a session, where `kill -0` answers).
    { kill -0 "${pid}" 2> /dev/null || ps -p "${pid}" > /dev/null 2>&1; } && continue
    rm -rf "${dir}"
    echo "fresh-build: deleted ${dir##*/}, left by a run that is gone"
  done
}

if [ "${1:-}" = "--self-test" ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fresh-build-test.XXXXXX")"
  mkdir -p "${tmp}/scratch-$$" "${tmp}/scratch-999999" "${tmp}/scratch-name"
  sweep "${tmp}" > /dev/null
  status=0
  [ -d "${tmp}/scratch-$$" ] || { echo "fresh-build self-test: the folder of a live run was deleted"; status=1; }
  [ ! -d "${tmp}/scratch-999999" ] || { echo "fresh-build self-test: the folder of a gone run was kept"; status=1; }
  [ -d "${tmp}/scratch-name" ] || { echo "fresh-build self-test: a folder without a pid was deleted"; status=1; }
  # The folder of a run is gone after it, also after a failure.
  OHMYMONEY_BUILD_ROOT="${tmp}" OHMYMONEY_LEAST_FREE_GB=0 "$0" false > /dev/null 2>&1
  [ "$(find "${tmp}" -maxdepth 1 -name 'scratch-*' | wc -l | tr -d ' ')" = "2" ] ||
    { echo "fresh-build self-test: a failed run left its folder"; status=1; }
  rm -rf "${tmp}"
  [ "${status}" = "0" ] && echo "fresh-build self-test: ok"
  exit "${status}"
fi

[ "$#" -ge 1 ] || { echo "usage: fresh-build.sh <make> <goal>…" >&2; exit 2; }
make_command="$1"
shift

mkdir -p "${root}"
sweep "${root}"
free_gb="$(df -g "${root}" | awk 'NR == 2 { print $4 }')"
if [ -n "${free_gb}" ] && [ "${free_gb}" -lt "${least_free_gb}" ]; then
  echo "fresh-build: ${free_gb} GB free in ${root}; a build from scratch needs about ${least_free_gb}." >&2
  echo "fresh-build: free some (scripts/clean-lane-builds.sh --dry-run), or REUSE_BUILD=1 to build in the old folders" >&2
  exit 1
fi

scratch="${root}/scratch-$$"
marker=""
for goal in "$@"; do
  case "${goal}" in verify | verify-full) marker="${root}/logs/verify-running" ;; esac
done
# The single-letter flags of make are the first word of MAKEFLAGS (`n` for a dry run); a
# variable given on the command line comes after ` -- `.
flags="${MAKEFLAGS:-}"
flags="${flags%% *}"
case "${flags}" in *=*) flags="" ;; esac
case "${flags}" in *n*) marker="" ;; esac
if [ -n "${marker}" ] && [ -f "${marker}" ]; then
  echo "fresh-build: $(cat "${marker}" 2> /dev/null) holds ${marker}; this run leaves it alone"
  marker=""
fi

cleanup() {
  rm -rf "${scratch}"
  if [ -n "${marker}" ] && [ "$(cut -d ' ' -f 1 "${marker}" 2> /dev/null)" = "$$" ]; then
    rm -f "${marker}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "${scratch}"
if [ -n "${marker}" ]; then
  mkdir -p "${marker%/*}"
  echo "$$ $(date '+%Y-%m-%d %H:%M:%S')" > "${marker}"
fi
echo "fresh-build: building from scratch in ${scratch} (deleted at the end; REUSE_BUILD=1 reuses the old folders)"
# Not `exec`: the trap must outlive make. The variables on this command line win over the same
# names a lane gave the outer make (DERIVED=…, SPM_SCRATCH=…), which reach it through MAKEFLAGS.
"${make_command}" "$@" FRESH_ROOT="${scratch}" DERIVED="${scratch}/DerivedData" SPM_SCRATCH="${scratch}"
