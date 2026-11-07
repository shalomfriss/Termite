// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalTabs",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TerminalTabs", targets: ["TerminalTabs"]),
    ],
    targets: [
        .target(
            name: "GhosttyBridge",
            path: "Sources/GhosttyBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "TerminalTabs",
            dependencies: ["GhosttyBridge"],
            path: "Sources/TerminalTabs"
        ),
        .testTarget(
            name: "TerminalTabsTests",
            dependencies: ["TerminalTabs"],
            path: "Tests/TerminalTabsTests"
        ),
    ]
)
