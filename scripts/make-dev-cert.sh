#!/bin/sh
# Creates a self-signed code-signing certificate named "Meeting Notes Dev" in the
# login keychain and trusts it for code signing. Run once:
#     sh scripts/make-dev-cert.sh
# Then build with CODE_SIGN_IDENTITY="Meeting Notes Dev" (project.yml already
# points at this name once you switch it on).
#
# Why: ad-hoc signed apps get a new signature on every build, and macOS ties the
# Screen & System Audio Recording permission to the signature, so the permission
# breaks after each rebuild. A stable certificate keeps it.
set -e
NAME="Meeting Notes Dev"
DIR=$(mktemp -d)
cd "$DIR"
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
# Import key and certificate separately (a PKCS12 made by OpenSSL 3 uses a
# cipher the macOS importer rejects). The keychain pairs them into an identity.
/usr/bin/openssl rsa -in key.pem -out key_rsa.pem -traditional 2>/dev/null || /usr/bin/openssl rsa -in key.pem -out key_rsa.pem
security import key_rsa.pem -k ~/Library/Keychains/login.keychain-db -t priv -f openssl \
  -T /usr/bin/codesign -T /usr/bin/security
security import cert.pem -k ~/Library/Keychains/login.keychain-db -t cert -f openssl
# User-level trust for code signing (asks for your login password).
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
rm -rf "$DIR"
echo "Done. Identity available:"
security find-identity -v -p codesigning | grep "$NAME"
