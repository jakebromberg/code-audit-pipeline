//
//  PackageGraphExtractor.swift
//  swift-catalog
//
//  V7 §6.5: package-dependency graph extractor.
//
//  Walks `--root` recursively and emits `package-graph.json` describing
//  inter-package dependency edges. Two input kinds:
//
//    1. SwiftPM packages (`Package.swift`). Parsed via SwiftSyntax — the
//       manifest is itself Swift source, so we walk the tree looking for
//       `.package(...)` entries inside the `dependencies:` array and
//       `.product(name: "X", package: "Y")` references inside per-target
//       `dependencies:` arrays.
//
//    2. Xcode project files (`WXYC.xcodeproj/project.pbxproj`). Parsed with
//       a brace-counting text scan. The xcodeproj gem and the Python pbxproj
//       library fail on complex projects (per wxyc-ios-64's CLAUDE.md), so the
//       methodology doc (§6.5) prescribes line-by-line text processing. We
//       locate the `XCSwiftPackageProductDependency` section, extract the
//       `productName` for each entry to build a uuid→productName map, then
//       walk the `PBXNativeTarget` section to associate `packageProductDependencies`
//       lists with target names.
//
//  Skip rules mirror the existing walker: dotdirs (`.git`, `.build`, `.swiftpm`,
//  `.xcodeproj` subdirs other than the top-level one we explicitly visit) and
//  the common build/dist/coverage directories.
//

import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - Output schema

struct PackageGraphNode: Encodable {
    var name: String
    var kind: String   // "package" | "app"
    var path: String
}

struct PackageGraphEdge: Encodable {
    var from: String
    var to: String
    var source: String   // "Package.swift" | "pbxproj"
}

struct PackageGraph: Encodable {
    var schemaVersion: String
    var nodes: [PackageGraphNode]
    var edges: [PackageGraphEdge]
}

// MARK: - Entry point

