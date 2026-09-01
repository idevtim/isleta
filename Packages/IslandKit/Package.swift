// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IslandKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "IslandKit", targets: ["IslandKit"])
    ],
    targets: [
        .target(
            name: "IslandKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IslandKitTests",
            dependencies: ["IslandKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
