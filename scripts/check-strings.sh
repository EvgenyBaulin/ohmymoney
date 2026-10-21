#!/bin/bash
# Every key the app's code hands to a lookup of a fixed table as a literal exists in that
# table's String Catalog. A key looked up in the wrong table comes back as itself: Settings →
# Справочники → Способы оплаты once said «entry.currency» under the currency picker, because the
# key lived in Entry and the row's helper looked in Settings, and no test knew that row.
#
# What counts as a lookup of a fixed table:
#   * `language(…)`, `language.format(…)` and `environment.format(…)`, with `table:` a literal,
#     a `let` constant of an enclosing type (`table`, `Self.table`, `Words.table`), or Common
#     when none is given. A table named any other way cannot be read and is reported: a key the
#     check cannot place is a key nobody checks;
#   * a helper whose first parameter is `_ key: String` and whose body hands `key` to one of the
#     above, or to another such helper, with a fixed table: `t(_:)`, `label(_:)`,
#     `PlanningText.t(_:_:)` and their like. A helper counts for calls in its type and the
#     types around it, or as `Type.helper(…)` from anywhere; two helpers of one name in two
#     types are two helpers;
#   * a pair of literals `("key", "Table")` or `(key: "key", table: "Table")` whose second is
#     the name of a catalog: a key handed on with its table.
# The key is every literal of the key's argument: `a ? "x.y" : "x.z"` and `name ?? "x.y"` are
# two keys and one. In an expression, only literals shaped like a key (`word.word…`) count, so
# a separator in `replacingOccurrences(of: ".", …)` is not read as one. Keys built at run time
# (`"forWhom.\(value.rawValue)"`) are not literals and are not read. Comments are not code,
# wherever they stand on a line. Tests are not read either: a test may look up a key that is
# missing on purpose.
#
# Usage: check-strings.sh [--self-test]
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/.." && pwd)"

