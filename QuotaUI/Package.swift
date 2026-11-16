// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaUI",
    defaultLocalization: "en",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
    products: [
        .library(name: "QuotaUI", targets: ["QuotaUI"]),
        .executable(name: "WidgetRender", targets: ["WidgetRender"]),
    ],
    dependencies: [.package(path: "../QuotaCore")],
    targets: [
        .target(
            name: "QuotaUI",
            dependencies: ["QuotaCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "WidgetRender",
            dependencies: ["QuotaUI", "QuotaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuotaUITests",
            dependencies: ["QuotaUI", "QuotaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
