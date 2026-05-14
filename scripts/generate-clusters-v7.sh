#!/usr/bin/env bash
#
# generate-clusters-v7.sh — extract catalogs + run V6/V7 queries, write JSONL.
#
# Drives the V7 refactor-recommendation experiment's Phase C cluster-generation
# step (plan §4.3): assembles the type/function/file-hash/package-graph catalogs
# from the served plant tree, then runs each cluster query in JSONL mode with
# its canonical args, depositing results under
#   $OUT_DIR/clusters-s1/  — V6 queries only (S1 condition)
#   $OUT_DIR/clusters-s2/  — V6 + V7-new queries (S2 condition)
#
# Inputs (env overrides):
#   SERVED_TREE   absolute path to the served plant tree
#                 default: /tmp/wxyc-audit/plants-v7
#   OUT_DIR       output root
#                 default: <repo>/experiments/v7-refactor-recommendation
#
# Idempotent: existing catalogs/ and clusters-s{1,2}/ are wiped and rewritten.
# Catalog and cluster outputs are gitignored per CLAUDE.md project notes.
#
# V6/V7 query inventory:
#   V6 queries (11): exact-duplicates, file-duplicates, function-duplicates,
#     cross-package-shadows{,_any}, cross-package-shape-near-duplicates{,_any},
#     near-duplicates{,_any}, name-collisions, subset-pairs.
#   V7-new queries (5, per Phase B PR 0dc2747): pat-candidates,
#     protocol-inheritance-candidates, generic-struct-candidates,
#     generic-function-candidates, default-impl-candidates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SERVED_TREE="${SERVED_TREE:-/tmp/wxyc-audit/plants-v7}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/experiments/v7-refactor-recommendation}"

SWIFT_BIN="$REPO_ROOT/extractors/swift/.build/release/swift-catalog"
FILE_HASHES_BIN="$REPO_ROOT/extractors/file-hashes/file-hashes.mjs"
QUERIES_DIR="$REPO_ROOT/pipeline/queries"

CATALOGS_DIR="$OUT_DIR/catalogs"
S1_DIR="$OUT_DIR/clusters-s1"
S2_DIR="$OUT_DIR/clusters-s2"

# --- Validate inputs ------------------------------------------------------

[[ -d "$SERVED_TREE" ]] || { echo "ERROR: SERVED_TREE not found: $SERVED_TREE" >&2; exit 1; }
[[ -d "$QUERIES_DIR" ]] || { echo "ERROR: queries dir missing: $QUERIES_DIR" >&2; exit 1; }
[[ -f "$FILE_HASHES_BIN" ]] || { echo "ERROR: file-hashes script missing: $FILE_HASHES_BIN" >&2; exit 1; }

if [[ ! -x "$SWIFT_BIN" ]]; then
  echo "Building swift-catalog (release)..." >&2
  ( cd "$REPO_ROOT/extractors/swift" && swift build -c release ) || {
    echo "ERROR: swift build failed" >&2
    exit 1
  }
fi

# --- Prepare output dirs --------------------------------------------------

rm -rf "$CATALOGS_DIR" "$S1_DIR" "$S2_DIR"
mkdir -p "$CATALOGS_DIR" "$S1_DIR" "$S2_DIR"

# --- Extract catalogs ------------------------------------------------------

echo "Extracting type catalog..." >&2
"$SWIFT_BIN" type --root "$SERVED_TREE" --include-tests \
  --output "$CATALOGS_DIR/type-catalog.json" 2>"$CATALOGS_DIR/type.stderr"

echo "Extracting function catalog..." >&2
"$SWIFT_BIN" func --root "$SERVED_TREE" --include-tests \
  --output "$CATALOGS_DIR/function-catalog.json" 2>"$CATALOGS_DIR/func.stderr"

echo "Extracting package graph..." >&2
"$SWIFT_BIN" package-graph --root "$SERVED_TREE" \
  --output "$CATALOGS_DIR/package-graph.json" 2>"$CATALOGS_DIR/package-graph.stderr" || \
  echo "  (package-graph extraction exit non-zero; continuing — query set doesn't depend on it)" >&2

