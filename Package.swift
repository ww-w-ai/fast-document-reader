// swift-tools-version:6.0
import PackageDescription
import Foundation

// The ported Rust engine is OPT-IN, and the default build stays exactly what it was: pure Swift,
// no Rust toolchain, no extra binary. It is still being proven against the shipped reader, so the
// two readers coexist and either can be built — which is also the only way to compare them.
//
//   ./Scripts/build-engine.sh                 # produces Vendor/FastdocEngine.xcframework
//   FMD_RUST_ENGINE=1 ./Scripts/make-app.sh   # links it, and takes its path at runtime
//
// Read at manifest-evaluation time on purpose: a `.binaryTarget` naming a path that does not exist
// fails the manifest outright, so the target has to be absent unless the build asked for it.
let rustEngine = ProcessInfo.processInfo.environment["FMD_RUST_ENGINE"] == "1"

var targets: [Target] = [
    // rhwp (Rust, MIT) HWP/HWPX parser, prebuilt as a static-library xcframework.
    // Source fork lives outside this repo; rebuild via docs/BUILD-RHWP.md. Statically
    // linked → absorbed into the executable (no dylib to embed/sign). arm64 only.
    .binaryTarget(name: "RhwpNative", path: "Vendor/RhwpNative.xcframework"),
]

var appDependencies: [Target.Dependency] = [
    .product(name: "Markdown", package: "swift-markdown"),
    "RhwpNative",
]

var swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

if rustEngine {
    targets.append(.binaryTarget(name: "FastdocEngine", path: "Vendor/FastdocEngine.xcframework"))
    appDependencies.append("FastdocEngine")
    swiftSettings.append(.define("FMD_RUST_ENGINE"))
}

targets.append(
    .executableTarget(
        name: "FastDocReader",
        dependencies: appDependencies,
        path: "Sources/FastDocReader",
        // AppKit app is not built around actors; use Swift 5 language mode to avoid
        // spurious strict-concurrency isolation errors against @MainActor AppKit types.
        swiftSettings: swiftSettings
    )
)
targets.append(
    .testTarget(
        name: "FastDocReaderTests",
        dependencies: ["FastDocReader"],
        path: "Tests/FastDocReaderTests",
        swiftSettings: swiftSettings
    )
)

let package = Package(
    name: "FastDocReader",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
    ],
    targets: targets
)
