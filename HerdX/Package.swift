// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Where libherdr_core.a lives. SwiftPM has no notion of the Rust build, so the
// directory is passed in rather than guessed: scripts/bundle.sh sets it to the
// profile it just built (and to a lipo'd universal staticlib for releases).
// The default keeps a bare `swift build` working for day-to-day debug work.
let coreSearchPath = ProcessInfo.processInfo.environment["HERDX_CORE_LIB_DIR"]
    ?? "../target/debug"

let package = Package(
    name: "HerdX",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CHerdrCore"),
        .executableTarget(
            name: "HerdX",
            dependencies: ["CHerdrCore"],
            linkerSettings: [
                .unsafeFlags(["-L\(coreSearchPath)"]),
                .linkedLibrary("herdr_core"),
            ]
        ),
    ]
)
