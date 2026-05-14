#!/usr/bin/env bash
# Tests for §6.4: function-body type-erased signature, TypeScript side.
#
# Runs function-catalog.mjs against fixtures/erased-body-pair.ts and asserts
# that function pairs differing only in type-identifier tokens produce matching
# body_hash_erased values while their body_hash values differ.
#
# Run from repo root or this directory:
#   extractors/typescript/tests/test_erased_body_sig.sh
#
# Exits 0 on success; non-zero on any assertion failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"

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

assert_ne() {
  local desc="$1"
  local a="$2"
  local b="$3"
  if [[ "$a" != "$b" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s\n     both values: %s\n" "$desc" "$a"
  fi
}

echo "=== ensure dependencies installed ==="
if [[ ! -d "$TS_DIR/node_modules" ]]; then
  (cd "$TS_DIR" && npm install --silent 2>&1 | tail -5)
fi
echo "  ✓ deps ok"

echo "=== run function-catalog.mjs against fixture ==="
JSON=$(cd "$TS_DIR" && node function-catalog.mjs --root "$FIXTURE_DIR" 2>/dev/null)

echo "=== body_hash_erased matches across type-only pairs ==="
hash_a=$(echo "$JSON" | jq -r '.[] | select(.name == "makeArrayA") | .body_hash_erased')
hash_b=$(echo "$JSON" | jq -r '.[] | select(.name == "makeArrayB") | .body_hash_erased')
assert_eq "makeArrayA.body_hash_erased == makeArrayB.body_hash_erased" "$hash_a" "$hash_b"

echo "=== body_hash differs across type-only pairs (sanity: erasure is doing work) ==="
raw_a=$(echo "$JSON" | jq -r '.[] | select(.name == "makeArrayA") | .body_hash')
raw_b=$(echo "$JSON" | jq -r '.[] | select(.name == "makeArrayB") | .body_hash')
assert_ne "makeArrayA.body_hash != makeArrayB.body_hash" "$raw_a" "$raw_b"

echo "=== multi-distinct-types erase to identical hash ==="
hash_p1=$(echo "$JSON" | jq -r '.[] | select(.name == "swapFoo") | .body_hash_erased')
hash_p2=$(echo "$JSON" | jq -r '.[] | select(.name == "swapBaz") | .body_hash_erased')
assert_eq "swapFoo.body_hash_erased == swapBaz.body_hash_erased" "$hash_p1" "$hash_p2"

echo "=== body_lines_erased contains placeholder tokens ==="
lines=$(echo "$JSON" | jq -c '.[] | select(.name == "makeArrayA") | .body_lines_erased')
if echo "$lines" | grep -q '_T1'; then
  PASS=$((PASS + 1))
  echo "  ✓ makeArrayA.body_lines_erased contains _T1"
else
  FAIL=$((FAIL + 1))
  echo "  ✗ makeArrayA.body_lines_erased missing _T1"
  echo "     actual: $lines"
fi

# makeArrayA has a single distinct type reference (UIColor), so erasure should
# yield exactly _T1 with no _T2 in the body.
if echo "$lines" | grep -q '_T2'; then
  FAIL=$((FAIL + 1))
  echo "  ✗ makeArrayA.body_lines_erased unexpectedly contains _T2"
  echo "     actual: $lines"
else
  PASS=$((PASS + 1))
  echo "  ✓ makeArrayA.body_lines_erased has no _T2 (single-type body)"
fi

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
