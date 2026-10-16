// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaCore",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
    products: [
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
    ],
    targets: [
        .target(
            name: "QuotaCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuotaCoreTests",
            dependencies: ["QuotaCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
