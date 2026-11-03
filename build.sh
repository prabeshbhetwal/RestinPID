#!/bin/sh
# Builds RestinPID.app (universal: Apple silicon + Intel) next to this script.
# Run: ./build.sh && open RestinPID.app
set -e
cd "$(dirname "$0")"

if [ ! -f AppIcon.icns ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  xcrun swift make-icon.swift "$ICONSET"
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

# Sign + verify in the temp folder: the Desktop re-adds Finder attributes that break signatures.
# A stable identity keeps users' Accessibility permission across updates (ad-hoc changes every build).
# Override with SIGN_IDENTITY="Developer ID Application: …" once enrolled; falls back to ad-hoc.
xattr -cr "$STAGE"
IDENTITY="${SIGN_IDENTITY:-AppRestarter Code Signing}" # keychain name of the existing certificate
security find-identity -p codesigning | grep -q "$IDENTITY" || { echo "warning: '$IDENTITY' not found, signing ad-hoc"; IDENTITY=-; }
codesign --force --deep --sign "$IDENTITY" "$STAGE"
codesign --verify --deep --strict "$STAGE"

# OUT=<dir> puts the app elsewhere (release.sh zips from a clean temp copy).
OUT="${OUT:-.}"
mkdir -p "$OUT/RestinPID.app"
rsync -a --delete "$STAGE/" "$OUT/RestinPID.app/"
echo "Built $(cd "$OUT" && pwd)/RestinPID.app"
