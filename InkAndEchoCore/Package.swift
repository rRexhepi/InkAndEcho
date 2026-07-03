// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InkAndEchoCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "InkAndEchoCore", targets: ["InkAndEchoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "InkAndEchoCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(
            name: "InkAndEchoCoreTests",
            dependencies: ["InkAndEchoCore"],
            resources: [.copy("Resources")]
        ),
    ]
)
