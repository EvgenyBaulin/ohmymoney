#!/bin/bash
# Looks at a published release from the outside, the way an installed copy meets it: the feed at
# the address every copy asks, the archive the feed points at, and the app inside that archive.
# Run it after a release is out; it writes nothing but a temporary folder it removes.
#
# What it refuses:
#   * a feed that does not parse, or whose entries are not newest first with a build number
#     each greater than the one below it (Sparkle offers the greatest build; two entries with
#     one build are one release announced twice);
#   * an entry whose archive address is not the release of its own version;
#   * an archive of another size than the feed says, or whose EdDSA signature does not hold for
#     the public key of the repository — Sparkle refuses such an update on every Mac, silently;
#   * an app inside that is not io.github.EvgenyBaulin.ohmymoney, says another version or build,
#     carries another key or feed address, asks for another macOS than the feed says, has a
#     broken signature, has no installer service of Sparkle or services of its own, or carries
#     another Sparkle than project.yml pins;
#   * an app not signed by the owner's certificate «OhMyMoney Local Signing» — an ad-hoc signature
#     verifies all the same, and make-release.sh only warns without the certificate;
#   * an app that does not satisfy the designated requirement of the app of the entry below it:
#     macOS keys the sandbox container and the keychain items of an installed copy to its
#     signature, and Sparkle, whose EdDSA check a new signer passes, would install a stranger.
#
# The feed comes through the cache of Pages: minutes after a push to gh-pages the address may
# still serve the feed before it. A version the address does not announce and the branch
# origin/gh-pages does is said to be that.
#
# Usage: check-release.sh [<version>]   the entry of that version; the newest when not given
#        check-release.sh --candidate <OhMyMoney.app> [<OhMyMoney-X.Y.Z.zip> <signature>]
#                                       an app built for release and not yet published, against
#                                       the newest entry: its build above it, the same id, key
#                                       and feed, the owner's certificate, the Sparkle pinned,
#                                       and the designated requirement of the release before;
#                                       with its archive and the EdDSA signature of its entry,
#                                       the signature holds for the repository's public key and
#                                       the archive holds OhMyMoney.app alone
#        check-release.sh --self-test   the checks on made-up feeds, keys and apps, offline
#   OHMYMONEY_FEED_URL      the feed to read instead of the published one
#   SPARKLE_PUBLIC_KEY  the key to check against; sparkle-public-key.txt when not set
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/.." && pwd)"
feed_url="https://EvgenyBaulin.github.io/ohmymoney/appcast.xml"
bundle_id="io.github.EvgenyBaulin.ohmymoney"
downloads="https://github.com/EvgenyBaulin/ohmymoney/releases/download"
certificate="OhMyMoney Local Signing"

fail() { printf 'release check: %s\n' "$1" >&2; exit 1; }
say() { printf 'release check: %s\n' "$1"; }

# One value of the feed, by an XPath over local names: the feed is read as XML, not as lines.
value() {
  /usr/bin/xmllint --xpath "string($2)" "$1" 2> /dev/null
}

