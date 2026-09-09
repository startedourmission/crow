// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CrowCore", targets: ["CrowCore"]),
    ],
    targets: [
        .target(name: "CrowCore"),
        .testTarget(
            name: "CrowCoreTests",
            dependencies: ["CrowCore"]
        ),
    ]
)
