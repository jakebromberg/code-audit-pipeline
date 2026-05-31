# Reconciliation with the snapshot/diff family (#117, #141, #142)

**Status:** Accepted. Amends ADR-0001 (`meta.json` schema). Establishes the "catalog envelope" vs "cluster envelope" terminology that ADR-0003's wrapper is renamed under.

Three areas of overlap surfaced between the audit-binary redesign and the snapshot/diff work tracked under #117. This ADR records the reconciliation. (a) The audit binary keeps per-repo `.audit/` for its cache; #142's global snapshot archive renames from `~/.audit/` to `~/.audit-snapshots/`. (b) Catalog-identity metadata — `schema_version`, `extractor.*`, `fingerprint_v`, `generated_at` — lives in each catalog file's #141 envelope, not in `.audit/meta.json`. `meta.json` becomes a local-state index with a cached `envelope_summary` per catalog kind. (c) "Catalog envelope" (per-catalog-file wrapper, from #141) and "cluster envelope" (per-JSONL-row wrapper, from ADR-0003) are distinct terms and must always be qualified.

## Considered Options

### `.audit/` location

- **Rename per-repo cache to `.audit-cache/` or `.audit-state/`; #142 keeps `~/.audit/`.** Loses the per-repo dotfile-directory convention (`.git/`, `.terraform/`, `.next/`, `.vite/`). The daily-frequency surface pays the conceptual cost.
- **Hierarchical under one global** (`~/.audit/state/<repo-fingerprint>/`, `~/.audit/snapshots/<repo>/`). Breaks the cwd-rooted lookup invariant that ADR-0001 depends on; forces fingerprinting of cwd to find local state. The hidden indirection swamps the cleanness gain.
- **Rename global archive to `~/.audit-snapshots/`** (chosen). Per-repo `.audit/` retains the dotfile-dir convention. #142's design intent (location outside the working tree, retention policy, refs) is preserved entirely. Mechanical change to the default value in the #142 spec.

### Provenance metadata location

- **Keep both copies authoritative.** Drift between catalog file and `meta.json` becomes a maintenance burden with no offsetting benefit.
- **Drop the #141 envelope in favor of `meta.json`.** Catalog files become opaque when moved off the original machine — breaks #117's diff use case which assumes catalogs are self-describing across snapshot times and machines.
- **Adopt #141's envelope as authoritative; `meta.json` becomes a local-state index** (chosen). Catalog files remain self-describing. `meta.json` caches an `envelope_summary` per kind so `code-audit status` doesn't have to read every catalog to report state.

### Envelope terminology

- **Rename ADR-0003's wrapper to something other than "envelope."** Loses the protocol-design connotation (each JSONL row is a self-describing wrapper around a shape-typed payload).
- **Qualify always** (chosen). Two envelopes coexist; documentation uses the qualified form. "Envelope" alone is never used in cross-cutting docs.

## Consequences

### Amendments to existing ADRs

- **ADR-0001** is amended. Its "Consequences" specify a `meta.json` schema with `catalog_format`, `extracted_at`, `root`, `audit_version`, `extractors[<name>]`. After this ADR, the schema is:

  ```
  audit_version       string
  last_touched_at     ISO timestamp
  root                absolute path
  catalogs[<kind>]    object with:
                        path                 (string, relative to .audit/)
                        source_sha           (sha256 of the catalog file)
                        envelope_summary     (cached copy of #141 envelope's
                                              schema_version, extractor, fingerprint_v,
                                              generated_at — authority remains the catalog)
                        cli_args             (object recording how this catalog was
                                              extracted; consumed by code-audit status' suggestions)
  ```

  Fields removed from `meta.json`: `catalog_format` (now in the catalog envelope as `schema_version`), per-extractor `version` (now in the catalog envelope as `extractor.version`).

- **ADR-0003** is unchanged semantically. Its wrapper is referred to as the **cluster envelope** in all cross-cutting docs (CONTEXT.md, `pipeline-contract.md`) to distinguish from #141's **catalog envelope**.

### Authority and cache invalidation

The catalog envelope is authoritative. `meta.json`'s `envelope_summary` is a derived cache. On every `code-audit status` or `code-audit query`, the binary reads each catalog file's envelope head (the top JSON object, before `entries`) and updates the cache if it differs. If a user hand-edits or replaces a catalog file, the next invocation catches up.

### What this asks of the existing trackers

- **#142.** Default `--snapshot-dir` renames from `~/.audit/` to `~/.audit-snapshots/`. All other design decisions in #142 unchanged. Mechanical edit to the spec; the design intent (location outside the working tree, retention, symlinked refs) is preserved.

- **#141.** No change requested. Recording that the audit binary will adopt the #141 envelope as authoritative for catalog-identity metadata; #141 has a downstream consumer to consider when evolving the schema.

- **#117.** No change requested. Per-repo `.audit/` (audit-binary cache) and `~/.audit-snapshots/` (snapshot store) coexist under the parent design memo; this ADR is the boundary record.

### Future integration (out of scope)

Once the audit binary exists, #142's `pipeline/snapshot.mjs` is a natural candidate to fold in as `code-audit snapshot capture` (same router, same `manifest.toml` discovery, same lookup-order chain). #117's planned `pipeline/diff.mjs` → `code-audit diff`. Not required for reconciliation; recorded here so a reader in two years understands why two CLIs may have shipped side by side transiently.

**Naming note (post-#214):** the binary's command-line name is `code-audit`; this document was authored when the working name was `audit`. The substantive decisions are unchanged.
