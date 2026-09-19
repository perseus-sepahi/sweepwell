// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SweepwellKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SweepwellKit", targets: ["SweepwellKit"])
    ],
    targets: [
        .target(name: "SweepwellKit"),
        .testTarget(name: "SweepwellKitTests", dependencies: ["SweepwellKit"])
    ]
)
