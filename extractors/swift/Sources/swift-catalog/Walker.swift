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

    /// V7 §6.6 context flags (#44). Derived from path heuristics during the
    /// walk so downstream record builders can propagate them at zero per-record
    /// cost. Same boolean shape as `generated`, but each flag has its own
    /// heuristic.
    ///
    /// - `isTest`: path is under `Tests/` or `*Testing/` (Swift library-target
    ///   convention), or the filename ends with `Tests.swift` / matches
    ///   `.test.` / `.spec.` infixes. When `--include-tests` is not set, the
    ///   walker skips test files entirely so the flag wouldn't fire on the
    ///   resulting catalog; `--include-tests` is the V7 trial-harness
    ///   invocation where the flag IS load-bearing for restraint scoring.
    /// - `isCodegen`: superset of `generated`. Catches `Generated/` subdirs
    ///   and `*.generated.swift`. Both fields are emitted for backwards compat —
    ///   V6 queries read `generated`; V7-aware queries should read `is_codegen`.
    /// - `isSampleApp`: path is under `Examples/`, `SampleApp/`, or `Demo/`
    ///   (case-insensitive). Flags sample-app mirrors of production types,
    ///   which is the Cat. 1 restraint twin idiom in the methodology's plant
    ///   manifest.
    /// - `isMockPath`: path is under `Mocks/`, `Stubs/`, or `Fakes/`. The
    ///   per-record `is_mock` field on a TypeRecord/FunctionRecord is the OR
    ///   of this path-flag with the record's own name-suffix check
    ///   (`*Mock`, `*Stub`, `*Fake`) — both signals fire independently and
    ///   the agent can cross-check.
    ///
    /// All four are HEURISTICS, not ground truth. A recommendation that
    /// ignores `is_test: true` on a cluster member loses partial credit per
    /// methodology §8 / §9.
    let isTest: Bool
    let isCodegen: Bool
    let isSampleApp: Bool
    let isMockPath: Bool
}

struct WalkOptions {
    let extensions: Set<String>
    let includeTests: Bool
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
        let generated = isGenerated(relativePath: relativePath)
        results.append(WalkedFile(
            absolutePath: absolutePath,
            relativePath: relativePath,
            package: resolvePackage(relativePath: relativePath),
            generated: generated,
            isTest: isTestPath(relativePath: relativePath),
            // is_codegen is a superset of legacy `generated` — `generated` =>
            // is_codegen, plus the additional path patterns isCodegenPath checks.
            // Computing OR explicitly so a single source of truth on each side
            // can evolve independently.
            isCodegen: generated || isCodegenPath(relativePath: relativePath),
            isSampleApp: isSampleAppPath(relativePath: relativePath),
            isMockPath: isMockPath(relativePath: relativePath)
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

// MARK: - V7 §6.6 context flag heuristics

/// Walk the path segments looking for any test-shaped container or filename.
/// Matches `Tests/`, `*Testing/` (Swift library-target convention used by
/// wxyc-ios-64's `CoreTesting`, `PlaylistTesting`, etc.), and the per-file
/// conventions inherited from `isTestFileName` (`*Tests.swift`, `*.test.*`,
/// `*.spec.*`). Case-sensitive on segment names — Swift conventionally
/// capitalizes these, and `tests/` lowercased is rare in Swift projects.
private func isTestPath(relativePath: String) -> Bool {
    let segments = relativePath.split(separator: "/").map(String.init)
    for segment in segments {
        if segment == "Tests" { return true }
        if segment.hasSuffix("Testing") && segment != "Testing" { return true }
        if segment == "__tests__" { return true }
    }
    let fname = segments.last ?? ""
    if fname.hasSuffix("Tests.swift") { return true }
    if fname.contains(".test.") || fname.contains(".spec.") { return true }
    return false
}

/// Catches codegen patterns beyond what `isGenerated` covers. The walker
/// passes the combined OR of both checks as `isCodegen` on `WalkedFile`, so
/// the legacy `generated` flag stays narrow and `is_codegen` is the broader
/// V7 signal a methodology §6.6 restraint can lean on.
///
/// Additional patterns beyond `isGenerated`'s `/generated/` and
/// `.generated.swift`:
///   - any path segment named `Generated` (capital G — the common Swift
///     convention vs `isGenerated`'s lowercase `/generated/`)
///   - filenames matching `*+Generated.swift` (some codegen tools, including
///     SwiftGen variants, use the plus-suffix convention)
private func isCodegenPath(relativePath: String) -> Bool {
    let segments = relativePath.split(separator: "/").map(String.init)
    for segment in segments where segment == "Generated" { return true }
    let fname = segments.last ?? ""
    if fname.hasSuffix("+Generated.swift") { return true }
    return false
}

/// Sample-app convention: `Examples/`, `SampleApp/`, `Demo/`, or `Demos/`
/// anywhere in the path. Case-insensitive on the segment name because the
/// convention varies (`Examples` vs `examples`).
private func isSampleAppPath(relativePath: String) -> Bool {
    for segment in relativePath.split(separator: "/") {
        let lower = segment.lowercased()
        if lower == "examples" || lower == "example" { return true }
        if lower == "sampleapp" || lower == "sample-app" || lower == "sample" { return true }
        if lower == "demo" || lower == "demos" { return true }
    }
    return false
}

/// Mocks-dir convention: any path segment named `Mocks`, `Stubs`, or `Fakes`.
/// The per-record `is_mock` flag also OR's in the record's own name-suffix
/// check (e.g., `protocol FooMock`), but the file-level signal covers the
/// containing-directory case which suffix checks miss (e.g.,
/// `Mocks/AuthClient.swift` with a record named `AuthClient`).
private func isMockPath(relativePath: String) -> Bool {
    for segment in relativePath.split(separator: "/") {
        if segment == "Mocks" || segment == "Stubs" || segment == "Fakes" {
            return true
        }
    }
    return false
}

// MARK: - V7 §6.6 record-name suffix check (consumed by visitors)

/// Last-segment suffix check used by the per-record `is_mock` decision. The
/// type/function visitors pass the qualified name (`Outer.Inner.bar`); this
/// helper strips to the last dot-separated segment (`bar`) and checks whether
/// it ends with `Mock`, `Stub`, or `Fake`. The qualifying-type check is the
/// visitor's responsibility — it knows the containing-type name structurally
/// and can construct the right input.
func nameEndsWithMockStubFakeSuffix(_ name: String) -> Bool {
    let last = name.split(separator: ".").last.map(String.init) ?? name
    return last.hasSuffix("Mock") || last.hasSuffix("Stub") || last.hasSuffix("Fake")
}
