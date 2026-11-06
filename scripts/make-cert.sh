#!/bin/bash
# Creates a self-signed code-signing certificate "Shotmark Dev" in the login keychain.
# A stable signature lets macOS keep the Screen Recording permission across rebuilds.
set -euo pipefail
NAME="${CODESIGN_ID:-Shotmark Dev}"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "certificate \"$NAME\" already exists"
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<EOF
[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
# /usr/bin/openssl is LibreSSL: its .p12 defaults are what `security import` understands
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cfg" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 12)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "created certificate \"$NAME\""
