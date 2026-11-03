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

mkdir -p AppRestarter.app
rsync -a --delete "$STAGE/" AppRestarter.app/

xattr -cr AppRestarter.app # Desktop/iCloud attributes break codesign; sign in place after copying
codesign --force --deep --sign - AppRestarter.app
codesign --verify --deep --strict AppRestarter.app
echo "Built $PWD/AppRestarter.app"
