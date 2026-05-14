// swift-tools-version: 6.0
//
// Cycle counterpart of ../Alpha/Package.swift. Together they form a 2-cycle:
// Packages/Alpha → Packages/Beta and Packages/Beta → Packages/Alpha.
//
import PackageDescription

let package = Package(
    name: "Beta",
    products: [
        .library(name: "Beta", targets: ["Beta"]),
    ],
    dependencies: [
        .package(path: "../Alpha"),
    ],
    targets: [
        .target(name: "Beta", dependencies: [
            .product(name: "Alpha", package: "Alpha"),
        ]),
    ]
)
