#!/bin/sh
# Prints the best code-signing identity on this Mac: a Developer ID (notarizable), the project's
# self-signed "Off the Record" certificate (scripts/make-signing-cert.sh), the older
# "Meeting Notes Dev" one, or "-" (ad-hoc: runs, but macOS asks for permissions again after
# every build).
ids=$(security find-identity -v -p codesigning 2>/dev/null)
for name in "Developer ID Application" "Off the Record" "Meeting Notes Dev"; do
  found=$(printf '%s\n' "$ids" | grep -o "\"$name[^\"]*\"" | head -1 | tr -d '"')
  if [ -n "$found" ]; then echo "$found"; exit 0; fi
done
# The signing keychain (scripts/signing-keychain.sh) may be locked now and is unlocked just before
# signing; never fall back to ad-hoc then, which would cost users their permissions.
if [ -n "$(scripts/signing-keychain.sh path 2>/dev/null)" ]; then echo "Off the Record"; exit 0; fi
echo "-"
