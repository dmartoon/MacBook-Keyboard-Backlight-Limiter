// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyboardBacklightLimiter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "KeyboardBacklightLimiter",
            path: "Sources/KeyboardBacklightLimiter"
        )
    ]
)
