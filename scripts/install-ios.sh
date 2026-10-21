#!/bin/bash
# Installs a built iPhone/iPad app on every physical device that is ready, and launches it.
# A device that is not ready (locked, not trusted, no developer disk image yet) is reported and
# skipped, so one sleeping iPad does not stop the iPhone; the exit status is 0 when at least
# one device got the app, 1 otherwise.
#
# Usage: install-ios.sh <path to .app> <bundle id> [device name or id fragment]
set -u

app="${1:-}"
bundle="${2:-}"
only="${3:-}"
[ -n "${app}" ] && [ -n "${bundle}" ] || { echo "usage: install-ios.sh <app> <bundle id> [device]"; exit 2; }
[ -d "${app}" ] || { echo "install-ios: no app at ${app}"; exit 1; }

list="$(mktemp -t ohmymoney-devices)"
trap 'rm -f "${list}"' EXIT
xcrun devicectl list devices --json-output "${list}" > /dev/null 2>&1 || true

# identifier<TAB>name<TAB>ready(1/0)<TAB>why, for physical iOS/iPadOS devices that are connected.
rows="$(python3 - "${list}" "${only}" <<'PY'
import json, sys
path, only = sys.argv[1], sys.argv[2].lower()
try:
    devices = json.load(open(path))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw, dp, cp = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") != "physical" or cp.get("tunnelState") == "unavailable":
        continue
    name, ident = dp.get("name", "?"), d["identifier"]
    if only and only not in name.lower() and only not in ident.lower() and only not in hw.get("udid", "").lower():
        continue
    if cp.get("tunnelState") != "connected":
        why = "not connected"
    elif dp.get("developerModeStatus") != "enabled":
        why = "Developer Mode is off"
    elif not dp.get("ddiServicesAvailable"):
        why = "developer disk image not mounted (unlock the device, tap Trust, open Xcode > Window > Devices once)"
    else:
        why = ""
    print("%s\t%s\t%d\t%s" % (ident, name, 0 if why else 1, why))
PY
)"

[ -n "${rows}" ] || { echo "install-ios: no physical device is connected"; exit 1; }

done_count=0
while IFS="$(printf '\t')" read -r ident name ready why; do
  [ -n "${ident}" ] || continue
  if [ "${ready}" != "1" ]; then
    echo "install-ios: SKIPPED ${name}: ${why}"
    continue
  fi
  echo "install-ios: installing on ${name}"
  if xcrun devicectl device install app --device "${ident}" "${app}"; then
    done_count=$((done_count + 1))
    xcrun devicectl device process launch --device "${ident}" --terminate-existing "${bundle}" \
      || echo "install-ios: installed on ${name} but not launched (first time: Settings > General > VPN & Device Management > trust the developer app)"
  else
    echo "install-ios: FAILED on ${name}"
  fi
done <<ROWS
${rows}
ROWS

echo "install-ios: ${done_count} device(s) updated"
[ "${done_count}" -gt 0 ]
