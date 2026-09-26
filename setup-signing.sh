#!/bin/bash
# One-time setup: create a stable, self-signed code-signing certificate named
# "MacExplorer Local" in your login keychain. Signing the app with a STABLE
# identity (instead of ad-hoc) is what lets macOS remember your Full Disk Access
# grant across rebuilds — an ad-hoc signature changes every build, so macOS
# treats each build as a new app and re-prompts for FDA.
#
# Run this ONCE. After that, ./run.sh automatically signs with it.
# To undo: delete the "MacExplorer Local" cert in Keychain Access (login keychain).
set -e

NAME="MacExplorer Local"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "'$NAME' already exists — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
cd "$WORK"
cat > csr.conf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = MacExplorer Local
[ v3 ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config csr.conf
# macOS keychain needs legacy PKCS12 PBE (not OpenSSL 3 defaults).
openssl pkcs12 -export -inkey key.pem -in cert.pem -out ident.p12 -passout pass:macexp \
    -name "$NAME" -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import ident.p12 -k ~/Library/Keychains/login.keychain-db -P macexp -T /usr/bin/codesign

rm -rf "$WORK"
echo "Created '$NAME'. ./run.sh will now sign with it, and Full Disk Access will persist."
echo "NOTE: you must grant FDA one more time (the signature just changed); it sticks after that."
