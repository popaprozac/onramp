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
        .executableTarget(
            name: "onramp",
            dependencies: [
                "OnrampCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "OnrampCoreTests", dependencies: ["OnrampCore"]),
    ]
)
