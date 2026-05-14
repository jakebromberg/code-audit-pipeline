// swift-tools-version: 6.0
//
// Fixture for V7 §6.5 follow-up #54 S3 — external `.package(url:)` deps.
// The manifest depends on a URL-declared external package; the target
// imports it via `.product(name:, package:)`. The extractor must emit
// a `kind: "external"` node for the URL dep and route both the package-
// level reachability edge and the target-level product edge to it.
//
import PackageDescription

let package = Package(
    name: "Local",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Local", targets: ["Local"]),
    ],
    dependencies: [
        // External URL dep — expected: emits `kind: "external"` node
        // named `swift-syntax` with `path == "https://github.com/swiftlang/swift-syntax.git"`.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        // External URL dep WITH an explicit name override — expected:
        // node name is `CustomNamed`, not the URL-derived `bar-package`.
        .package(url: "https://github.com/example/bar-package", name: "CustomNamed", from: "1.0.0"),
    ],
    targets: [
        .target(name: "Local", dependencies: [
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "BarLib", package: "CustomNamed"),
        ]),
    ]
)
