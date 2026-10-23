// swift-tools-version: 6.0
// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import PackageDescription

let package = Package(
    name: "Barc",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Barc", targets: ["Barc"])
    ],
    targets: [
        .executableTarget(name: "Barc", path: "Sources/Barc"),
        .testTarget(name: "BarcTests", dependencies: ["Barc"], path: "Tests/BarcTests")
    ]
)
