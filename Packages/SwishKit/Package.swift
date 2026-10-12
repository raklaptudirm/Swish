// swift-tools-version: 6.0
import PackageDescription

// SwiitKit's old name, for plugins written against SwishKit: a module of that
// name that brings in SwiitKit, linked as SwiitKit's one shared copy.
let package = Package(
    name: "SwishKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwishKit", targets: ["SwishKit"]),
    ],
    dependencies: [
        .package(path: "../../../Swiit/SwiitKit"),
    ],
    targets: [
        .target(name: "SwishKit", dependencies: [.product(name: "SwiitKit", package: "SwiitKit")]),
        .testTarget(name: "SwishKitTests", dependencies: ["SwishKit"]),
    ]
)