echo "Extracting file hashes..." >&2
# `--extensions swift` enables the file-hashes script's Swift mode, which
# applies the same path-filtering heuristics as swift-catalog (Tests/ skip,
# .build/ skip, etc.).
node "$FILE_HASHES_BIN" --root "$SERVED_TREE" --extensions swift --include-tests \
  --output "$CATALOGS_DIR/file-hashes.json" 2>"$CATALOGS_DIR/file-hashes.stderr"

TYPE_CAT="$CATALOGS_DIR/type-catalog.json"
FUNC_CAT="$CATALOGS_DIR/function-catalog.json"
FILE_CAT="$CATALOGS_DIR/file-hashes.json"

# --- Run queries ----------------------------------------------------------
#
# Each query call:
#   - writes JSONL to $S1_DIR/<q>.jsonl, $S2_DIR/<q>.jsonl, or both
#   - exit non-zero is tolerated only if the query genuinely produces no rows
#     (jq always exits 0 on a valid filter, so failure means a real error)

run_query_both() {
  local q="$1"; local input="$2"; shift 2
  local args=("$@")
  echo "  running $q (both)..." >&2
  OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r "${args[@]}" -f "$QUERIES_DIR/$q.jq" "$input" \
    > "$S1_DIR/$q.jsonl"
  cp "$S1_DIR/$q.jsonl" "$S2_DIR/$q.jsonl"
}

run_query_s2_only() {
  local q="$1"; local input="$2"; shift 2
  local args=("$@")
  echo "  running $q (S2 only)..." >&2
  OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r "${args[@]}" -f "$QUERIES_DIR/$q.jq" "$input" \
    > "$S2_DIR/$q.jsonl"
}

echo "Running V6 queries (S1 + S2)..." >&2

# Type-catalog queries (no args)
for q in exact-duplicates cross-package-shadows cross-package-shadows-any \
         name-collisions subset-pairs; do
  run_query_both "$q" "$TYPE_CAT"
done

# Type-catalog queries (--argjson threshold 0.7)
for q in cross-package-shape-near-duplicates cross-package-shape-near-duplicates-any \
         near-duplicates near-duplicates-any; do
  run_query_both "$q" "$TYPE_CAT" --argjson threshold 0.7
done

# Function-catalog query (--argjson threshold 0.7)
run_query_both "function-duplicates" "$FUNC_CAT" --argjson threshold 0.7

# File-hashes query
run_query_both "file-duplicates" "$FILE_CAT"

echo "Running V7-new queries (S2 only)..." >&2

# Type-catalog V7 queries
run_query_s2_only "pat-candidates" "$TYPE_CAT" --argjson max_slot_diffs 1
run_query_s2_only "protocol-inheritance-candidates" "$TYPE_CAT" --argjson min_overlap 2
run_query_s2_only "generic-struct-candidates" "$TYPE_CAT" --argjson max_slot_diffs 1

# Function-catalog V7 queries
run_query_s2_only "generic-function-candidates" "$FUNC_CAT" \
  --argjson threshold 0.7 --argjson max_subs 2

# default-impl-candidates needs --slurpfile types
echo "  running default-impl-candidates (S2 only, --slurpfile types)..." >&2
OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
  --argjson min_conformers 3 \
  --slurpfile types "$TYPE_CAT" \
  -f "$QUERIES_DIR/default-impl-candidates.jq" "$FUNC_CAT" \
  > "$S2_DIR/default-impl-candidates.jsonl"

# --- Summary -------------------------------------------------------------

s1_count="$(ls "$S1_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
s2_count="$(ls "$S2_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
s1_rows="$(cat "$S1_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
s2_rows="$(cat "$S2_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"

echo ""
echo "Cluster generation complete:"
echo "  served tree:  $SERVED_TREE"
echo "  S1 (V6):      $s1_count files, $s1_rows total rows  → $S1_DIR"
echo "  S2 (V6+V7):   $s2_count files, $s2_rows total rows  → $S2_DIR"
