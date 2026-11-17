// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "onramp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "onramp", targets: ["onramp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .target(name: "OnrampCore"),
        // Everything that touches the system: processes, packages, launchd, the console user.
        .target(name: "OnrampPlatform", dependencies: ["OnrampCore"]),
        .executableTarget(
            name: "onramp",
            dependencies: [
                "OnrampCore",
                "OnrampPlatform",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "OnrampCoreTests", dependencies: ["OnrampCore"]),
        .testTarget(name: "OnrampPlatformTests", dependencies: ["OnrampCore", "OnrampPlatform"]),
    ]
)
