// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaseoKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PaseoKit", targets: ["PaseoKit"]),
        .library(name: "PaseoTerminal", targets: ["PaseoTerminal"]),
    ],
    dependencies: [
        // libsodium: Curve25519 + XSalsa20-Poly1305 (NaCl box) for relay E2EE. CryptoKit has no XSalsa20.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.11.0"),
        // 1.99 is the 2.0 preview; pinned exactly until 2.0 ships. Its build-tool plugin must be trusted once
        // in Xcode ("Trust & Enable"), or pass `-skipPackagePluginValidation` to xcodebuild.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.0"),
    ],
    targets: [
        .target(
            name: "PaseoKit",
            dependencies: [.product(name: "Clibsodium", package: "swift-sodium")]
        ),
        .target(name: "PaseoTerminal", dependencies: ["PaseoKit", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(
            name: "PaseoKitTests",
            dependencies: ["PaseoKit"],
            resources: [.copy("Resources"), .copy("Fixtures")]
        ),
        .testTarget(name: "PaseoTerminalTests", dependencies: ["PaseoTerminal", .product(name: "SwiftTerm", package: "SwiftTerm")]),
    ]
)
