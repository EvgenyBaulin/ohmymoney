#!/bin/bash
# Fails when CI runs less than `make verify` does. CI vouches for what one Mac cannot show
# alone (a clean store bundle, a native app, glass only where it belongs), and a check that
# `make verify` has and the workflow does not passes every
# pull request unseen: on 24.09 the workflow ran two checks of fourteen and built the App Store
# configuration without once looking inside it.
#
# Every prerequisite of `verify` must be reached by a `make` the workflow runs, directly or
# through a target whose prerequisites include it. Left out on purpose: `fmt`, which rewrites
# files instead of judging them; `lint`, advisory in style, which
# the Makefile runs within `ci-checks` for the one rule it enforces; `check-toolchain`, which
# `test-core` asks for itself; `bench`, whose time budgets are set for the author's Mac and say
# nothing on a runner of another speed; and `check-skips`, since CI skips what its screen and
# its session cannot show (TestEnvironment) — on the author's Mac no test is skipped.
#
# And every job of every workflow has a limit of its own (`timeout-minutes`), and every
# `xcodebuild … test` gives each test one: without them a test that hangs holds a runner for
# GitHub's default six hours and never says which test it was. `make test` carries the limits
# of a test by itself, and so must every target of the
# Makefile that runs `xcodebuild … test` — `make test-ui` too, which ran with none: a UI test
# stuck on a system prompt held the run until the alarm of the whole of it, half an hour later,
# and named no test.
#
# And every secret a workflow reads is named as a secret in the instructions a maintainer
# follows — the section «Выпуск» of guide/development.md: a release once stopped on SPARKLE_PUBLIC_KEY
# while the instructions of the day asked for SPARKLE_PRIVATE_KEY alone. A name counts where a
# list item or a paragraph that says «секрет» or «secret» spells it; a variable of the same name
# elsewhere does not.
#
# And every job on macOS that runs the tests of AppCore hands them a Python with pandas
# (`OHMYMONEY_PYTHON=` on the line of the command, as build.yml does): without it the suite that
# reads every Reports table back with `pandas.read_csv` is skipped and the job still ends green.
# The Linux job is left out: one reading on macOS keeps the promise.
#
# And every job that generates the project — `xcodegen`, or `make`, whose targets generate it —
# installs XcodeGen through scripts/install-xcodegen.sh, one release built from a source checked
# against its checksum; never with `brew install`, which takes whatever the day's formula is, so
# the project CI builds could change without a line of this repository changing.
#
# And every action a workflow uses is at a major that runs on Node 24. The runners of 21.09 ran
# checkout@v4 and setup-python@v5, both declared for Node 20, on Node 24 already and said in every
# log that Node 20 is going (github.blog, 2025-09-19); the next step is a failure. An action the
# table below does not know fails too, so a new one is added with its first Node 24 major.
#
# And every step a workflow names in an expression (`steps.<id>.outcome`, `steps.<id>.outputs…`)
# is declared by an `id:` in the same job. A step GitHub cannot find reads as an empty outcome:
# `if: steps.prepared.outcome == 'success'` over a renamed id is false, the steps it guards are
# skipped, and a skipped step does not fail the job — the run ends green without building or
# testing anything.
#
# Usage: check-ci.sh [<Makefile> <workflow.yml>]   (default: Makefile, .github/workflows/build.yml;
#                                                  the limits, pandas, XcodeGen, the actions,
#                                                  the step ids and the secrets are checked in
#                                                  every workflow)
#        check-ci.sh --self-test
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/.." && pwd)"
optional=" fmt lint check-toolchain bench check-skips "

# The prerequisites of one rule, one per line. Lines ending in a backslash are joined first; a
# line that sets a variable for a target (`test-one: XCB_TIME = 600`) is not a rule.
prerequisites() {
  awk -v target="$1" '
    { line = line $0 }
    /\\$/ { sub(/\\$/, "", line); next }
    {
      if (index(line, target ":") == 1 && line !~ /=/) {
        sub(/^[^:]*:/, "", line)
        print line
      }
      line = ""
    }
  ' "$2" | tr -s ' \t' '\n\n' | grep -v '^$'
}

