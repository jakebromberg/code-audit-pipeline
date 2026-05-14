// swift-tools-version: 6.0
//
// Fixture for V7 §6.5 follow-up #54 S2 — cycle detection.
// Alpha depends on Beta; Beta depends on Alpha (see ../Beta/Package.swift).
// Swift's compiler would reject this in practice, but the substrate is
// language-source-agnostic and must detect + warn rather than mishandle.
//
import PackageDescription

let package = Package(
    name: "Alpha",
    products: [
        .library(name: "Alpha", targets: ["Alpha"]),
    ],
    dependencies: [
        .package(path: "../Beta"),
    ],
    targets: [
        .target(name: "Alpha", dependencies: [
            .product(name: "Beta", package: "Beta"),
        ]),
    ]
)
