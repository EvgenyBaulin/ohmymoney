#!/bin/bash
# Builds a release of the Direct build, packages it, signs the package with the owner's
# Sparkle key and writes the entry that announces it.
#
# What this script will not do, ever: make a key, or put one in the repository. The private
# key lives in the owner's keychain (on a runner of the release workflow, in a file of that run
# named by SPARKLE_ED_KEY_FILE), the public key is passed in, and the tool that signs is
# Sparkle's own.
#
# Usage: make-release.sh [--dry-run]
#   SPARKLE_PUBLIC_KEY   the EdDSA public key that goes into Info.plist; without it, or with
#                        the placeholder, the release stops. A file `sparkle-public-key.txt`
#                        in the repository root is read when the variable is not set; it is
#                        ignored by git.
#   SPARKLE_BIN          directory holding Sparkle's `sign_update`; found among the packages
#                        Xcode fetched when not given.
#   OHMYMONEY_BUILD_ROOT     the build root, as `make release-local` passes its BUILD_ROOT; when
#                        not set, the real path the `Build.nosync` link points to.
#   SPARKLE_ED_KEY_FILE  a file holding the EdDSA private key as `generate_keys -x` writes it;
#                        `sign_update` reads the key from there instead of the login keychain.
#                        Not set on the owner's Mac; the release workflow sets it on a runner.
#   OHMYMONEY_REQUIRE_CERTIFICATE
#                        when not empty, a missing «OhMyMoney Local Signing» stops the release
#                        instead of signing ad-hoc: a runner must never ship a stranger.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/.." && pwd)"
placeholder="SPARKLE_PUBLIC_KEY_NOT_SET"
dry_run=""
if [ "${1:-}" = "--dry-run" ]; then dry_run="yes"; fi

say() { printf 'release: %s\n' "$1"; }
stop() { printf 'release: %s\n' "$1" >&2; exit 1; }

# The build root by its real path, never through the link in the repository: xcodebuild compares
# what it would delete with the root it was given as text, and reached through the link every
# stale intermediate of the release before is left behind with a warning.
build_root="${OHMYMONEY_BUILD_ROOT:-}"
if [ -z "${build_root}" ]; then
  build_root="$(cd "${root}/Build.nosync" 2> /dev/null && pwd -P)" ||
    stop "no build folder: run make release-local, which makes it, rather than this script alone."
fi

# 1. The public key. A release built with the placeholder would announce updates nobody can
# verify, and Sparkle would refuse every one of them — silently, on the owner's Mac, weeks
# later. So it stops here instead.
key="${SPARKLE_PUBLIC_KEY:-}"
if [ -z "${key}" ] && [ -f "${root}/sparkle-public-key.txt" ]; then
  key="$(tr -d '[:space:]' < "${root}/sparkle-public-key.txt")"
fi
if [ -z "${key}" ]; then
  stop "no public key. Put it in sparkle-public-key.txt or set SPARKLE_PUBLIC_KEY; the key is made by Sparkle's generate_keys on your Mac, and this script never makes one."
fi
if [ "${key}" = "${placeholder}" ]; then
  stop "the public key is still the placeholder ${placeholder}."
fi

# 2. The version being released, read the way the workflow of a tag reads it.
version="$("${here}/release-version.sh" version)" || stop "no version to release"
build="$("${here}/release-version.sh" build)" || stop "no build number to release"
say "version ${version} (build ${build})"
# The build number is compared with every release out: the tags and the feed on gh-pages. Both
# are only as fresh as the last fetch — a release made on GitHub, by the spare workflow or from
# another clone leaves this clone's refs behind, and a build that repeats one installed copies
# already have would pass. So they are fetched first; offline, only a dry run goes on.
if ! git -C "${root}" fetch --quiet --tags origin \
    "+refs/heads/gh-pages:refs/remotes/origin/gh-pages" 2> /dev/null; then
  [ -n "${dry_run}" ] ||
    stop "could not fetch the tags and gh-pages from origin: the build number cannot be compared with what is out."
  say "warning: could not fetch the tags and gh-pages from origin; comparing with what this clone saw last."