# The shell a workflow runs, one command per line as `<job> TAB <1 on macOS, else 0> TAB
# <command>`: the value of every `run:`, a block (`run: |`) line by line, lines continued with a
# backslash read as one, comments taken away. Only what runs: the name of a step that says «the
# checks of make verify» runs nothing, and on 24.09 that name alone passed for `make verify` and
# left the comparison below with nothing to find. Read twice: a job may say `runs-on` after its
# steps.
run_lines() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function emit(text) {
      sub(/(^|[[:space:]])#.*$/, "", text)
      if (text !~ /^[[:space:]]*$/) print job "\t" (mac[job] ? 1 : 0) "\t" text
    }
    FNR == 1 { in_jobs = 0; block = -1; job = ""; line = "" }
    { line = line $0 }
    /\\$/ { sub(/\\$/, "", line); next }
    {
      if (line ~ /^jobs:/) { in_jobs = 1 }
      else if (line ~ /^[^ #]/) { in_jobs = 0; block = -1 }
      if (in_jobs && line ~ /^  [A-Za-z0-9_-]+:[[:space:]]*$/) {
        job = line; sub(/^  /, "", job); sub(/:.*$/, "", job); block = -1
      }
      if (FNR == NR) {
        if (in_jobs && line ~ /^    runs-on:[[:space:]]*(macos|xcode)/) { mac[job] = 1 }
        line = ""; next
      }
      if (block >= 0) {
        if (line ~ /^[[:space:]]*$/ || indent(line) > block) { emit(line); line = ""; next }
        block = -1
      }
      if (line ~ /^[[:space:]]*(- )?run:/) {
        key = indent(line); if (line ~ /^[[:space:]]*- /) key += 2
        text = line; sub(/^[[:space:]]*(- )?run:[[:space:]]*/, "", text)
        if (text ~ /^[|>][-+]?[[:space:]]*$/) { block = key } else { emit(text) }
      }
      line = ""
    }
  ' "$1" "$1"
}

# The targets of every `make` the workflow runs. Variables and options before and after `make`
# are skipped.
invoked() {
  run_lines "$1" | cut -f3- | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i != "make") continue
        for (j = i + 1; j <= NF; j++) {
          word = $j
          if (word ~ /^(&&|\|\||;|\||>|2>)/) break
          if (word ~ /=/ || word ~ /^-/) continue
          print word
        }
      }
    }'
}

# The targets given and everything they bring in, one per line, each once, in the order met.
closure() {
  local makefile="$1" queue="$2" reached=" " target next
  while [ -n "${queue}" ]; do
    next=""
    for target in ${queue}; do
      case "${reached}" in *" ${target} "*) continue ;; esac
      reached="${reached}${target} "
      echo "${target}"
      next="${next} $(prerequisites "${target}" "${makefile}" | tr '\n' ' ')"
    done
    queue="$(printf '%s' "${next}" | tr -s ' ' | sed 's/^ *//')"
  done
}

# Prints what verify runs and the workflow does not; exit 1 when that is anything.
missing() {
  local makefile="$1" workflow="$2" reached wanted target found=""
  reached=" $(closure "${makefile}" "$(invoked "${workflow}" | tr '\n' ' ')" | tr '\n' ' ')"
  # A loop, not a case inside $(…): bash 3.2 reads the `)` of a pattern there as the end.
  wanted=""
  for target in $(prerequisites verify "${makefile}"); do
    case "${optional}" in *" ${target} "*) continue ;; esac
    wanted="${wanted} ${target}"
  done
  for target in $(closure "${makefile}" "${wanted}"); do
    case "${reached}" in *" ${target} "*) continue ;; esac
    echo "${target}"
    found="yes"
  done
  [ -z "${found}" ]
}

