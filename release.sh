#!/bin/sh
# Packages a Sparkle update. Bump CFBundleShortVersionString + CFBundleVersion in Info.plist first.
# Then:
#   1. ./release.sh                     -> releases/AppRestarter-<version>.zip and appcast.xml
#   2. Upload the zip to GitHub release "v<version>" of prabeshbhetwal/AppRestarter
#   3. Commit + push appcast.xml to main (SUFeedURL points at it)
set -e
cd "$(dirname "$0")"
OUT="$(mktemp -d)"
OUT="$OUT" ./build.sh
codesign --verify --deep --strict "$OUT/AppRestarter.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
mkdir -p releases
ditto -c -k --keepParent "$OUT/AppRestarter.app" "releases/AppRestarter-$VERSION.zip"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/prabeshbhetwal/AppRestarter/releases/download/v$VERSION/" \
  -o appcast.xml releases
echo "Release $VERSION ready: releases/AppRestarter-$VERSION.zip + appcast.xml"