fi
grew="$("${here}/release-version.sh" grew)" || stop "raise CURRENT_PROJECT_VERSION in project.yml first."
say "${grew}"

# 3. The signing identity. An ad-hoc signature is different in every build, so an update
# cannot show it came from the same place as what it replaces; the owner's own certificate
# can. Ad-hoc is allowed all the same, so this warns rather than stops.
identity="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"OhMyMoney Local Signing"'; then
  identity="OhMyMoney Local Signing"
elif [ -n "${OHMYMONEY_REQUIRE_CERTIFICATE:-}" ]; then
  stop "no valid «OhMyMoney Local Signing» certificate in the keychains of this user, and an ad-hoc signature is not allowed here: installed copies would refuse the update as another app."
else
  say "warning: no «OhMyMoney Local Signing» certificate; signing ad-hoc, and every build will look like a different author."
fi
say "signing with: ${identity}"

# 4. Sparkle's own signing tool. Never built here and never replaced by something of ours:
# what signs an update is the tool that wrote the format.
signer=""
if [ -n "${SPARKLE_BIN:-}" ] && [ -x "${SPARKLE_BIN}/sign_update" ]; then
  signer="${SPARKLE_BIN}/sign_update"
else
  # Where Xcode puts the tool after it has fetched the package.
  signer="${build_root}/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  if [ ! -x "${signer}" ]; then
    # Two things about this search. The trailing slash: should the build root itself be a
    # symbolic link, `find` does not walk into one handed to it as a starting point unless it
    # is written as a directory. And `-path`, not `-name`: the package ships **three** files
    # called `sign_update`, two of them the DSA script of Sparkle 1 under
    # `bin/old_dsa_scripts/`. Picking one by name is a coin flip between a tool that signs the
    # way Sparkle 2 verifies and one that does not.
    signer="$(find "${build_root}/SourcePackages/artifacts/" -type f -perm -111 \
      -path '*/bin/sign_update' -print -quit 2>/dev/null || true)"
  fi
fi
if [ -z "${signer}" ] || [ ! -x "${signer}" ]; then
  stop "Sparkle's sign_update was not found. Run make build once so the package is fetched, or set SPARKLE_BIN."
fi
say "signing tool: ${signer}"
# The private key: the login keychain, or the file the caller names. The file is read by
# Sparkle's tool alone; nothing here prints it.
key_file="${SPARKLE_ED_KEY_FILE:-}"
if [ -n "${key_file}" ]; then
  [ -s "${key_file}" ] || stop "SPARKLE_ED_KEY_FILE names no file with a key in it."
  say "private key: from a file, not the keychain"
fi

out="${build_root}/release"
app="${out}/Release/OhMyMoney.app"
archive="${out}/OhMyMoney-${version}.zip"
if [ -n "${dry_run}" ]; then
  # The entry is the one step a dry run can take whole: it is written and read back in the
  # feed on made-up values.
  "${here}/release-entry.sh" --self-test > /dev/null || "${here}/release-entry.sh" --self-test
  "${here}/release-version.sh" --self-test > /dev/null || "${here}/release-version.sh" --self-test
  say "dry run: would build Release, package ${archive##*/} and add an entry to appcast.xml"
  exit 0
fi

# 5. Build. The key goes in through the build setting the Info.plist reads, so it never has
# to be written down in the repository.
mkdir -p "${out}"
# The packages are the ones already fetched, not a second copy: without this the release
# downloads Sparkle's binary artifact all over again. The toolchain is Xcode's own, as in every
# build of the Makefile: a `TOOLCHAINS` in the shell would otherwise hand the release to
# another compiler than the one the tests ran with.
xcodebuild -project "${root}/OhMyMoney.xcodeproj" -scheme OhMyMoney -configuration Release \
  -destination 'platform=macOS' -toolchain com.apple.dt.toolchain.XcodeDefault \
  -derivedDataPath "${out}/DerivedData" \
  -clonedSourcePackagesDirPath "${build_root}/SourcePackages" \
  CODE_SIGN_IDENTITY="${identity}" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  SU_PUBLIC_ED_KEY="${key}" build