/// Run the package-graph extractor against `root` and write the result to
/// `output` (or stdout if nil). Returns process-exit code.
func runPackageGraph(root: String, output: String?) -> Int32 {
    let canonicalRoot: String = root.withCString { cstr in
        guard let r = realpath(cstr, nil) else { return root }
        defer { free(r) }
        return String(cString: r)
    }

    var nodes: [PackageGraphNode] = []
    var edges: [PackageGraphEdge] = []
    var packageFiles = 0
    var pbxprojFiles = 0
    var parseErrors = 0
    var warnings = 0

    // ---- 1. SwiftPM Package.swift discovery ---------------------------------

    let packageManifests = findPackageManifests(root: canonicalRoot)
    for manifestPath in packageManifests {
        let relManifest = relativize(manifestPath, root: canonicalRoot)
        let pkgName = packageNameFromManifestPath(relManifest)

        // Empty-dir signal: if the containing dir has nothing but the manifest
        // and the manifest itself is empty/missing, warn (likely an uninitialized
        // submodule like Shared/Wallpaper). We still emit the node so downstream
        // consumers can see the gap.
        let containingDir = (manifestPath as NSString).deletingLastPathComponent
        if isLikelyUninitializedSubmodule(dir: containingDir) {
            logErr("warning: \(relManifest) appears to live in an uninitialized submodule; dependencies may be missing")
            warnings += 1
        }

        nodes.append(PackageGraphNode(name: pkgName, kind: "package", path: relManifest))

        guard let source = try? String(contentsOfFile: manifestPath, encoding: .utf8) else {
            parseErrors += 1
            logErr("parse error: could not read \(relManifest)")
            continue
        }
        let tree = Parser.parse(source: source)
        let visitor = PackageManifestVisitor()
        visitor.walk(tree)
        packageFiles += 1

        // Note on path-deps vs product-deps: `.package(path:)` declares
        // reachability (the manifest CAN see the upstream); `.product(name:,
        // package:)` declares use (a target actually imports it). For a
        // recommendation-target graph the latter is the truth, but we emit
        // both so a downstream consumer can distinguish — the dedup at the
        // end of this function collapses any (from, to, "Package.swift") pair
        // declared via both forms into a single edge.
        for depPath in visitor.pathDependencies {
            let target = packageNameFromRelativeDepPath(depPath, fromManifest: relManifest)
            edges.append(PackageGraphEdge(from: pkgName, to: target, source: "Package.swift"))
        }
        for prod in visitor.productDependencies {
            // `.product(name: "Core", package: "Core")` inside a target's
            // dependencies — the `package:` value names the upstream package.
            // We resolve that against the manifest's own pathDependencies to
            // recover the on-disk path-based package name. If we can't resolve,
            // fall back to the raw product name and emit a warning.
            let target = resolveProductPackage(
                productPackage: prod.packageName,
                productName: prod.productName,
                pathDeps: visitor.pathDependencies,
                manifestPath: relManifest
            )
            edges.append(PackageGraphEdge(from: pkgName, to: target, source: "Package.swift"))
        }
    }

    // ---- 2. Xcode project pbxproj discovery ---------------------------------

    // Resolve pbxproj product references against a deterministically-ordered
    // snapshot of the package nodes. `findPackageManifests` walks via
    // `FileManager.enumerator`, whose ordering is not guaranteed to be stable
    // across filesystems or platforms; resolving against the unsorted, walk-
    // order list lets two packages with the same trailing path component
    // (e.g. `Shared/Core` vs `Vendor/Core`) produce different edges on
    // different machines. Sort once, here, and feed the sorted view to the
    // resolver.
    let sortedPackageNodes = nodes
        .filter { $0.kind == "package" }
        .sorted { $0.name < $1.name }

    let pbxprojPaths = findPbxprojs(root: canonicalRoot)
    for pbxpath in pbxprojPaths {
        let rel = relativize(pbxpath, root: canonicalRoot)
        guard let text = try? String(contentsOfFile: pbxpath, encoding: .utf8) else {
            parseErrors += 1
            logErr("parse error: could not read \(rel)")
            continue
        }
        let parsed = parsePbxproj(text: text)
        pbxprojFiles += 1

        for target in parsed.targets {
            nodes.append(PackageGraphNode(name: target.name, kind: "app", path: rel))
            for productUuid in target.packageProductDependencies {
                guard let productName = parsed.productNameByUuid[productUuid] else {
                    logErr("warning: pbxproj target \(target.name) references unknown product uuid \(productUuid)")
                    warnings += 1
                    continue
                }
                // App-target dependencies name the SPM *product*, which conventionally
                // matches the *package* name in wxyc-ios-64's Shared/<Pkg> layout.
                // Emit the edge against the package-name form so downstream joins
                // against the SwiftPM-derived nodes line up.
                let to = resolveAppEdgeTarget(productName: productName, packageNodes: sortedPackageNodes)
                edges.append(PackageGraphEdge(from: target.name, to: to, source: "pbxproj"))
            }
        }
    }

    // ---- 3. Emit + summary --------------------------------------------------

    if packageFiles == 0 && pbxprojFiles == 0 {
        logErr("error: no Package.swift or project.pbxproj found under \(canonicalRoot)")
        return 1
    }

    // Deduplicate nodes by (name, kind). Keying on name alone silently drops
    // the second occurrence when, e.g., a package named `iOS` (a per-platform
    // Shared/<Plat>/Package.swift layout) coexists with an app target also
    // called `iOS` — the package-side and the app-side both legitimately
    // appear in the graph and downstream queries need both rows to render
    // the edge correctly. The (name, kind) key preserves the distinction
    // while still collapsing real duplicates (same kind, same name).
    struct NodeKey: Hashable { let name: String; let kind: String }
    var seenNodes = Set<NodeKey>()
    let dedupedNodes = nodes.filter { node in
        let key = NodeKey(name: node.name, kind: node.kind)
        if seenNodes.contains(key) { return false }
        seenNodes.insert(key)
        return true
    }

    // Deduplicate edges by (from, to, source).
    var seenEdges = Set<String>()
    let dedupedEdges = edges.filter { edge in
        let key = "\(edge.from)\u{0}\(edge.to)\u{0}\(edge.source)"
        if seenEdges.contains(key) { return false }
        seenEdges.insert(key)
        return true
    }

    let graph = PackageGraph(
        schemaVersion: "1",
        nodes: dedupedNodes.sorted { $0.name < $1.name },
        edges: dedupedEdges.sorted { lhs, rhs in
            if lhs.from != rhs.from { return lhs.from < rhs.from }
            if lhs.to != rhs.to { return lhs.to < rhs.to }
            return lhs.source < rhs.source
        }
    )

    logErr("package-graph: \(packageFiles) Package.swift, \(pbxprojFiles) pbxproj, \(dedupedNodes.count) nodes, \(dedupedEdges.count) edges, \(parseErrors) parse errors, \(warnings) warnings")

    do {
        try writeJSON(graph, to: output)
    } catch {
        logErr("failed to write output: \(error)")
        return 1
    }
    return 0
}

