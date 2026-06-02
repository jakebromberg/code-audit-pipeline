#!/usr/bin/env bash
# resolve-touched.sh — resolve the set of repo-relative paths a PR touches,
# filter to the subset each detected language's extractor recognizes, and
# emit a JSON array on stdout (or --output <path>).
#
# Inputs come from the workflow's runtime context, not flags, to keep the
# script callable from the composite without flag-plumbing every audit-core
# detail. Required env:
#   PR_NUMBER          — pull_request.number (or empty to read TOUCHED_RAW directly)
#   LANGUAGES_DETECTED — comma-separated list from audit-core's languages-detected output
#   EXTRACTORS_DIR     — absolute path to the pipeline's extractors/ tree
#   INCLUDE_TESTS      — "true" forwards --include-tests to language walkers
# Optional env:
#   TOUCHED_RAW        — newline-separated list of paths to filter (testing/fixture path).
#                        When set, gh pr view is skipped entirely. Useful for unit-testing
#                        the script and for the selftest's fixture mode.
#   OUTPUT_PATH        — write JSON to this path instead of stdout.
#   GH_TOKEN / GITHUB_TOKEN — passed through to `gh` (set by the workflow).
#
# Per-language resolution:
#   typescript  → extractors/typescript/type-catalog.mjs --list-relevant (canonical walker)
#   swift       → extension-glob fallback (.swift), drops .build/ Pods/ DerivedData/
#   go          → extension-glob fallback (.go), drops vendor/
#   file-hashes → no filter (every file is in the catalog)
#   <other>     → extension-glob fallback per a per-language table below; document the gap
#                 in docs/integrations/github-action.md and file a follow-up to add
#                 --list-relevant on that language's extractor.
#
# Output: a JSON array of paths, deduplicated. Empty array when the PR
# touches no extractor-recognized files (the composite's downstream
# code-audit report --touched call treats this as "no structural impact").

set -Eeuo pipefail

OUTPUT_PATH="${OUTPUT_PATH:-}"
PR_NUMBER="${PR_NUMBER:-}"
LANGUAGES_DETECTED="${LANGUAGES_DETECTED:-}"
EXTRACTORS_DIR="${EXTRACTORS_DIR:-}"
INCLUDE_TESTS="${INCLUDE_TESTS:-false}"
TOUCHED_RAW="${TOUCHED_RAW:-}"

if [ -z "$EXTRACTORS_DIR" ]; then
  echo "resolve-touched: EXTRACTORS_DIR is required (path to the pipeline's extractors/)" >&2
  exit 2
fi
if [ ! -d "$EXTRACTORS_DIR" ]; then
  echo "resolve-touched: EXTRACTORS_DIR does not exist: $EXTRACTORS_DIR" >&2
  exit 2
fi

# Resolve the raw touched-file list. Fixture path wins when TOUCHED_RAW is
# explicitly set; otherwise fall back to gh pr view. This lets the selftest
# inject a deterministic input without standing up a real PR.
raw_file="$(mktemp)"
trap 'rm -f "$raw_file" "$filtered_acc"' EXIT
filtered_acc="$(mktemp)"
: > "$filtered_acc"

if [ -n "$TOUCHED_RAW" ]; then
  printf '%s\n' "$TOUCHED_RAW" > "$raw_file"
elif [ -n "$PR_NUMBER" ]; then
  # `gh pr view --json files --jq` is the canonical newline-separated source
  # of touched repo-relative paths. The `--paginate` flag isn't needed for
  # the files list (it's not paginated on GitHub's API), and `--repo` is
  # picked up from $GITHUB_REPOSITORY when running inside a workflow.
  gh pr view "$PR_NUMBER" --json files --jq '.files[].path' > "$raw_file"
else
  echo "resolve-touched: neither PR_NUMBER nor TOUCHED_RAW is set; cannot resolve touched files" >&2
  exit 2
fi

# Strip blank lines once up front. Every per-language filter inherits this.
raw_clean="$(mktemp)"
trap 'rm -f "$raw_file" "$raw_clean" "$filtered_acc"' EXIT
grep -v '^[[:space:]]*$' "$raw_file" > "$raw_clean" || true

raw_count="$(wc -l < "$raw_clean" | tr -d ' ')"
echo "resolve-touched: $raw_count raw path(s) from PR" >&2

if [ "$raw_count" = "0" ]; then
  # Empty PR (e.g. all changes were file-mode bits or empty deletes). Emit
  # an empty JSON array — code-audit report --touched treats this as "no
  # cluster has any touched member" and falls through to the "no structural
  # impact" body.
  out='[]'
  if [ -n "$OUTPUT_PATH" ]; then
    printf '%s\n' "$out" > "$OUTPUT_PATH"
  else
    printf '%s\n' "$out"
  fi
  exit 0
fi

# Per-language filter table. Each function reads stdin, writes the kept
# subset to stdout, exits 0. The dispatcher below routes paths through the
# appropriate filter and appends results to $filtered_acc.

