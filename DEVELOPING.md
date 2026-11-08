# Developing RestinPID

## Build

```sh
./build.sh                       # builds RestinPID.app here
OUT=/Applications ./build.sh     # builds straight into Applications
selftest/run.sh                  # logic self-test against a throwaway app
```

Icons: `Icon.swift` holds the tombstone geometry for both the menu bar and the app icon. After changing it, delete `AppIcon.icns` and run `./build.sh` to regenerate it. To check that the alert icon is visible on black, grey and white menu bars (contrast and rendered pixels, with a contact sheet):

```sh
xcrun swiftc -parse-as-library Icon.swift MenuBarAlert.swift selftest/icon-check.swift -o /tmp/icon-check && /tmp/icon-check /tmp
open -n RestinPID.app --args --preview-alert   # shows the alert in the real menu bar for 6 s
```

## Release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. Write `release-notes/RestinPID-<version>.html` (what’s new; shown in the update window).
3. Run `./release.sh`. It writes `releases/RestinPID/RestinPID-<version>.zip`, delta updates, and `appcast.xml`. It refuses to sign ad-hoc. Once enrolled in the Apple Developer Program, run it as `SIGN_IDENTITY="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=<profile> ./release.sh` to sign with the hardened runtime, notarise and staple (create the profile once with `xcrun notarytool store-credentials`). Switching certificates resets users' Accessibility permission once, so say so in that release's notes.
4. Create GitHub release `v<version>` with the zip and the `.delta` files attached, **then** commit and push `appcast.xml`. The feed goes live on push, phased over about a week for automatic checks.

Keep offline backups of the Sparkle EdDSA private key (`.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>`) and the signing certificate (.p12). Losing the EdDSA key means existing users can never update again.
