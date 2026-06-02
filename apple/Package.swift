// swift-tools-version:6.0
// ChatKit — shared multiplatform core for the Claude Code UI native client.
// V1 ships a macOS executable via SPM. iOS app target ships via a separate
// Xcode project later that imports ChatKit as a local SPM package.
import PackageDescription

let package = Package(
    name: "ChatKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),   // SwiftData requires watchOS 10+; ChatKit core is platform-agnostic
    ],
    products: [
        .library(name: "ChatKit", targets: ["ChatKit"]),
        .library(name: "ChatKitUI", targets: ["ChatKitUI"]),
        .executable(name: "ClaudeChat", targets: ["ClaudeChat"]),
    ],
    targets: [
        // iOS-safe core: Network / Storage / IM / DTOs / Events / Protocols.
        .target(
            name: "ChatKit",
            path: "Sources/ChatKit",
            exclude: [
                "Network/README.md",
                "Storage/README.md",
            ]
        ),
        // macOS UI layer (AppKit). Depends on the core; not linked by the iOS app.
        .target(
            name: "ChatKitUI",
            dependencies: ["ChatKit"],
            path: "Sources/ChatKitUI",
            exclude: [
                "README.md",
            ]
        ),
        .executableTarget(
            name: "ClaudeChat",
            dependencies: ["ChatKit", "ChatKitUI"],
            path: "Sources/ClaudeChat",
            // AppIcon.png is read directly by scripts/make-macos-app.sh to build
            // the .icns; we deliberately do NOT declare it as a SwiftPM resource
            // (a nested .bundle would break the packaged app's code signature
            // and prevent macOS notification registration).
            exclude: ["AppIcon.png"]
        ),
        .testTarget(
            name: "ChatKitTests",
            dependencies: ["ChatKit", "ChatKitUI"],
            path: "Tests/ChatKitTests"
        ),
    ]
)
