#!/bin/bash
# Every name of a journal event is a token: at most 24 letters, digits and «. - _ /»
# (LogValue.isToken). A longer one reaches the file as «<not-a-name>», and the owner's report
# then says that something happened without saying what — four such names came in with the
# fixes of 24.09. The name is the first string of an AppLog call, which may start on the line
# after the call. And the type of a caught error goes through `LogValue.error`, never through
# `.token(String(describing: type(of: error)))`: a type name longer than a token is lost too.
#
#   scripts/check-log-names.sh               checks the sources of the app and the packages
#   scripts/check-log-names.sh --self-test   proves on two small samples that it catches both
set -eu

scan() {
  perl -0777 -ne '
    while (/AppLog\.(?:debug|info|notice|warning|error|fault)\(\s*"([^"]*)"/g) {
      my $name = $1;
      if (length($name) > 24 || $name !~ /^[A-Za-z0-9._\/-]+$/) { print "$ARGV: event name \"$name\" is not a token\n" }
    }
    while (/\.token\(\s*String\(describing:\s*type\(of:/g) { print "$ARGV: an error type written as a token\n" }
  ' "$@"
}

if [ "${1:-}" = "--self-test" ]; then
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  printf 'AppLog.error(\n  "backup.mirrorRetentionFailed", .db, "x")\n' > "$dir/name.swift"
  printf 'AppLog.error("x.y", .db, "x", [LogPair("error", .token(String(describing: type(of: error))))])\n' > "$dir/type.swift"
  printf 'AppLog.info(\n  "backup.done", .db, "a copy was written", [LogPair("error", .error(error))])\n' > "$dir/good.swift"
  [ -n "$(scan "$dir/name.swift")" ] || { echo "log names self-test: a long name was not caught" >&2; exit 1; }
  [ -n "$(scan "$dir/type.swift")" ] || { echo "log names self-test: a token type was not caught" >&2; exit 1; }
  [ -z "$(scan "$dir/good.swift")" ] || { echo "log names self-test: a good call was caught" >&2; exit 1; }
  echo "log names self-test: ok"
  exit 0
fi

found=$(find Apps Packages/AppCore/Sources Packages/AppDatabase/Sources -name '*.swift' \
  -not -path '*/Tests/*' -not -path '*/UITests/*' -print0 | xargs -0 perl -0777 -ne '
    while (/AppLog\.(?:debug|info|notice|warning|error|fault)\(\s*"([^"]*)"/g) {
      my $name = $1;
      if (length($name) > 24 || $name !~ /^[A-Za-z0-9._\/-]+$/) { print "$ARGV: event name \"$name\" is not a token\n" }
    }
    while (/\.token\(\s*String\(describing:\s*type\(of:/g) { print "$ARGV: an error type written as a token\n" }
  ')
if [ -n "$found" ]; then
  echo "$found"
  echo "log names: a name the journal cannot write (LogValue.isToken)" >&2
  exit 1
fi
echo "log names: every event name is a token"
