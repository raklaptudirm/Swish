// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwishKit",
    platforms: [.macOS(.v14)],
    products: [
        // Dynamic so the shell and every compiled plugin share one copy of
        // SwishKit's types; a static copy per binary would make them distinct.
        .library(name: "SwishKit", type: .dynamic, targets: ["SwishKit"]),
    ],
    targets: [
        .target(
            name: "SwishKit",
            swiftSettings: [
                // Keeps the ABI resilient, so SwishKit can grow without
                // breaking plugins that were built against an older version.
                .unsafeFlags(["-enable-library-evolution"]),
            ]
        ),
        .testTarget(name: "SwishKitTests", dependencies: ["SwishKit"]),
    ]
)
