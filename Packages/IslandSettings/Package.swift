// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IslandSettings",
    // English is the source language and lives in the Swift files, as the second argument to this
    // package's text lookup. `defaultLocalization` is what SwiftPM requires before it will build a
    // target with localized resources at all; it names the fallback, and there is no `en.lproj`.
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "IslandSettings", targets: ["IslandSettings"])
    ],
    dependencies: [
        .package(path: "../IslandKit"),
        .package(path: "../IslandActivities"),
        // **For the sides preview, and only for it.** The preview in the Island pane draws the two
        // slivers with `ActivityContentView` and the island's own outline with `IslandShape`, so
        // what a person sees while they are choosing is the renderer that will draw it — not a
        // second spelling of it that agrees until one of the two is changed. The layering is
        // unaffected: IslandUI depends on IslandKit and IslandActivities and not on this package,
        // so the edge is acyclic, and CLAUDE.md's test — anything in IslandUI builds and previews
        // with no permission granted — is a statement about IslandUI, which this does not touch.
        .package(path: "../IslandUI"),
    ],
    targets: [
        .target(
            name: "IslandSettings",
            dependencies: ["IslandKit", "IslandActivities", "IslandUI"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IslandSettingsTests",
            dependencies: ["IslandSettings", "IslandActivities", "IslandUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
