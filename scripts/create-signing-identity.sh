#!/usr/bin/env bash
# One-time: creates a self-signed "NoPeek Local Signing" code-signing identity in your login keychain.
# Why: macOS ties Camera/Accessibility permissions to the app's signature. Ad-hoc signatures change on
# every build, so permissions reset after each rebuild. A stable identity keeps them.
set -euo pipefail

NAME="NoPeek Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "✓ '$NAME' already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:nopeek -name "$NAME" >/dev/null 2>&1

security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P nopeek -T /usr/bin/codesign >/dev/null

echo "✓ Created '$NAME'. Rebuild with: make install"
echo "  (macOS may ask once to let codesign use the key: choose 'Always Allow')"
