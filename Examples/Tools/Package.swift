// swift-tools-version: 6.0
import PackageDescription

// A Swish plugin: `import Tools from "Examples/Tools"`.
let package = Package(
    name: "Tools",
    platforms: [.macOS(.v14)],
    products: [
        // Plugins are dynamic libraries named after their module.
        .library(name: "Tools", type: .dynamic, targets: ["Tools"]),
    ],
    dependencies: [
        .package(path: "../../Packages/SwishKit"),
    ],
    targets: [
        .target(name: "Tools", dependencies: [.product(name: "SwishKit", package: "SwishKit")]),
    ]
)
