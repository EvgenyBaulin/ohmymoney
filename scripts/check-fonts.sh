#!/bin/bash
# Every font the app names grows with the size of the text chosen in Settings → Appearance:
# it is set with `.appFont(_:)` (Apps/macOS/Shared/DesignSystem/AppFont.swift), never with
# `.font(_:)`. macOS draws a `Font` at the size it was written at whatever `dynamicTypeSize`
# says, so a `.font(.caption)` stayed 10 pt at «Очень крупный» — about six hundred of them did,
# and «Крупный» changed almost nothing.
#
# A size fixed on purpose — a symbol that is a picture, an arrow placed by its size — says so on
# its line: `// font-fixed: <why>`. Comments and the tests are not read.
#
#   scripts/check-fonts.sh               checks the sources of the app
#   scripts/check-fonts.sh --self-test   proves on small samples that it catches a font call
set -u

home="Apps/macOS/Shared/DesignSystem/AppFont.swift"

# Prints every line of the files given that sets a font past the rule.
scan() {
  /usr/bin/perl -ne '
    my $line = $_;
    if ($line !~ m{^\s*//} && $line !~ m{//\s*font-fixed\b}) {
      (my $code = $line) =~ s{//.*$}{};
      if ($code =~ /\.font\((?!at:)/) { print "$ARGV:$.: $line"; $bad = 1 }
    }
    close ARGV if eof;
    END { exit($bad ? 1 : 0) }
  ' "$@"
}

if [ "${1:-}" = "--self-test" ]; then
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  printf 'Text("a")\n  .font(.caption)\n' > "$dir/plain.swift"
  printf 'Text("a").font(\n  .caption.monospacedDigit())\n' > "$dir/split.swift"
  printf 'Text("a")\n  .appFont(.caption)\n// .font(.caption) in a comment\nImage("x").font(.system(size: 44))  // font-fixed: a picture\nlet f = font.font(at: size)\n' > "$dir/good.swift"
  [ -n "$(scan "$dir/plain.swift")" ] || { echo "fonts self-test: a font call was not caught" >&2; exit 1; }
  [ -n "$(scan "$dir/split.swift")" ] || { echo "fonts self-test: a split font call was not caught" >&2; exit 1; }
  [ -z "$(scan "$dir/good.swift")" ] || { echo "fonts self-test: a good line was caught" >&2; exit 1; }
  echo "fonts self-test: ok"
  exit 0
fi

files=$(find Apps/macOS -name '*.swift' -not -path '*/Tests/*' -not -path '*/UITests/*' \
  -not -path "${home}" | sort)
# shellcheck disable=SC2086
found=$(scan ${files})
if [ -n "${found}" ]; then
  echo "${found}"
  echo "fonts: set with .font(_:) — use .appFont(_:), or mark a size fixed on purpose with // font-fixed: <why>" >&2
  exit 1
fi
echo "fonts: every font grows with the size of the text"
