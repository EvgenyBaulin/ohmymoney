#!/bin/bash
# The version of a release, read in one place and checked in the places it ends up. Used by
# make-release.sh and by .github/workflows/release.yml alike.
#
# The rule: CFBundleShortVersionString comes from the tag,
# CFBundleVersion grows with every release. The version lives in project.yml,
# so a tag has to say what project.yml says, and the app that was built
# has to say it too. Sparkle compares CFBundleVersion only: an archive named 1.0.1 that holds an
# app saying 1.0.0 (1) is either never offered or offered again after every install.
#
# Usage: release-version.sh version [<project.yml>]     prints MARKETING_VERSION
#        release-version.sh build [<project.yml>]       prints CURRENT_PROJECT_VERSION
#        release-version.sh tag <tag> [<project.yml>]   fails unless the tag is v<MARKETING_VERSION>
#        release-version.sh app <OhMyMoney.app> <version> <build>
#                                                       fails unless the built app says both
#        release-version.sh grew [<repository>]         fails unless CURRENT_PROJECT_VERSION is
#                                                       greater than at the release before and
#                                                       than every build the feed on
#                                                       origin/gh-pages announces
#        release-version.sh --self-test
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/.." && pwd)"

fail() { printf 'release version: %s\n' "$1" >&2; exit 1; }

# The first line of project.yml that sets the key, quotes and spaces taken away.
setting() {
  awk -v key="$1" '$1 == key ":" { gsub(/[" ]/, "", $2); print $2; exit }' "$2"
}

marketing() {
  local value
  value="$(setting MARKETING_VERSION "$1")"
  [ -n "${value}" ] || fail "no MARKETING_VERSION in $1"
  printf '%s\n' "${value}"
}

build_number() {
  local value
  value="$(setting CURRENT_PROJECT_VERSION "$1")"
  [ -n "${value}" ] || fail "no CURRENT_PROJECT_VERSION in $1"
  printf '%s\n' "${value}"
}

check_tag() {
  local tag="$1" spec version
  spec="$(marketing "$2")"
  version="${tag#v}"
  [ "${tag}" = "v${version}" ] || fail "tag ${tag} does not start with v"
  [ "${version}" = "${spec}" ] || fail "tag ${tag} but project.yml says ${spec}"
}

# The feed on the branch Pages publishes, as this clone last fetched or pushed it: every build it
# announces is on somebody's Mac already. A release published with `gh release create` gets its
# tag on GitHub and not here, so until the next fetch the nearest tag under HEAD is the release
# before it, and only the feed still knows the last build. A clone that never saw the branch
# has nothing to compare with, and says so, the way a missing tag is said aloud below; a feed
# that does not parse is one Sparkle drops whole, and no release should go out over it. The ref
# is only as fresh as the last fetch: make-release.sh fetches it first.
check_feed() {
  local repo="$1" build="$2" feed announced last
  if ! feed="$(git -C "${repo}" show refs/remotes/origin/gh-pages:appcast.xml 2> /dev/null)"; then
    printf 'build %s: no appcast.xml on origin/gh-pages in this clone, compared with the tags alone\n' \
      "${build}"
    return 0
  fi
  announced="$(printf '%s\n' "${feed}" | /usr/bin/xmllint --xpath \
    "count(//*[local-name()='item']/*[local-name()='version'][number(.) >= ${build}])" - \
    2> /dev/null)" || fail "appcast.xml on origin/gh-pages does not parse"
  last="$(printf '%s\n' "${feed}" | sed -nE 's/.*<sparkle:version>([0-9]+)<\/sparkle:version>.*/\1/p' |
    sort -n | tail -n 1)"
  [ "${announced}" = "0" ] ||
    fail "CURRENT_PROJECT_VERSION ${build} is not greater than build ${last:-?} the feed on origin/gh-pages announces: Sparkle would never offer this release"
  printf 'build %s is above every build the feed on origin/gh-pages announces (the last: %s)\n' \
    "${build}" "${last:-none}"
}

