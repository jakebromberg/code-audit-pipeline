//
//  main.swift
//  swift-catalog
//
//  CLI entry point. Two subcommands: `type` and `func`. Each walks a root directory
//  (with optional --shared for a second package root), parses Swift files via
//  SwiftSyntax, and emits JSON conforming to docs/pipeline-contract.md.
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
    Usage: swift-catalog <type|func> --root <path> [--shared <path>] [--output <path>] [--include-tests] [--min-body-lines N]

    Subcommands:
      type    Emit type-catalog (struct/class/protocol/enum/extension/typealias/actor).
      func    Emit function-catalog (func/method/initializer/computed-property).

    Flags:
      --root            Required. Root of the codebase to scan.
      --shared          Optional. Second package root, walked in addition to --root.
      --output          Optional. Write JSON to this path. Default: stdout.
      --include-tests   Optional. Don't skip Tests/ directories or *Tests.swift files.
      --min-body-lines  function-catalog only. Skip functions with fewer normalized body lines. Default 3.
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

let walkOpts = WalkOptions(extensions: ["swift"], includeTests: args.includeTests)
var files = walkRoot(root: root, options: walkOpts)
if let shared = args.shared {
    files.append(contentsOf: walkRoot(root: shared, options: walkOpts))
}

logErr("swift-catalog \(args.subcommand): scanning \(files.count) files")

switch args.subcommand {
case "type":
    var allRecords: [TypeRecord] = []
    var parseErrors = 0
    for file in files {
        do {
            let source = try String(contentsOfFile: file.absolutePath, encoding: .utf8)
            let tree = Parser.parse(source: source)
            let visitor = TypeCatalogVisitor(file: file, tree: tree)
            visitor.walk(tree)
            allRecords.append(contentsOf: visitor.records)
        } catch {
            parseErrors += 1
            logErr("parse error in \(file.relativePath): \(error)")
        }
    }

    // V7 §6.3: second-pass resolution. After the visitor emits every record
    // (so the lookup index is complete), walk protocol records and union
    // their parents' fields in. Fixed-point loop bounded at 5 iterations;
    // protocol-only — class inheritance is round-2 scope.
    resolveProtocolInheritance(&allRecords)

    let resolvedCount = allRecords.filter { $0.resolvedFrom == "protocol-inheritance" }.count
    logErr("emitted \(allRecords.count) type records (parse errors: \(parseErrors), protocol-inheritance-resolved: \(resolvedCount))")
    do {
        try writeJSON(allRecords, to: args.output)
    } catch {
        logErr("failed to write output: \(error)")
        exit(1)
    }

case "func":
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

default:
    logErr("Unknown subcommand: \(args.subcommand)")
    printUsage()
    exit(2)
}