rm -rf "${out}/Release"
mkdir -p "${out}/Release"
cp -R "${out}/DerivedData/Build/Products/Release/OhMyMoney.app" "${app}"

# 6. What was actually built has to carry the key and the version, not what we meant to build.
built="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${app}/Contents/Info.plist")"
[ "${built}" = "${key}" ] || stop "the built app carries ${built}, not the key that was passed in."
# The id every installed copy is known by: its container, its defaults and Sparkle's services
# are named after it. The Debug build has one of its own, and it must never be what ships.
bundle_id="io.github.EvgenyBaulin.ohmymoney"
built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Contents/Info.plist")"
[ "${built_id}" = "${bundle_id}" ] || stop "the built app is ${built_id}, not ${bundle_id}."
"${here}/release-version.sh" app "${app}" "${version}" "${build}" ||
  stop "the entry would announce a version the archive does not hold."
feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "${app}/Contents/Info.plist")"
say "feed: ${feed}"
# And that the updater is in there at all. A release that carries a key, a feed and no
# Sparkle would look perfectly well until the first update never arrived.
[ -d "${app}/Contents/Frameworks/Sparkle.framework" ] || \
  stop "the built app has no Sparkle.framework: run make build once so the package is fetched."
[ -d "${app}/Contents/Frameworks/Sparkle.framework/XPCServices/Installer.xpc" ] || \
  stop "Sparkle is there but its installer service is not; the update would not install."
[ ! -d "${app}/Contents/XPCServices" ] || \
  stop "the app bundles XPC services of its own; Sparkle refuses to start when it finds them there."


# 7. Package and sign. `ditto` keeps the symlinks and the extended attributes a bundle needs.
rm -f "${archive}"
ditto -c -k --sequesterRsrc --keepParent "${app}" "${archive}"
# `-p`: the signature alone. Without it the tool prints a `length` attribute as well, and the
# entry below writes its own: twice on one element, and the feed would not parse at all.
if [ -n "${key_file}" ]; then
  signature="$("${signer}" --ed-key-file "${key_file}" -p "${archive}")"
else
  signature="$("${signer}" -p "${archive}")"
fi
say "signed: ${signature}"

# 8. The entry that announces it. Written next to the archive, not into the repository: what
# goes on Pages is the owner's to publish. release-entry.sh reads it back inside the envelope
# of the feed first and writes nothing the feed could not carry.
length="$(stat -f%z "${archive}")"
entry="${out}/appcast-entry-${version}.xml"
rm -f "${entry}"
if ! "${here}/release-entry.sh" "${version}" "${build}" "${length}" "${signature}" > "${entry}.partial"; then
  rm -f "${entry}.partial"
  stop "the entry for appcast.xml did not come out whole; the archive is signed, the entry is not written."
fi
mv "${entry}.partial" "${entry}"

# The bundles built here are steps on the way, not copies to open: Launch Services learnt of
# them while they were built, and would offer them for an archive or a feed next to the one in
# /Applications. The files stay — the release is checked from them — the registrations go.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "${lsregister}" ]; then
  "${lsregister}" -u "${app}" 2> /dev/null || true
  "${lsregister}" -u "${out}/DerivedData/Build/Products/Release/OhMyMoney.app" 2> /dev/null || true
fi

say "archive: ${archive}"
say "entry:   ${entry}"
say "next, by hand: create the release v${version} on GitHub, upload the archive, put the entry into appcast.xml on Pages (scripts/release-entry.sh into <gh-pages>/appcast.xml ... does it the way release.yml does)."
say "the archive and the entry are a pair: the entry carries the length and the signature of this archive only, never of one release.yml built."