// MARK: - File discovery

/// Walk `root` recursively for files named `Package.swift`. Skips hidden
/// directories and the standard build/dist/coverage dirs.
private func findPackageManifests(root: String) -> [String] {
    let fm = FileManager.default
    let rootURL = URL(fileURLWithPath: root)
    guard let enumerator = fm.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var results: [String] = []
    while let url = enumerator.nextObject() as? URL {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if values?.isDirectory == true {
            if shouldSkipPackageWalkDir(name: url.lastPathComponent) {
                enumerator.skipDescendants()
            }
            continue
        }
        if values?.isRegularFile == true && url.lastPathComponent == "Package.swift" {
            results.append(url.path)
        }
    }
    return results
}

/// Walk `root` for `*.xcodeproj/project.pbxproj` files. We don't descend into
/// .xcodeproj as a package walker but we do explicitly look for them at any
/// nesting depth.
private func findPbxprojs(root: String) -> [String] {
    let fm = FileManager.default
    let rootURL = URL(fileURLWithPath: root)
    guard let enumerator = fm.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var results: [String] = []
    while let url = enumerator.nextObject() as? URL {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if values?.isDirectory == true {
            if shouldSkipPackageWalkDir(name: url.lastPathComponent) {
                enumerator.skipDescendants()
            }
            continue
        }
        if values?.isRegularFile == true && url.lastPathComponent == "project.pbxproj" {
            results.append(url.path)
        }
    }
    return results
}

/// Shared skip predicate for the package-graph walkers. We can't rely on
/// `FileManager`'s `.skipsHiddenFiles` alone: agent worktrees and IDE state
/// (`.claude`, `.cursor`, `.idea`, `.vscode`, `.next`) often contain
/// near-duplicate clones of the host repo, and HFS+/APFS will report some of
/// those as non-hidden depending on filesystem flags. Per `CLAUDE.md`'s rule
/// for extractors, we explicitly refuse to descend into any dot-prefixed
/// directory, then layer the project-specific build/cache list on top.
///
/// `findPackageManifests` and `findPbxprojs` both call this so the two walks
/// agree on what's in-bounds — asymmetry between them would let, e.g., a
/// stale `.cursor/` clone contribute pbxproj edges while its sibling
/// `Package.swift`es went unseen.
private func shouldSkipPackageWalkDir(name: String) -> Bool {
    // Mirrors the existing Walker.swift skip rules; we explicitly do NOT skip
    // Tests/ here because Package.swift files can declare test targets and we
    // want to see those packages too.
    if name.hasPrefix(".") { return true }
    if ["node_modules", "build", "dist", "coverage", "DerivedData", "Pods"].contains(name) {
        return true
    }
    return false
}

// MARK: - Naming

private func relativize(_ absolutePath: String, root: String) -> String {
    let prefix = root + "/"
    if absolutePath.hasPrefix(prefix) {
        return String(absolutePath.dropFirst(prefix.count))
    }
    return absolutePath
}

/// Derive a package name from the relative path of its `Package.swift`.
/// `Shared/Core/Package.swift` → `Shared/Core` (matches the spec's example shape).
/// A bare top-level `Package.swift` → root directory name fallback, or `"root"`.
private func packageNameFromManifestPath(_ rel: String) -> String {
    let parts = rel.split(separator: "/").map(String.init)
    guard parts.last == "Package.swift" else { return rel }
    let dirParts = parts.dropLast()
    if dirParts.isEmpty { return "root" }
    return dirParts.joined(separator: "/")
}

