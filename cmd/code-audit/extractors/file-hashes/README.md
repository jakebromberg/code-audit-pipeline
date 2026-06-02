# File-hashes extractor

Walks a repo and emits a JSON record per source file with two SHA-256 hashes:

- `sha256` — raw bytes
- `sha256_normalized` — after `CRLF`→`LF`, trailing-whitespace strip, trailing blank lines dropped

Two hashes let `pipeline/queries/file-duplicates.jq` distinguish byte-equal copies from "same file, different line endings or editor-added trailing whitespace" pairs without the agent having to read both files.

No external dependencies — pure Node stdlib (`crypto`, `fs`).

## Run

```bash
node file-hashes.mjs --root /path/to/repo > file-hashes.json

# Cross-package, custom extension set, include test files
node file-hashes.mjs \
  --root /path/to/main-repo \
  --shared /path/to/shared-repo \
  --extensions ts,tsx,mts,cts,js,jsx \
  --include-tests \
  --output file-hashes.json
```

| Flag | Meaning |
|---|---|
| `--root` | Required. Root of the codebase to scan. |
| `--shared` | Optional. Secondary package root. Tagged as `package="shared"`. |
| `--output` | Optional. Write JSON to this path. Default: stdout. |
| `--extensions` | Optional. Comma-separated list of extensions to hash (no dots). Default `ts,tsx,mts,cts`. |
| `--include-tests` | Optional. Don't skip `tests/`, `*.test.*`, `*.spec.*`. |

Stats land on stderr; the JSON catalog lands on stdout (or `--output`).

## Schema

See [`../../docs/pipeline-contract.md`](../../docs/pipeline-contract.md) under "File-hash catalog" for the full record shape.

## What it doesn't

- Doesn't fingerprint semantic equivalence — re-formatted code with reordered imports won't normalize to the same hash. For semantic dedup, see `function-catalog.mjs` + `function-duplicates.jq` (function-body-level) or the type catalog's `shape_sig` clustering.
- Doesn't follow symlinks. `readdirSync({withFileTypes:true}).isFile()` uses `lstat`, so symlinked files are skipped silently. If the repo has a symlinked source tree, only files reached by ordinary directory walk appear in the catalog.
- The `--include-tests` filter regex matches JS-family test conventions (`*.test.ts`, `*.spec.tsx`, etc). If you broaden `--extensions` to include Python or another language with a different test-naming convention (Python's `test_*.py` / `*_test.py`), those test files won't be filtered automatically — pass `--include-tests` and accept the noise, or pre-filter the directory.
