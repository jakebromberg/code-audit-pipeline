# Binary as a router: subprocess to extractors, embedded gojq for queries

The audit binary is a router. It owns subcommand dispatch, `.audit/` state, manifest parsing, lookup-order discovery, and markdown rendering. It does not absorb the existing extractors or reimplement their AST walks. Extractors are invoked via `os/exec` against each `manifest.toml`'s `command:`. Queries are evaluated by `gojq` embedded in the binary, but the `.jq` files themselves are unchanged and remain hand-runnable with system `jq`.

## Considered Options

- **Router + embedded gojq + external extractors** (chosen). gojq pulls jq evaluation into the binary, removing one runtime dependency for the binary's own path. Extractors stay external because each is tied to a language-native AST library Go can't substitute for.
- **Pure router (shell out to system `jq` as well).** Keeps `jq` as a system dependency. The embedded-gojq win is real and worth taking — gojq is a single Go import.
- **Full reimplementation.** Would absorb extractors into the binary. Impossible without replacing each extractor's host AST library (TypeScript compiler API, SwiftSyntax, planned Python `ast`). The project's principle ("use the language's compiler API directly") forbids this.

## Consequences

- gojq compatibility is a one-time verification step before PR 3 (the binary skeleton). Per-query fallback to system `jq` via `#! engine: jq` covers any divergences.
- Subprocess spawn cost per extractor invocation is acceptable at current scale (small catalogs, ~22 queries). A future at-scale need would revisit this independently — see `docs/future-directions.md` §3 for the substrate evolution path.
- The "deterministic extraction, agentic synthesis" identity is preserved end-to-end: extractors are the sole structural enumeration step, run in their host languages, and the binary's role is composition rather than analysis.
- A degraded mode exists for users without Go-toolchain expertise: every `.jq` query remains usable via naked `jq`, and every extractor remains usable via direct invocation. The binary is a convenience layer, not a replacement.