/// Resolve `.package(path: "../Core")` from a manifest at `relManifest` to the
/// target package's path-derived name. Used for inter-package edges declared
/// via local paths (the wxyc-ios-64 convention).
private func packageNameFromRelativeDepPath(_ depPath: String, fromManifest relManifest: String) -> String {
    let manifestDirParts = (relManifest as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
    var resolved = manifestDirParts
    for segment in depPath.split(separator: "/") {
        if segment == ".." {
            if !resolved.isEmpty { resolved.removeLast() }
        } else if segment == "." {
            continue
        } else {
            resolved.append(String(segment))
        }
    }
    if resolved.isEmpty { return depPath }
    return resolved.joined(separator: "/")
}

/// Best-effort resolution of `.product(name: ..., package: ...)` to the path-
/// derived package name used in nodes. If the `package:` matches one of the
/// manifest's own pathDependencies basenames, prefer the path-derived form.
/// Otherwise fall back to the raw package identifier.
private func resolveProductPackage(
    productPackage: String,
    productName: String,
    pathDeps: [String],
    manifestPath: String
) -> String {
    // Try to find a pathDep whose final component (the directory name) matches
    // either the productPackage or productName. That's the wxyc-ios-64 idiom:
    // `.package(path: "../Core")` declares a dependency on a package whose
    // manifest declares `name: "Core"`.
    for dep in pathDeps {
        let last = String(dep.split(separator: "/").last ?? Substring(dep))
        if last == productPackage || last == productName {
            return packageNameFromRelativeDepPath(dep, fromManifest: manifestPath)
        }
    }
    // Fallback: bare package name; downstream consumers will see it as a node
    // without a `path` if there's no corresponding manifest in the walk.
    return productPackage
}

/// For an app-target -> SPM-product edge, prefer to point at an already-emitted
/// `package`-kind node whose name ends with the product name (e.g., the pbxproj
/// declares `productName = Core` and we already have a `Shared/Core` node from
/// the Package.swift walk — emit the edge against `Shared/Core`).
private func resolveAppEdgeTarget(productName: String, packageNodes: [PackageGraphNode]) -> String {
    for node in packageNodes where node.kind == "package" {
        let parts = node.name.split(separator: "/")
        if parts.last == Substring(productName) {
            return node.name
        }
        if node.name == productName {
            return node.name
        }
    }
    return productName
}

/// Heuristic for "submodule isn't initialized." A submodule's working dir is
/// empty (or contains only a stale `.git` file) until `git submodule update`
/// pulls it in. The git-submodule machinery leaves a `.git` *file* (not dir)
/// pointing at the parent's modules directory, so our signal is: the directory
/// is empty other than that file. Real packages always have at least one of
/// Sources/, Tests/, Resources/, but absence of those alone is too noisy for a
/// warning — synthetic fixtures and minimal packages also lack them. We
/// require the stronger signal of a `.git` *file* (submodule pointer) sitting
/// alongside an otherwise-bare Package.swift.
private func isLikelyUninitializedSubmodule(dir: String) -> Bool {
    let fm = FileManager.default
    let gitPath = (dir as NSString).appendingPathComponent(".git")
    var isDir: ObjCBool = false
    let gitExists = fm.fileExists(atPath: gitPath, isDirectory: &isDir)
    // `.git` as a regular file (not a directory) is the submodule-pointer
    // signature. If `.git` is a directory, we're at the root of a real repo
    // (or a worktree); not a submodule placeholder.
    guard gitExists && !isDir.boolValue else { return false }
    guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return false }
    let interesting = contents.filter { name in
        name != ".git" && name != "Package.swift" && name != "Package.resolved" && !name.hasPrefix(".")
    }
    return interesting.isEmpty
}

// MARK: - Package.swift parsing (SwiftSyntax)

