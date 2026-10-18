// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AtemProxyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AtemProxyKit", type: .dynamic, targets: ["AtemProxyKit"]),
        .executable(name: "atem-proxy", targets: ["atem-proxy"]),
    ],
    targets: [
        .target(name: "AtemProxyKit"),
        .executableTarget(name: "atem-proxy", dependencies: ["AtemProxyKit"]),
        .testTarget(name: "AtemProxyKitTests", dependencies: ["AtemProxyKit"]),
    ]
)
