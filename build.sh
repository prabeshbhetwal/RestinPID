#!/bin/sh
# Builds AppRestarter.app (universal: Apple silicon + Intel) next to this script.
# Run: ./build.sh && open AppRestarter.app
set -e
cd "$(dirname "$0")"

if [ ! -f AppIcon.icns ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  xcrun swift make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o AppIcon.icns
fi

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

STAGE="$(mktemp -d)/AppRestarter.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Frameworks" "$STAGE/Contents/Resources"
cp "$BIN/AppRestarter" "$STAGE/Contents/MacOS/AppRestarter"
cp Info.plist "$STAGE/Contents/Info.plist"
cp AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
ditto "$BIN/Sparkle.framework" "$STAGE/Contents/Frameworks/Sparkle.framework"

# Sign + verify in the temp folder: the Desktop re-adds Finder attributes that break signatures.
# A stable identity keeps users' Accessibility permission across updates (ad-hoc changes every build).
# Override with SIGN_IDENTITY="Developer ID Application: …" once enrolled; falls back to ad-hoc.
xattr -cr "$STAGE"
IDENTITY="${SIGN_IDENTITY:-AppRestarter Code Signing}"
security find-identity -p codesigning | grep -q "$IDENTITY" || { echo "warning: '$IDENTITY' not found, signing ad-hoc"; IDENTITY=-; }
codesign --force --deep --sign "$IDENTITY" "$STAGE"
codesign --verify --deep --strict "$STAGE"

# OUT=<dir> puts the app elsewhere (release.sh zips from a clean temp copy).
OUT="${OUT:-.}"
mkdir -p "$OUT/AppRestarter.app"
rsync -a --delete "$STAGE/" "$OUT/AppRestarter.app/"
echo "Built $(cd "$OUT" && pwd)/AppRestarter.app"