# Sparkle offers an update only when CFBundleVersion is greater than the one installed, so a
# release that forgot to raise CURRENT_PROJECT_VERSION reaches nobody.
# The release before this one is the nearest tag of the history under it, the tag of this very
# version left out: on the runner that tag is at HEAD already.
check_grew() {
  local repo="$1" version build previous before
  version="$(marketing "${repo}/project.yml")"
  build="$(build_number "${repo}/project.yml")"
  [[ "${build}" =~ ^[1-9][0-9]*$ ]] ||
    fail "CURRENT_PROJECT_VERSION «${build}» is not a whole number above zero"
  check_feed "${repo}" "${build}"
  # A shallow clone has no tags under HEAD, and every release would look like the first one.
  [ "$(git -C "${repo}" rev-parse --is-shallow-repository)" = "false" ] ||
    fail "the history is shallow, so the release before this one cannot be seen (fetch-depth: 0)"
  previous="$(git -C "${repo}" describe --tags --abbrev=0 --match 'v[0-9]*' \
    --exclude "v${version}" HEAD 2> /dev/null || true)"
  if [ -z "${previous}" ]; then
    # Said aloud: a tag made on GitHub and never fetched looks exactly like no release at all.
    printf 'build %s: no release tag v* under HEAD, taken as the first release\n' "${build}"
    return 0
  fi
  before="$(git -C "${repo}" show "${previous}:project.yml" | setting CURRENT_PROJECT_VERSION -)"
  [[ "${before}" =~ ^[0-9]+$ ]] || fail "no CURRENT_PROJECT_VERSION in project.yml of ${previous}"
  [ "${build}" -gt "${before}" ] ||
    fail "CURRENT_PROJECT_VERSION ${build} is not greater than ${before} of ${previous}: Sparkle would never offer this release"
  printf 'build %s follows build %s of %s\n' "${build}" "${before}" "${previous}"
}

# What the built bundle says, not what was meant to be built: a build setting given on the
# command line, or a stale product, would otherwise pass unseen.
check_app() {
  local app="$1" version="$2" build="$3" plist said_version said_build
  plist="${app}/Contents/Info.plist"
  [ -f "${plist}" ] || fail "no ${plist}"
  said_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}")"
  said_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}")"
  [ "${said_version}" = "${version}" ] && [ "${said_build}" = "${build}" ] ||
    fail "the built app says ${said_version} (${said_build}), the release is ${version} (${build})"
}

