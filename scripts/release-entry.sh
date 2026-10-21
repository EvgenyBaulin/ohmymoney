#!/bin/bash
# Writes the <item> that announces a release in the update feed, and refuses to print one that
# the feed could not carry: the entry is put into the envelope of the feed
# (scripts/appcast-envelope.xml) and read back with xmllint before a line of it is printed. A
# feed that does not parse is not one bad entry — Sparkle drops the whole document, and no
# installed copy ever sees an update again.
#
# Usage: release-entry.sh <version> <build> <length> <signature> [<date>]
#        release-entry.sh into <appcast.xml> <version> <build> <length> <signature> [<date>]
#                   puts the entry into that feed, newest first, and refuses a build number the
#                   feed already announces, or one below
#   version    MARKETING_VERSION, X.Y.Z
#   build      CURRENT_PROJECT_VERSION, a whole number
#   length     the size of the archive in bytes
#   signature  the EdDSA signature of the archive alone: what `sign_update -p` prints. Without
#              `-p` the tool prints `sparkle:edSignature="…" length="…"`, and a length written
#              twice on one element is a document no XML parser reads (the length is ours).
#   date       RFC 822 date of the entry; now, when not given
#        release-entry.sh --self-test
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/.." && pwd)"
envelope="${here}/appcast-envelope.xml"
marker="<!-- Release entries go here, newest first. -->"

fail() { printf 'release entry: %s\n' "$1" >&2; exit 1; }

render() {
  local version="$1" build="$2" length="$3" signature="$4" published="$5"
  cat <<XML
    <item>
      <title>${version}</title>
      <pubDate>${published}</pubDate>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/EvgenyBaulin/ohmymoney/releases/download/v${version}/OhMyMoney-${version}.zip"
                 length="${length}"
                 type="application/octet-stream"
                 sparkle:edSignature="${signature}" />
    </item>
XML
}

