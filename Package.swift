// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RestinPID",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "RestinPID",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: ".",
            exclude: ["RestinPID.app", "_trash", "releases", ".github", "AppIcon.icns", "Info.plist", "make-icon.swift",
                      "build.sh", "release.sh", "release-notes", "appcast.xml", "selftest", "README.md", "DEVELOPING.md", "screenshots"],
            sources: ["RestinPID.swift", "Model.swift", "Views.swift", "Hotkey.swift",
                      "Icon.swift", "MenuBarAlert.swift", "AlertsTab.swift"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
