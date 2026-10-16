// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Speak",
    platforms: [.macOS("26.0")],
    targets: [
        // All state and decisions. Reaches the system only through protocols, so it stays testable.
        .target(name: "SpeakCore"),
        // AppKit/SwiftUI shell plus the real adapters.
        .executableTarget(name: "Speak", dependencies: ["SpeakCore"]),
        .testTarget(name: "SpeakCoreTests", dependencies: ["SpeakCore"]),
    ]
)
