# Bundle queries, leave extractor runtime external, discover via lookup order

> Update (per [ADR-0008](0008-extractor-embedding-and-auto-bootstrap.md)): **extractor *source* is now embedded too** — only the language-specific *runtime* (Node, Swift toolchain, future Python) stays external. The discovery chain (tiers 1–4) is unchanged; ADR-0008 specifies the auto-extract behaviour that fires when tier 4 resolves and is missing or stale. Read this ADR for the chain; read ADR-0008 for what happens at tier 4 on a fresh brew install.

The Go binary embeds `pipeline/queries/*.jq` via Go's `embed` package, plus the extractor source tree under `extractors/<lang>/` (per ADR-0008). The extractor *runtime* — `npm install`, `swift build`, future `pip install` — stays external; the binary executes a manifest-declared `[runtime].bootstrap` argv (e.g. `["npm", "install"]`) automatically when laying down source. Both queries and extractors are discovered via a lookup-order chain that prefers explicit flags, then cwd-relative paths, then `$AUDIT_HOME`, then a fallback: bundled queries (always present) or `~/.config/audit/` for extractors (auto-populated from the embedded source on first `code-audit extract`, or explicitly via `code-audit init`).

## Considered Options

- **Bundle everything.** Workable for Node extractors (write sources to temp, exec via `node`), painful for Swift (would require shipping ~10MB of pre-compiled binary per platform inside the audit binary), wrong for future Python (pip dependencies cannot be embedded). Inflates the artifact for partial benefit.
- **Bundle nothing.** Forces users to clone the repo for every install. The dominant "I have a catalog, show me clusters" path requires no extractors, only queries — bundling queries is essentially free at ~50KB total and pays back immediately for evaluators trying the tool against a pre-existing catalog.
- **Bundle queries, leave extractors external, lookup-order discovery** (chosen).

## Consequences

- Three personas share one discovery model: evaluators get bundled queries on `brew install`; daily users get `AUDIT_HOME` set by `code-audit init`; contributors get cwd-relative resolution that picks up local edits without rebuild.
- `code-audit status` surfaces the resolved query and extractor source paths so the lookup order is never invisible.
- `code-audit init` is non-destructive on re-run; it nukes-and-re-clones the canonical paths but warns loudly when locally-modified files exist under `~/.config/audit/`. Convention borrowed from `rustup`, `nvm`.
- Bundled queries are pinned to the binary's release version. Users wanting newer queries between binary releases run `code-audit init --upgrade`; the resulting `$AUDIT_HOME/pipeline/queries/` then wins over the embedded fallback via the lookup order.
- The `--queries-dir` and `--extractors-dir` flags exist for explicit override (CI, forks, alternative repos). They take precedence over every other source.

**Naming note (post-#214):** the binary's command-line name is `code-audit`; this document was authored when the working name was `audit`. The substantive decisions are unchanged.
