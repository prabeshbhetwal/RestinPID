# RestinPID

*Rest in PID.* A macOS menu bar app that force quits and restarts your apps, even when they're frozen. Formerly AppRestarter.

![Panel](screenshots/panel-light.png)

## Features

- Lists your running apps in three groups:
  - **Apps:** Dock apps you installed.
  - **Menu Bar & Background:** third-party menu bar and background apps such as Paste or KeepingYouAwake.
  - **macOS:** apps that came with macOS, such as Finder, Dock or Spotlight. These only appear when they pass a RAM or CPU limit or stop responding; you can change the limits, or show them always or never.
- Restart or force quit one app, or all of your own apps at once. macOS apps are never included in bulk actions.
- RAM and CPU use for each app, counting its helper processes, as Activity Monitor measures them.
- "Not Responding" badge, plus optional auto-restart when an app stays frozen.
- Search, pinned apps, and full keyboard control (⌃⌥R opens the panel).
- Exclude list, restart history, notifications and launch at login.
- Send Feedback window, which opens a pre-filled GitHub issue.
- Light, dark or system appearance.
- Updates through Sparkle: check every day, week, two weeks or month, or never. A new version shows as a dot on the menu bar icon and a banner in the panel, with its release notes.

Requires macOS 13 or later.

## Install

1. Download the latest `RestinPID-<version>.zip` from [Releases](https://github.com/prabeshbhetwal/RestinPID/releases).
2. Unzip it and move `RestinPID.app` to Applications.
3. The first time you open it, right-click it and choose **Open**. The app isn't notarised yet, so macOS warns you.

To show the "Not Responding" badge and auto-restart frozen apps, RestinPID needs Accessibility access: Settings → Auto-Restart → Grant Access….

Coming from AppRestarter 2.x? RestinPID has a new app identity, so it won't arrive as an update. Install it as above and quit AppRestarter. RestinPID copies your AppRestarter settings on its first launch. You'll need to grant Accessibility again once.

## Feedback

Use **Send Feedback…** in the gear menu, or open an [issue](https://github.com/prabeshbhetwal/RestinPID/issues/new/choose).

## Build

```sh
./build.sh                       # builds RestinPID.app here
OUT=/Applications ./build.sh     # builds straight into Applications
selftest/run.sh                  # logic self-test against a throwaway app
```

## Release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. Write `release-notes/RestinPID-<version>.html` (what’s new; shown in the update window).
3. Run `./release.sh`. It writes `releases/RestinPID-<version>.zip` and updates `appcast.xml`.
4. Create GitHub release `v<version>` with the zip attached, then commit and push `appcast.xml`.