# TypeScript: canonical walker via the extractor's --list-relevant mode.
# This is the only filter that perfectly matches what the extractor would
# index — SKIP_DIRS, EXT_RE, TEST_DIRS/TEST_FILE_RE all enforced by the
# extractor itself. See extractors/typescript/_lib/walk-predicate.mjs.
filter_typescript() {
  local ts_extractor="$EXTRACTORS_DIR/typescript/type-catalog.mjs"
  if [ ! -f "$ts_extractor" ]; then
    echo "resolve-touched: typescript extractor missing at $ts_extractor; skipping language" >&2
    return 0
  fi
  local args=()
  if [ "$INCLUDE_TESTS" = "true" ]; then
    args+=( --include-tests )
  fi
  # The extractor's --list-relevant mode reads newline-separated paths on
  # stdin and emits the kept subset on stdout. Exit codes:
  #   0 — normal (may emit empty stdout if nothing matched)
  #   non-zero — the extractor itself failed; surface for diagnosis but
  #              don't fail the action (other languages may still resolve).
  if ! node "$ts_extractor" --list-relevant "${args[@]}"; then
    echo "resolve-touched: typescript --list-relevant failed; results may be incomplete" >&2
  fi
}

# Extension-glob fallback. Drops common build/cache dirs that the language's
# extractor would also drop, but is NOT a substitute for the real walker.
# Documented as a known gap in docs/integrations/github-action.md.
filter_extglob() {
  local ext_pattern="$1"
  local skip_pattern="$2"
  # ext_pattern: anchored extension regex (e.g. '\.swift$' or '\.go$')
  # skip_pattern: leading-segment regex of dirs to drop (e.g. '^(\.build|Pods)/')
  if [ -z "$skip_pattern" ]; then
    grep -E "$ext_pattern" || true
  else
    grep -E "$ext_pattern" | grep -Ev "$skip_pattern" || true
  fi
}

filter_swift() {
  # .build/ — SwiftPM build dir. Pods/ — CocoaPods. DerivedData/ — Xcode.
  # .swiftpm/ — SwiftPM cache. These mirror the SwiftSyntax extractor's
  # SKIP_DIRS roughly; canonical walker via --list-relevant on the Swift
  # extractor is a follow-up.
  filter_extglob '\.swift$' '^(\.build|\.swiftpm|Pods|DerivedData|build|node_modules)/'
}

filter_go() {
  filter_extglob '\.go$' '^(vendor|node_modules)/'
}

filter_python() {
  filter_extglob '\.py$' '^(\.venv|venv|__pycache__|\.tox|build|dist|node_modules)/'
}

filter_rust() {
  filter_extglob '\.rs$' '^(target|node_modules)/'
}

# file-hashes catalogs every file under the audit root. The catalog rows'
# `.file` field is set to the repo-relative path of each indexed file, so
# any touched path that survives basic blank-line cleanup is a candidate
# match. We do NOT extension-filter here — the file-hashes extractor
# itself decides what to index (JSON, TOML, YAML, MD, etc.) and an
# over-inclusive touched set just means more potential matches, never
# false-positive impacts (the touched-filter is an intersection with
# catalog member paths).
filter_file_hashes() {
  cat
}

# Comma → space split with empty-language tolerance.
IFS=',' read -ra langs <<< "$LANGUAGES_DETECTED"
if [ ${#langs[@]} -eq 0 ] || { [ ${#langs[@]} -eq 1 ] && [ -z "${langs[0]:-}" ]; }; then
  echo "resolve-touched: no languages detected; emitting empty touched set" >&2
  out='[]'
  if [ -n "$OUTPUT_PATH" ]; then
    printf '%s\n' "$out" > "$OUTPUT_PATH"
  else
    printf '%s\n' "$out"
  fi
  exit 0
fi

# Always include the file-hashes pass — the composite runs the file-hashes
# extractor by default (include-file-hashes input is true by default in
# audit-core), so the catalog will contain file-hashes rows whose .file
# entries may match touched paths even when no language extractor recognized
# the file (e.g. an audit window where every touched file is a YAML config).
filter_file_hashes < "$raw_clean" >> "$filtered_acc"

for lang in "${langs[@]}"; do
  lang="$(echo "$lang" | tr -d '[:space:]')"
  [ -z "$lang" ] && continue
  case "$lang" in
    typescript) filter_typescript < "$raw_clean" >> "$filtered_acc" ;;
    swift)      filter_swift      < "$raw_clean" >> "$filtered_acc" ;;
    go)         filter_go         < "$raw_clean" >> "$filtered_acc" ;;
    python)     filter_python     < "$raw_clean" >> "$filtered_acc" ;;
    rust)       filter_rust       < "$raw_clean" >> "$filtered_acc" ;;
    file-hashes)
      # file-hashes was always-on above; skip the duplicate pass.
      :
      ;;
    *)
      echo "resolve-touched: no walker for language '$lang'; falling back to passthrough" >&2
      cat < "$raw_clean" >> "$filtered_acc"
      ;;
  esac
done

# Deduplicate (stable order) and JSON-encode. `jq -R . | jq -s .` is the
# canonical recipe for "newline-separated stdin → JSON array of strings"
# with proper escaping of any embedded quotes / backslashes.
filtered_count="$(awk '!seen[$0]++' "$filtered_acc" | grep -cv '^[[:space:]]*$' || true)"
echo "resolve-touched: $filtered_count filtered path(s) after per-language walkers" >&2

json="$(awk '!seen[$0]++' "$filtered_acc" | grep -v '^[[:space:]]*$' | jq -R . | jq -sc .)"
# Guard against the all-stripped-to-empty case where jq emits null on empty
# input. The downstream `code-audit report --touched` validates this as a
# JSON array, so substitute an empty-array literal when needed.
if [ -z "$json" ] || [ "$json" = "null" ]; then
  json='[]'
fi

if [ -n "$OUTPUT_PATH" ]; then
  printf '%s\n' "$json" > "$OUTPUT_PATH"
  echo "resolve-touched: wrote $OUTPUT_PATH" >&2
else
  printf '%s\n' "$json"
fi
