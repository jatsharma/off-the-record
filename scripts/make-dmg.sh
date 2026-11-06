#!/bin/sh
# Packs a built app into a compressed, drag-to-install disk image.
#   scripts/make-dmg.sh "<path to Off the Record.app>" <version> "<signing identity or ->"
set -eu
APP="$1"; VERSION="$2"; IDENTITY="${3:--}"
NAME="Off the Record"
OUT="dist/$NAME $VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p dist
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
case "$IDENTITY" in
  "Developer ID Application"*) ;;   # notarized builds open normally
  *) cat > "$STAGE/If macOS blocks the app.txt" <<TXT
Off the Record is open source and not notarized by Apple, so the first time you open it macOS says it
cannot check it for malicious software.

1. Drag Off the Record into Applications and open it once (it will be blocked).
2. Open System Settings > Privacy & Security, scroll down and click "Open Anyway" next to
   Off the Record, then confirm.

You only do this once. Updates signed with the same certificate open normally and keep your
microphone and system-audio permissions.
TXT
  ;;
esac
rm -f "$OUT"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
if [ "$IDENTITY" != "-" ]; then codesign --force --sign "$IDENTITY" --timestamp=none "$OUT"; fi
# For the release notes, so people can check the download and the app before "Open Anyway".
( cd dist && shasum -a 256 "$NAME $VERSION.dmg" > "$NAME $VERSION.dmg.sha256" )
echo "$OUT ($(du -h "$OUT" | cut -f1))"
echo "SHA-256: $(cut -d' ' -f1 "$OUT.sha256")"
if [ "$IDENTITY" != "-" ]; then
  echo "Certificate SHA-256: $(security find-certificate -c "$IDENTITY" -Z -a 2>/dev/null | awk '/SHA-256/ {print $3; exit}')"
fi
