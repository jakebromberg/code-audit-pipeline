// swift-tools-version: 6.0
//
// swift-catalog: SwiftSyntax-based extractor for the code-audit-pipeline substrate.
// Emits type-catalog and function-catalog JSON conforming to docs/pipeline-contract.md.

import PackageDescription

let package = Package(
    name: "swift-catalog",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "swift-catalog",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources/swift-catalog"
        ),
    ]
)
