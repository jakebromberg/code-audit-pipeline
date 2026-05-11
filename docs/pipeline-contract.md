# Pipeline contract

Every extractor in `extractors/<language>/` emits the same JSON shape so cluster queries don't care which language they're operating on. This is the schema.

## Catalog shape

The catalog is a single JSON array. Each entry describes one declared type-like construct.

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

## CLI contract

Every extractor:

```
extractor --root <path> [--shared <path>] [--touched <json-file>] [--output <path>] [--include-tests]
```

Defaults: `--output` writes to stdout. Summary stats (file counts, kind histogram, error count) go to stderr.

Exit code: `0` if at least one file was successfully indexed, `1` if no files could be parsed.
