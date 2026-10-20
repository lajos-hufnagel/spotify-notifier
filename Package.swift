// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpotifyNotifier",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SpotifyNotifier",
            path: "Sources/SpotifyNotifier"
        )
    ]
)
