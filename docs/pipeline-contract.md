# Pipeline contract

Every extractor in `extractors/<language>/` emits the same JSON shape so cluster queries don't care which language they're operating on. This is the schema.

The substrate has three catalog kinds today, each in its own JSON file:

- `type-catalog.json` — type / interface / Zod / Drizzle declarations (shape-of-named-members).
- `function-catalog.json` — function / method / arrow-function declarations (body-of-named-callable).
- `file-hashes.json` — file-level content hashes (raw and whitespace-normalized).

Each section below specifies one. Queries in `pipeline/queries/` consume one specific catalog kind and document which.

## Type catalog (`type-catalog.json`)

The type catalog is a single JSON array. Each entry describes one declared type-like construct.

```jsonc
[
  {
    "name": "FlowsheetEntry",            // identifier as declared
    "kind": "interface",                  // see "Kinds" below
    "package": "main",                    // which root this came from
    "file": "src/models/flowsheet.ts",   // path relative to that root
    "line": 42,                           // 1-indexed
    "exported": true,                     // true if exported from the file
    "generated": false,                   // true if .d.ts or under generated/

    "fields": [                           // sorted "name:type" list, or null
      "album_title:string | null",
      "artist_name:string | null",
      "id:number"
    ],
    "shape_sig": "album_title:string | null|artist_name:string | null|id:number",  // fields.join("|").lower

    "touched_in_window": false,           // true if file is in --touched JSON list

    // Optional, kind-dependent:
    "generics": "T,U",                    // type-parameter names if generic
    "type_text": "Pick<X, 'a' | 'b'>",   // for non-object type aliases
    "type_sig": "pick<x, 'a' | 'b'>",    // normalized type_text for clustering
    "infer_ref": { "kind": "InferSelectModel", "table": "user" }, // ORM-derived types
    "db_table_name": "user_accounts"      // for ORM table declarations
  }
]
```

## Kinds

| Kind | Source construct (TypeScript) | Source construct (other languages) |
|---|---|---|
| `interface` | `interface X { … }` | Python: `Protocol`; Go: `type X interface { … }` |
| `type-alias-object` | `type X = { … }` | Python: `TypedDict`; Go: `type X struct { … }` |
| `type-alias-union` | `type X = A \| B \| C` | Python: `Union[…]`; Rust: enum variants |
| `type-alias-intersection` | `type X = A & B` | (rare elsewhere) |
| `type-alias-infer-model` | `type X = InferSelectModel<typeof T>` | SQLAlchemy: `Mapped[…]`; Django: model classes |
| `type-alias-other` | other utility types | mapped/conditional types |
| `zod-object` | `const X = z.object({ … })` | Python: Pydantic `BaseModel`; Go: validator tags |
| `drizzle-table` | `pgTable("…", { … })` or `wxyc_schema.table(…)` | Python: SQLAlchemy `Table(…)`; Go: GORM struct |

Languages without an exact analog can extend with their own kind values — keep prefix conventions (`type-alias-*`, etc.) so queries can pattern-match.

## Required fields

- `name`, `kind`, `package`, `file`, `line`

## Required-when-applicable

- `fields` + `shape_sig` for any "shape-of-named-members" construct (interface, struct, type literal, Pydantic model, etc.). Without these the cluster queries can't compare it.
- `type_text` + `type_sig` for non-object type aliases. Without these the InferModel-style derived-type clustering won't work.

## Optional but useful

- `exported`, `generated`, `touched_in_window`, `generics`, `infer_ref`, `db_table_name`

### Intersection-type resolution

`type X = A & B & { c: number }` entries (kind `type-alias-intersection`) emit `fields` populated by unioning their operands' field sets, when all operands resolve. A second pass walks the catalog up to 5 iterations to handle transitive cases (`Y = X & C`). Resolved entries carry:

- `resolved_from: "intersection"` — marker so downstream queries can include or exclude these synthetically-resolved shapes.
- `operands: ["A", "B", "<literal>"]` — names of the type references and `"<literal>"` placeholders for inline literals. Diagnostic trace.

If at least one operand can't be resolved (utility types like `Pick<X, 'a'>`, conditional types, or references whose declaration was outside the scanned roots), the entry stays at `fields: null` and gains:

- `unresolved: true`
- `unresolved_operands: ["Pick<X, 'a'>", …]` — the operands that defeated resolution.

This is additive: intersection types that resolve get treated like normal shape-bearing constructs by `subset-pairs.jq`, `near-duplicates.jq`, `exact-duplicates.jq`, etc. Intersection entries that fail to resolve stay invisible to those queries, as before.

**Order-dependent conflict resolution.** When two operands declare the same field name with different types (`type X = { a: string } & { a: number }`), the extractor keeps the FIRST occurrence in declaration order. TypeScript's true semantics would intersect (`string & number = never`); the substrate flattens to the first binding so `shape_sig` stays deterministic. This is a clustering tool, not a type-checker — if you need conflict detection, compare operand field-type pairs separately, or wait for the dedicated check that will accompany #5 (substrate-emitted cluster_ids).

