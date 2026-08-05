// swift-tools-version: 6.0
import PackageDescription

// Four targets, and the arrows between them only ever point one way: the app
// knows everything, the adapters know the domain, and the domain knows nobody.
// That is the whole of the Windows story — DiktafCore imports Foundation and
// nothing else, so a second platform is a second adapter target, not a rewrite.
let package = Package(
    name: "diktaf",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "diktaf", targets: ["Diktaf"]),
        .library(name: "DiktafCore", targets: ["DiktafCore"]),
    ],
    targets: [
        // The domain, and the ports it asks the world for. No AppKit, no
        // Speech, no Process: anything that touches the machine is a protocol
        // here and an implementation elsewhere.
        .target(name: "DiktafCore"),

        // macOS adapters: the system transcriber, the pasteboard, the key
        // press, the global hotkey, the permission prompts.
        .target(name: "DiktafMac", dependencies: ["DiktafCore"]),

        // The local Claude agent, reached as a subprocess. Foundation only, so
        // it is one of the pieces a Windows build keeps.
        .target(name: "DiktafClaude", dependencies: ["DiktafCore"]),

        // The composition root: SwiftUI, the menu bar, and the one place that
        // decides which adapter fills which port.
        .executableTarget(
            name: "Diktaf",
            dependencies: ["DiktafCore", "DiktafMac", "DiktafClaude"]
        ),

        .testTarget(name: "DiktafCoreTests", dependencies: ["DiktafCore"]),
        // Small on purpose: what is worth testing here is not the adapters —
        // they need a microphone and a desktop session — but the assumptions
        // made about what the frameworks mean.
        .testTarget(
            name: "DiktafMacTests",
            dependencies: ["DiktafMac", "DiktafCore"]
        ),
        .testTarget(
            name: "DiktafClaudeTests",
            dependencies: ["DiktafClaude", "DiktafCore"]
        ),
    ]
)
