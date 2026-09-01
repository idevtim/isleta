// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IslandSources",
    // English is the source language and lives in the Swift files, as `sourceText`'s second
    // argument. `defaultLocalization` is what SwiftPM requires before it will build a target with
    // localized resources at all; it names the fallback, and there is no `en.lproj`.
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "IslandSources", targets: ["IslandSources"])
    ],
    dependencies: [
        .package(path: "../IslandKit"),
        .package(path: "../IslandActivities"),
    ],
    targets: [
        .target(
            name: "IslandSources",
            dependencies: ["IslandKit", "IslandActivities"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IslandSourcesTests",
            dependencies: ["IslandSources"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
