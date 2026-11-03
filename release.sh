#!/bin/sh
# Packages a Sparkle update. Bump CFBundleShortVersionString + CFBundleVersion in Info.plist first.
# Write release notes in release-notes/RestinPID-<version>.html first (shown in the update window).
# Then:
#   1. ./release.sh                     -> releases/RestinPID/RestinPID-<version>.zip and appcast.xml
#   2. Upload the zip to GitHub release "v<version>" of prabeshbhetwal/RestinPID
#   3. Commit + push appcast.xml to main (SUFeedURL points at it)
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
NOTES="release-notes/RestinPID-$VERSION.html" # shown in the update window; required
[ -f "$NOTES" ] || { echo "error: write $NOTES first (what's new in $VERSION)"; exit 1; }
OUT="$(mktemp -d)"
OUT="$OUT" ./build.sh
codesign --verify --deep --strict "$OUT/RestinPID.app"
# Own folder: generate_appcast makes deltas from every older zip it finds, and AppRestarter 2.x zips
# (a different app identity) sit in releases/.
ARCHIVES=releases/RestinPID
mkdir -p "$ARCHIVES"
cp "$NOTES" "$ARCHIVES/"
ditto -c -k --keepParent "$OUT/RestinPID.app" "$ARCHIVES/RestinPID-$VERSION.zip"
# --maximum-versions 1: only the latest item, so every URL points at this release.
# AppRestarter 2.x (builds < 4) has another bundle ID and can't install RestinPID in place, so it
# gets an informational update that links to the download page instead.
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/prabeshbhetwal/RestinPID/releases/download/v$VERSION/" \
  --informational-update-versions "<4" --link "https://github.com/prabeshbhetwal/RestinPID/releases/latest" \
  --maximum-versions 1 -o appcast.xml "$ARCHIVES"
echo "Release $VERSION ready: $ARCHIVES/RestinPID-$VERSION.zip + appcast.xml"
