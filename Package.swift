// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacScope",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacScopeCore", targets: ["MacScopeCore"]),
        .library(name: "MacScopeMCPBridge", targets: ["MacScopeMCPBridge"]),
        .executable(name: "MacScope", targets: ["MacScope"]),
        .executable(name: "MacScopeHelper", targets: ["MacScopeHelper"]),
        .executable(name: "MacScopeMCPServer", targets: ["MacScopeMCPServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        .target(
            name: "MacScopeCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "MacScope",
            dependencies: ["MacScopeCore", "MacScopeMCPBridge"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Charts"),
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "MacScopeHelper",
            dependencies: ["MacScopeCore"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "MacScopeMCPBridge",
            dependencies: ["MacScopeCore"]
        ),
        .executableTarget(
            name: "MacScopeMCPServer",
            dependencies: [
                "MacScopeMCPBridge",
                .product(name: "MCP", package: "swift-sdk")
            ],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "MacScopeCoreTests", dependencies: ["MacScopeCore"]),
        .testTarget(
            name: "MacScopeTests",
            dependencies: ["MacScope"],
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
        .testTarget(name: "MacScopeMCPBridgeTests", dependencies: ["MacScopeMCPBridge", "MacScopeCore"])
    ],
    swiftLanguageModes: [.v6]
)
