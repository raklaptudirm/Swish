// swift-tools-version: 6.0
import PackageDescription

// The shell. It is a client of the interpreter (Packages/Swiit).
let package = Package(
    name: "Swish",
    platforms: [.macOS(.v14)],
    products: [
        // The command keeps its lowercase name, as Unix programs do.
        .executable(name: "swish", targets: ["Swish"]),
    ],
    dependencies: [
        .package(path: "Packages/Swiit"),
        // A separate package so the host links SwishKit as a dylib (products of
        // the same package would be linked statically into the executable).
        .package(path: "Packages/SwishKit"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(name: "Swish", dependencies: ["SwishShell"]),
        // The shell's functions that reach the process, the files and the
        // session: `ls`, `ps`, `pwd`, `with(env:)`, `readLine`, `history`.
        .target(
            name: "SwishShellLibrary",
            dependencies: [
                .product(name: "SwishStandardLibrary", package: "Swiit"),
                .product(name: "SwishKit", package: "SwishKit"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/SwishShell/Library"
        ),
        // The shell: commands, pipelines, jobs, the line editor and the process
        // it runs in, built on the interpreter.
        .target(
            name: "SwishShell",
            dependencies: [
                .product(name: "Swiit", package: "Swiit"),
                "SwishShellLibrary",
                .product(name: "SwishKit", package: "SwishKit"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            exclude: ["Library"]
        ),
        .testTarget(name: "SwishShellTests", dependencies: [
            "SwishShell", .product(name: "Swiit", package: "Swiit"), .product(name: "SwiitSwiftSyntax", package: "Swiit"),
        ]),
    ]
)
