# Implement the binary in Go with gojq as the jq engine

The audit binary is written in Go, distributed as a single static executable per platform via `goreleaser`. jq evaluation is performed by `gojq` (`itchyny/gojq`), embedded in the binary. Extractors remain in their host languages — Node for TypeScript and file-hashes, Swift for Swift, planned Python for Python — because each uses its language's native AST library, which Go cannot substitute for without recall regression.

## Considered Options

- **Node binary, host-language extractors.** Minimizes marginal effort: Node is already a hard dependency for TS extraction, so the binary in Node adds no new runtime. The "fewer languages in the repo" argument that initially favored this option does not survive scrutiny — the repo is already polyglot (Node + Swift + jq + Bash + planned Python = 5 languages). Adding Go is +1 language, not a categorical crossing from uniform to polyglot.
- **Full Go via tree-sitter for AST.** Would replace `typescript` package and `SwiftSyntax` with tree-sitter grammars. Real recall regression on generics, intersection types, macros, property wrappers — exactly the gaps the V2–V6 experiment series surfaced and closed. Conflicts with the project's foundational principle of using each language's native compiler API for extraction.
- **Go binary, host-language extractors, embedded gojq** (chosen). Best distribution story (`brew install jakebromberg/tap/audit`, single binary), embedded jq removes one runtime dependency, native AST per extractor preserves the substrate principle.

## Consequences

- The repo grows from 5 to 6 languages. The Go-specific contributor cost is paid by binary maintainers; query and extractor contributors don't touch Go (queries are `.jq`, extractors stay in their host languages).
- Cross-platform release matrix is darwin/linux × amd64/arm64 via `goreleaser`. Windows ships via GH Releases tarballs.
- `gojq` compatibility must be verified against every existing query before PR 3 (the binary skeleton) commits to the engine. If any query diverges from system `jq` output, that query gets `#! engine: jq` in front-matter and the binary shells out to system `jq` for that case only.
- `jq` is no longer a runtime dependency of the binary's default path. The `.jq` files remain hand-runnable with system `jq` for users who prefer that — the project does not abandon its naked-jq invariant.
- The contributor-cognitive-load argument that initially favored Node was wrong-framed: query authors and extractor authors don't touch the binary's language, so the choice is paid by one maintainer rather than amortized across contributors.
