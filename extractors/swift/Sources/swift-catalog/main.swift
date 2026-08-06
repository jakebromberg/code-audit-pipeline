//
//  main.swift
//  swift-catalog
//
//  CLI entry point. Four subcommands: `type`, `func`, `literal`, and
//  `package-graph`. `type`, `func`, and `literal` each walk a root directory
//  (with optional --shared for a second package root), parse Swift files via
//  SwiftSyntax, and emit JSON conforming to docs/pipeline-contract.md.
//  `package-graph` walks the root for Package.swift files (parsed via
//  SwiftSyntax) and project.pbxproj files (parsed via brace-counting text
//  scan, per V7 §6.5) and emits an inter-package dependency graph.
//

import Foundation
import SwiftParser
import SwiftSyntax

struct Args {
    var subcommand: String
    var root: String?
    var shared: String?
    var output: String?
    var includeTests: Bool = false
    var minBodyLines: Int = 3
}

func parseArgs() -> Args? {
    let argv = CommandLine.arguments
    guard argv.count >= 2 else { return nil }
    var args = Args(subcommand: argv[1])
    var i = 2
    while i < argv.count {
        let flag = argv[i]
        switch flag {
        case "--root":
            i += 1
            guard i < argv.count else { return nil }
            args.root = argv[i]
        case "--shared":
            i += 1
            guard i < argv.count else { return nil }
            args.shared = argv[i]
        case "--output":
            i += 1
            guard i < argv.count else { return nil }
            args.output = argv[i]
        case "--include-tests":
            args.includeTests = true
        case "--min-body-lines":
            i += 1
            guard i < argv.count, let v = Int(argv[i]) else { return nil }
            args.minBodyLines = v
        default:
            logErr("Unknown flag: \(flag)")
            return nil
        }
        i += 1
    }
    return args
}

func printUsage() {
    let usage = """
    Usage: swift-catalog <type|func|literal|package-graph> --root <path> [--shared <path>] [--output <path>] [--include-tests] [--min-body-lines N]

    Subcommands:
      type           Emit type-catalog (struct/class/protocol/enum/extension/typealias/actor).
      func           Emit function-catalog (func/method/initializer/computed-property).
      literal        Emit literal-catalog (numeric literals in binding initializers and call arguments).
      package-graph  Emit inter-package dependency graph (Package.swift + project.pbxproj).

    Flags:
      --root            Required. Root of the codebase to scan.
      --shared          Optional. Second package root, walked in addition to --root.
      --output          Optional. Write JSON to this path. Default: stdout.
      --include-tests   literal only. Don't skip test-path files (see docs/pipeline-contract.md).
                        type and func always walk test files and tag every row with is_test;
                        this flag is a documented no-op for them.
      --min-body-lines  func only. Skip functions with fewer normalized body lines. Default 3.
    """
    logErr(usage)
}

guard let args = parseArgs() else {
    printUsage()
    exit(2)
}

guard let root = args.root else {
    logErr("error: --root is required")
    printUsage()
    exit(2)
}

// The package-graph subcommand has its own discovery walk (Package.swift +
// project.pbxproj only) and doesn't share the type/func source-file walk.
// Dispatch to it directly so the rest of this file doesn't have to special-case
// the unused source-file list.
if args.subcommand == "package-graph" {
    let code = runPackageGraph(root: root, output: args.output)
    exit(code)
}

// The walk always includes test files and tags each with `isTest` (contract
// §"Test path patterns"). `type` and `func` emit every row unconditionally —
// `--include-tests` is a documented no-op for them, matching the Rust
// extractor's precedent. `literal` is the one subcommand that still filters:
// it's an occurrence catalog that deliberately omits `is_test` and keeps the
// exclude-by-default polarity (docs/pipeline-contract.md §"literal-catalog").
let walkOpts = WalkOptions(extensions: ["swift"])
var files = walkRoot(root: root, options: walkOpts)
if let shared = args.shared {
    files.append(contentsOf: walkRoot(root: shared, options: walkOpts))
}

switch args.subcommand {
case "type":
    logErr("swift-catalog \(args.subcommand): scanning \(files.count) files")
    var allRecords: [TypeRecord] = []
    var parseErrors = 0
    var notificationWrappers = 0
    for file in files {
        do {
            let source = try String(contentsOfFile: file.absolutePath, encoding: .utf8)
            let tree = Parser.parse(source: source)
            let visitor = TypeCatalogVisitor(file: file, tree: tree)
            visitor.walk(tree)
            allRecords.append(contentsOf: visitor.records)
            notificationWrappers += visitor.notificationWrappersDetected
        } catch {
            parseErrors += 1
            logErr("parse error in \(file.relativePath): \(error)")
        }
    }
    logErr("emitted \(allRecords.count) type records (parse errors: \(parseErrors), notification wrappers: \(notificationWrappers))")
    do {
        try writeJSON(allRecords, to: args.output)
    } catch {
        logErr("failed to write output: \(error)")
        exit(1)
    }

case "func":
    logErr("swift-catalog \(args.subcommand): scanning \(files.count) files")
    var allRecords: [FunctionRecord] = []
    var parseErrors = 0
    for file in files {
        do {
            let source = try String(contentsOfFile: file.absolutePath, encoding: .utf8)
            let tree = Parser.parse(source: source)
            let visitor = FunctionCatalogVisitor(file: file, tree: tree, minBodyLines: args.minBodyLines)
            visitor.walk(tree)
            allRecords.append(contentsOf: visitor.records)
        } catch {
            parseErrors += 1
            logErr("parse error in \(file.relativePath): \(error)")
        }
    }
    logErr("emitted \(allRecords.count) function records (parse errors: \(parseErrors))")
    do {
        try writeJSON(allRecords, to: args.output)
    } catch {
        logErr("failed to write output: \(error)")
        exit(1)
    }

case "literal":
    let literalFiles = args.includeTests ? files : files.filter { !$0.isTest }
    logErr("swift-catalog \(args.subcommand): scanning \(literalFiles.count) files")
    var allRecords: [LiteralRecord] = []
    var parseErrors = 0
    for file in literalFiles {
        do {
            let source = try String(contentsOfFile: file.absolutePath, encoding: .utf8)
            let tree = Parser.parse(source: source)
            let visitor = LiteralCatalogVisitor(file: file, tree: tree)
            visitor.walk(tree)
            allRecords.append(contentsOf: visitor.records)
        } catch {
            parseErrors += 1
            logErr("parse error in \(file.relativePath): \(error)")
        }
    }
    logErr("emitted \(allRecords.count) literal records (parse errors: \(parseErrors))")
    do {
        try writeJSON(allRecords, to: args.output)
    } catch {
        logErr("failed to write output: \(error)")
        exit(1)
    }

default:
    logErr("Unknown subcommand: \(args.subcommand)")
    printUsage()
    exit(2)
}
