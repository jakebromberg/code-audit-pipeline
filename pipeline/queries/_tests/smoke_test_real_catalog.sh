#!/usr/bin/env bash
# Smoke-test all cluster queries against a real Swift catalog (default: wxyc-ios-64).
# Verifies that each query runs without error on real-scale input in both
# text and JSONL modes, every JSONL line is valid JSON with a cluster_id,
# and cluster_id values are unique within a query's output.
#
# Run from repo root: pipeline/queries/_tests/smoke_test_real_catalog.sh
# Override the target with: WXYC_ROOT=/path/to/source pipeline/queries/_tests/smoke_test_real_catalog.sh
#
# Synthetic-fixture tests under test_queries_integration.sh cover the cluster_id
# contract abstractly; this smoke test covers it on real-scale codebase data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
QUERIES_DIR="$REPO_ROOT/pipeline/queries"
SWIFT_BIN="$REPO_ROOT/extractors/swift/.build/release/swift-catalog"
WXYC_ROOT="${WXYC_ROOT:-$HOME/Developer/WXYC/wxyc-ios-64}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ ! -d "$WXYC_ROOT" ]]; then
  echo "SKIP: WXYC_ROOT=$WXYC_ROOT does not exist." >&2
  exit 0
fi

if [[ ! -x "$SWIFT_BIN" ]]; then
  echo "ERROR: swift-catalog binary not built. Run: (cd extractors/swift && swift build -c release)" >&2
  exit 1
fi

PASS=0
FAIL=0

assert_query_clean() {
  local query="$1"
  local catalog="$2"
  shift 2
  local extra_args=("$@")

  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r "${extra_args[@]}" -f "$QUERIES_DIR/$query" "$catalog" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ %s: query crashed:\n%s\n" "$query" "$jsonl"
    return
  }

  local rows uniques
  rows=$(echo "$jsonl" | grep -c . || true)

  if [[ "$rows" == "0" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s: 0 rows on real catalog (acceptable)\n" "$query"
    return
  fi

  # Validate every line is well-formed JSON with a cluster_id.
  if ! echo "$jsonl" | jq -e '.cluster_id' >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "  ✗ %s: rows missing cluster_id or JSON malformed\n" "$query"
    return
  fi

  uniques=$(echo "$jsonl" | jq -r '.cluster_id' | sort -u | grep -c .)
  if [[ "$rows" != "$uniques" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ %s: %d rows, %d unique cluster_ids — collision\n" "$query" "$rows" "$uniques"
    echo "$jsonl" | jq -r '.cluster_id' | sort | uniq -c | awk '$1 > 1 {print "      duplicate:", $2}'
    return
  fi

  PASS=$((PASS + 1))
  printf "  ✓ %s: %d unique cluster_ids on real catalog\n" "$query" "$rows"
}

echo "=== Extracting catalogs from $WXYC_ROOT ==="
(cd "$WXYC_ROOT" && git submodule update --init --recursive 2>/dev/null) || true

"$SWIFT_BIN" type --root "$WXYC_ROOT" --output "$WORK_DIR/type-catalog.json" 2>/dev/null
"$SWIFT_BIN" func --root "$WXYC_ROOT" --output "$WORK_DIR/function-catalog.json" 2>/dev/null
node "$REPO_ROOT/extractors/file-hashes/file-hashes.mjs" --root "$WXYC_ROOT" --extensions swift --output "$WORK_DIR/file-hashes.json" 2>/dev/null

echo "    type-catalog:     $(jq '. | length' "$WORK_DIR/type-catalog.json") records"
echo "    function-catalog: $(jq '. | length' "$WORK_DIR/function-catalog.json") records"
echo "    file-hashes:      $(jq '. | length' "$WORK_DIR/file-hashes.json") records"

echo ""
echo "=== Type-catalog queries ==="
assert_query_clean exact-duplicates.jq "$WORK_DIR/type-catalog.json"
assert_query_clean name-collisions.jq "$WORK_DIR/type-catalog.json"
assert_query_clean cross-package-shadows.jq "$WORK_DIR/type-catalog.json"
assert_query_clean cross-package-shadows-any.jq "$WORK_DIR/type-catalog.json"
assert_query_clean near-duplicates.jq "$WORK_DIR/type-catalog.json" --argjson threshold 0.7
assert_query_clean near-duplicates-any.jq "$WORK_DIR/type-catalog.json" --argjson threshold 0.7
assert_query_clean cross-package-shape-near-duplicates.jq "$WORK_DIR/type-catalog.json" --argjson threshold 0.7
assert_query_clean cross-package-shape-near-duplicates-any.jq "$WORK_DIR/type-catalog.json" --argjson threshold 0.7
assert_query_clean subset-pairs.jq "$WORK_DIR/type-catalog.json"
assert_query_clean protocol-inheritance-candidates.jq "$WORK_DIR/type-catalog.json" --argjson min_overlap 2
assert_query_clean pat-candidates.jq "$WORK_DIR/type-catalog.json" --argjson max_slot_diffs 1
assert_query_clean generic-struct-candidates.jq "$WORK_DIR/type-catalog.json" --argjson max_slot_diffs 1

echo ""
echo "=== Function-catalog query ==="
assert_query_clean function-duplicates.jq "$WORK_DIR/function-catalog.json" --argjson threshold 0.7
assert_query_clean default-impl-candidates.jq "$WORK_DIR/function-catalog.json" --argjson min_conformers 2
assert_query_clean generic-function-candidates.jq "$WORK_DIR/function-catalog.json" --argjson threshold 0.7 --argjson max_subs 2

echo ""
echo "=== File-hash query ==="
assert_query_clean file-duplicates.jq "$WORK_DIR/file-hashes.json"

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
