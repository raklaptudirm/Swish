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
        .target(
            name: "SwishCore",
            dependencies: [
                "CShim",
                .product(name: "SwishKit", package: "SwishKit"),
            ]
        ),
        .target(name: "CShim"),
        .testTarget(name: "SwishCoreTests", dependencies: ["SwishCore"]),
    ]
)
