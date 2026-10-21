#!/bin/bash
# The app is called OhMyMoney. Its earlier names exist nowhere in the tree: no identifier, path,
# comment, document, history line or fixture says them, and nothing is allowed as an exception.
# The patterns are built from pieces so that this script does not spell the words itself.
#
# Not read: this script itself. Nothing else is an exception.
set -u
cd "$(dirname "$0")/.."
first="It""ogo"
second="Ost""atok"
magic="ITG""OARC"
pattern="${first}|${magic}|${second}|Остаток(\\.app|\\.online| [Ll]ocal)"

found="$(git ls-files | grep -vE '^(scripts/check-names\.sh)$' \
  | grep -v '\.icon/' | xargs grep -nIiE "${pattern}" 2>/dev/null || true)"
# Binary files too: a fixture can carry the old signature.
binary="$(git ls-files | grep -vE '^(scripts/check-names\.sh)$' \
  | xargs grep -laiE "${first}|${magic}|${second}" 2>/dev/null || true)"
bad="${found}"
for file in ${binary}; do
  printf '%s\n' "${found}" | grep -q "^${file}:" || bad="${bad}"$'\n'"${file}: binary file with an old name"
done
if [ -n "${bad//[$'\n ']/}" ]; then
  echo "check-names: an earlier name of the app is left in the tree:" >&2
  echo "${bad}" >&2
  exit 1
fi
echo "check-names: ok"
