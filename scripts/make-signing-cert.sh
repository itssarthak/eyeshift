#!/bin/sh
# One-time setup: creates a self-signed "Eyeshift Local Signing" certificate in your login keychain.
# build.sh signs with it when present, so macOS keeps the Camera and Accessibility permissions across
# rebuilds (ad-hoc builds look like a new app to macOS every time). Remove it any time in Keychain Access.
set -e
NAME="Eyeshift Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "Already set up: $NAME"; exit 0; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# -legacy: macOS's keychain can't read OpenSSL 3's default PKCS#12 encryption
openssl pkcs12 -export -legacy -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:eyeshift 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:eyeshift
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P eyeshift -T /usr/bin/codesign
echo "Created: $NAME. Run ./build.sh, then tick Eyeshift in Accessibility one last time."
