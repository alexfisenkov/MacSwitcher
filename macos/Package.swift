// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RuSwitcher",
            path: "Sources/RuSwitcher",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "RuSwitcherTests",
            dependencies: ["RuSwitcher"],
            path: "Tests/RuSwitcherTests"
        )
    ]
)
