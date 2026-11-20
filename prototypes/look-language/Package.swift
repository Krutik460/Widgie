// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "look-language",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "render", path: "Sources/render")
    ]
)
