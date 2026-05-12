#!/usr/bin/env bash
# Tests for _canonical.jq's cluster_id helpers and output-mode behavior.
#
# Run from repo root: pipeline/queries/_tests/test_canonical.sh
# Exits 0 on success; non-zero on any assertion failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s\n     expected: %s\n     actual:   %s\n" "$desc" "$expected" "$actual"
  fi
}

run() {
  local jq_expr="$1"
  echo '{}' | jq -L "$QUERIES_DIR" -r "include \"_canonical\"; $jq_expr"
}

run_env() {
  local env_var="$1"
  local jq_expr="$2"
  echo '{}' | env "$env_var" jq -L "$QUERIES_DIR" -r "include \"_canonical\"; $jq_expr"
}

echo "=== cluster_id_sorted_names ==="
assert_eq "sorts ['B','A','C'] alphabetically" \
  "exact-duplicates:A+B+C" \
  "$(run 'cluster_id_sorted_names("exact-duplicates"; ["B", "A", "C"])')"

assert_eq "single-name input emits prefix:Name" \
  "exact-duplicates:OnlyOne" \
  "$(run 'cluster_id_sorted_names("exact-duplicates"; ["OnlyOne"])')"

assert_eq "handles names with special chars literally" \
  "function-duplicates-exact:Foo+Foo_v2" \
  "$(run 'cluster_id_sorted_names("function-duplicates-exact"; ["Foo_v2", "Foo"])')"

echo "=== cluster_id_single_name ==="
assert_eq "emits prefix:Name" \
  "name-collisions:RadioStation" \
  "$(run 'cluster_id_single_name("name-collisions"; "RadioStation")')"

echo "=== cluster_id_sorted_pair ==="
assert_eq "sorts pair regardless of input order — (B, A)" \
  "near-duplicates:A+B" \
  "$(run 'cluster_id_sorted_pair("near-duplicates"; "B"; "A")')"

assert_eq "sorts pair — (A, B)" \
  "near-duplicates:A+B" \
  "$(run 'cluster_id_sorted_pair("near-duplicates"; "A"; "B")')"

assert_eq "different prefixes for -any variants" \
  "near-duplicates-any:Foo+Goo" \
  "$(run 'cluster_id_sorted_pair("near-duplicates-any"; "Foo"; "Goo")')"

echo "=== cluster_id_directed_pair ==="
assert_eq "preserves direction — Sub__Sup" \
  "subset-pairs:Sub__Sup" \
  "$(run 'cluster_id_directed_pair("subset-pairs"; "Sub"; "Sup")')"

assert_eq "swapped direction yields different id" \
  "subset-pairs:Sup__Sub" \
  "$(run 'cluster_id_directed_pair("subset-pairs"; "Sup"; "Sub")')"

echo "=== cluster_id_sorted_paths ==="
assert_eq "sorts repo-relative paths" \
  "file-duplicates-exact:Shared/A.swift+Shared/B.swift" \
  "$(run 'cluster_id_sorted_paths("file-duplicates-exact"; ["Shared/B.swift", "Shared/A.swift"])')"

echo "=== loc_key ==="
assert_eq "concatenates package:file:line:name" \
  "Shared/Core:Sources/Core/Foo.swift:42:hashSlug" \
  "$(run 'loc_key({package: "Shared/Core", file: "Sources/Core/Foo.swift", line: 42, name: "hashSlug"})')"

assert_eq "fn_location_key alias produces identical output" \
  "Shared/Core:Sources/Core/Foo.swift:42:hashSlug" \
  "$(run 'fn_location_key({package: "Shared/Core", file: "Sources/Core/Foo.swift", line: 42, name: "hashSlug"})')"

echo "=== output_format ==="
assert_eq "default is text" \
  "text" \
  "$(run 'output_format')"

assert_eq "OUTPUT_FORMAT=jsonl flips to jsonl" \
  "jsonl" \
  "$(run_env 'OUTPUT_FORMAT=jsonl' 'output_format')"

assert_eq "OUTPUT_FORMAT=text is explicit default" \
  "text" \
  "$(run_env 'OUTPUT_FORMAT=text' 'output_format')"

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
