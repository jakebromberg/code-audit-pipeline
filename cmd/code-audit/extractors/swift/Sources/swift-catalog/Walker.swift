//
//  Walker.swift
//  swift-catalog
//
//  Directory walker + skip rules + package-name resolution from path.
//

import Foundation

struct WalkedFile {
    let absolutePath: String
    let relativePath: String
    let package: String
    let generated: Bool
    let isTest: Bool
}

struct WalkOptions {
    let extensions: Set<String>
}

func walkRoot(root: String, options: WalkOptions) -> [WalkedFile] {
    let fm = FileManager.default
    // POSIX realpath() canonicalizes /tmp → /private/tmp on macOS so the
    // enumerator's URLs (which always come back canonicalized) and our
    // rootPath share the same form for the prefix-strip below. URL's
    // resolvingSymlinksInPath does NOT cross /tmp on macOS.
    let canonicalRoot: String = root.withCString { cstr in
        guard let r = realpath(cstr, nil) else { return root }
        defer { free(r) }
        return String(cString: r)
    }
    let rootURL = URL(fileURLWithPath: canonicalRoot)
    let rootPath = rootURL.path
    var results: [WalkedFile] = []

    guard let enumerator = fm.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    while let url = enumerator.nextObject() as? URL {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])

        if values?.isDirectory == true {
            let name = url.lastPathComponent
            if shouldSkipDirectory(name: name) {
                enumerator.skipDescendants()
            }
            continue
        }

        guard values?.isRegularFile == true else { continue }
        let ext = url.pathExtension.lowercased()
        guard options.extensions.contains(ext) else { continue }

        let absolutePath = url.path
        guard absolutePath.hasPrefix(rootPath + "/") else { continue }
        let relativePath = String(absolutePath.dropFirst(rootPath.count + 1))
        results.append(WalkedFile(
            absolutePath: absolutePath,
            relativePath: relativePath,
            package: resolvePackage(relativePath: relativePath),
            generated: isGenerated(relativePath: relativePath),
            isTest: isTestPath(relativePath: relativePath)
        ))
    }

    return results
}

private func shouldSkipDirectory(name: String) -> Bool {
    if name.hasPrefix(".") { return true }
    if ["node_modules", "build", "dist", "coverage", "DerivedData", "Pods", "scripts", "ci_scripts"].contains(name) { return true }
    return false
}

/// Universal test-path directory segments (docs/pipeline-contract.md
/// §"Test path patterns"), plus Swift's SwiftPM `Tests/` convention
/// (capital T). Matched per-segment, exact and case-sensitive — a
/// substring or case-insensitive match would swallow non-test directories
/// like `CoreTesting`.
private let testDirSegments: Set<String> = [
    "tests", "test", "__tests__", "__test__",
    "spec",
    "__mocks__",
    "__fixtures__", "fixtures",
    "e2e",
    "Tests",
]

/// Universal test-filename suffixes (docs/pipeline-contract.md
/// §"Test path patterns"), plus Swift's `*Tests.swift` convention.
private let testFileSuffixes: [String] = [
    ".test.swift", ".spec.swift",
    ".fixture.swift", ".fixtures.swift",
    ".mock.swift", ".mocks.swift",
    "Tests.swift",
]

/// True if `relativePath` matches the contract's normative test-path
/// pattern set: any path segment (directory, not basename) exactly
/// matches a known test-directory name, or the basename ends with a
/// known test-file suffix.
func isTestPath(relativePath: String) -> Bool {
    let parts = relativePath.split(separator: "/").map(String.init)
    guard let basename = parts.last else { return false }
    for segment in parts.dropLast() {
        if testDirSegments.contains(segment) { return true }
    }
    return testFileSuffixes.contains { basename.hasSuffix($0) }
}

/// Resolve which "package" a file belongs to from its path relative to root.
/// Convention for wxyc-ios-64-style layouts:
///   Shared/<Pkg>/...        → "<Pkg>"
///   WXYC/<Target>/...       → "app:<Target>"
///   Sources/<X>/...         → "<X>"   (when rooted inside a SwiftPM package)
///   <other top-level dir>/  → "<top-level dir>"
func resolvePackage(relativePath: String) -> String {
    let parts = relativePath.split(separator: "/").map(String.init)
    if parts.count >= 2 && parts[0] == "Shared" {
        return parts[1]
    }
    if parts.count >= 2 && parts[0] == "WXYC" {
        return "app:\(parts[1])"
    }
    if parts.count >= 2 && parts[0] == "Sources" {
        return parts[1]
    }
    return parts.first ?? "root"
}

private func isGenerated(relativePath: String) -> Bool {
    let lower = relativePath.lowercased()
    if lower.contains("/generated/") { return true }
    if lower.hasSuffix(".generated.swift") { return true }
    return false
}
