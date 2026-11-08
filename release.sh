#!/bin/sh
# Packages a Sparkle update. Bump CFBundleShortVersionString + CFBundleVersion in Info.plist first.
# Write release notes in release-notes/RestinPID-<version>.html first (shown in the update window).
# Then:
#   1. ./release.sh                     -> releases/RestinPID/RestinPID-<version>.zip and appcast.xml
#   2. Upload the zip (and .delta files) to GitHub release "v<version>" of prabeshbhetwal/RestinPID
#   3. Only then commit + push appcast.xml to main (SUFeedURL points at it; it goes live on push)
# With a Developer ID: SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<notarytool
# keychain profile> ./release.sh notarises and staples the app before zipping it.
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
NOTES="release-notes/RestinPID-$VERSION.html" # shown in the update window; required
[ -f "$NOTES" ] || { echo "error: write $NOTES first (what's new in $VERSION)"; exit 1; }
OUT="$(mktemp -d)"
OUT="$OUT" REQUIRE_IDENTITY=1 ./build.sh # never ship an ad-hoc build: it would reset Accessibility
codesign --verify --deep --strict "$OUT/RestinPID.app"
if [ -n "$NOTARY_PROFILE" ]; then
  ditto -c -k --keepParent "$OUT/RestinPID.app" "$OUT/notarise.zip"
  xcrun notarytool submit "$OUT/notarise.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT/RestinPID.app"
  spctl --assess --type execute "$OUT/RestinPID.app"
else
  echo "warning: NOTARY_PROFILE not set; not notarised, Gatekeeper will block first launch"
fi
# Own folder: generate_appcast makes deltas from every older zip it finds, and AppRestarter 2.x zips
# (a different app identity) sit in releases/.
ARCHIVES=releases/RestinPID
mkdir -p "$ARCHIVES"
cp "$NOTES" "$ARCHIVES/"
ditto -c -k --keepParent "$OUT/RestinPID.app" "$ARCHIVES/RestinPID-$VERSION.zip"
# --maximum-versions 1: only the latest item, so every URL points at this release.
# AppRestarter 2.x (builds < 4) has another bundle ID and can't install RestinPID in place, so it
# gets an informational update that links to the download page instead.
# --phased-rollout-interval: automatic checks reach everyone over about a week (7 groups, 1 day
# apart), so a bad release can be replaced before most people get it. Manual checks get it at once.
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/prabeshbhetwal/RestinPID/releases/download/v$VERSION/" \
  --informational-update-versions "<4" --link "https://github.com/prabeshbhetwal/RestinPID/releases/latest" \
  --phased-rollout-interval 86400 \
  --maximum-versions 1 -o appcast.xml "$ARCHIVES"
echo "Release $VERSION ready: $ARCHIVES/RestinPID-$VERSION.zip + appcast.xml"
echo "Upload the zip and .delta files to GitHub release v$VERSION BEFORE pushing appcast.xml."
