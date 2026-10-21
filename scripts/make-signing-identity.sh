#!/bin/bash
# Makes the self-signed code-signing certificate «OhMyMoney Local Signing» in the login keychain,
# so the Debug build and its UI-test runner keep one signature from build to build and the
# permissions macOS gave them (Accessibility, automation) survive a rebuild.
#
# Run it once, by hand: it writes to the login keychain, outside the project, and macOS asks
# for the login password to trust the certificate.
#
# Running it again is safe: it finishes whatever is missing and never makes a second
# certificate with the same name.
set -euo pipefail

NAME="OhMyMoney Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Already done? `-v` lists only identities that are valid for signing, which is exactly what
# the build looks for.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${NAME}\""; then
  echo "«${NAME}» is already there and trusted for code signing — nothing to do."
  exit 0
fi

# Is a certificate of that name in the keychain already? A second one with the same name only
# makes the choice ambiguous, so the script never adds one.
hashes="$(security find-certificate -a -c "$NAME" -Z "$KEYCHAIN" 2>/dev/null || true)"
found="$(printf '%s\n' "$hashes" | grep -c '^SHA-1 hash:' || true)"

if [ "${found:-0}" -gt 1 ]; then
  echo "There is more than one certificate named «${NAME}» in the login keychain." >&2
  echo "Remove the extra ones in Keychain Access, then run this again." >&2
  exit 1
fi

if [ "${found:-0}" -eq 1 ]; then
  # Without `-v` the list includes identities that are not valid yet: if the name is there,
  # the private key is there too and only the trust is missing.
  if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"${NAME}\""; then
    echo "«${NAME}» is in the keychain but not trusted for code signing yet."
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$tmp/cert.pem"
    echo "Trusting the certificate for code signing — macOS asks for your login password."
    security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"
  else
    echo "There is a certificate «${NAME}» in the keychain, but no private key for it." >&2
    echo "Remove it in Keychain Access, then run this again to make a new pair." >&2
    exit 1
  fi
else
  cat > "$tmp/request.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

  # Ten years: a certificate that expires would bring the prompts back.
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/request.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null

  # OpenSSL 3 writes PKCS#12 with ciphers the keychain cannot read unless told `-legacy`;
  # the LibreSSL that ships with macOS writes the old ones and has no such flag. The array is
  # expanded so that an empty one is nothing at all: under `set -u` bash 3.2 would otherwise
  # stop at «legacy[@]: unbound variable».
  legacy=()
  if openssl version | grep -q '^OpenSSL 3'; then legacy=(-legacy); fi
  transfer="ohmymoney-$$"
  openssl pkcs12 -export ${legacy[@]+"${legacy[@]}"} -name "$NAME" -inkey "$tmp/key.pem" \
    -in "$tmp/cert.pem" -out "$tmp/identity.p12" -passout "pass:$transfer"

  # Only codesign may use the key without asking.
  security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$transfer" -T /usr/bin/codesign

  echo "Trusting the certificate for code signing — macOS asks for your login password."
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"
fi

if security find-identity -v -p codesigning | grep -q "\"${NAME}\""; then
  echo "Done: «${NAME}» signs the Debug build from the next make build."
else
  echo "The certificate is imported but not trusted for code signing yet." >&2
  echo "Keychain Access → login → «${NAME}» → Trust → Code Signing: Always Trust." >&2
  exit 1
fi
