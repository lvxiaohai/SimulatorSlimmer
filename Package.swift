// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SimulatorSlimmer",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SimulatorSlimmerCore",
            targets: ["SimulatorSlimmerCore"]
        )
    ],
    targets: [
        .target(
            name: "SimulatorSlimmerCore",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SimulatorSlimmerCoreTests",
            dependencies: ["SimulatorSlimmerCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