# Prints one line per entry, in the order of the feed, the fields between bars, so a field the
# entry lacks stays an empty field and never lends its place to the next one:
#   <build>|<version>|<minimum macOS>|<length>|<signature>|<archive address>
entries() {
  local feed="$1" count index item
  count="$(/usr/bin/xmllint --xpath "count(//*[local-name()='item'])" "${feed}" 2> /dev/null)" ||
    fail "the feed does not parse"
  index=1
  while [ "${index}" -le "${count}" ]; do
    item="(//*[local-name()='item'])[${index}]"
    printf '%s|%s|%s|%s|%s|%s\n' \
      "$(value "${feed}" "${item}/*[local-name()='version']")" \
      "$(value "${feed}" "${item}/*[local-name()='shortVersionString']")" \
      "$(value "${feed}" "${item}/*[local-name()='minimumSystemVersion']")" \
      "$(value "${feed}" "${item}/*[local-name()='enclosure']/@length")" \
      "$(value "${feed}" "${item}/*[local-name()='enclosure']/@*[local-name()='edSignature']")" \
      "$(value "${feed}" "${item}/*[local-name()='enclosure']/@url")"
    index=$((index + 1))
  done
}

# The entry right under the one of a version, as `entries` prints it; nothing for the last one.
# awk reads to the end: one that left at the entry it wanted would close the pipe while
# `entries` still writes the entries under it, and under pipefail that SIGPIPE ends the whole
# check with 141 for every version but the last two of the feed.
below_of() {
  entries "$1" |
    awk -F '|' -v wanted="$2" 'found && !taken { print; taken = 1 } $2 == wanted { found = 1 }'
}

# The feed as a whole: every entry whole, the builds falling from the top down, one entry per
# version.
check_feed() {
  local feed="$1" lines below="" seen=" " build version minimum length signature url
  /usr/bin/xmllint --noout "${feed}" 2> /dev/null || fail "the feed does not parse"
  lines="$(entries "${feed}")"
  [ -n "${lines}" ] || fail "the feed announces no release"
  while IFS='|' read -r build version minimum length signature url; do
    [[ "${build}" =~ ^[1-9][0-9]*$ ]] || fail "an entry has the build «${build}»"
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "an entry has the version «${version}»"
    [[ "${minimum}" =~ ^[0-9]+(\.[0-9]+)*$ ]] ||
      fail "the entry of ${version} names no minimum macOS"
    [[ "${length}" =~ ^[1-9][0-9]*$ ]] || fail "the entry of ${version} has the length «${length}»"
    [[ "${signature}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
      fail "the entry of ${version} carries no bare EdDSA signature"
    [ "${url}" = "${downloads}/v${version}/OhMyMoney-${version}.zip" ] ||
      fail "the entry of ${version} points at ${url}"
    if [ -n "${below}" ] && [ "${build}" -ge "${below}" ]; then
      fail "build ${build} of ${version} stands under build ${below}: the feed is not newest first, or announces a build twice"
    fi
    case "${seen}" in
      *" ${version} "*) fail "the feed announces ${version} twice" ;;
    esac
    seen="${seen}${version} "
    below="${build}"
  done <<< "${lines}"
}

# Sparkle's EdDSA is Ed25519 over the whole archive; CryptoKit reads the same key and signature.
# `sign` is for the self-test only: a key made on the spot, never one of the owner's.
ed25519() {
  local program="${scratch}/ed25519.swift"
  cat > "${program}" <<'SWIFT'
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
switch arguments[1] {
case "verify":
  guard let raw = Data(base64Encoded: arguments[2]), let signature = Data(base64Encoded: arguments[4]),
    let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
  else { exit(2) }
  let data = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
  exit(key.isValidSignature(signature, for: data) ? 0 : 1)
default:
  let key = Curve25519.Signing.PrivateKey()
  let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
  let signature = try key.signature(for: data)
  print(key.publicKey.rawRepresentation.base64EncodedString(), signature.base64EncodedString())
}
SWIFT
  xcrun swift "${program}" "$@"
}

# The archive as downloaded: the size the feed announces, and the signature made for it with the
# key installed copies carry.
check_archive() {
  local archive="$1" length="$2" signature="$3" key="$4" size
  size="$(stat -f%z "${archive}")"
  [ "${size}" = "${length}" ] || fail "the archive is ${size} bytes, the feed says ${length}"
  ed25519 verify "${key}" "${archive}" "${signature}" ||
    fail "the EdDSA signature of the archive does not hold for the repository's key"
}

# What the app says about itself, against what the feed and the repository say it must.
check_plist() {
  local plist="$1" version="$2" build="$3" key="$4" minimum="$5" said
  said="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" 2> /dev/null || true)"
  [ "${said}" = "${bundle_id}" ] || fail "the app is «${said}», not ${bundle_id}"
  said="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" 2> /dev/null || true)"
  [ "${said}" = "${version}" ] || fail "the app says version «${said}», the feed ${version}"
  said="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}" 2> /dev/null || true)"
  [ "${said}" = "${build}" ] || fail "the app says build «${said}», the feed ${build}"
  said="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${plist}" 2> /dev/null || true)"
  [ "${said}" = "${key}" ] || fail "the app carries another Sparkle key than the repository's"
  said="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "${plist}" 2> /dev/null || true)"
  [ "${said}" = "${feed_url}" ] || fail "the app asks for updates at «${said}», not ${feed_url}"
  said="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${plist}" 2> /dev/null || true)"
  [ "${said}" = "${minimum}" ] ||
    fail "the app asks for macOS «${said}», the feed promises ${minimum}"
}

# The first authority of a signature as `codesign -dvv` describes it (the leaf certificate), or
# «ad-hoc» when it names none.
authority_in() {
  local said
  said="$(printf '%s\n' "$1" | sed -n 's/^Authority=//p' | sed -n 1p)"
  printf '%s\n' "${said:-ad-hoc}"
}

signer_of() {
  local details
  details="$(codesign -dvv "$1" 2>&1)" || fail "codesign cannot read the signature of ${1##*/}"
  authority_in "${details}"
}

