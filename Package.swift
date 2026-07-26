// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FastDocReader",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
    ],
    targets: [
        // rhwp (Rust, MIT) HWP/HWPX parser, prebuilt as a static-library xcframework.
        // Source fork lives outside this repo; rebuild via docs/BUILD-RHWP.md. Statically
        // linked → absorbed into the executable (no dylib to embed/sign). arm64 only.
        .binaryTarget(name: "RhwpNative", path: "Vendor/RhwpNative.xcframework"),
        .executableTarget(
            name: "FastDocReader",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                "RhwpNative",
            ],
            path: "Sources/FastDocReader",
            // AppKit app is not built around actors; use Swift 5 language mode to avoid
            // spurious strict-concurrency isolation errors against @MainActor AppKit types.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FastDocReaderTests",
            dependencies: ["FastDocReader"],
            path: "Tests/FastDocReaderTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
