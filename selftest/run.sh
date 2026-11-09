#!/bin/sh
# Self-test: builds a throwaway Dummy.app, then checks listing, frozen badge, watchdog
# auto-restart, exclude and force quit against it. Needs Accessibility access for the
# terminal running it (frozen detection). Run: selftest/run.sh
set -e
cd "$(dirname "$0")/.."
T="$(mktemp -d)"
A="$T/Dummy.app"
mkdir -p "$A/Contents/MacOS"
xcrun swiftc selftest/dummy.swift -o "$A/Contents/MacOS/Dummy"
cat > "$A/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Dummy</string><key>CFBundleIdentifier</key><string>com.test.ARDummy</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleName</key><string>Dummy</string></dict></plist>
EOF
codesign -f -s - "$A"
xcrun swiftc -swift-version 5 -parse-as-library Model.swift LayoutHold.swift Hotkey.swift selftest/logic.swift -o "$T/logic"
"$T/logic" "$A" | tee "$T/out.txt"
! grep -q FAIL "$T/out.txt"
