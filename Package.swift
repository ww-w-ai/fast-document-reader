// swift-tools-version:6.0
import PackageDescription
import Foundation

// The Rust engine is the document reader. It was opt-in while it was being proven against the
// shipped Swift reader; S9 ended that, so every build links it and the Swift readers keep their
// place only as the differential oracle the tests compare against (`Render/Office/DocxReader.swift`
// et al. — 44 test files, zero production callers).
//
//   ./Scripts/build-engine.sh   # produces Vendor/FastdocEngine.xcframework; make-app.sh runs it
//
// The xcframework is NOT committed (66 MB, and this repo is public). `RhwpNative` is committed for
// a reason that does not apply here — its source fork lives outside this repo and there is no
// script to rebuild it from a clean checkout, while `build-engine.sh` is right there.
//
// A `.binaryTarget` naming a path that does not exist fails the manifest OUTRIGHT, which reads as
// an unrelated SwiftPM error rather than "you have not built the engine yet". So the path is
// checked here and the manifest says what to do about it.
let enginePath = "Vendor/FastdocEngine.xcframework"
if !FileManager.default.fileExists(atPath: enginePath) {
    print("""
        error: \(enginePath) is missing. Build it first:
            ./Scripts/build-engine.sh
        (`Scripts/make-app.sh` does this for you.)
        """)
}

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

targets.append(.binaryTarget(name: "FastdocEngine", path: enginePath))
appDependencies.append("FastdocEngine")

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
