#!/bin/bash
# One-time setup: a persistent self-signed code-signing identity in the login
# keychain, so macOS keeps the Accessibility permission across fork rebuilds.
# The private key exists only in the keychain; temporary files are removed.
set -euo pipefail
NAME="ClipBoardLine Local Signing (SelcukOzbilgi)"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -Fq "\"$NAME\""; then
  echo "Already present: $NAME"
else
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# OpenSSL 3 writes PKCS#12 ciphers that the macOS keychain cannot read.
LEGACY=()
if openssl version | grep -q '^OpenSSL 3'; then LEGACY=(-legacy); fi
PASSWORD="$(openssl rand -hex 24)"
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASSWORD"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
rm -rf "$TMP"
security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\""
echo "Installed: $NAME (\"not trusted\" is expected and fine for codesign)"
fi

# Let codesign use the key without a keychain dialog on every build. This asks
# once for the login keychain password in this terminal (not stored anywhere).
echo "Allowing codesign to use the key; enter your login keychain password:"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$NAME" "$KEYCHAIN" >/dev/null
echo "Done. Build with: bash scripts/build-fork.sh"
