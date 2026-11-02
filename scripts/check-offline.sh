#!/bin/bash
# The builds and tests of this Mac work without a network: the owner unplugs it, and a build
# from scratch (scripts/fresh-build.sh) must not need github.com for what it built yesterday.
# What it needs is downloaded once and kept:
#   - Xcode's packages in SourcePackages (-clonedSourcePackagesDirPath of every xcodebuild):
#     GRDB and Sparkle at the versions the project pins — Sparkle exactly (project.yml), GRDB
#     exactly (Packages/AppDatabase/Package.swift) — and Sparkle's binary framework among the
#     artifacts;
#   - the sources of GRDB for SwiftPM in spm-sources/appdatabase, a resolved scratch folder that
#     every fresh `swift test` of AppDatabase starts from as an APFS clone.
# This fails, with the command that fills the cache, when either is missing or holds another
# version than the pins. Then it proves the second offline: it resolves AppDatabase in a fresh
# folder seeded from the cache with every proxy variable pointing at a closed port, so a clone
# or a fetch from github.com fails at once instead of quietly succeeding on a connected Mac.
# (xcodebuild reads the proxies of the system, not of the environment, so the same cannot be
# done for it here; it is given -skipPackageUpdates and the cache is checked by version.)
#
# Usage: check-offline.sh <build root> <repository root>
#        check-offline.sh --self-test
set -u

here="$(cd "$(dirname "$0")" && pwd)"
fill="make packages   (with the network on: fills SourcePackages and spm-sources once)"

# The version a workspace-state.json of SwiftPM or Xcode has checked out for a package; empty
# when it has none.
checked_out() {
  /usr/bin/python3 - "$1" "$2" << 'EOF'
import json, sys
try:
    state = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dep in state.get("object", {}).get("dependencies", []):
    if dep.get("packageRef", {}).get("identity", "").lower() == sys.argv[2]:
        print((dep.get("state", {}).get("checkoutState") or {}).get("version", ""))
EOF
}

# Prints a line for each package of a state file not at its pin; exit 1 when there is any.
# Arguments: <state file> <what it is> <identity>=<version>…
compare() {
  local state="$1" what="$2" pair name want have bad=""
  shift 2
  for pair in "$@"; do
    name="${pair%%=*}"
    want="${pair#*=}"
    have="$(checked_out "${state}" "${name}")"
    if [ "${have}" != "${want}" ]; then
      echo "offline: ${what} has ${name} ${have:-<none>}, the pin is ${want}"
      bad="yes"
    fi
  done
  [ -z "${bad}" ]
}

if [ "${1:-}" = "--self-test" ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-offline-test.XXXXXX")"
  cat > "${tmp}/state.json" << 'EOF'
{"object": {"dependencies": [
  {"packageRef": {"identity": "grdb.swift"}, "state": {"checkoutState": {"version": "7.11.1"}}},
  {"packageRef": {"identity": "sparkle"}, "state": {"checkoutState": {"version": "2.9.0"}}}]}}
EOF
  status=0
  compare "${tmp}/state.json" test grdb.swift=7.11.1 > /dev/null ||
    { echo "check-offline self-test: GRDB at its pin was refused"; status=1; }
  found="$(compare "${tmp}/state.json" test sparkle=2.10.0 grdb.swift=7.11.1 nothing=1.0 | wc -l | tr -d ' ')"
  [ "${found}" = "2" ] ||
    { echo "check-offline self-test: expected Sparkle 2.9.0 and a missing package, got ${found} lines"; status=1; }
  compare "${tmp}/missing.json" test grdb.swift=7.11.1 > /dev/null &&
    { echo "check-offline self-test: a missing state file passed"; status=1; }
  rm -rf "${tmp}"
  [ "${status}" = "0" ] && echo "check-offline self-test: ok"
  exit "${status}"
fi

root="${1:?build root}"
repo="${2:?repository root}"
grdb="$(sed -nE 's/.*GRDB\.swift\.git", exact: "([0-9.]+)".*/\1/p' "${repo}/Packages/AppDatabase/Package.swift" | head -n 1)"
sparkle="$(awk '/^  Sparkle:/ { on = 1 } on && /exactVersion:/ { print $2; exit }' "${repo}/project.yml")"
[ -n "${grdb}" ] && [ -n "${sparkle}" ] ||
  { echo "offline: the pins of GRDB (${grdb:-?}) and Sparkle (${sparkle:-?}) cannot be read"; exit 1; }

status=0
compare "${root}/SourcePackages/workspace-state.json" "SourcePackages (Xcode)" \
  "grdb.swift=${grdb}" "sparkle=${sparkle}" || status=1
[ -d "${root}/SourcePackages/artifacts/sparkle/Sparkle" ] ||
  { echo "offline: SourcePackages has no binary framework of Sparkle"; status=1; }
compare "${root}/spm-sources/appdatabase/workspace-state.json" "spm-sources (SwiftPM)" \
  "grdb.swift=${grdb}" || status=1
if [ "${status}" != "0" ]; then
  echo "offline: the cache does not match the pins; fill it: ${fill}"
  exit 1
fi

# The proof: a fresh folder from the cache, with no way out.
probe="$(mktemp -d "${root}/scratch-offline.XXXXXX")"
trap 'rm -rf "${probe}"' EXIT
cp -c -R "${root}/spm-sources/appdatabase/repositories" "${root}/spm-sources/appdatabase/checkouts" \
  "${root}/spm-sources/appdatabase/workspace-state.json" "${probe}/"
closed="http://127.0.0.1:9"
if ! out="$(cd "${repo}" && http_proxy="${closed}" https_proxy="${closed}" HTTP_PROXY="${closed}" \
    HTTPS_PROXY="${closed}" ALL_PROXY="${closed}" all_proxy="${closed}" \
    xcrun --toolchain default swift package resolve --disable-automatic-resolution \
    --package-path Packages/AppDatabase --scratch-path "${probe}" 2>&1)"; then
  echo "${out}"
  echo "offline: SwiftPM could not resolve AppDatabase from the cache without the network; ${fill}"
  exit 1
fi
if echo "${out}" | grep -qiE 'fetch|clon|unable to access'; then
  echo "${out}"
  echo "offline: SwiftPM reached for the network while resolving AppDatabase from the cache"
  exit 1
fi
echo "offline: GRDB ${grdb} and Sparkle ${sparkle} are in the cache, and SwiftPM resolves without a network"
