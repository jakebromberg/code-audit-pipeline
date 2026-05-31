# Bundle queries, leave extractors external, discover via lookup order

The Go binary embeds `pipeline/queries/*.jq` via Go's `embed` package. Extractors are not bundled — each has heavyweight language-specific dependencies (`npm install`, `swift build`, future `pip install`) the binary cannot meaningfully package. Both queries and extractors are discovered via a lookup-order chain that prefers explicit flags, then cwd-relative paths, then `$AUDIT_HOME`, then a fallback: bundled queries (always present) or `~/.config/audit/` for extractors (populated by `code-audit init`). `code-audit init` clones (or extracts a release tarball of) the project source into `~/.config/audit/` to bootstrap extractor discovery on a fresh install.

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