# The scanner: the folder of the catalogs first, then the Swift files. Prints each key that is
# not in the table it is looked up in, and each lookup whose table cannot be read; exits 1 when
# there is any.
scan() {
  /usr/bin/perl -e '
    use strict; use warnings; use JSON::PP;

    my $catalogs = shift @ARGV;
    my %keys;
    opendir(my $dh, $catalogs) or die "check-strings: no folder $catalogs\n";
    for my $name (grep { /\.xcstrings$/ } readdir($dh)) {
      (my $table = $name) =~ s/\.xcstrings$//;
      open(my $fh, "<:raw", "$catalogs/$name") or die "check-strings: cannot read $name\n";
      local $/; my $json = <$fh>; close $fh;
      my $catalog = JSON::PP->new->decode($json);
      $keys{$table} = { map { $_ => 1 } keys %{ $catalog->{strings} } };
    }
    closedir $dh;

    my $keyish = qr/^[A-Za-z][\w-]*(?:\.[\w-]+)+$/;

    # ---- Reading a file: comments and the insides of strings become spaces, so that nothing in
    # them is taken for code; the strings are kept aside with where they stand. The code of an
    # interpolation stays code.
    sub lex {
      my ($text) = @_;
      my @c = split //, $text;
      my @m = @c;
      my @literals;
      my $n = scalar @c;
      my $blank = sub { my ($i) = @_; $m[$i] = " " unless $c[$i] eq "\n" };
      my $code; my $string;
      # Code from $i; with $inner set, until the ")" that closes an interpolation.
      $code = sub {
        my ($i, $inner) = @_;
        my $depth = 0;
        while ($i < $n) {
          my $ch = $c[$i];
          if ($ch eq "/" && $i + 1 < $n && $c[$i + 1] eq "/") {
            while ($i < $n && $c[$i] ne "\n") { $blank->($i); $i++ }
            next;
          }
          if ($ch eq "/" && $i + 1 < $n && $c[$i + 1] eq "*") {
            my $level = 0;
            while ($i < $n) {
              if ($c[$i] eq "/" && $i + 1 < $n && $c[$i + 1] eq "*") {
                $level++; $blank->($i); $blank->($i + 1); $i += 2; next;
              }
              if ($c[$i] eq "*" && $i + 1 < $n && $c[$i + 1] eq "/") {
                $level--; $blank->($i); $blank->($i + 1); $i += 2;
                last if $level == 0;
                next;
              }
              $blank->($i); $i++;
            }
            next;
          }
          if ($ch eq "#" || $ch eq "\"") {
            my $j = $i; my $hashes = 0;
            while ($j < $n && $c[$j] eq "#") { $hashes++; $j++ }
            if ($j < $n && $c[$j] eq "\"") { $i = $string->($i, $j, $hashes); next }
          }
          if ($inner) {
            if ($ch eq "(") { $depth++ }
            elsif ($ch eq ")") { return $i + 1 if $depth == 0; $depth-- }
          }
          $i++;
        }
        return $i;
      };
      # A string whose first quote is at $q, `#` × $hashes before it from $start.
      $string = sub {
        my ($start, $q, $hashes) = @_;
        my $multi = $q + 2 < $n && $c[$q + 1] eq "\"" && $c[$q + 2] eq "\"";
        my $i = $q + ($multi ? 3 : 1);
        my $close = ($multi ? "\"\"\"" : "\"") . ("#" x $hashes);
        my $escape = "\\" . ("#" x $hashes);
        my ($value, $plain) = ("", 1);
        while ($i < $n) {
          if (substr($text, $i, length $close) eq $close) {
            push @literals, { start => $start, end => $i + length($close), value => $value,
              plain => $plain };
            return $i + length($close);
          }
          if (!$multi && $c[$i] eq "\n") { last }
          if (substr($text, $i, length $escape) eq $escape) {
            my $after = $i + length($escape);
            if ($after < $n && $c[$after] eq "(") {
              $plain = 0;
              $blank->($_) for $i .. $after - 1;
              $i = $code->($after + 1, 1);
              next;
            }
            $value .= $after < $n ? $c[$after] : "";
            $blank->($_) for $i .. ($after < $n ? $after : $n - 1);
            $i = $after + 1;
            next;
          }
          $value .= $c[$i]; $blank->($i); $i++;
        }
        push @literals, { start => $start, end => $i, value => $value, plain => 0 };
        return $i;
      };
      $code->(0, 0);
      return (join("", @m), \@literals);
    }

    # The index just past the bracket that closes the one at $open.
    sub closing {
      my ($m, $open) = @_;
      my $depth = 0; my $n = length $m;
      for (my $i = $open; $i < $n; $i++) {
        my $ch = substr($m, $i, 1);
        if ($ch eq "(" || $ch eq "[" || $ch eq "{") { $depth++ }
        elsif ($ch eq ")" || $ch eq "]" || $ch eq "}") { $depth--; return $i if $depth == 0 }
      }
      return $n;
    }

    # The arguments of the call whose "(" is at $open: [start, end) of each, split at the commas
    # of its own level.
    sub arguments {
      my ($m, $open) = @_;
      my $close = closing($m, $open);
      my @args; my $depth = 0; my $from = $open + 1;
      for (my $i = $open + 1; $i < $close; $i++) {
        my $ch = substr($m, $i, 1);
        if ($ch eq "(" || $ch eq "[" || $ch eq "{") { $depth++ }
        elsif ($ch eq ")" || $ch eq "]" || $ch eq "}") { $depth-- }
        elsif ($ch eq "," && $depth == 0) { push @args, [$from, $i]; $from = $i + 1 }
      }
      push @args, [$from, $close] if substr($m, $from, $close - $from) =~ /\S/;
      return @args;
    }

    my @files;
    for my $path (@ARGV) {
      open(my $fh, "<:encoding(UTF-8)", $path) or die "check-strings: cannot read $path\n";
      local $/; my $text = <$fh>; close $fh;
      my ($masked, $literals) = lex($text);
      my %at = map { $_->{start} => $_ } @$literals;
      my $file = { path => $path, text => $text, m => $masked, literals => $literals,
        at => \%at };

      # Types, from the brace of their body to the one that closes it.
      my @scopes;
      while ($masked =~ /\b(?:struct|enum|class|extension|actor|protocol)\s+([A-Za-z_][\w.]*)/g) {
        my ($name, $after) = ($1, pos($masked));
        next if $name =~ /^(?:func|var|let|subscript|init|deinit|static|case)$/;
        my $open = index($masked, "{", $after);
        next if $open < 0 || substr($masked, $after, $open - $after) =~ /[;}]/;
        push @scopes, { name => $name, start => $open, end => closing($masked, $open) };
      }
      for my $scope (@scopes) {
        my ($parent) = sort { $b->{start} <=> $a->{start} }
          grep { $_->{start} < $scope->{start} && $scope->{end} <= $_->{end} } @scopes;
        $scope->{parent} = $parent;
      }
      for my $scope (@scopes) {
        my @names; my $s = $scope;
        while ($s) { unshift @names, $s->{name}; $s = $s->{parent} }
        $scope->{path} = join(".", @names);
      }
      $file->{scopes} = \@scopes;
      push @files, $file;
    }

    # The innermost type at $p, and the paths from it outwards; "" is the level of the file.
    sub chain {
      my ($file, $p) = @_;
      my ($inner) = sort { $b->{start} <=> $a->{start} }
        grep { $_->{start} < $p && $p < $_->{end} } @{ $file->{scopes} };
      my @paths;
      while ($inner) { push @paths, $inner->{path}; $inner = $inner->{parent} }
      return @paths;
    }

    sub line_of {
      my ($file, $p) = @_;
      return 1 + (substr($file->{m}, 0, $p) =~ tr/\n//);
    }

    # Constants of the form `let name = "Word"`, by the type they stand in.
    my %constants;
    for my $file (@files) {
      my $m = $file->{m};
      while ($m =~ /\blet\s+(\w+)\s*(?::\s*String\s*)?=\s*(?=")/g) {
        my ($name, $at) = ($1, pos($m));
        my $literal = $file->{at}{$at} or next;
        next unless $literal->{plain} && $literal->{value} =~ /^\w+$/;
        my ($path) = chain($file, $at);
        $path //= "file:$file->{path}";
        $constants{$path}{$name}{ $literal->{value} } = 1;
      }
    }

    sub constant {
      my ($paths, $name) = @_;
      for my $path (@$paths) {
        my $values = $constants{$path}{$name} or next;
        my @values = keys %$values;
        return @values == 1 ? $values[0] : undef;
      }
      return undef;
    }

    # The table an argument names, or undef when it cannot be read.
    sub table_of {
      my ($file, $expression, $p) = @_;
      return "Common" unless defined $expression;
      return $1 if $expression =~ /^"(\w+)"$/;
      my @paths = (chain($file, $p), "file:$file->{path}");
      return constant(\@paths, $1) if $expression =~ /^(?:(?:self|Self)\.)?(\w+)$/;
      if ($expression =~ /^(\w+(?:\.\w+)*)\.(\w+)$/) {
        my ($type, $name) = ($1, $2);
        my @types = grep { $_ eq $type || /\.\Q$type\E$/ } keys %constants;
        return constant(\@types, $name) if @types;
      }
      return undef;
    }

    # Every lookup of a file: where it is, its key argument, and the text of its table.
    for my $file (@files) {
      my ($m, $text) = ($file->{m}, $file->{text});
      my @lookups;
      while ($m =~ /(?<![\w])(?:language|(?:language|environment)\.format)\s*\(/g) {
        my ($at, $open) = ($-[0], pos($m) - 1);
        next if substr($m, $at > 5 ? $at - 5 : 0, $at > 5 ? 5 : $at) =~ /func\s$/;
        my @args = arguments($m, $open) or next;
        my $table;
        for my $arg (@args[1 .. $#args]) {
          my $argument = substr($text, $arg->[0], $arg->[1] - $arg->[0]);
          if ($argument =~ /^\s*table:\s*(.*?)\s*$/s) { $table = $1; last }
        }
        push @lookups, { at => $at, key => $args[0], table => $table };
      }
      $file->{lookups} = \@lookups;
    }

    # ---- Helpers: a function whose first parameter is `_ key: String`, found with its body.
    my (@helpers, %helpers_in);
    for my $file (@files) {
      my $m = $file->{m};
      while ($m =~ /\bfunc\s+(\w+)\s*(?:<[^>{}]*>)?\s*\(/g) {
        my ($name, $open) = ($1, pos($m) - 1);
        my $close = closing($m, $open);
        my $parameters = substr($m, $open + 1, $close - $open - 1);
        next unless $parameters =~ /^\s*_\s+(\w+)\s*:\s*String\b(?!\s*\?)/;
        my $parameter = $1;
        my $body = index($m, "{", $close);
        next if $body < 0 || substr($m, $close, $body - $close) =~ /[;}]|\bfunc\b/;
        my ($path) = chain($file, $open);
        my $helper = { file => $file, name => $name, parameter => $parameter,
          start => $body, end => closing($m, $body), tables => {}, open => 0 };
        push @helpers, $helper;
        push @{ $helpers_in{ $path // "file:$file->{path}" }{$name} }, $helper;
        push @{ $helpers_in{"module"}{$name} }, $helper
          if !defined $path
          && substr($m, 0, $open) !~ /\b(?:private|fileprivate)\s+func\s+\w+\s*(?:<[^>{}]*>)?\s*$/;
      }
    }

    # The helpers a call of `name` at $p may mean: through `Type.`, or from the type it is in
    # outwards, then the file, then the module.
    sub helpers_for {
      my ($file, $p, $qualifier, $name) = @_;
      my @paths;
      if (defined $qualifier && $qualifier !~ /^(?:self|Self)$/) {
        @paths = grep { $_ eq $qualifier || /\.\Q$qualifier\E$/ } keys %helpers_in;
      } else {
        @paths = (chain($file, $p), "file:$file->{path}");
        push @paths, "module" unless defined $qualifier;
      }
      for my $path (@paths) {
        my $found = $helpers_in{$path}{$name} or next;
        my @live = grep { !$_->{open} && %{ $_->{tables} } } @$found;
        return @live if @live;
      }
      return ();
    }

    # The calls of a text: [where, qualifier, name, "(" ] — the lookups apart.
    sub calls {
      my ($file, $from, $to) = @_;
      my $m = $file->{m};
      my @calls;
      pos($m) = $from;
      while ($m =~ /\G.*?(?<![.\w])((?:\w+\.)*?)(\w+)\s*\(/gs) {
        my ($qualifier, $name) = ($1, $2);
        my $open = pos($m) - 1;
        last if $open >= $to;
        $qualifier =~ s/\.$// if defined $qualifier;
        $qualifier = undef if defined $qualifier && $qualifier eq "";
        my $at = $open - length($name) - (defined $qualifier ? length($qualifier) + 1 : 0);
        next if substr($m, $at > 5 ? $at - 5 : 0, $at > 5 ? 5 : $at) =~ /func\s$/;
        # The lookups themselves are read apart.
        next if $name eq "language"
          || ($name eq "format" && ($qualifier // "") =~ /(?:^|\.)(?:language|environment)$/);
        push @calls, [$at, $qualifier, $name, $open];
      }
      return @calls;
    }

    # What a helper hands its key to directly.
    for my $helper (@helpers) {
      my $file = $helper->{file};
      for my $lookup (@{ $file->{lookups} }) {
        next unless $helper->{start} < $lookup->{at} && $lookup->{at} < $helper->{end};
        my ($from, $to) = @{ $lookup->{key} };
        next unless substr($file->{m}, $from, $to - $from) =~ /^\s*\Q$helper->{parameter}\E\s*$/;
        my $table = table_of($file, $lookup->{table}, $lookup->{at});
        if (defined $table) { $helper->{tables}{$table} = 1 } else { $helper->{open} = 1 }
      }
    }

    # And through other helpers, until nothing grows. The tables of a helper only ever grow,
    # and there are finitely many, so this ends.
    my $grew = 1;
    while ($grew) {
      $grew = 0;
      for my $helper (grep { !$_->{open} } @helpers) {
        my $file = $helper->{file};
        for my $call (calls($file, $helper->{start}, $helper->{end})) {
          my ($at, $qualifier, $name, $open) = @$call;
          my @args = arguments($file->{m}, $open) or next;
          my ($from, $to) = @{ $args[0] };
          next unless substr($file->{m}, $from, $to - $from) =~ /^\s*\Q$helper->{parameter}\E\s*$/;
          for my $inner (helpers_for($file, $at, $qualifier, $name)) {
            next if $inner == $helper;
            for my $table (keys %{ $inner->{tables} }) {
              next if $helper->{tables}{$table};
              $helper->{tables}{$table} = 1;
              $grew = 1;
            }
          }
        }
      }
    }

    my $bad = 0;
    sub check {
      my ($file, $p, $key, $tables) = @_;
      return if grep { exists $keys{$_} && $keys{$_}{$key} } @$tables;
      my $where = join(" or ", map { "$_.xcstrings" } sort @$tables);
      printf "%s:%d: \"%s\" is not in %s\n", $file->{path}, line_of($file, $p), $key, $where;
      $bad = 1;
    }

    # The keys of an argument: the literal it is, or every literal in it shaped like a key.
    sub keys_of {
      my ($file, $from, $to) = @_;
      my @inside = grep { $_->{start} >= $from && $_->{end} <= $to } @{ $file->{literals} };
      my $whole = substr($file->{text}, $from, $to - $from);
      $whole =~ s/^\s+|\s+$//g;
      if (@inside == 1 && $inside[0]->{plain}
        && length($whole) == $inside[0]->{end} - $inside[0]->{start}) {
        return ($inside[0]);
      }
      return grep { $_->{plain} && $_->{value} =~ $keyish } @inside;
    }

    for my $file (@files) {
      for my $lookup (@{ $file->{lookups} }) {
        my @found = keys_of($file, @{ $lookup->{key} }) or next;
        my $table = table_of($file, $lookup->{table}, $lookup->{at});
        if (!defined $table) {
          printf "%s:%d: the table of this lookup cannot be read (table: %s)\n", $file->{path},
            line_of($file, $lookup->{at}), $lookup->{table};
          $bad = 1;
          next;
        }
        check($file, $_->{start}, $_->{value}, [$table]) for @found;
      }
      for my $call (calls($file, 0, length $file->{m})) {
        my ($at, $qualifier, $name, $open) = @$call;
        my @helpers = helpers_for($file, $at, $qualifier, $name) or next;
        my @args = arguments($file->{m}, $open) or next;
        my %tables = map { %{ $_->{tables} } } @helpers;
        check($file, $_->{start}, $_->{value}, [keys %tables]) for keys_of($file, @{ $args[0] });
      }
      # A key handed on with its table: ("key", "Table") and (key: "key", table: "Table").
      my @literals = @{ $file->{literals} };
      for my $i (0 .. $#literals - 1) {
        my ($key, $table) = @literals[$i, $i + 1];
        next unless $key->{plain} && $table->{plain} && exists $keys{ $table->{value} };
        next if $table->{value} eq "InfoPlist";
        my $between = substr($file->{m}, $key->{end}, $table->{start} - $key->{end});
        next unless $between =~ /^\s*,\s*(?:table:\s*)?$/;
        # A tuple, not the arguments of a call: nothing but a space or a punctuation mark
        # stands right before its bracket.
        my $before = substr($file->{m}, 0, $key->{start});
        next unless $before =~ /(?:^|[\s=:,(\[{])\(\s*(?:key:\s*)?$/;
        next unless substr($file->{m}, $table->{end}) =~ /^\s*\)/;
        check($file, $key->{start}, $key->{value}, [ $table->{value} ]);
      }
    }
    exit $bad;
  ' "$@"
}

if [ "${1:-}" = "--self-test" ]; then
  dir="$(mktemp -d)"
  trap 'rm -rf "${dir}"' EXIT
  mkdir "${dir}/Strings"
  printf '%s\n' '{"sourceLanguage":"en","strings":{"common.ok":{},"shared.ok":{}},"version":"1.0"}' \
    > "${dir}/Strings/Common.xcstrings"
  printf '%s\n' '{"sourceLanguage":"en","strings":{"settings.ok":{},"shared.ok":{}},"version":"1.0"}' \
    > "${dir}/Strings/Settings.xcstrings"
  printf '%s\n' '{"sourceLanguage":"en","strings":{"planning.ok":{}},"version":"1.0"}' \
    > "${dir}/Strings/Planning.xcstrings"
  cat > "${dir}/good.swift" <<'SWIFT'
/// `language("made.up")` in a comment is not a lookup.
struct Row: View {
  var body: some View {
    Text(verbatim: environment.language("settings.ok", table: "Settings"))
    Text(verbatim: environment.language("common.ok"))  // language("made.up") after the code
    Text(verbatim: environment.format("settings.ok", table: "Settings", 1))
    label("settings.ok")
    Text(verbatim: t("shared.ok"))
    Text(verbatim: Words.t("settings.ok", environment))
    Text(verbatim: environment.language("forWhom.\(value.rawValue)"))
    Text(verbatim: Other.t("anything at all"))
    Text(verbatim: environment.language(flag ? "common.ok" : "shared.ok"))
    Text(verbatim: environment.language(name ?? "common.ok"))
    Text(verbatim: environment.language(key.replacingOccurrences(of: ".", with: "_")))
    Text(verbatim: "https://example.com/{path}")
    Text(verbatim: "\(environment.language("common.ok")) and \(count)")
  }
  private func label(_ key: String) -> some View {
    Text(verbatim: environment.language(key, table: "Settings"))
  }
  private func t(_ key: String) -> String {
    key.hasPrefix("common.")
      ? environment.language(key) : environment.language(key, table: "Settings")
  }
  static func pair(_ empty: Bool) -> (key: String, table: String) {
    empty ? ("settings.ok", "Settings") : (key: "planning.ok", table: "Planning")
  }
}

@MainActor
enum Words {
  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: "Settings")
  }
  static func format(_ key: String, _ environment: AppEnvironment) -> String {
    String(format: t(key, environment), locale: nil)
  }
  static func title(_ language: AppLanguage) -> String {
    language.format("settings.ok", table: table)
  }
  private static let table = "Settings"
}

/// Two types in one scope, each with a `t(_:)` of its own table: they were one helper once,
/// overwritten by the other on every pass, and the scan never ended.
open class Screens {
  struct Plan {
    func t(_ key: String) -> String { language(key, table: "Planning") }
    var title: String { t("planning.ok") }
  }
  package struct Options {
    func t(_ key: String) -> String { language(key, table: "Settings") }
    func u(_ key: String) -> String { t(key) }
    var title: String { t("settings.ok") + u("shared.ok") }
  }
}

extension Screens.Plan {
  func v(_ key: String) -> String { w(key) }
  func w(_ key: String) -> String { v(key) }
  var other: String { Self.caption + language("planning.ok", table: Self.table) }
  static let table = "Planning"
}
SWIFT
  cat > "${dir}/bad.swift" <<'SWIFT'
struct Row: View {
  var body: some View {
    Text(verbatim: environment.language("settings.ok"))
    Text(verbatim: environment.language("common.ok", table: "Settings"))
    label("common.ok")
    Text(verbatim: Words.format("missing.key", environment))
    Text(verbatim: environment.language(flag ? "common.ok" : "settings.ok"))
    Text(verbatim: environment.language(name ?? "settings.ok"))
    Text(verbatim: environment.language("common.ok", table: Self.tableOfTheDay))
  }
  private func label(_ key: String) -> some View {
    Text(verbatim: environment.language(key, table: "Settings"))
  }
  static func pair(_ empty: Bool) -> (key: String, table: String) {
    empty ? ("common.ok", "Settings") : (key: "settings.ok", table: "Planning")
  }
}

enum Words {
  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: "Settings")
  }
  static func format(_ key: String, _ environment: AppEnvironment) -> String {
    String(format: t(key, environment), locale: nil)
  }
  static func title(_ language: AppLanguage) -> String {
    language("common.ok", table: table)
  }
  private static let table = "Settings"
}

open class Screens {
  struct Plan {
    func t(_ key: String) -> String { language(key, table: "Planning") }
    var title: String { t("settings.ok") }
  }
  package struct Options {
    func t(_ key: String) -> String { language(key, table: "Settings") }
    var title: String { t("planning.ok") }
  }
}
SWIFT
  if ! found="$(scan "${dir}/Strings" "${dir}/good.swift")"; then
    echo "check-strings self-test: good.swift looks up only keys that exist, and was refused:"
    echo "${found}"
    exit 1
  fi
  found="$(scan "${dir}/Strings" "${dir}/bad.swift" | sed 's/^[^:]*:\([0-9]*\):.*/\1/' | sort -n |
    tr '\n' ' ')" || true
  expected="3 4 5 6 7 8 9 15 15 27 35 39 "
  if [ "${found}" != "${expected}" ]; then
    echo "check-strings self-test: expected the lines ${expected}of bad.swift, got: ${found}"
    scan "${dir}/Strings" "${dir}/bad.swift" || true
    exit 1
  fi
  echo "check-strings self-test: ok"
  exit 0
fi

cd "${root}"
sources=()
while IFS= read -r file; do sources+=("${file}"); done < <(
  find Apps/macOS -name '*.swift' -not -path '*/Tests/*' -not -path '*/UITests/*' | sort)
if ! found="$(scan Apps/macOS/Resources/Strings "${sources[@]}")"; then
  echo "${found}"
  echo "strings: a key is looked up in a table that does not have it" >&2
  exit 1
fi
echo "strings: every literal key is in the table it is looked up in"
