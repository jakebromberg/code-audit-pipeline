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
| `--scan-header` | Optional. Scan the first ~30 lines of each file for "copied from"-style phrases (`copied from`, `fork of`, `based on`, `duplicate of`, `ported from` — case-insensitive). Each record gains a `header_match: { line, phrase, text } \| null` field. Drives `pipeline/queries/copied-from-header.jq`. |
| `--scan-marks` | Optional. Scan each file for `// MARK:` section markers (Swift convention). Adds `mark_count`, `line_count`, `mark_labels[]` fields to every row. Drives `pipeline/queries/mark-section-density.jq`. |

Stats land on stderr; the JSON catalog lands on stdout (or `--output`).

## Optional `--scan-marks` pass

`// MARK: <title>` (or `// MARK: - <title>`) is the Swift convention for partitioning a long file into named sections. When `--scan-marks` is set, every record carries three extra fields:

- `mark_count` — number of `// MARK:` lines in the file.
- `line_count` — total source-line count (POSIX `wc -l` semantics: a trailing `\n` does not produce an extra empty line).
- `mark_labels[]` — `{ "line": <1-indexed>, "label": "<captured title>" }` per MARK.

When the flag is unset the three fields are omitted entirely (not `null`, not `0`) — back-compatible with consumers that pre-date the field.

The Swift convention is the calibration target; the regex is language-agnostic, so the same flag is safe to run against other extensions but won't surface anything on languages that don't use `// MARK:`.

## Schema

See [`../../docs/pipeline-contract.md`](../../docs/pipeline-contract.md) under "File-hash catalog" for the full record shape.

## What it doesn't

- Doesn't fingerprint semantic equivalence — re-formatted code with reordered imports won't normalize to the same hash. For semantic dedup, see `function-catalog.mjs` + `function-duplicates.jq` (function-body-level) or the type catalog's `shape_sig` clustering.
- Doesn't follow symlinks. `readdirSync({withFileTypes:true}).isFile()` uses `lstat`, so symlinked files are skipped silently. If the repo has a symlinked source tree, only files reached by ordinary directory walk appear in the catalog.
- The `--include-tests` filter regex matches JS-family test conventions (`*.test.ts`, `*.spec.tsx`, etc). If you broaden `--extensions` to include Python or another language with a different test-naming convention (Python's `test_*.py` / `*_test.py`), those test files won't be filtered automatically — pass `--include-tests` and accept the noise, or pre-filter the directory.