/// Collected dependencies from a single Package.swift. The visitor records
/// `.package(path: "...")` entries (path-based local deps) and per-target
/// `.product(name: ..., package: ...)` references (the actual edges into
/// targets). The two are emitted separately because path-deps establish
/// reachability while product-deps establish *which* package a target actually
/// imports.
private final class PackageManifestVisitor: SyntaxVisitor {
    var pathDependencies: [String] = []
    var productDependencies: [(productName: String, packageName: String)] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Match `.package(path: "...")` and `.product(name: ..., package: ...)`
        // by looking at the called-expression's trailing identifier.
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return .visitChildren
        }
        let methodName = memberAccess.declName.baseName.text
        switch methodName {
        case "package":
            if let path = stringArg(node.arguments, label: "path") {
                pathDependencies.append(path)
            }
            // We deliberately skip `.package(url: ...)` for now — V7 §6.5's
            // wxyc-ios-64 use case is path-only inter-package deps. Adding URL
            // support is straightforward when needed.
        case "product":
            let name = stringArg(node.arguments, label: "name")
            let pkg = stringArg(node.arguments, label: "package")
            if let name = name, let pkg = pkg {
                productDependencies.append((productName: name, packageName: pkg))
            }
        default:
            break
        }
        return .visitChildren
    }

    private func stringArg(_ args: LabeledExprListSyntax, label: String) -> String? {
        for arg in args {
            if arg.label?.text == label {
                if let strLit = arg.expression.as(StringLiteralExprSyntax.self) {
                    return stringLiteralValue(strLit)
                }
            }
        }
        return nil
    }

    private func stringLiteralValue(_ lit: StringLiteralExprSyntax) -> String? {
        // Concatenate non-interpolated segments. Interpolated literals
        // (`"\(foo)"`) are rare in Package.swift and we treat them as
        // unresolvable; SwiftSyntax exposes them as StringSegmentSyntax /
        // ExpressionSegmentSyntax variants on `segments`.
        var out = ""
        for segment in lit.segments {
            guard let seg = segment.as(StringSegmentSyntax.self) else {
                return nil
            }
            out.append(seg.content.text)
        }
        return out
    }
}

// MARK: - pbxproj parsing (brace-counting text scan)

private struct PbxNativeTarget {
    var name: String
    var packageProductDependencies: [String]
}

private struct ParsedPbxproj {
    var targets: [PbxNativeTarget]
    /// uuid → productName, populated from the `XCSwiftPackageProductDependency`
    /// section. Targets reference these uuids in their `packageProductDependencies`
    /// list.
    var productNameByUuid: [String: String]
}

/// Brace-counting parse of a project.pbxproj file. Identifies:
///   - `XCSwiftPackageProductDependency` blocks → uuid→productName map.
///   - `PBXNativeTarget` blocks with `productType` matching application or
///     app-extension → target name + packageProductDependencies uuids.
///
/// The pbxproj format is a series of `<uuid> /* comment */ = { key = value; ... };`
/// blocks. We tokenize by walking braces; inside each block we look for the
/// `isa = X;` line to identify the block kind, then extract the relevant
/// fields. This deliberately avoids any third-party pbxproj library — wxyc-ios-64's
/// CLAUDE.md flags that the Ruby xcodeproj gem and Python pbxproj library
/// occasionally fail on complex projects (V7 §6.5).
private func parsePbxproj(text: String) -> ParsedPbxproj {
    let chars = Array(text)
    var targets: [PbxNativeTarget] = []
    var productNameByUuid: [String: String] = [:]

    // A pbxproj file is structured as a top-level dict whose `objects = { ... };`
    // contains all the interesting blocks. We can't simply scan for `= {` at
    // depth 0 — every block is nested inside `objects`. So we collect every
    // block at every depth and inspect those whose `isa = ...` matches what
    // we care about.
    collectPbxBlocks(chars, openAt: 0) { uuid, body in
        if let isa = pbxValue(body: body, key: "isa") {
            if isa == "XCSwiftPackageProductDependency" {
                if let productName = pbxValue(body: body, key: "productName") {
                    productNameByUuid[uuid] = productName
                }
            } else if isa == "PBXNativeTarget" {
                // Only app-style targets count for the package-graph: apps and
                // app-extensions. Frameworks and tests aren't "app targets" in
                // §6.5's vocabulary. We accept either explicit application-style
                // productType strings or fall back to including any PBXNativeTarget
                // with a `packageProductDependencies` list — synthetic test
                // fixtures may omit productType.
                let productType = pbxValue(body: body, key: "productType") ?? ""
                let isApp = productType.contains("application") || productType.contains("app-extension") || productType.contains("watchapp")
                let deps = pbxArrayValue(body: body, key: "packageProductDependencies")
                if (isApp || !deps.isEmpty),
                   let targetName = pbxValue(body: body, key: "name") {
                    targets.append(PbxNativeTarget(
                        name: targetName,
                        packageProductDependencies: deps
                    ))
                }
            }
        }
    }

    return ParsedPbxproj(targets: targets, productNameByUuid: productNameByUuid)
}

