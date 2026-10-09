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
        // Pinned below 1.12: 1.12+ compiles a Metal shader (needs Xcode's optional Metal toolchain)
        // and 1.19+ adds a build-tool plugin that Xcode requires every user to trust.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.11.2")),
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
    ]
)