# The version of Sparkle a project.yml pins with `exactVersion`.
pinned_sparkle() {
  awk '/^  Sparkle:/ { inside = 1; next } inside && /^  [^ ]/ { inside = 0 }
    inside && /exactVersion:/ { print $2; exit }' "$1"
}

# The bundle as macOS and Sparkle meet it: a signature that holds, made by the certificate
# given, Sparkle's installer service and none of the app's own, and the Sparkle pinned.
check_bundle() {
  local app="$1" signer="$2" sparkle="$3" said
  codesign --verify --deep --strict "${app}" 2> "${scratch}/codesign" || {
    cat "${scratch}/codesign" >&2
    fail "the signature of the app does not hold"
  }
  said="$(signer_of "${app}")"
  [ "${said}" = "${signer}" ] ||
    fail "the app is signed by «${said}», not «${signer}»: installed copies would meet another author"
  [ -d "${app}/Contents/Frameworks/Sparkle.framework/XPCServices/Installer.xpc" ] ||
    fail "the app has no installer service of Sparkle; no update would install"
  [ ! -d "${app}/Contents/XPCServices" ] ||
    fail "the app bundles XPC services of its own; Sparkle refuses to start"
  said="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${app}/Contents/Frameworks/Sparkle.framework/Resources/Info.plist" 2> /dev/null || true)"
  [ -n "${sparkle}" ] && [ "${said}" = "${sparkle}" ] ||
    fail "the app carries Sparkle «${said}», project.yml pins «${sparkle}»"
}

# The designated requirement an installed copy states, and the app that replaces it meeting it.
requirement_of() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p' | sed -n 1p
}

check_successor() {
  local before="$1" app="$2" requirement
  requirement="$(requirement_of "${before}")"
  [ -n "${requirement}" ] || fail "the app of the release before states no designated requirement"
  codesign --verify -R "=${requirement}" "${app}" 2> "${scratch}/codesign" || {
    cat "${scratch}/codesign" >&2
    fail "the app does not satisfy the designated requirement of the release before it («${requirement}»): installed copies would take it for another app"
  }
}

