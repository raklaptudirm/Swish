// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Swish",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swish", targets: ["swish"]),
    ],
    dependencies: [
        // A separate package so the host links SwishKit as a dylib (products of
        // the same package would be linked statically into the executable).
        .package(path: "Packages/SwishKit"),
    ],
    targets: [
        .executableTarget(name: "swish", dependencies: ["SwishCore"]),
        // Reads Swift's symbol graphs and writes the glue that bridges them
        // (scripts/generate-bridge.swish); not part of the shell.
        .executableTarget(name: "swish-bridge"),
        .target(
            name: "SwishCore",
            dependencies: [.product(name: "SwishKit", package: "SwishKit")]
        ),
        .testTarget(name: "SwishCoreTests", dependencies: ["SwishCore"]),
    ]
)
