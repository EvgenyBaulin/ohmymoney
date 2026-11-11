#!/bin/bash
# Prints the GB free for a build on the volume of a path (default: home), the way Finder counts
# it: with the space macOS frees on demand. `df` shows only what is free this second and on this
# Mac reads 20–60 GB less, which stopped builds and lanes for no reason.
#
#   scripts/disk-free.sh [path]   → whole GB, one line
#
# The measure is a small Objective-C tool (scripts/disk-free.m), built once into the build
# folder; `swift` scripts do not run in the agent sandbox. When it cannot be built or read,
# the script falls back to `df`, which is the lower, safe number.
set -u

path="${1:-${HOME}}"
here="$(cd "$(dirname "$0")" && pwd)"
tool_dir="${HOME}/Library/Developer/OhMyMoney/bin"
tool="${tool_dir}/disk-free"

if [ ! -x "${tool}" ] || [ "${here}/disk-free.m" -nt "${tool}" ]; then
  mkdir -p "${tool_dir}" 2> /dev/null &&
    xcrun clang -fobjc-arc -framework Foundation -O2 -o "${tool}.tmp.$$" "${here}/disk-free.m" \
      2> /dev/null && mv -f "${tool}.tmp.$$" "${tool}"
  rm -f "${tool}.tmp.$$"
fi

if [ -x "${tool}" ] && gb="$("${tool}" "${path}" 2> /dev/null)" && [ -n "${gb}" ]; then
  echo "${gb}"
else
  df -g "${path}" | awk 'NR == 2 { print $4 }'
fi
