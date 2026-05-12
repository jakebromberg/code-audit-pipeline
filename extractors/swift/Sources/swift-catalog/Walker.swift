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
}

struct WalkOptions {
    let extensions: Set<String>
    let includeTests: Bool
}

func walkRoot(root: String, options: WalkOptions) -> [WalkedFile] {
    let fm = FileManager.default
    let rootURL = URL(fileURLWithPath: root).standardizedFileURL
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
            if shouldSkipDirectory(name: name, includeTests: options.includeTests) {
                enumerator.skipDescendants()
            }
            continue
        }

        guard values?.isRegularFile == true else { continue }
        let ext = url.pathExtension.lowercased()
        guard options.extensions.contains(ext) else { continue }

        let fname = url.lastPathComponent
        if !options.includeTests && isTestFileName(fname) { continue }

        let absolutePath = url.path
        guard absolutePath.hasPrefix(rootPath + "/") else { continue }
        let relativePath = String(absolutePath.dropFirst(rootPath.count + 1))
        results.append(WalkedFile(
            absolutePath: absolutePath,
            relativePath: relativePath,
            package: resolvePackage(relativePath: relativePath),
            generated: isGenerated(relativePath: relativePath)
        ))
    }

    return results
}

private func shouldSkipDirectory(name: String, includeTests: Bool) -> Bool {
    if name.hasPrefix(".") { return true }
    if ["node_modules", "build", "dist", "coverage", "DerivedData", "Pods", "scripts", "ci_scripts"].contains(name) { return true }
    if name == "Tests" && !includeTests { return true }
    return false
}

private func isTestFileName(_ name: String) -> Bool {
    if name.hasSuffix("Tests.swift") { return true }
    if name.contains(".test.") || name.contains(".spec.") { return true }
    return false
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
