// swift-tools-version: 6.2
import PackageDescription

let concurrencyBaseline: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "Networking",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "AnvyxNetworkKit", targets: ["AnvyxNetworkKit"]),
    ],
    targets: [
        .target(name: "AnvyxNetworkKit", swiftSettings: concurrencyBaseline),
        .testTarget(
            name: "AnvyxNetworkKitTests",
            dependencies: ["AnvyxNetworkKit"],
            swiftSettings: concurrencyBaseline
        ),
    ]
)
