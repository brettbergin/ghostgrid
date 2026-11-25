// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GhostGrid",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Prebuilt libghostty (GhosttyKit.xcframework) plus AppKit views.
        // Pinned exactly: the embedding API is not stable upstream.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "2.2.2026112401"),
    ],
    targets: [
        .executableTarget(
            name: "GhostGrid",
            dependencies: [
                "GhostGridCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources/GhostGrid"
        ),
        .testTarget(
            name: "GhostGridTests",
            dependencies: ["GhostGridCore"],
            path: "Tests/GhostGridTests"
        ),
        // Layout math and config handling, kept free of AppKit so it is unit-testable.
        .target(
            name: "GhostGridCore",
            path: "Sources/GhostGridCore"
        ),
    ],
    swiftLanguageModes: [.v6]
)
