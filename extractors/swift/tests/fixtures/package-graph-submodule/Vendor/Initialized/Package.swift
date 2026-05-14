// swift-tools-version: 6.0
//
// A submodule that IS initialized. Declared in ../../.gitmodules but the
// directory has a real Package.swift, so the S1 check should NOT warn about
// it. Pair this with Shared/Wallpaper (declared in .gitmodules but missing
// from disk) to exercise both the "warning fires" and "warning suppressed"
// branches in the same fixture.
//
import PackageDescription

let package = Package(
    name: "Initialized",
    targets: [
        .target(name: "Initialized"),
    ]
)