# Every value goes into the feed as it is, so each is refused unless it has its one form.
# `[[ =~ ]]` and not grep: grep would pass a value of two lines when one of them fits.
check() {
  local version="$1" build="$2" length="$3" signature="$4"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version «${version}» is not X.Y.Z"
  [[ "${build}" =~ ^[1-9][0-9]*$ ]] || fail "build «${build}» is not a whole number above zero"
  [[ "${length}" =~ ^[1-9][0-9]*$ ]] || fail "length «${length}» is not a size in bytes"
  [[ "${signature}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
    fail "the signature is not a bare EdDSA signature; ask sign_update with -p"
}

# A feed as it would be with the entry in it: the entry goes where the feed says entries go,
# which puts it above every entry pasted before — newest first.
in_feed() {
  local feed="$1" entry="$2"
  grep -qF "${marker}" "${feed}" || fail "no «${marker}» in ${feed}"
  awk -v marker="${marker}" -v entry="${entry}" '
    { print }
    index($0, marker) { while ((getline line < entry) > 0) print line }
  ' "${feed}"
}

# Writes the entry into a feed and reads the feed back: fails, with the file untouched, when it
# would not parse.
written_into() {
  local feed="$1"
  shift
  render "$@" > "${scratch}/entry.xml"
  in_feed "${feed}" "${scratch}/entry.xml" > "${scratch}/appcast.xml"
  if ! /usr/bin/xmllint --noout "${scratch}/appcast.xml" 2> "${scratch}/errors"; then
    cat "${scratch}/errors" >&2
    fail "the feed would not parse with this entry in it; nothing was written"
  fi
}

# Prints the entry when the envelope of the feed with it parses; says why not, and prints
# nothing, otherwise.
entry() {
  check "$1" "$2" "$3" "$4"
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/ohmymoney-entry.XXXXXX")"
  trap 'rm -rf "${scratch}"' EXIT
  written_into "${envelope}" "$@"
  cat "${scratch}/entry.xml"
}

# Puts the entry into the live feed itself (the workflow of a tag does this on the branch Pages
# publishes). Sparkle offers what has the greatest build number, so an entry whose build is not
# above every one the feed announces would be a release nobody is offered — or, run twice, the
# same release announced twice.
into() {
  local feed="$1" build="$3" newer
  [ -f "${feed}" ] || fail "no feed at ${feed}"
  shift
  check "$1" "$2" "$3" "$4"
  newer="$(/usr/bin/xmllint --xpath \
    "count(//*[local-name()='item']/*[local-name()='version'][number(.) >= ${build}])" "${feed}")" ||
    fail "the feed at ${feed} does not parse as it is"
  [ "${newer}" = "0" ] || fail "the feed already announces a build of ${build} or above"
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/ohmymoney-entry.XXXXXX")"
  trap 'rm -rf "${scratch}"' EXIT
  written_into "${feed}" "$@"
  cat "${scratch}/appcast.xml" > "${feed}"
}

if [ "${1:-}" = "--self-test" ]; then
  date="Thu, 24 Sep 2026 10:00:00 +0000"
  # What Sparkle's sign_update prints for an archive, with -p and without, word for word in form.
  bare="uBgNQfm0zgveLzZY/vJ6ZgtMy1eA3E16USKFRh46yworcViVcOmaYdVACh4MRGHnKqd77BnHJEkZLvwevbDmBw=="
  printed="sparkle:edSignature=\"${bare}\" length=\"123\""
  if ! out="$(entry 1.0.1 2 123 "${bare}" "${date}" 2>&1)"; then
    printf 'release-entry self-test: the entry of a signed archive does not parse in the feed\n%s\n' "${out}"
    exit 1
  fi
  lengths="$(printf '%s\n' "${out}" | grep -o 'length="[^"]*"' | tr '\n' ' ')"
  if [ "${lengths}" != 'length="123" ' ]; then
    printf 'release-entry self-test: expected one length="123", found: %s\n' "${lengths}"
    exit 1
  fi
  # Anything but the bare signature is refused before it reaches the feed: the whole line of
  # sign_update, a value that would close the attribute, a second line.
  for wrong in "${printed}" "${bare}\" length=\"1" "$(printf '%s\n%s' "${bare}" "${bare}")"; do
    if (entry 1.0.1 2 123 "${wrong}" "${date}" > /dev/null 2>&1); then
      printf 'release-entry self-test: took a signature that is not one: %s\n' "${wrong}"
      exit 1
    fi
  done
  for args in "1.0 2 123" "1.0.1 0 123" "1.0.1 two 123" "1.0.1 2 0"; do
    # shellcheck disable=SC2086
    if (entry ${args} "${bare}" "${date}" > /dev/null 2>&1); then
      printf 'release-entry self-test: took version, build and length %s\n' "${args}"
      exit 1
    fi
  done
  # The live feed on Pages: an entry goes in newest first, once, and only with a build number
  # above every one the feed already announces.
  feed="$(mktemp -d "${TMPDIR:-/tmp}/ohmymoney-feed.XXXXXX")/appcast.xml"
  cp "${envelope}" "${feed}"
  (into "${feed}" 1.0.0 1 100 "${bare}" "${date}") ||
    { echo "release-entry self-test: the first entry did not go into the feed"; exit 1; }
  (into "${feed}" 1.0.1 2 123 "${bare}" "${date}") ||
    { echo "release-entry self-test: the second entry did not go into the feed"; exit 1; }
  before="$(cat "${feed}")"
  for args in "1.0.1 2 123" "1.0.2 2 124" "1.0.2 1 124"; do
    # shellcheck disable=SC2086
    if (into "${feed}" ${args} "${bare}" "${date}" 2> /dev/null); then
      echo "release-entry self-test: the feed took ${args} after build 2"
      exit 1
    fi
    [ "$(cat "${feed}")" = "${before}" ] ||
      { echo "release-entry self-test: a refused entry changed the feed"; exit 1; }
  done
  /usr/bin/xmllint --noout "${feed}" ||
    { echo "release-entry self-test: the feed with two entries does not parse"; exit 1; }
  order="$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "${feed}" | tr -dc '0-9\n' | tr '\n' ' ')"
  [ "${order}" = "2 1 " ] ||
    { echo "release-entry self-test: the feed lists builds «${order}», not the newest first"; exit 1; }
  rm -rf "$(dirname "${feed}")"
  echo "release-entry self-test: ok"
  exit 0
fi

now="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
if [ "${1:-}" = "into" ]; then
  [ "$#" -ge 6 ] ||
    fail "usage: release-entry.sh into <appcast.xml> <version> <build> <length> <signature> [<date>]"
  into "$2" "$3" "$4" "$5" "$6" "${7:-${now}}"
  exit 0
fi
[ "$#" -ge 4 ] || fail "usage: release-entry.sh <version> <build> <length> <signature> [<date>]"
entry "$1" "$2" "$3" "$4" "${5:-${now}}"
