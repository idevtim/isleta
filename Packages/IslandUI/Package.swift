// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IslandUI",
    // English is the source language and lives in the Swift files, as the second argument to this
    // package's text lookup. `defaultLocalization` is what SwiftPM requires before it will build a
    // target with localized resources at all; it names the fallback, and there is no `en.lproj`.
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "IslandUI", targets: ["IslandUI"])
    ],
    dependencies: [
        .package(path: "../IslandKit"),
        .package(path: "../IslandActivities"),
    ],
    targets: [
        .target(
            name: "IslandUI",
            dependencies: ["IslandKit", "IslandActivities"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IslandUITests",
            dependencies: ["IslandUI", "IslandActivities"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
