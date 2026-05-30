# Use `.audit/` as the binary's local cached state

The `audit` binary stores catalogs and metadata in a hidden `.audit/` directory inside the user's repo, looked up implicitly by every subcommand. Catalogs are not passed as positional arguments to `audit query`; the binary finds them via the cwd-rooted convention. Provenance metadata in `.audit/meta.json` records the absolute root path, extraction timestamp, and extractor versions, so `audit query` can warn when the cwd no longer matches the catalog's origin and when source files have been modified since the catalog was extracted.

## Considered Options

- **Explicit positional catalog argument.** `audit query exact-duplicates catalog.json`. Honest — every command is a function of its arguments — but forces the user to type the catalog path on every invocation. The dominant friction we set out to eliminate.
- **Pipe-first composition.** `audit extract ts ../repo | audit query exact-duplicates`. Clean Unix shape but re-extracts per query or requires manual file capture for multi-query runs.
- **Implicit cached state in `.audit/`** (chosen). Matches `git`, `terraform`, `cargo`, `nix` conventions. The worst failure mode (silent wrong answer when cwd doesn't match catalog provenance) is closed by the provenance check.

## Consequences

- The binary writes to the user's repo. `.gitignore` is auto-managed (the binary appends `.audit/` on first extract if absent).
- `audit status` becomes load-bearing — it is the user's primary surface for inspecting what is cached, what is stale, and what the resolved query and extractor source paths are.
- `meta.json` schema is mandatory: `catalog_format` (integer), `extracted_at` (ISO timestamp), `root` (absolute path), `audit_version` (string), `extractors[<name>]` (object with `version`, `extracted_at`, and the original CLI flags). Versioned so future schema changes can be detected.
- Two staleness checks must be implemented: mtime-vs-source-files and root-vs-cwd. Both must be cheap; both surface in `audit status` and in non-zero exit codes from `audit status` and `audit query` on hard mismatches.
