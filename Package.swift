// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Laur",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "LaurCore", targets: ["LaurCore"]),
        .library(name: "LaurRuntime", targets: ["LaurRuntime"]),
        .executable(name: "laur", targets: ["laur"]),
    ],
    targets: [
        // Lexer, AST, parser and checker. No UI dependencies, so every tool can share it.
        .target(name: "LaurCore"),

        // Turns a parsed component into live SwiftUI views. Shared by the previewer today
        // and the iOS Simulator previewer later.
        .target(name: "LaurRuntime", dependencies: ["LaurCore"]),

        // The `laur` command: `laur preview`, `laur check`, `laur fmt`.
        .executableTarget(name: "laur", dependencies: ["LaurCore", "LaurRuntime"]),

        .testTarget(name: "LaurCoreTests", dependencies: ["LaurCore"]),
        .testTarget(name: "LaurRuntimeTests", dependencies: ["LaurCore", "LaurRuntime"]),
    ]
)
