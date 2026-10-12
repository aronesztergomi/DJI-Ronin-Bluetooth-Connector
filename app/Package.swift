// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RS3Studio",
    platforms: [.macOS(.v13)],
    targets: [
        // Thin C shim exposing the Rust staticlib to Swift.
        .systemLibrary(name: "RS3Kit", path: "Sources/RS3Kit"),
        .executableTarget(
            name: "RS3Studio",
            dependencies: ["RS3Kit"],
            path: "Sources/RS3Studio",
            linkerSettings: [
                .unsafeFlags([
                    "-L../target/release",
                    "-L../target/debug",
                    "-lrs3_ffi",
                ]),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