if [ "${1:-}" = "--self-test" ]; then
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/ohmymoney-release-check.XXXXXX")"
  trap 'rm -rf "${scratch}"' EXIT
  bare="uBgNQfm0zgveLzZY/vJ6ZgtMy1eA3E16USKFRh46yworcViVcOmaYdVACh4MRGHnKqd77BnHJEkZLvwevbDmBw=="
  # A feed in the form scripts/release-entry.sh writes, with the entries given as
  # «build version length url» from the top down.
  feed_of() {
    local build version length url
    printf '<?xml version="1.0" standalone="yes"?>\n'
    printf '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    printf '<channel><title>OhMyMoney</title>\n'
    for entry in "$@"; do
      read -r build version length url <<< "${entry}"
      printf '<item><title>%s</title><sparkle:version>%s</sparkle:version>' "${version}" "${build}"
      printf '<sparkle:shortVersionString>%s</sparkle:shortVersionString>' "${version}"
      if [ -n "${entry_minimum}" ]; then
        printf '<sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>' "${entry_minimum}"
      fi
      printf '<enclosure url="%s" length="%s" type="application/octet-stream" sparkle:edSignature="%s" /></item>\n' \
        "${url:-${downloads}/v${version}/OhMyMoney-${version}.zip}" "${length}" "${entry_signature}"
    done
    printf '</channel></rss>\n'
  }
  entry_minimum="26.0"
  entry_signature="${bare}"
  feed="${scratch}/appcast.xml"
  feed_of "3 1.1.1 120" "2 1.1.0 110" "1 1.0.0 100" > "${feed}"
  (check_feed "${feed}") || { echo "check-release self-test: refused a whole feed"; exit 1; }
  [ "$(entries "${feed}" | sed -n 2p)" = "2|1.1.0|26.0|110|${bare}|${downloads}/v1.1.0/OhMyMoney-1.1.0.zip" ] ||
    { echo "check-release self-test: read the second entry as «$(entries "${feed}" | sed -n 2p)»"; exit 1; }
  # `check-release.sh 1.1.1` over this feed of three: the entry under the one asked for is read,
  # and the reading itself succeeds, for the top entry as for the last.
  for asked in "1.1.1|2|1.1.0|110" "1.1.0|1|1.0.0|100" "1.0.0|"; do
    IFS='|' read -r version build under length <<< "${asked}"
    expected=""
    [ -z "${build}" ] ||
      expected="${build}|${under}|26.0|${length}|${bare}|${downloads}/v${under}/OhMyMoney-${under}.zip"
    found="$(below_of "${feed}" "${version}")" || {
      echo "check-release self-test: reading the entry under ${version} failed with $?"
      exit 1
    }
    [ "${found}" = "${expected}" ] ||
      { echo "check-release self-test: read the entry under ${version} as «${found}»"; exit 1; }
  done
  # Each of these is one feed an installed copy would be misled by.
  wrong=(
    "2 1.1.0 110|3 1.1.1 120"
    "2 1.1.1 120|2 1.1.0 110"
    "3 1.1.0 120|2 1.1.0 110"
    "3 1.1.1 120 ${downloads}/v1.1.0/OhMyMoney-1.1.0.zip|2 1.1.0 110"
    "3 1.1.1 0|2 1.1.0 110"
    "0 1.1.1 120"
    "3 1.1 120"
  )
  for broken in "${wrong[@]}"; do
    IFS='|' read -r -a given <<< "${broken}"
    feed_of "${given[@]}" > "${feed}"
    if (check_feed "${feed}" 2> /dev/null); then
      echo "check-release self-test: took the feed «${broken}»"
      exit 1
    fi
  done
  printf '<rss><channel><item>' > "${feed}"
  if (check_feed "${feed}" 2> /dev/null); then
    echo "check-release self-test: took a feed that does not parse"
    exit 1
  fi
  feed_of > "${feed}"
  if (check_feed "${feed}" 2> /dev/null); then
    echo "check-release self-test: took a feed that announces nothing"
    exit 1
  fi
  # An entry without its minimum macOS is offered to every Mac; a signature with the rest of
  # sign_update's line glued on, or none, is one Sparkle cannot check.
  for broken in "minimum=" "signature=${bare%%=*}length=110" "signature=" "signature=${bare} length=110"; do
    entry_minimum="26.0"
    entry_signature="${bare}"
    case "${broken}" in
      minimum=*) entry_minimum="${broken#minimum=}" ;;
      signature=*) entry_signature="${broken#signature=}" ;;
    esac
    feed_of "3 1.1.1 120" "2 1.1.0 110" > "${feed}"
    if (check_feed "${feed}" 2> /dev/null); then
      echo "check-release self-test: took a feed whose entries have «${broken}»"
      exit 1
    fi
  done
  entry_minimum="26.0"
  entry_signature="${bare}"
  # The signature holds for the archive it was made for, and for nothing else.
  printf 'an archive' > "${scratch}/archive.zip"
  read -r public signature <<< "$(ed25519 sign "${scratch}/archive.zip")"
  ed25519 verify "${public}" "${scratch}/archive.zip" "${signature}" ||
    { echo "check-release self-test: refused a signature that holds"; exit 1; }
  printf 'another archive' > "${scratch}/other.zip"
  if ed25519 verify "${public}" "${scratch}/other.zip" "${signature}"; then
    echo "check-release self-test: took the signature of another archive"
    exit 1
  fi
  read -r other _ <<< "$(ed25519 sign "${scratch}/archive.zip")"
  if ed25519 verify "${other}" "${scratch}/archive.zip" "${signature}"; then
    echo "check-release self-test: took a signature made with another key"
    exit 1
  fi
  (check_archive "${scratch}/archive.zip" 10 "${signature}" "${public}") ||
    { echo "check-release self-test: refused the archive the feed describes"; exit 1; }
  for given in "11 ${signature} ${public}" "10 ${signature} ${other}" "10 ${bare} ${public}"; do
    # shellcheck disable=SC2086
    if (check_archive "${scratch}/archive.zip" ${given} 2> /dev/null); then
      echo "check-release self-test: took an archive of 10 bytes for «${given}»"
      exit 1
    fi
  done
  # The app says what the feed says, or it is refused.
  plist="${scratch}/Info.plist"
  make_plist() {
    rm -f "${plist}"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $1" \
      -c "Add :CFBundleShortVersionString string $2" -c "Add :CFBundleVersion string $3" \
      -c "Add :SUPublicEDKey string $4" -c "Add :SUFeedURL string $5" \
      -c "Add :LSMinimumSystemVersion string $6" "${plist}" > /dev/null
  }
  make_plist "${bundle_id}" 1.1.1 3 "${public}" "${feed_url}" 26.0
  (check_plist "${plist}" 1.1.1 3 "${public}" 26.0) ||
    { echo "check-release self-test: refused an app that says what the feed says"; exit 1; }
  for said in "${bundle_id}.debug 1.1.1 3 ${public} ${feed_url} 26.0" \
    "${bundle_id} 1.1.0 3 ${public} ${feed_url} 26.0" \
    "${bundle_id} 1.1.1 2 ${public} ${feed_url} 26.0" \
    "${bundle_id} 1.1.1 3 ${other} ${feed_url} 26.0" \
    "${bundle_id} 1.1.1 3 ${public} https://example.invalid/appcast.xml 26.0" \
    "${bundle_id} 1.1.1 3 ${public} ${feed_url} 27.0"; do
    # shellcheck disable=SC2086
    make_plist ${said}
    if (check_plist "${plist}" 1.1.1 3 "${public}" 26.0 2> /dev/null); then
      echo "check-release self-test: took an app saying «${said}»"
      exit 1
    fi
  done
  # Made-up apps, signed ad-hoc on the spot: an executable, Sparkle's framework with its
  # installer service, each part signed from the inside out as Xcode does. What a variant
  # leaves out or adds is named by its arguments: no-installer, own-service, sparkle=<version>,
  # resource=<text>.
  made_app() {
    local app="$1" framework executable="/usr/bin/true" sparkle="2.10.0" resource="one"
    local installer="yes" own="" option
    shift
    for option in "$@"; do
      case "${option}" in
        no-installer) installer="" ;;
        own-service) own="yes" ;;
        sparkle=*) sparkle="${option#sparkle=}" ;;
        resource=*) resource="${option#resource=}" ;;
      esac
    done
    rm -rf "${app}"
    framework="${app}/Contents/Frameworks/Sparkle.framework"
    mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources" "${framework}/Versions/B/Resources"
    cp "${executable}" "${app}/Contents/MacOS/OhMyMoney"
    cp "${executable}" "${framework}/Versions/B/Sparkle"
    printf '%s' "${resource}" > "${app}/Contents/Resources/resource.txt"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${bundle_id}" \
      -c 'Add :CFBundleExecutable string OhMyMoney' "${app}/Contents/Info.plist" > /dev/null
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string org.sparkle-project.Sparkle' \
      -c 'Add :CFBundleExecutable string Sparkle' -c 'Add :CFBundlePackageType string FMWK' \
      -c "Add :CFBundleShortVersionString string ${sparkle}" \
      "${framework}/Versions/B/Resources/Info.plist" > /dev/null
    ln -s B "${framework}/Versions/Current"
    ln -s Versions/Current/Sparkle "${framework}/Sparkle"
    ln -s Versions/Current/Resources "${framework}/Resources"
    if [ -n "${installer}" ]; then
      service "${framework}/Versions/B/XPCServices/Installer.xpc" Installer
      ln -s Versions/Current/XPCServices "${framework}/XPCServices"
    fi
    [ -z "${own}" ] || service "${app}/Contents/XPCServices/Helper.xpc" Helper
    codesign -f -s - "${framework}" 2> /dev/null
    codesign -f -s - "${app}" 2> /dev/null
  }
  service() {
    mkdir -p "$1/Contents/MacOS"
    cp /usr/bin/true "$1/Contents/MacOS/$2"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string org.example.$2" \
      -c "Add :CFBundleExecutable string $2" -c 'Add :CFBundlePackageType string XPC!' \
      "$1/Contents/Info.plist" > /dev/null
    codesign -f -s - "$1" 2> /dev/null
  }
  app="${scratch}/apps/OhMyMoney.app"
  made_app "${app}"
  (check_bundle "${app}" ad-hoc 2.10.0) ||
    { echo "check-release self-test: refused a whole app"; exit 1; }
  if (check_bundle "${app}" "${certificate}" 2.10.0 2> /dev/null); then
    echo "check-release self-test: took an ad-hoc signature for «${certificate}»"
    exit 1
  fi
  printf 'two' > "${app}/Contents/Resources/resource.txt"
  if (check_bundle "${app}" ad-hoc 2.10.0 2> /dev/null); then
    echo "check-release self-test: took an app changed after it was signed"
    exit 1
  fi
  for variant in no-installer own-service sparkle=2.9.0; do
    made_app "${app}" "${variant}"
    if (check_bundle "${app}" ad-hoc 2.10.0 2> /dev/null); then
      echo "check-release self-test: took an app with «${variant}»"
      exit 1
    fi
  done
  made_app "${app}" sparkle=
  if (check_bundle "${app}" ad-hoc "" 2> /dev/null); then
    echo "check-release self-test: took a Sparkle without a version while project.yml pins none"
    exit 1
  fi
  [ "$(authority_in "$(printf 'Identifier=x\nAuthority=%s\nAuthority=Root\n' "${certificate}")")" = "${certificate}" ] ||
    { echo "check-release self-test: did not read the leaf authority of a signature"; exit 1; }
  printf 'packages:\n  Other:\n    exactVersion: 9.9.9\n  Sparkle:\n    url: https://example.invalid\n    exactVersion: 2.10.0\n  Last:\n    exactVersion: 8.8.8\n' \
    > "${scratch}/project.yml"
  [ "$(pinned_sparkle "${scratch}/project.yml")" = "2.10.0" ] ||
    { echo "check-release self-test: read «$(pinned_sparkle "${scratch}/project.yml")» as the Sparkle pinned"; exit 1; }
  # The same app, signed again, meets the requirement of the one before; another does not
  # (an ad-hoc requirement is the code's own hash, a certificate's is the certificate).
  made_app "${scratch}/apps/Before.app"
  made_app "${app}"
  (check_successor "${scratch}/apps/Before.app" "${app}") ||
    { echo "check-release self-test: refused the app the one before requires"; exit 1; }
  made_app "${app}" resource=another
  if (check_successor "${scratch}/apps/Before.app" "${app}" 2> /dev/null); then
    echo "check-release self-test: took an app the one before does not require"
    exit 1
  fi
  echo "check-release self-test: ok"
  exit 0
