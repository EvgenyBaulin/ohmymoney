#!/bin/bash
# Runs after the application is built, and does one thing: takes Sparkle out of the store
# build: there is no updater of any kind in the App Store configuration. Nothing in that build
# refers to Sparkle, so the linker has already dropped the
# load command; what is left is the framework Xcode embeds for every configuration.
#
# What this script deliberately does **not** do is copy Sparkle's XPC services into
# `Contents/XPCServices`. Sparkle 2 refuses to run when it finds them there — «XPC Service
# must be in the Sparkle framework, not in the application bundle» (`SPUUpdater.m`). They ship
# inside the framework, and a sandboxed application turns them on with
# `SUEnableInstallerLauncherService` in its Info.plist, exactly as Sparkle's own sandboxed
# test application does.
#
# `make check-appstore-clean` looks inside the finished bundle afterwards, so this script
# being wrong is a failure of `make verify` and not a surprise months later.
set -euo pipefail

app="${TARGET_BUILD_DIR:-}/${WRAPPER_NAME:-}"
[ -d "${app}" ] || { echo "sparkle: ${app} is not there"; exit 1; }

if [ "${CONFIGURATION:-}" != "AppStore" ]; then
  echo "sparkle: nothing to do in ${CONFIGURATION:-?}"
  exit 0
fi

rm -rf "${app}/Contents/Frameworks/Sparkle.framework" "${app}/Contents/XPCServices"
# An empty Frameworks folder left behind is not an error, but it is litter.
rmdir "${app}/Contents/Frameworks" 2>/dev/null || true

# And Sparkle's settings: the one Info.plist serves both builds, and a store bundle that still
# names an update feed, a key and a schedule of checks invites a reviewer's question with
# nothing behind it. Every top-level `SU…` key goes; the bundle is signed after this phase.
plist="${app}/Contents/Info.plist"
for key in $(plutil -p "${plist}" | sed -nE 's/^  "(SU[A-Za-z]+)" => .*/\1/p'); do
  plutil -remove "${key}" "${plist}"
done
echo "sparkle: taken out of the store build"
