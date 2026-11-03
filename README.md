# AppRestarter

A macOS menu bar app that force quits and restarts your apps, even when they're frozen.

![Panel](screenshots/panel-light.png)

## Features

- Lists the apps you installed that are running (not system or background apps)
- Restart or force quit one app, or all of them at once
- "Not Responding" badge, and optional auto-restart when an app stays frozen
- Search, pinned apps, memory use, full keyboard control (⌃⌥R opens the panel)
- Exclude list, restart history, notifications, launch at login
- Updates through Sparkle

Requires macOS 13 or later.

## Install

Download the latest `AppRestarter-<version>.zip` from [Releases](https://github.com/prabeshbhetwal/AppRestarter/releases), unzip it, and move `AppRestarter.app` to Applications. The app is not notarised, so the first time you open it, right-click it and choose **Open**.

To show the "Not Responding" badge and auto-restart frozen apps, AppRestarter needs Accessibility access (Settings → Auto-Restart → Grant Access…).

## Build

```sh
./build.sh          # builds AppRestarter.app
selftest/run.sh     # logic self-test against a throwaway app
```

## Release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. Run `./release.sh`. It writes `releases/AppRestarter-<version>.zip` and updates `appcast.xml`.
3. Create GitHub release `v<version>` with the zip attached, then commit and push `appcast.xml`.