fi

wanted="${1:-}"
candidate=""
if [ "${wanted}" = "--candidate" ]; then
  candidate="${2:-}"
  candidate_archive="${3:-}"
  candidate_signature="${4:-}"
  wanted=""
  [ -d "${candidate}" ] ||
    fail "usage: check-release.sh --candidate <OhMyMoney.app> [<OhMyMoney-X.Y.Z.zip> <signature>]"
  if [ -n "${candidate_archive}" ]; then
    [ -f "${candidate_archive}" ] && [ -n "${candidate_signature}" ] ||
      fail "usage: check-release.sh --candidate <OhMyMoney.app> [<OhMyMoney-X.Y.Z.zip> <signature>]"
  fi
fi
key="${SPARKLE_PUBLIC_KEY:-}"
if [ -z "${key}" ] && [ -f "${root}/sparkle-public-key.txt" ]; then
  key="$(tr -d '[:space:]' < "${root}/sparkle-public-key.txt")"
fi
[ -n "${key}" ] || fail "no public key: put it in sparkle-public-key.txt or set SPARKLE_PUBLIC_KEY"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ohmymoney-release-check.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT
feed="${scratch}/appcast.xml"
source_url="${OHMYMONEY_FEED_URL:-${feed_url}}"
curl -fsSL --retry 2 -o "${feed}" "${source_url}" || fail "the feed at ${source_url} did not download"
check_feed "${feed}"
say "feed: $(entries "${feed}" | awk -F '|' '{ printf "%s%s (%s)", sep, $2, $1; sep = ", " }')"

