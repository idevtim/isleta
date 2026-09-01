// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IslandActivities",
    // English is the source language and lives in the Swift files, as `activityText`'s second
    // argument. `defaultLocalization` is what SwiftPM requires before it will build a target with
    // localized resources at all; it names the fallback, and there is deliberately no `en.lproj`.
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "IslandActivities", targets: ["IslandActivities"])
    ],
    dependencies: [.package(path: "../IslandKit")],
    targets: [
        .target(
            name: "IslandActivities",
            dependencies: ["IslandKit"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IslandActivitiesTests",
            dependencies: ["IslandActivities"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
