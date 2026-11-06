#!/bin/sh
# Keeps the release signing key in its own keychain, locked except while a release is signed.
#
# Why: the key is the app's identity. Anything signed with it keeps users' microphone and
# system-audio permissions, so a program that can use the key can ship a trojaned "update" or
# give itself the app's permissions on this Mac. In the login keychain the key is usable whenever
# you are logged in; in a locked keychain only after you type its password.
#
#   scripts/signing-keychain.sh move <file.p12>  Put an exported key + certificate into the signing
#                                                keychain (asks for the .p12 password and a new
#                                                password for the keychain). Then delete the copy
#                                                in the login keychain (see the message at the end).
#   scripts/signing-keychain.sh create           Create the empty keychain (make-signing-cert.sh uses it).
#   scripts/signing-keychain.sh unlock           Unlock it (make build/test/release do this).
#   scripts/signing-keychain.sh lock             Lock it again.
#   scripts/signing-keychain.sh path             Print its path when it exists.
#
# OTR_SIGNING_KEYCHAIN overrides the keychain path (for testing).
set -eu
KEYCHAIN="${OTR_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/off-the-record-signing.keychain-db}"

exists() { [ -f "$KEYCHAIN" ]; }

create() {
  if exists; then return; fi
  echo "Choose a password for the signing keychain (you type it for each release):"
  security create-keychain "$KEYCHAIN"
  # Locks itself after 10 minutes and on sleep, whatever happens to a build.
  security set-keychain-settings -l -u -t 600 "$KEYCHAIN"
  # Add to the search list (keeping the existing entries) so codesign and xcodebuild find it.
  # shellcheck disable=SC2046
  security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KEYCHAIN"
}

case "${1:-}" in
  move)
    P12="${2:?usage: $0 move <file.p12>}"
    create
    security unlock-keychain "$KEYCHAIN"
    # Only codesign may use the key, and only while this keychain is unlocked.
    security import "$P12" -k "$KEYCHAIN" -f pkcs12 -T /usr/bin/codesign
    echo "Keychain password again, so codesign can use the key without a dialog while unlocked:"
    security set-key-partition-list -S apple-tool:,apple: -s "$KEYCHAIN" >/dev/null
    security lock-keychain "$KEYCHAIN"
    cat <<TXT

Done: the key and certificate are in $KEYCHAIN (locked).
Now remove the old copy so only the locked keychain has it:
  1. Open Keychain Access, choose the "login" keychain, then "My Certificates".
  2. Delete "Off the Record" (certificate and its private key).
Keep the .p12 backup somewhere safe, away from this Mac if you can.
Check with: make dmg   (asks for the signing keychain password once)
TXT
    ;;
  create)
    create
    ;;
  unlock)
    if exists; then
      if [ -t 0 ]; then
        echo "Unlocking the signing keychain:"
        security unlock-keychain "$KEYCHAIN"
      else
        # No terminal to type into (an IDE or script): unlock it beforehand with
        # `scripts/signing-keychain.sh unlock`, or macOS asks in a dialog when signing.
        echo "Signing keychain: not unlocking here (no terminal); unlock it first or answer the macOS dialog."
      fi
    fi
    ;;
  lock)
    if exists; then security lock-keychain "$KEYCHAIN"; fi
    ;;
  path)
    if exists; then echo "$KEYCHAIN"; fi
    ;;
  *)
    sed -n '2,18p' "$0"
    exit 1
    ;;
esac