if [ -n "${wanted}" ]; then
  line="$(entries "${feed}" | awk -F '|' -v wanted="${wanted}" '$2 == wanted' | sed -n 1p)"
  if [ -z "${line}" ]; then
    branch="$(git -C "${root}" show refs/remotes/origin/gh-pages:appcast.xml 2> /dev/null || true)"
    case "${branch}" in
      *"<sparkle:shortVersionString>${wanted}</sparkle:shortVersionString>"*)
        fail "the feed at ${source_url} does not announce ${wanted} yet, origin/gh-pages does: Pages serves the feed through a cache for some minutes; run this again a little later" ;;
    esac
    fail "the feed does not announce ${wanted}"
  fi
  below="$(below_of "${feed}" "${wanted}")"
else
  line="$(entries "${feed}" | sed -n 1p)"
  below="$(entries "${feed}" | sed -n 2p)"
fi
IFS='|' read -r build version minimum length signature url <<< "${line}"

# The archive of one entry, downloaded, measured, its signature checked, and unpacked; prints
# the path of the app inside.
unpack() {
  local version="$1" length="$2" signature="$3" url="$4" archive
  archive="${scratch}/${url##*/}"
  curl -fsSL --retry 2 -o "${archive}" "${url}" || fail "the archive at ${url} did not download"
  check_archive "${archive}" "${length}" "${signature}" "${key}"
  ditto -x -k "${archive}" "${scratch}/unpacked-${version}"
  [ -d "${scratch}/unpacked-${version}/OhMyMoney.app" ] ||
    fail "the archive of ${version} holds no OhMyMoney.app at its top"
  printf '%s\n' "${scratch}/unpacked-${version}/OhMyMoney.app"
}