# Prints each job without a limit of its own and each `xcodebuild … test` without the limits
# of a test; exit 1 when there is any. Lines continued with a backslash are read as one.
unlimited() {
  awk -v file="${1##*/}" '
    { line = line $0 }
    /\\$/ { sub(/\\$/, "", line); next }
    {
      if (line ~ /^jobs:/) { in_jobs = 1 }
      else if (line ~ /^[^ #]/) { in_jobs = 0 }
      if (in_jobs && line ~ /^  [A-Za-z0-9_-]+:[[:space:]]*$/) {
        if (job != "" && !limited) { print file ": job " job " has no timeout-minutes"; bad = 1 }
        job = line; sub(/^  /, "", job); sub(/:.*$/, "", job); limited = 0
      }
      if (in_jobs && line ~ /^    timeout-minutes:/) { limited = 1 }
      code = line; sub(/(^|[[:space:]])#.*$/, "", code)
      if (code ~ /xcodebuild/ && code ~ /[[:space:]]test([[:space:]]|$)/ &&
          code !~ /-test-timeouts-enabled YES/) {
        print file ": xcodebuild test without -test-timeouts-enabled YES"; bad = 1
      }
      line = ""
    }
    END {
      if (job != "" && !limited) { print file ": job " job " has no timeout-minutes"; bad = 1 }
      exit bad
    }' "$1"
}

# Prints each target of a Makefile whose `xcodebuild … test` (through `$(XCB…)`) gives a test
# no limit — neither `-test-timeouts-enabled YES` on the line nor a variable that carries it;
# exit 1 when there is any. Read twice: a variable may be set below the rule that uses it.
untimed() {
  awk -v file="${1##*/}" '
    FNR == 1 { line = ""; target = "" }
    { line = line $0 }
    /\\$/ { sub(/\\$/, "", line); next }
    FNR == NR {
      if (line ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[:?+]?=/ &&
          line ~ /-test-timeouts-enabled YES/) {
        name = line; sub(/[[:space:]]*[:?+]?=.*$/, "", name); limits[name] = 1
      }
      line = ""; next
    }
    {
      if (line ~ /^\t/) {
        if (line ~ /\$\(XCB|xcodebuild/ && line ~ /[[:space:]]test([[:space:]]|$)/) {
          ok = line ~ /-test-timeouts-enabled YES/
          for (name in limits) if (index(line, "$(" name ")")) ok = 1
          if (!ok) { print file ": " target " runs xcodebuild test without the limits of a test"; bad = 1 }
        }
      } else if (line ~ /^[A-Za-z0-9_.-]+:/ && line !~ /=/) {
        target = line; sub(/:.*$/, "", target)
      }
      line = ""
    }
    END { exit bad }' "$1" "$1"
}

# Prints each command of a macOS job that runs the tests of AppCore — `make test-core`,
# `make verify`, `swift test` of Packages/AppCore — without `OHMYMONEY_PYTHON=` on its line; exit 1
# when there is any.
pandasless() {
  run_lines "$1" | awk -F '\t' -v file="${1##*/}" '
    $2 == 1 {
      core = 0
      if ($3 ~ /(^|[[:space:]])make[[:space:]]/ &&
          $3 ~ /[[:space:]](test-core|verify)([[:space:]]|$)/) { core = 1 }
      if ($3 ~ /swift[[:space:]]+test/ && $3 ~ /Packages\/AppCore/) { core = 1 }
      if (core && $3 !~ /OHMYMONEY_PYTHON=/) {
        print file ": job " $1 " runs the AppCore tests without OHMYMONEY_PYTHON, and pandas would be skipped"
        bad = 1
      }
    }
    END { exit bad }'
}

# Prints each job that installs XcodeGen with Homebrew, and each job that runs `xcodegen` or
# `make` without scripts/install-xcodegen.sh; exit 1 when there is any.
unpinned() {
  run_lines "$1" | awk -F '\t' -v file="${1##*/}" '
    {
      if (!($1 in seen)) { seen[$1] = 1; order[++jobs] = $1 }
      if ($3 ~ /brew[[:space:]]+install/ && $3 ~ /xcodegen/) {
        print file ": job " $1 " installs XcodeGen with brew, whatever version the day brings"
        bad = 1
      }
      if ($3 ~ /scripts\/install-xcodegen\.sh/) { pinned[$1] = 1 }
      else if ($3 ~ /(^|[[:space:]])(xcodegen|make)[[:space:]]/) { generates[$1] = 1 }
    }
    END {
      for (i = 1; i <= jobs; i++) {
        job = order[i]
        if (generates[job] && !pinned[job]) {
          print file ": job " job " generates the project without scripts/install-xcodegen.sh"
          bad = 1
        }
      }
      exit bad
    }'
}

# Prints each `steps.<id>` an expression of a job names — the whole value of an `if:`, or what
# stands inside `${{ … }}` — that no `id:` of that job declares; exit 1 when there is any.
# Comments are not read. Read twice: a job may name a step before the step declares its id
# (the outputs of a job come before its steps).
undeclared() {
  awk -v file="${1##*/}" -v quote="'" '
    function refs(text, found,   rest) {
      rest = text
      while (match(rest, /steps\.[A-Za-z_][A-Za-z0-9_-]*/)) {
        found[substr(rest, RSTART + 6, RLENGTH - 6)] = 1
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    FNR == 1 { in_jobs = 0; job = "" }
    {
      code = $0; sub(/(^|[[:space:]])#.*$/, "", code)
      if (code ~ /^jobs:/) { in_jobs = 1; next }
      if (code ~ /^[^ ]/) { in_jobs = 0; next }
      if (!in_jobs) next
      if (code ~ /^  [A-Za-z0-9_-]+:[[:space:]]*$/) {
        job = code; sub(/^  /, "", job); sub(/:.*$/, "", job); next
      }
      if (FNR == NR) {
        if (code ~ /^[[:space:]]*(- )?id:/) {
          id = code; sub(/^[[:space:]]*(- )?id:[[:space:]]*/, "", id)
          gsub(/"/, "", id); gsub(quote, "", id); sub(/[[:space:]].*$/, "", id)
          declared[job SUBSEP id] = 1
        }
        next
      }
      delete named
      if (code ~ /^[[:space:]]*(- )?if:/) { refs(code, named) }
      rest = code
      while (match(rest, /\$\{\{[^}]*\}\}/)) {
        # refs() matches too, and match() sets RSTART and RLENGTH for everyone.
        expression = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        refs(expression, named)
      }
      for (id in named) {
        if (!((job SUBSEP id) in declared)) {
          print file ": job " job " reads steps." id ", and no step of it has id: " id
          bad = 1
        }
      }
    }
    END { exit bad }' "$1" "$1"
}

# The first major of each action this repository uses that runs on Node 24: the `using:` of the
# action.yml at that tag says node24. upload-artifact@v5 still says node20 (every failed run of
# build.yml warned so); v6 is its first on Node 24.
node24="actions/checkout@5 actions/setup-python@6 actions/upload-artifact@6"

# Prints each `uses:` of an action older than its first Node 24 major, or not in the table;
# exit 1 when there is any. Comments are not read.
outdated() {
  sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$1" |
    grep -oE 'uses:[[:space:]]*[^[:space:]]+' | sed -E 's/^uses:[[:space:]]*//' |
    awk -v file="${1##*/}" -v table="${node24}" '
      BEGIN {
        n = split(table, entries, " ")
        for (i = 1; i <= n; i++) { split(entries[i], pair, "@"); least[pair[1]] = pair[2] + 0 }
      }
      {
        name = $0; sub(/@.*$/, "", name)
        major = $0; sub(/^[^@]*@v?/, "", major); sub(/[^0-9].*$/, "", major)
        if (!(name in least)) {
          print file ": " $0 " is not in the table of Node 24 majors of check-ci.sh"; bad = 1
        } else if (major == "" || major + 0 < least[name]) {
          print file ": " $0 " runs on Node 20; " name "@v" least[name] " is the first on Node 24"
          bad = 1
        }
      }
      END { exit bad }'
}

# The documents that tell a maintainer what to set up on GitHub.
instructions="guide/development.md"

# Prints each secret the workflows read (all arguments after the first) that a document of the
# first argument, a list of paths, does not name as a secret; exit 1 when there is any.
# GITHUB_TOKEN is GitHub's own: nobody creates it. A secret only named in a comment is not read.
unnamed() {
  local docs="$1" name doc bad=""
  shift
  for name in $(sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$@" |
      grep -o 'secrets\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/^secrets\.//' | sort -u); do
    [ "${name}" = "GITHUB_TOKEN" ] && continue
    for doc in ${docs}; do
      # One line per list item or paragraph, then the ones that speak of secrets.
      if ! awk '
          function flush() { if (item != "") print item; item = "" }
          /^[[:space:]]*$/ { flush(); next }
          /^[[:space:]]*([0-9]+\.|[-*])[[:space:]]/ { flush() }
          { item = item " " $0 }
          END { flush() }
        ' "${doc}" | grep -E '[Сс]екрет|[Ss]ecret' | grep -qF "\`${name}\`"; then
        echo "${doc##*/}: the workflows read the secret ${name}, and this does not ask for it"
        bad="yes"
      fi
    done
  done
  [ -z "${bad}" ]
}

if [ "${1:-}" = "--self-test" ]; then
  fixtures="${here}/fixtures/ci"
  if ! missing "${fixtures}/Makefile.txt" "${fixtures}/good.yml.txt" > /dev/null; then
    echo "check-ci self-test: good.yml.txt runs everything verify runs, and was refused:"
    missing "${fixtures}/Makefile.txt" "${fixtures}/good.yml.txt"
    exit 1
  fi
  found="$(missing "${fixtures}/Makefile.txt" "${fixtures}/bad.yml.txt" | tr '\n' ' ')"
  if [ "${found}" != "check-b ci-checks check-c check-d " ]; then
    echo "check-ci self-test: expected check-b ci-checks check-c check-d missing from bad.yml.txt, got: ${found}"
    exit 1
  fi
  if ! unlimited "${fixtures}/good.yml.txt" > /dev/null; then
    echo "check-ci self-test: good.yml.txt has its limits, and was refused:"
    unlimited "${fixtures}/good.yml.txt"
    exit 1
  fi
  found="$(unlimited "${fixtures}/bad.yml.txt" | wc -l | tr -d ' ')"
  if [ "${found}" != "3" ]; then
    echo "check-ci self-test: expected 3 missing limits in bad.yml.txt, got ${found}"
    unlimited "${fixtures}/bad.yml.txt"
    exit 1
  fi
  found="$(untimed "${fixtures}/Makefile.txt" | tr '\n' ' ')"
  if [ "${found}" != "Makefile.txt: test-ui runs xcodebuild test without the limits of a test " ]; then
    echo "check-ci self-test: expected test-ui alone without limits in Makefile.txt, got: ${found}"
    exit 1
  fi
  if ! outdated "${fixtures}/good.yml.txt" > /dev/null; then
    echo "check-ci self-test: good.yml.txt uses actions on Node 24, and was refused:"
    outdated "${fixtures}/good.yml.txt"
    exit 1
  fi
  found="$(outdated "${fixtures}/bad.yml.txt" | wc -l | tr -d ' ')"
  if [ "${found}" != "4" ]; then
    echo "check-ci self-test: expected three actions on Node 20 and one unknown in bad.yml.txt, got ${found}"
    outdated "${fixtures}/bad.yml.txt"
    exit 1
  fi
  if ! unpinned "${fixtures}/good.yml.txt" > /dev/null; then
    echo "check-ci self-test: good.yml.txt installs its XcodeGen, and was refused:"
    unpinned "${fixtures}/good.yml.txt"
    exit 1
  fi
  found="$(unpinned "${fixtures}/bad.yml.txt" | wc -l | tr -d ' ')"
  if [ "${found}" != "2" ]; then
    echo "check-ci self-test: expected brew and no install script in bad.yml.txt, got ${found}"
    unpinned "${fixtures}/bad.yml.txt"
    exit 1
  fi
  if ! pandasless "${fixtures}/good.yml.txt" > /dev/null; then
    echo "check-ci self-test: good.yml.txt hands pandas to the AppCore tests, and was refused:"
    pandasless "${fixtures}/good.yml.txt"
    exit 1
  fi
  found="$(pandasless "${fixtures}/bad.yml.txt" | wc -l | tr -d ' ')"
  if [ "${found}" != "3" ]; then
    echo "check-ci self-test: expected 3 AppCore test runs without pandas in bad.yml.txt, one of them on an xcode- runner, got ${found}"
    pandasless "${fixtures}/bad.yml.txt"
    exit 1
  fi
  if ! undeclared "${fixtures}/good.yml.txt" > /dev/null; then
    echo "check-ci self-test: good.yml.txt declares every step it reads, and was refused:"
    undeclared "${fixtures}/good.yml.txt"
    exit 1
  fi
  found="$(undeclared "${fixtures}/bad.yml.txt" | sed 's/.* reads steps\.\([A-Za-z_-]*\),.*/\1/' |
    sort | tr '\n' ' ')"
  if [ "${found}" != "asked built prepared " ]; then
    echo "check-ci self-test: expected the undeclared steps asked built prepared in bad.yml.txt, got: ${found}"
    undeclared "${fixtures}/bad.yml.txt"
    exit 1
  fi
  if ! unnamed "${fixtures}/owner-good.md.txt" "${fixtures}/secrets.yml.txt" > /dev/null; then
    echo "check-ci self-test: owner-good.md.txt asks for every secret, and was refused:"
    unnamed "${fixtures}/owner-good.md.txt" "${fixtures}/secrets.yml.txt"
    exit 1
  fi
  found="$(unnamed "${fixtures}/owner-bad.md.txt" "${fixtures}/secrets.yml.txt" |
    sed 's/.*secret \([A-Z_]*\),.*/\1/' | tr '\n' ' ')"
  if [ "${found}" != "RELEASE_KEY SIGNING_KEY " ]; then
    echo "check-ci self-test: expected RELEASE_KEY SIGNING_KEY not asked for in owner-bad.md.txt, got: ${found}"
    exit 1
  fi
  echo "check-ci self-test: ok"
  exit 0
fi

makefile="${1:-${root}/Makefile}"
workflow="${2:-${root}/.github/workflows/build.yml}"
status=0
untimed "${makefile}" || status=1
if ! found="$(missing "${makefile}" "${workflow}")"; then
  echo "ci: ${workflow##*/} does not run what make verify runs:" ${found}
  status=1
fi
undeclared "${workflow}" || status=1
for file in "${root}"/.github/workflows/*.yml; do
  unlimited "${file}" || status=1
  pandasless "${file}" || status=1
  unpinned "${file}" || status=1
  outdated "${file}" || status=1
  [ "${file}" -ef "${workflow}" ] || undeclared "${file}" || status=1
done
docs=""
for doc in ${instructions}; do docs="${docs} ${root}/${doc}"; done
unnamed "${docs}" "${root}"/.github/workflows/*.yml || status=1
[ "${status}" = "0" ] || exit 1
echo "ci: runs what make verify runs, every job and test with a limit, here and on CI, pandas for the AppCore tests, one XcodeGen, actions on Node 24, every step an expression reads declared, every secret asked for"
