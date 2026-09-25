// swift-tools-version:5.9
import PackageDescription

// RememoruCore is Foundation-only so its logic builds and tests on Linux
// too; everything that touches macOS frameworks lives in RememoruMac and
// the app target, behind `#if os(macOS)`.
let package = Package(
    name: "Rememoru",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Rememoru", targets: ["Rememoru"]),
    ],
    targets: [
        .target(name: "RememoruCore"),
        .target(name: "RememoruMac", dependencies: ["RememoruCore"]),
        .executableTarget(
            name: "Rememoru",
            dependencies: ["RememoruCore", "RememoruMac"]
        ),
        .testTarget(
            name: "RememoruCoreTests",
            dependencies: ["RememoruCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
