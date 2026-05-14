// swift-tools-version: 6.0
//
// Root package for V7 §6.5 follow-up #54 S1 fixture. Keeps the extractor's
// "no Package.swift found" non-zero exit path from firing while the .gitmodules
// check runs against this directory tree. The S1 behavior under test is the
// warning about Shared/Wallpaper (declared in .gitmodules but no directory
// exists for it) — Vendor/Initialized has its own Package.swift so the
// initialized-submodule case is also covered in the same fixture.
//
import PackageDescription

let package = Package(
    name: "Host",
    targets: [
        .target(name: "Host"),
    ]
)
