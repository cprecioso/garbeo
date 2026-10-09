// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaseoKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PaseoKit", targets: ["PaseoKit"]),
    ],
    dependencies: [
        // libsodium: Curve25519 + XSalsa20-Poly1305 (NaCl box) for relay E2EE. CryptoKit has no XSalsa20.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "PaseoKit",
            dependencies: [.product(name: "Clibsodium", package: "swift-sodium")]
        ),
        .testTarget(
            name: "PaseoKitTests",
            dependencies: ["PaseoKit"],
            resources: [.copy("Resources")]
        ),
    ]
)
