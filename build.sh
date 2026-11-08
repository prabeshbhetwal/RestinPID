#!/bin/sh
# Builds RestinPID.app (universal: Apple silicon + Intel) next to this script.
# Run: ./build.sh && open RestinPID.app
set -e
cd "$(dirname "$0")"

if [ ! -f AppIcon.icns ]; then
  TMP="$(mktemp -d)"
  ICONSET="$TMP/AppIcon.iconset"
  xcrun swiftc -parse-as-library make-icon.swift Icon.swift -o "$TMP/make-icon"
  "$TMP/make-icon" "$ICONSET"
  iconutil -c icns "$ICONSET" -o AppIcon.icns
fi

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

STAGE="$(mktemp -d)/RestinPID.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Frameworks" "$STAGE/Contents/Resources"
cp "$BIN/RestinPID" "$STAGE/Contents/MacOS/RestinPID"
cp Info.plist "$STAGE/Contents/Info.plist"
cp AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
ditto "$BIN/Sparkle.framework" "$STAGE/Contents/Frameworks/Sparkle.framework"
# Licences travel with the app: RestinPID's own, and Sparkle's (MIT asks for its notice in every copy).
cp LICENSE "$STAGE/Contents/Resources/LICENSE.txt"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$STAGE/Contents/Resources/Sparkle-LICENSE.txt"

# Sign + verify in the temp folder: the Desktop re-adds Finder attributes that break signatures.
# A stable identity keeps users' Accessibility permission across updates (ad-hoc changes every build).
# SIGN_IDENTITY="Developer ID Application: …" turns on the hardened runtime and a secure timestamp,
# which notarisation needs. REQUIRE_IDENTITY=1 (release.sh sets it) fails instead of signing ad-hoc.
xattr -cr "$STAGE"
IDENTITY="${SIGN_IDENTITY:-AppRestarter Code Signing}" # keychain name of the existing certificate
if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
  [ "$REQUIRE_IDENTITY" = 1 ] && { echo "error: signing identity '$IDENTITY' not found"; exit 1; }
  echo "warning: '$IDENTITY' not found, signing ad-hoc"; IDENTITY=-
fi
case "$IDENTITY" in
  "Developer ID Application"*) OPTS="--options runtime --timestamp" ;;
  *) OPTS="" ;;
esac
# Inside out, without --deep: Sparkle's helpers first, then the framework, then the app.
SPARKLE="$STAGE/Contents/Frameworks/Sparkle.framework"
for item in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
            "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  codesign --force --sign "$IDENTITY" $OPTS --preserve-metadata=entitlements "$item"
done
codesign --force --sign "$IDENTITY" $OPTS "$STAGE"
codesign --verify --deep --strict "$STAGE"

# OUT=<dir> puts the app elsewhere (release.sh zips from a clean temp copy).
OUT="${OUT:-.}"
mkdir -p "$OUT/RestinPID.app"
rsync -a --delete "$STAGE/" "$OUT/RestinPID.app/"
echo "Built $(cd "$OUT" && pwd)/RestinPID.app"
