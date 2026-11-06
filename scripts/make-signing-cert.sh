#!/bin/sh
# Creates a self-signed code-signing certificate named "Off the Record" in the login keychain
# and trusts it for code signing. Run once on the machine that builds releases:
#     sh scripts/make-signing-cert.sh
# `make` then signs with it automatically.
#
# Why: ad-hoc signed apps get a new signature on every build, and macOS ties the microphone and
# Screen & System Audio Recording permissions to the signature, so users would have to allow them
# again after every update. Signing every release with the same certificate keeps them.
# Keep the private key safe (export it from Keychain Access as a backup): releases signed with a
# different key lose those permissions. A Developer ID certificate replaces this for notarized builds.
set -e
NAME="${1:-Off the Record}"
DIR=$(mktemp -d)
# The unencrypted key never outlives this script, also when a step fails.
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
# Import key and certificate separately (a PKCS12 made by OpenSSL 3 uses a
# cipher the macOS importer rejects). The keychain pairs them into an identity.
/usr/bin/openssl rsa -in key.pem -out key_rsa.pem -traditional 2>/dev/null || /usr/bin/openssl rsa -in key.pem -out key_rsa.pem
# Only codesign may use the key without asking. (Allowing /usr/bin/security too would let any
# program export the key silently, and with it sign "updates" that keep users' permissions.)
security import key_rsa.pem -k ~/Library/Keychains/login.keychain-db -t priv -f openssl \
  -T /usr/bin/codesign
security import cert.pem -k ~/Library/Keychains/login.keychain-db -t cert -f openssl
# User-level trust for code signing (asks for your login password).
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
echo "Done. Identity available:"
security find-identity -v -p codesigning | grep "$NAME"