if [ "${1:-}" = "--self-test" ]; then
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/ohmymoney-version.XXXXXX")"
  trap 'rm -rf "${scratch}"' EXIT
  printf 'settings:\n  base:\n    MARKETING_VERSION: "0.1.0"\n    CURRENT_PROJECT_VERSION: "1"\n' \
    > "${scratch}/project.yml"
  [ "$(marketing "${scratch}/project.yml")" = "0.1.0" ] ||
    { echo "release-version self-test: MARKETING_VERSION not read"; exit 1; }
  [ "$(build_number "${scratch}/project.yml")" = "1" ] ||
    { echo "release-version self-test: CURRENT_PROJECT_VERSION not read"; exit 1; }
  (check_tag v0.1.0 "${scratch}/project.yml") ||
    { echo "release-version self-test: refused the tag that project.yml names"; exit 1; }
  for tag in v1.0.1 v0.1.0.1 0.1.0 v0.1; do
    if (check_tag "${tag}" "${scratch}/project.yml" 2> /dev/null); then
      echo "release-version self-test: took the tag ${tag} for project.yml's 0.1.0"
      exit 1
    fi
  done
  # A built app, as far as this looks into one.
  app="${scratch}/OhMyMoney.app"
  mkdir -p "${app}/Contents"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.1.0' \
    -c 'Add :CFBundleVersion string 1' "${app}/Contents/Info.plist" > /dev/null
  (check_app "${app}" 0.1.0 1) ||
    { echo "release-version self-test: refused an app that says what was asked"; exit 1; }
  for asked in "0.2.0 1" "0.1.0 2"; do
    # shellcheck disable=SC2086
    if (check_app "${app}" ${asked} 2> /dev/null); then
      echo "release-version self-test: took an app saying 0.1.0 (1) for ${asked}"
      exit 1
    fi
  done
  # A history with a release in it. Hooks and signing of the one who runs this stay out.
  repo="${scratch}/repo"
  mkdir -p "${repo}"
  in_repo() {
    git -C "${repo}" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false \
      -c user.name=test -c user.email=test@example.invalid "$@" > /dev/null
  }
  yml() {
    printf 'settings:\n  base:\n    MARKETING_VERSION: "%s"\n    CURRENT_PROJECT_VERSION: "%s"\n' \
      "$1" "$2" > "${repo}/project.yml"
  }
  in_repo init -q
  yml 1.0.0 1
  (check_grew "${repo}" > /dev/null) ||
    { echo "release-version self-test: refused the first release, which has nothing before it"; exit 1; }
  case "$(check_grew "${repo}")" in
    *"no appcast.xml on origin/gh-pages"*) ;;
    *) echo "release-version self-test: a clone without the branch of the feed was not said aloud"; exit 1 ;;
  esac
  in_repo add project.yml
  in_repo commit -q -m "1.0.0"
  in_repo tag v1.0.0
  for build in 1 0 1a; do
    yml 1.0.1 "${build}"
    if (check_grew "${repo}" > /dev/null 2>&1); then
      echo "release-version self-test: took build ${build} after v1.0.0 with build 1"
      exit 1
    fi
  done
  yml 1.0.1 2
  (check_grew "${repo}" > /dev/null) ||
    { echo "release-version self-test: refused build 2 after build 1"; exit 1; }
  # On the runner the tag being released is at HEAD already: the release before it is the one
  # to compare with, not the release itself.
  in_repo commit -q -am "1.0.1"
  in_repo tag v1.0.1
  (check_grew "${repo}" > /dev/null) ||
    { echo "release-version self-test: compared the tag being released with itself"; exit 1; }
  # A release published with `gh release create` gets its tag on GitHub, not here: until the
  # next fetch the nearest tag under HEAD is the release before it. The feed on the branch Pages
  # publishes, as this clone last saw it, still says which builds installed copies have.
  feed_of() {
    printf '<?xml version="1.0"?>\n<rss version="2.0" xmlns:sparkle="%s"><channel>' \
      "http://www.andymatuschak.org/xml-namespaces/sparkle"
    for announced in "$@"; do
      printf '<item><sparkle:version>%s</sparkle:version></item>' "${announced}"
    done
    printf '</channel></rss>\n'
  }
  pages() {
    local blob tree commit
    blob="$(printf '%s' "$1" | git -C "${repo}" hash-object -w --stdin)"
    tree="$(printf '100644 blob %s\tappcast.xml\n' "${blob}" | git -C "${repo}" mktree)"
    commit="$(git -C "${repo}" -c commit.gpgsign=false -c user.name=test \
      -c user.email=test@example.invalid commit-tree "${tree}" -m feed)"
    git -C "${repo}" update-ref refs/remotes/origin/gh-pages "${commit}"
  }
  pages "$(feed_of 3 2 1)"
  yml 1.0.3 3
  if (check_grew "${repo}" > /dev/null 2>&1); then
    echo "release-version self-test: took build 3 while the feed on gh-pages announces build 3"
    exit 1
  fi
  yml 1.0.3 4
  (check_grew "${repo}" > /dev/null) ||
    { echo "release-version self-test: refused build 4 over a feed that announces 3"; exit 1; }
  pages "$(feed_of)"
  yml 1.0.3 3
  (check_grew "${repo}" > /dev/null) ||
    { echo "release-version self-test: refused build 3 over a feed that announces nothing"; exit 1; }
  pages "<rss><channel><item>"
  if (check_grew "${repo}" > /dev/null 2>&1); then
    echo "release-version self-test: took a build over a feed on gh-pages that does not parse"
    exit 1
  fi
  echo "release-version self-test: ok"
  exit 0
fi

command="${1:-}"
[ "$#" -gt 0 ] && shift
case "${command}" in
  version) marketing "${1:-${root}/project.yml}" ;;
  build) build_number "${1:-${root}/project.yml}" ;;
  tag)
    [ "$#" -ge 1 ] || fail "usage: release-version.sh tag <tag> [<project.yml>]"
    check_tag "$1" "${2:-${root}/project.yml}"
    ;;
  app)
    [ "$#" -eq 3 ] || fail "usage: release-version.sh app <OhMyMoney.app> <version> <build>"
    check_app "$1" "$2" "$3"
    ;;
  grew) check_grew "${1:-${root}}" ;;
  *) fail "usage: release-version.sh version|build|tag|app|grew|--self-test" ;;
esac
