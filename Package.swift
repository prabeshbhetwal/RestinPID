// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppRestarter",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "AppRestarter",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: ".",
            exclude: ["AppRestarter.app", "releases", "AppIcon.icns", "Info.plist", "make-icon.swift",
                      "build.sh", "release.sh", "appcast.xml", "selftest", "README.md", "screenshots"],
            sources: ["AppRestarter.swift", "Model.swift", "Views.swift", "Hotkey.swift"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
