// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Caching",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Caching", targets: ["Caching"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "Caching",
            dependencies: [
                .product(name: "Core", package: "Core"),
            ]
        ),
    ]
)
