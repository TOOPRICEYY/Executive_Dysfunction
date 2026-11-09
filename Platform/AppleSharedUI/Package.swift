// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HoldfastSharedInterface",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HoldfastSharedInterface", targets: ["HoldfastSharedInterface"]),
        .executable(name: "HoldfastSharedUIPreview", targets: ["HoldfastSharedUIPreview"])
    ],
    targets: [
        .target(name: "HoldfastSharedInterface"),
        .executableTarget(name: "HoldfastSharedUIPreview", dependencies: ["HoldfastSharedInterface"])
    ]
)
