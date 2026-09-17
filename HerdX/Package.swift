// swift-tools-version: 6.0
import PackageDescription

// The Rust staticlib is built by `just build-core` (see the repo justfile) into
// ../target/<profile>/libherdr_core.a.
let coreSearchPath = "../target/debug"

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