## Conventions

### Field encoding

Each field in `fields` is `"name:type"`, where:

- `name` includes `?` if optional (e.g., `email?:string`).
- `type` is the raw type text, **normalized** (whitespace collapsed to single spaces, trimmed).
- The array is sorted alphabetically by full string. This makes `shape_sig` deterministic regardless of declaration order.

### `shape_sig` computation

```
shape_sig = fields.sorted().join("|").lower()
```

Lowercasing means `Foo` and `foo` collide. That's intentional — case differences are usually not semantic.

### Path-relative-to-which-root?

`file` is relative to the root that produced it. The `package` field tells you which root. For example, with `--root /a/b/main --shared /a/b/shared`:

- A file at `/a/b/main/src/foo.ts` → `package: "main"`, `file: "src/foo.ts"`
- A file at `/a/b/shared/src/bar.ts` → `package: "shared"`, `file: "src/bar.ts"`

Cluster queries that compare across packages always include the `package` field in their grouping or output.

### What to skip

Default skip-list (extractors may extend):

- `node_modules/`, `dist/`, `build/`, `coverage/`, `tests/`
- **Any directory beginning with `.`** — `.git/`, `.next/`, `.claude/`, `.cursor/`, `.idea/`, `.vscode/`. These typically hold IDE/agent state or git worktree clones; descending into them inflates the catalog with near-duplicate copies of the same repo.
- Files matching `*.test.*`, `*.spec.*`

Use `--include-tests` to keep test directories in scope when auditing test-fixture duplication.

## Function catalog (`function-catalog.json`)

The function catalog is a single JSON array. Each entry describes one declared function-like construct (function declaration, class method, arrow function or function expression assigned to a named binding).

```jsonc
[
  {
    "name": "betterAuthSessionToAuthenticationData",
    "kind": "function",                          // function | method | arrow-function | function-expression
    "package": "main",
    "file": "lib/features/authentication/utilities.ts",
    "line": 89,
    "generated": false,
    "exported": true,
    "async": false,
    "param_count": 1,
    "param_names": ["session"],
    "body_line_count": 48,                       // after normalization (comments stripped, blank lines dropped)
    "body_length": 1500,                         // chars of normalized body
    "body_hash": "<sha256 of normalized body>",  // exact-equality clustering
    "body_lines": [                              // sorted-unique normalized non-empty lines
      "const authority = mapRoleToAuthorization(roleToMap);",
      "const token = session.session?.token;",
      "…"
    ]
  }
]
```

**Method-name qualification.** For class methods, `name` is `ClassName.methodName`. For methods on anonymous classes, just the method name.

**Body normalization.** Comments (line `//` and block `/* */`) are stripped, internal whitespace runs collapsed to single spaces, each line trimmed, blank lines dropped. `body_hash` is sha256 of `body_lines.join('\n')`. `body_lines` is also de-duplicated and sorted, so it can serve as the input set for Jaccard pairwise comparison without further work.

**Skip rules.** Functions with `< --min-body-lines` (default 3) normalized lines are not emitted — one-liners and trivial stubs aren't useful duplication signal. Generated files (`*.d.ts`, `generated/`) are marked `generated: true` like the type catalog.

Used by `pipeline/queries/function-duplicates.jq`, which emits two sections: exact body-hash clusters (size ≥ 2) and pairwise Jaccard near-duplicates on `body_lines` above a threshold (default 0.7).

## File-hash catalog (`file-hashes.json`)

The file-hash catalog is a single JSON array. Each entry describes one source file:

```jsonc
[
  {
    "package": "main",
    "file": "lib/features/playlist-search/utils.ts",
    "generated": false,
    "size_bytes": 994,                                  // raw size
    "size_normalized": 994,                             // after CRLF→LF, trailing-whitespace strip, trailing blank lines dropped
    "sha256": "<raw bytes sha256>",
    "sha256_normalized": "<normalized sha256>"
  }
]
```

**Normalization.** `CRLF` → `LF`, trailing whitespace stripped per line, trailing blank lines dropped. `sha256_normalized` catches "same file, editor / line-ending drift" pairs that raw `sha256` would miss.

**Skip rules.** Same dir skip-list as the type extractor (`.dotdirs`, `node_modules`, `dist`, `build`, `coverage`, `tests` unless `--include-tests`). Extension filter is configurable via `--extensions` (default `ts,tsx,mts,cts`).

Used by `pipeline/queries/file-duplicates.jq`, which emits two sections: exact-byte clusters and whitespace-normalized-only clusters (files identical after normalization but not byte-equal).

## CLI contract

Every extractor:

```
extractor --root <path> [--shared <path>] [--touched <json-file>] [--output <path>] [--include-tests]
```

Defaults: `--output` writes to stdout. Summary stats (file counts, kind histogram, error count) go to stderr.

Exit code: `0` if at least one file was successfully indexed, `1` if no files could be parsed.