app="$(unpack "${version}" "${length}" "${signature}" "${url}")"
say "archive: ${url##*/}, ${length} bytes, EdDSA signature holds"

if [ -n "${candidate}" ]; then
  plist="${candidate}/Contents/Info.plist"
  said_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" 2> /dev/null || true)"
  said_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}" 2> /dev/null || true)"
  said_minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${plist}" 2> /dev/null || true)"
  [[ "${said_build}" =~ ^[1-9][0-9]*$ ]] && [ "${said_build}" -gt "${build}" ] ||
    fail "the candidate is build «${said_build}», not above build ${build} of ${version} the feed announces: Sparkle would never offer it"
  check_plist "${plist}" "${said_version}" "${said_build}" "${key}" "${said_minimum}"
  sparkle="$(pinned_sparkle "${root}/project.yml")"
  check_bundle "${candidate}" "${certificate}" "${sparkle}"
  check_successor "${app}" "${candidate}"
  # The archive installed copies would download, signed with the private key that pairs with
  # the public key inside the app: a key file of another pair signs an update every Mac refuses.
  if [ -n "${candidate_archive}" ]; then
    check_archive "${candidate_archive}" "$(stat -f%z "${candidate_archive}")" \
      "${candidate_signature}" "${key}"
    # Read whole, not with `grep -q`: under pipefail a reader that leaves early fails the
    # pipeline, and the failure would read as «nothing found».
    extra="$(unzip -Z1 "${candidate_archive}" | grep -vE '^(OhMyMoney\.app/|__MACOSX/)' || true)"
    [ -z "${extra}" ] ||
      fail "the archive ${candidate_archive##*/} holds something besides OhMyMoney.app: $(printf '%s\n' "${extra}" | sed -n 1p)"
    say "candidate archive: ${candidate_archive##*/}, EdDSA signature holds for the repository's key"
  fi
  say "candidate: ${said_version} (${said_build}) above ${version} (${build}), the repository's key and feed, signed by ${certificate}, Sparkle ${sparkle}, meets the designated requirement of ${version}"
  say "ok"
  exit 0
fi

# The Sparkle the release was built with: project.yml at its tag, or of this tree when the tag
# is not here.
spec="${scratch}/project.yml"
git -C "${root}" show "v${version}:project.yml" > "${spec}" 2> /dev/null || cp "${root}/project.yml" "${spec}"
sparkle="$(pinned_sparkle "${spec}")"
check_plist "${app}/Contents/Info.plist" "${version}" "${build}" "${key}" "${minimum}"
check_bundle "${app}" "${certificate}" "${sparkle}"
say "app: ${bundle_id} ${version} (${build}), macOS ${minimum}, the repository's key and feed, signed by ${certificate}, Sparkle ${sparkle} with its installer"

if [ -n "${below}" ]; then
  IFS='|' read -r _ before_version _ before_length before_signature before_url <<< "${below}"
  before="$(unpack "${before_version}" "${before_length}" "${before_signature}" "${before_url}")"
  check_successor "${before}" "${app}"
  say "update: ${before_version} → ${version}, the archive of ${before_version} holds too, and ${version} meets the designated requirement of ${before_version}"
else
  say "update: ${version} is the first release of the feed, nothing before it to meet"
fi
say "ok"
