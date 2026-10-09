// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Swish",
    platforms: [.macOS(.v14)],
    products: [
        // The commands keep their lowercase names, as Unix programs do.
        .executable(name: "swish", targets: ["Swish"]),
        .executable(name: "swish-bridge", targets: ["SwishBridge"]),
    ],
    dependencies: [
        // A separate package so the host links SwishKit as a dylib (products of
        // the same package would be linked statically into the executable).
        .package(path: "Packages/SwishKit"),
        // FilePath, until the standard library's (SE-0529) ships; swift-system's
        // then becomes a typealias for it, keeping the members added here.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(name: "Swish", dependencies: ["SwishShell"]),
        // Reads Swift's symbol graphs and writes the glue that bridges them
        // (`run bridge`); not part of the shell.
        .executableTarget(name: "SwishBridge"),
        // The shell's own functions, written in Swift: `swish-bridge` reads
        // their declarations (`run bridge`) and SwishCore calls them.
        .target(
            name: "SwishStandardLibrary",
            dependencies: [
                .product(name: "SwishKit", package: "SwishKit"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .target(
            name: "SwishCore",
            dependencies: [
                "SwishStandardLibrary",
                .product(name: "SwishKit", package: "SwishKit"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        // The shell: commands, pipelines, jobs, the line editor and the process
        // it runs in, built on the core's interpreter.
        .target(
            name: "SwishShell",
            dependencies: [
                "SwishCore",
                .product(name: "SwishKit", package: "SwishKit"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        // boundaries.txt is data the boundary test reads from the source tree.
        .testTarget(name: "SwishCoreTests", dependencies: ["SwishCore"], exclude: ["boundaries.txt"]),
        .testTarget(name: "SwishShellTests", dependencies: ["SwishShell", "SwishCore"]),
    ]
)
