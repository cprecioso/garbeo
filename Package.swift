// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaseoKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PaseoKit", targets: ["PaseoKit"]),
    ],
    targets: [
        .target(name: "PaseoKit"),
        .testTarget(name: "PaseoKitTests", dependencies: ["PaseoKit"]),
    ]
)
