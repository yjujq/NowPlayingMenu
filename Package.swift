// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NowPlayingMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NowPlayingMenu", targets: ["NowPlayingMenu"])],
    targets: [
        .target(
            name: "MediaRemoteBridge",
            path: "Sources/MediaRemoteBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "NowPlayingMenu",
            dependencies: ["MediaRemoteBridge"],
            path: "Sources/NowPlayingMenu",
            resources: [.process("Resources")]
        )
    ]
)
