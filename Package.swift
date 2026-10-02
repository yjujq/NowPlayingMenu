// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NowPlayingMenu",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NowPlayingMenu", targets: ["NowPlayingMenu"]),
        // Not linked into the app: loaded by /usr/bin/perl to fetch artwork.
        .library(name: "ArtworkHelper", type: .dynamic, targets: ["ArtworkHelper"])
    ],
    targets: [
        .target(
            name: "MediaRemoteBridge",
            path: "Sources/MediaRemoteBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .target(
            name: "ArtworkHelper",
            path: "Sources/ArtworkHelper",
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
