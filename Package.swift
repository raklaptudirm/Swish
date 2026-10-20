// swift-tools-version: 6.0
import PackageDescription

// The shell. It is a client of the interpreter (github.com/raklaptudirm/Swiit, checked out beside this one).
let package = Package(
    name: "Swish",
    platforms: [.macOS(.v14)],
    products: [
        // The command keeps its lowercase name, as Unix programs do.
        .executable(name: "swish", targets: ["Swish"]),
    ],
    dependencies: [
        .package(path: "../Swiit"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(name: "Swish", dependencies: ["SwishShell"]),
        // The shell: commands, pipelines, jobs, the line editor and the process
        // it runs in, built on the interpreter.
        .target(
            name: "SwishShell",
            dependencies: [
                .product(name: "Swiit", package: "Swiit"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            // The shell's prelude is Swift source that is read, not compiled: it is embedded in the target.
            resources: [.embedInCode("Resources/Prelude.swift")]
        ),
        .testTarget(name: "SwishShellTests", dependencies: [
            "SwishShell", .product(name: "Swiit", package: "Swiit"),
        ], exclude: ["Goldens", "programs.txt"]),
    ]
)
