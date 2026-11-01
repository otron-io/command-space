// swift-tools-version:5.10
// Command Space: a Spotlight replacement with an AI agent built in.
// `swift build` compiles it, `scripts/build-app.sh` wraps it into Command Space.app,
// `swift test` runs the parsing and whistle-matching tests.
import PackageDescription

let package = Package(
    name: "CommandSpace",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/Defaults", exact: "9.0.6"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", exact: "1.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "CommandSpace",
            dependencies: [
                "Defaults",
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                "Sparkle",
            ],
            path: "Sources/CommandSpace",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "RequestParsingTests", dependencies: ["CommandSpace"], path: "Tests/RequestParsingTests"),
    ]
)
