// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "claude-switch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "claude-switch",
            path: "Sources/claude-switch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
