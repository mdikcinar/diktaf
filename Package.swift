// swift-tools-version: 6.0
import PackageDescription

// Six targets, and the arrows between them only ever point one way: the app
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
    dependencies: [
        // WhisperKit, for the second recogniser. The only dependency this
        // package has, and it earns it: Whisper large-v3-turbo as Core ML,
        // running on this Mac, is the one thing that hears "Firebase CLI" in a
        // Turkish sentence. It brings swift-argument-parser and nothing else.
        //
        // The old `argmaxinc/WhisperKit` URL now redirects here, and the
        // `WhisperKit` product is the same library under a wider umbrella.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
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

        // Cleanup by a model Ollama serves on this machine, over its local HTTP
        // API. Beside the CLI rather than instead of it: a warm 7B model answers
        // in under a second where the CLI takes several, but it is one more
        // thing to install.
        .target(name: "DiktafOllama", dependencies: ["DiktafCore"]),

        // The second recogniser: Whisper as Core ML, weights fetched on demand.
        // Its own target rather than part of DiktafMac so that the choice of
        // engine costs nothing to the machine that never makes it, and so the
        // dependency stops at this boundary.
        .target(
            name: "DiktafWhisper",
            dependencies: [
                "DiktafCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),

        // The composition root: SwiftUI, the menu bar, and the one place that
        // decides which adapter fills which port.
        .executableTarget(
            name: "Diktaf",
            dependencies: [
                "DiktafCore", "DiktafMac", "DiktafClaude", "DiktafOllama", "DiktafWhisper",
            ]
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
        // Against a stub transport: what is sent, and what each answer the
        // server can give turns into. No server is needed to run them.
        .testTarget(
            name: "DiktafOllamaTests",
            dependencies: ["DiktafOllama", "DiktafCore"]
        ),
        // The catalogue only: what a variant is called, where its weights land,
        // and whether they are there. Transcribing needs a microphone and a
        // gigabyte of weights, so it is not tested here.
        .testTarget(
            name: "DiktafWhisperTests",
            dependencies: ["DiktafWhisper", "DiktafCore"]
        ),
    ]
)
