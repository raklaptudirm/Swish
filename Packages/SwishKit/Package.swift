// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SwishKit",
    platforms: [.macOS(.v14)],
    products: [
        // Dynamic so the shell and every compiled plugin share one copy of
        // SwishKit's types; a static copy per binary would make them distinct.
        .library(name: "SwishKit", type: .dynamic, targets: ["SwishKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        .target(
            name: "SwishKit",
            dependencies: ["SwishKitMacros"],
            swiftSettings: [
                // Keeps the ABI resilient, so SwishKit can grow without
                // breaking plugins that were built against an older version.
                .unsafeFlags(["-enable-library-evolution"]),
            ]
        ),
        // `@SwishExport` and `#swishPlugin`, run by the compiler when a
        // plugin is built.
        .macro(
            name: "SwishKitMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .testTarget(name: "SwishKitTests", dependencies: ["SwishKit"]),
    ]
)
