#!/bin/sh
# Creates a stable self-signed code-signing identity, "SpeakDev", in the login
# keychain. A stable identity keeps macOS permission grants across rebuilds;
# ad-hoc signing would reset them every time. Safe to re-run.
set -eu
NAME=SpeakDev
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "SpeakDev identity already exists"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/cert.conf" <<CONF
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
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$tmp/cert.conf" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null

# The password only protects the temporary bundle during import.
pass=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$NAME" -out "$tmp/id.p12" -passout "pass:$pass" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
       -name "$NAME" -out "$tmp/id.p12" -passout "pass:$pass"

security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS may ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "SpeakDev identity created"
else
  echo "make-identity: imported, but SpeakDev is not listed as a valid signing identity" >&2
  exit 1
fi
