// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexMonitorMinibar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexMonitorMinibar", targets: ["CodexMonitorMinibar"]),
        .executable(name: "CodexMonitorHookBridge", targets: ["CodexMonitorHookBridge"])
    ],
    targets: [
        .target(
            name: "CodexMonitorCore",
            path: "Sources/CodexMonitorCore"
        ),
        .executableTarget(
            name: "CodexMonitorMinibar",
            dependencies: ["CodexMonitorCore"],
            path: "Sources/CodexMonitorMinibar"
        ),
        .executableTarget(
            name: "CodexMonitorHookBridge",
            dependencies: ["CodexMonitorCore"],
            path: "Sources/CodexMonitorHookBridge"
        ),
        .executableTarget(
            name: "CodexMonitorCoreTestRunner",
            dependencies: ["CodexMonitorCore"],
            path: "Sources/CodexMonitorCoreTestRunner"
        )
    ],
    swiftLanguageModes: [.v5]
)
