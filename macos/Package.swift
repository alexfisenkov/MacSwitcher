// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuSwitcher",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "RuSwitcher",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
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
