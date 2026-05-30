# TypeScript extractors

Two complementary extractors live here:

- `type-catalog.mjs` — type/interface/Zod/Drizzle declarations (one record per declared shape).
- `function-catalog.mjs` — function/method/arrow-function declarations (one record per function with a normalized body hash and a body-line set for Jaccard near-duplicate detection).

Both follow the same `--root` / `--shared` / `--output` CLI shape and emit JSON arrays.

## type-catalog.mjs

Walks a TypeScript repo and emits a JSON catalog of every type / interface / Zod schema / Drizzle table declared.

## Install

```bash
npm install
```

Pulls in `typescript` only. The script uses the TypeScript compiler API directly — no `ts-morph`, no `ast-grep`.

## Run

```bash
node type-catalog.mjs --root /path/to/repo
```

Common invocations:

```bash
# Audit one repo, scan everything, write to stdout
node type-catalog.mjs --root /path/to/repo > catalog.json

# Compare against a sibling "canonical types" package
node type-catalog.mjs \
  --root /path/to/main-repo \
  --shared /path/to/shared-types-repo \
  --output catalog.json

# Only mark a subset of files as "touched in this audit window"
node type-catalog.mjs \
  --root /path/to/repo \
  --touched ./candidates.json \
  --output catalog.json

# Also emit sibling files.json (per-file import edges) for the
# cross-package-backward-imports.jq layering check
node type-catalog.mjs \
  --root /path/to/main \
  --shared /path/to/shared \
  --output catalog.json \
  --emit-files files.json
```

Stats land on stderr; the catalog JSON lands on stdout (or `--output`).

## What it picks up

| Source construct | `kind` value |
|---|---|
| `interface X { … }` | `interface` |
| `type X = { … }` | `type-alias-object` |
| `type X = A \| B \| C` | `type-alias-union` |
| `type X = A & B` | `type-alias-intersection` |
| `type X = InferSelectModel<typeof T>` / `InferInsertModel` | `type-alias-infer-model` |
| other type aliases | `type-alias-other` |
| `const X = z.object({ … })` | `zod-object` |
| `const X = pgTable("…", { … })` or `someSchema.table("…", { … })` | `drizzle-table` |

For each, the script extracts a sorted `name:type` field list and computes `shape_sig` for clustering. See [`../../docs/pipeline-contract.md`](../../docs/pipeline-contract.md) for the full record schema.

## What it doesn't (yet)

- Generic-instantiation resolution. `Pick<User, 'id'>` is recorded as a `type-alias-other` with its `type_text`, not expanded into its field set.
- Computed property keys. Only literal property names are captured.
- Import-graph type identity. `--emit-files` captures the file-level import edges (resolved against `--root` / `--shared`), but doesn't tell you whether `Foo` here is the same `Foo` declared by an import target — type-identity unification is a separate pass.
- `tsconfig.json` `paths` aliases in the `--emit-files` resolver — v1 handles relative paths only.
- JSDoc / TSDoc. Comments are ignored.

These are all fine for type-duplication auditing, but if you want a richer surface — e.g., to feed a "missed imports" detector — wire in a real `ts.Program` with type-checker calls.

## Performance

Pure AST walk, no type checking. ~5000 lines/sec on typical hardware. The WXYC audit (~300 source files across two packages) finishes in under 2 seconds.

## function-catalog.mjs

Walks the same TypeScript repos and emits one JSON record per function-like construct: `function` declarations, class `method` declarations, and arrow / function expressions assigned to named bindings.

```bash
node function-catalog.mjs --root /path/to/repo > function-catalog.json
node function-catalog.mjs --root /path/to/main --shared /path/to/shared --output function-catalog.json
```

Each record carries:

| Field | Meaning |
|---|---|
| `name`, `package`, `file`, `line`, `exported`, `generated` | Same conventions as `type-catalog.mjs` |
| `kind` | `function`, `method`, `arrow-function`, or `function-expression` |
| `async` | `true` if declared `async` |
| `param_count`, `param_names` | Function arity and parameter identifiers |
| `body_line_count`, `body_length` | After comment + whitespace normalization |
| `body_hash` | SHA-256 of the normalized body (comments stripped, lines trimmed, blank lines dropped) |
| `body_lines` | Sorted-unique normalized non-empty non-comment lines — the input set for Jaccard near-duplicate queries |

Used by `pipeline/queries/function-duplicates.jq`, which emits two sections: exact body-hash clusters and pairwise Jaccard near-duplicates (default threshold 0.7, override with `--argjson threshold 0.6` etc).

Skip rules: same dotdir + `node_modules` / `dist` / `build` / `coverage` skip-list as `type-catalog.mjs`, plus `tests/` and `*.test.ts` / `*.spec.ts` files skipped unless `--include-tests` is passed. (`type-catalog.mjs` no longer has `--include-tests`: it always extracts test files and tags every row with an `is_test` flag instead — aligning function-catalog with that model is a follow-up.) Functions with `< --min-body-lines` (default 3) normalized lines are skipped — one-liners and trivial stubs aren't useful duplication signal.
