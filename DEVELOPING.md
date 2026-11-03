# Developing RestinPID

## Build

```sh
./build.sh                       # builds RestinPID.app here
OUT=/Applications ./build.sh     # builds straight into Applications
selftest/run.sh                  # logic self-test against a throwaway app
```

## Release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. Write `release-notes/RestinPID-<version>.html` (what’s new; shown in the update window).
3. Run `./release.sh`. It writes `releases/RestinPID/RestinPID-<version>.zip`, delta updates, and `appcast.xml`.
4. Create GitHub release `v<version>` with the zip and the `.delta` files attached, then commit and push `appcast.xml`.
