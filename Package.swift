// swift-tools-version: 6.2
import Foundation
import PackageDescription

// libghostty: the published libghostty-spm binary, unless a local build with
// custom shader support exists (Scripts/build-libghostty.sh writes it to
// Vendor/libghostty-spm, which is Git-ignored). Same package, same version.
let localLibghostty = "Vendor/libghostty-spm"
let useLocalLibghostty = FileManager.default.fileExists(
    atPath: "\(Context.packageDirectory)/\(localLibghostty)/BinaryTarget/GhosttyKit.xcframework"
)

// The core module and its tests are plain Swift and also build on Linux,
// where CI runs them in a container (.berg-runner/ci.yaml). The app itself
// needs AppKit and the libghostty xcframework, so it exists only on macOS.
let coreTargets: [Target] = [
    // Layout math and config handling, kept free of AppKit so it is unit-testable.
    .target(
        name: "GhostGridCore",
        path: "Sources/GhostGridCore"
    ),
    .testTarget(
        name: "GhostGridTests",
        dependencies: ["GhostGridCore"],
        path: "Tests/GhostGridTests"
    ),
]

#if os(macOS)
    let appDependencies: [Package.Dependency] = [
        // Prebuilt libghostty (GhosttyKit.xcframework) plus AppKit views.
        // Pinned exactly: the embedding API is not stable upstream.
        // build-libghostty.sh reads this version for the local build.
        useLocalLibghostty
            ? .package(path: localLibghostty)
            : .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "2.2.2026112401"),
    ]
    let appTargets: [Target] = [
        .executableTarget(
            name: "GhostGrid",
            dependencies: [
                "GhostGridCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources/GhostGrid",
            // Shown in Settings: which libghostty this build links.
            swiftSettings: useLocalLibghostty ? [.define("GHOSTGRID_LOCAL_LIBGHOSTTY")] : []
        ),
    ]
#else
    let appDependencies: [Package.Dependency] = []
    let appTargets: [Target] = []
#endif

let package = Package(
    name: "GhostGrid",
    platforms: [.macOS(.v14)],
    dependencies: appDependencies,
    targets: appTargets + coreTargets,
    swiftLanguageModes: [.v6]
)
