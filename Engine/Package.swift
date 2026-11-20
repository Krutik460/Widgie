// swift-tools-version: 6.2
import PackageDescription

// Public products: WidgetEngine, WidgetBuilder, WidgetHosting, and render-tool. Spec, Rows, and Sandbox are
// package-internal: they declare `package`, never `public`, so code outside this package links them only
// through the public products and cannot call into them. `scripts/check` enforces that and each target's
// imports against docs/engine/MODULES.md.
let package = Package(
    name: "WidgetEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "WidgetEngine", targets: ["WidgetEngine"]),
        .library(name: "WidgetBuilder", targets: ["WidgetBuilder"]),
        .library(name: "WidgetHosting", targets: ["WidgetHosting"]),
        .executable(name: "render-tool", targets: ["RenderTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0")
    ],
    targets: [
        .target(name: "Spec"),
        .target(name: "Rows", dependencies: ["Spec", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "Sandbox"),
        .target(name: "WidgetEngine", dependencies: ["Spec", "Rows", "Sandbox"]),
        .target(name: "WidgetBuilder", dependencies: ["WidgetEngine", "Spec", "Rows", "Sandbox"]),
        .target(name: "WidgetHosting", dependencies: ["WidgetEngine"]),
        .executableTarget(name: "RenderTool", dependencies: ["WidgetEngine", "WidgetBuilder"]),
        .testTarget(name: "SpecTests", dependencies: ["Spec"]),
        .testTarget(name: "RowsTests", dependencies: ["Rows", "Spec"]),
        .testTarget(name: "LookTests", dependencies: ["Sandbox", "WidgetEngine", "Rows", "Spec"]),
        .testTarget(
            name: "EngineTests",
            dependencies: ["WidgetEngine", "WidgetBuilder", "WidgetHosting", "RenderTool", "Rows", "Sandbox", "Spec"]),
    ]
)
