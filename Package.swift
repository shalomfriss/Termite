// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Air",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Air", targets: ["Air"]),
    ],
    targets: [
        .target(
            name: "GhosttyBridge",
            path: "Sources/GhosttyBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Air",
            dependencies: ["GhosttyBridge"],
            path: "Sources/TerminalTabs",
            resources: [.copy("Resources/ShellIntegration")],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "AirTests",
            dependencies: ["Air"],
            path: "Tests/TerminalTabsTests"
        ),
    ]
)