/// Walk a pbxproj text and invoke `visit(uuid, body)` for every `<uuid> = { ... }`
/// block, at any nesting depth. We scan linearly, tracking brace/paren/quote
/// state, and emit a visit each time a balanced `{ ... }` block closes for which
/// the preceding token chain looked like `<uuid> [/* comment */] =`.
///
/// This is the central decoupling: rather than try to slice the file into
/// top-level blocks (which fails because everything is nested inside the outer
/// `objects = { ... };`), we recognize block boundaries as we cross them and
/// hand each balanced body to the caller's classifier.
///
/// Paren tracking matters: pbxproj array literals (`buildSettings = ( ... );`)
/// can contain `{ ... }` dictionaries as elements (e.g.
/// `OTHER_LDFLAGS = ("$(inherited)", { foo = bar; });`). Those inner braces
/// must not be treated as block openings — they aren't preceded by a
/// `<uuid> = ` header, so emitting a visit for them would feed `pbxValue` a
/// malformed body and could misclassify the enclosing target. While paren
/// depth is > 0 we ignore both `{` and `}`; the paren-array text is opaque
/// to the block walker.
private func collectPbxBlocks(
    _ chars: [Character],
    openAt offset: Int,
    visit: (_ uuid: String, _ body: String) -> Void
) {
    var i = offset
    let n = chars.count
    var stack: [(uuid: String, bodyStart: Int)] = []
    var parenDepth = 0
    var inString = false
    var inComment = false

    while i < n {
        let c = chars[i]

        if inString {
            if c == "\\" && i + 1 < n {
                i += 2
                continue
            }
            if c == "\"" { inString = false }
            i += 1
            continue
        }

        if inComment {
            if c == "*" && i + 1 < n && chars[i + 1] == "/" {
                inComment = false
                i += 2
                continue
            }
            i += 1
            continue
        }

        if c == "\"" {
            inString = true
            i += 1
            continue
        }

        if c == "/" && i + 1 < n && chars[i + 1] == "*" {
            inComment = true
            i += 2
            continue
        }

        if c == "(" {
            parenDepth += 1
            i += 1
            continue
        }

        if c == ")" {
            if parenDepth > 0 { parenDepth -= 1 }
            i += 1
            continue
        }

        if c == "{" {
            // While inside a paren-delimited array we treat `{...}` as opaque
            // element syntax — it cannot be a block header here, since the
            // grammar requires a `<uuid> = ` prefix at object-section depth.
            if parenDepth > 0 {
                i += 1
                continue
            }
            // Look backward to recover the block-header `<uuid> [/* ... */] = `.
            let header = pbxHeaderBefore(chars, openIdx: i)
            let uuid = pbxFirstToken(header)
            stack.append((uuid: uuid, bodyStart: i + 1))
            i += 1
            continue
        }

        if c == "}" {
            if parenDepth > 0 {
                i += 1
                continue
            }
            if let frame = stack.popLast() {
                let body = String(chars[frame.bodyStart..<i])
                // Skip the outermost (rootObject-level) block — it has no uuid
                // header — to avoid invoking visit() on the entire file body.
                if !frame.uuid.isEmpty {
                    visit(frame.uuid, body)
                }
            }
            i += 1
            continue
        }

        i += 1
    }
}

/// Walk backward from an `{` at `openIdx` to recover the header substring
/// (uuid + comments + `=`). We stop at the previous `;`, `{`, `}`, `(`, `)`, or
/// the start of the file.
private func pbxHeaderBefore(_ chars: [Character], openIdx: Int) -> String {
    var i = openIdx - 1
    while i >= 0 {
        let c = chars[i]
        if c == ";" || c == "{" || c == "}" || c == "(" || c == ")" {
            break
        }
        i -= 1
    }
    let start = i + 1
    let header = String(chars[start..<openIdx])
    // Require a trailing `=` to count as a block header; otherwise this is
    // probably the outer `{` of the file, an array literal, etc. Return an
    // empty string in that case (collectPbxBlocks skips empty-uuid frames).
    if !header.contains("=") { return "" }
    // Trim trailing whitespace and the `=` and any `/* ... */` annotations.
    var trimmed = header
    if let eq = trimmed.lastIndex(of: "=") {
        trimmed = String(trimmed[..<eq])
    }
    // Strip /* ... */ comments.
    while let r = trimmed.range(of: "/*"),
          let e = trimmed.range(of: "*/", range: r.upperBound..<trimmed.endIndex)
    {
        trimmed.removeSubrange(r.lowerBound..<e.upperBound)
    }
    return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Extract the first whitespace-delimited token from a header fragment like
/// `\t\tAAAA0001 /* iOS */ ` → `AAAA0001`.
private func pbxFirstToken(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if let space = trimmed.firstIndex(where: { $0.isWhitespace }) {
        return String(trimmed[..<space])
    }
    return trimmed
}

/// Extract a scalar `key = value;` from a pbxproj block body. Values can be
/// bare identifiers or quoted strings; trailing comments (`/* ... */`) are
/// stripped. Returns the trimmed value or nil if the key isn't present at
/// brace-depth 0.
private func pbxValue(body: String, key: String) -> String? {
    let chars = Array(body)
    let pattern = Array("\(key) = ")
    var depth = 0
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "{" || c == "(" {
            depth += 1
            i += 1
            continue
        }
        if c == "}" || c == ")" {
            depth -= 1
            i += 1
            continue
        }
        if depth == 0 && matches(chars, at: i, pattern: pattern) {
            let valStart = i + pattern.count
            return readPbxScalar(chars, from: valStart)
        }
        i += 1
    }
    return nil
}

