# Front-matter for queries, `manifest.toml` for extractors

Queries register themselves to the binary via single-line `#! key: value` front-matter at the top of each `.jq` file. Extractors register via a `manifest.toml` sidecar in each extractor directory. The asymmetry reflects the underlying tool shapes: queries are short text files where header comments fit naturally and the file IS the query; extractors are multi-file directories with their own runtimes (npm, swift toolchain), where a sidecar declaration matches the per-directory configuration pattern those runtimes already use.

## Considered Options

- **Hardcoded registration in the binary.** Adding a new query would require a binary edit. Kills the contributor flow.
- **Sidecar manifests everywhere.** Doubles the file count under `pipeline/queries/`; each `.jq` paired with a `.toml`. The two would drift and a contributor changing knobs in one would forget the other.
- **Front-matter everywhere.** Impossible for Swift's compiled binary extractor. Embedding TOML-in-comments for the Node extractors would also fight the underlying file shape — extractor directories are multi-file with `package.json` / `Package.swift` already declaring per-language config.
- **Hybrid** (chosen). Each registration kind matches the file shape it annotates. Front-matter for single-file queries; sidecar TOML for multi-file extractor directories.

## Consequences

- Two parsers in the binary: a ~30-line `#!`-prefixed line parser, and a TOML parser (stdlib in Go).
- The `.jq` files remain hand-runnable with naked `jq`. The `#!` lines are comments to jq.
- A contributor adding both a Node extractor and a new query learns two grammars. The asymmetry is documented in `docs/pipeline-contract.md` and surfaced in `code-audit extract --help` / `code-audit query --help`.
- Front-matter is versioned (`#! version: 1`, default 1 when absent) so the grammar can evolve without breaking older `.jq` files. Catalog manifests carry their own version field for the same reason.

**Naming note (post-#214):** the binary's command-line name is `code-audit`; this document was authored when the working name was `audit`. The substantive decisions are unchanged.