private func matches(_ chars: [Character], at offset: Int, pattern: [Character]) -> Bool {
    guard offset + pattern.count <= chars.count else { return false }
    for k in 0..<pattern.count where chars[offset + k] != pattern[k] {
        return false
    }
    // Boundary check: don't match the middle of an identifier like
    // `displayName` when key is `name`. Require that the character before
    // `offset` is a non-identifier char (whitespace, ;, newline, start).
    if offset > 0 {
        let prev = chars[offset - 1]
        if prev.isLetter || prev.isNumber || prev == "_" { return false }
    }
    return true
}

/// Read a pbxproj scalar value from `chars[from...]` up to the next semicolon,
/// stripping a trailing `/* comment */` and surrounding quotes.
private func readPbxScalar(_ chars: [Character], from: Int) -> String? {
    var s = ""
    var i = from
    var inQuote = false
    while i < chars.count {
        let c = chars[i]
        if inQuote {
            if c == "\\" && i + 1 < chars.count {
                s.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "\"" {
                inQuote = false
            } else {
                s.append(c)
            }
        } else {
            if c == "\"" {
                inQuote = true
            } else if c == ";" {
                break
            } else {
                s.append(c)
            }
        }
        i += 1
    }
    // Strip trailing `/* ... */`.
    if let r = s.range(of: "/*") {
        s = String(s[..<r.lowerBound])
    }
    return s.trimmingCharacters(in: .whitespaces)
}

/// Extract a paren-delimited array like `packageProductDependencies = (\n  UUID /* X */,\n);`
/// into a list of uuid tokens. Strips comments and commas.
private func pbxArrayValue(body: String, key: String) -> [String] {
    let chars = Array(body)
    let pattern = Array("\(key) = (")
    var depth = 0
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "{" {
            depth += 1
            i += 1
            continue
        }
        if c == "}" {
            depth -= 1
            i += 1
            continue
        }
        if depth == 0 && matches(chars, at: i, pattern: pattern) {
            let openParen = i + pattern.count - 1
            // Find matching close paren.
            var pdepth = 1
            var j = openParen + 1
            while j < chars.count && pdepth > 0 {
                if chars[j] == "(" { pdepth += 1 }
                if chars[j] == ")" { pdepth -= 1 }
                if pdepth == 0 { break }
                j += 1
            }
            guard j < chars.count else { return [] }
            let inner = String(chars[(openParen + 1)..<j])
            return parsePbxArrayInner(inner)
        }
        i += 1
    }
    return []
}

/// Split a pbxproj array's inner text into uuid tokens, stripping inline
/// `/* ... */` comments and the trailing comma separators.
private func parsePbxArrayInner(_ text: String) -> [String] {
    // Strip /* ... */ comments first.
    var stripped = ""
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        if i + 1 < chars.count && chars[i] == "/" && chars[i + 1] == "*" {
            // Skip to next "*/".
            var j = i + 2
            while j + 1 < chars.count && !(chars[j] == "*" && chars[j + 1] == "/") {
                j += 1
            }
            i = j + 2
            continue
        }
        stripped.append(chars[i])
        i += 1
    }
    return stripped
        .split { $0 == "," || $0.isWhitespace }
        .map(String.init)
        .filter { !$0.isEmpty }
}
