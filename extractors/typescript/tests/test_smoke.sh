#!/usr/bin/env bash
#
# test_smoke.sh — fixture-based smoke test for the TypeScript type-catalog
# extractor. Runs `node type-catalog.mjs --root <fixture>` against a small
# fixture that covers the five declaration shapes (plain interface, Zod
# schema, Drizzle table, generic type alias, re-export), then asserts:
#
#   1. schema_version matches docs/pipeline-contract.md (currently "1.1").
#   2. The expected declaration names are all present in entries[].
#   3. Output is byte-identical across two consecutive runs (determinism guard).
#
# The CI workflow's existing `node --check` step only confirms the extractor
# parses; this script confirms it still emits a contract-conformant catalog.
#
# Run from the worktree root: extractors/typescript/tests/test_smoke.sh
# Exit code: 0 on success; non-zero on any assertion failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_ROOT="$SCRIPT_DIR/fixtures"
EXTRACTOR="$EXTRACTOR_ROOT/type-catalog.mjs"

# Contract version. Bump in lockstep with docs/pipeline-contract.md and the
# SCHEMA_VERSION constant in type-catalog.mjs.
EXPECTED_SCHEMA_VERSION="1.1"

# Declaration names the fixture is expected to produce. Order doesn't matter;
# the assertion sorts both sides.
EXPECTED_NAMES=(
  FlowsheetEntry
  ListenerSchema
  PageEnvelope
  stations
)

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf "  PASS: %s\n" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf "  FAIL: %s\n" "$1" >&2
}

if [[ ! -f "$EXTRACTOR" ]]; then
  echo "ERROR: extractor not found at $EXTRACTOR" >&2
  exit 1
fi

if [[ ! -d "$FIXTURE_ROOT" ]]; then
  echo "ERROR: fixture root not found at $FIXTURE_ROOT" >&2
  exit 1
fi

echo "=== Smoke test: TypeScript type-catalog extractor ==="
echo "    fixture: $FIXTURE_ROOT"
echo "    extractor: $EXTRACTOR"

# ---- Run twice for determinism check ---------------------------------------
RUN1="$WORK_DIR/run1.json"
RUN2="$WORK_DIR/run2.json"

node "$EXTRACTOR" --root "$FIXTURE_ROOT" >"$RUN1" 2>"$WORK_DIR/run1.stderr"
node "$EXTRACTOR" --root "$FIXTURE_ROOT" >"$RUN2" 2>"$WORK_DIR/run2.stderr"

# ---- Assertion: schema_version matches contract ----------------------------
ACTUAL_SCHEMA="$(jq -r '.schema_version' "$RUN1")"
if [[ "$ACTUAL_SCHEMA" == "$EXPECTED_SCHEMA_VERSION" ]]; then
  pass "schema_version == $EXPECTED_SCHEMA_VERSION"
else
  fail "schema_version: expected $EXPECTED_SCHEMA_VERSION, got $ACTUAL_SCHEMA"
fi

# ---- Assertion: extractor provenance block is well-formed ------------------
if jq -e '.extractor.language == "typescript" and .extractor.name == "type-catalog" and (.extractor.version | test("^\\d+\\.\\d+\\.\\d+"))' "$RUN1" >/dev/null; then
  pass "extractor block: language=typescript, name=type-catalog, version=semver"
else
  fail "extractor block malformed: $(jq -c .extractor "$RUN1")"
fi

# ---- Assertion: entries[] is an array --------------------------------------
if jq -e '.entries | type == "array"' "$RUN1" >/dev/null; then
  pass "entries[] is an array"
else
  fail "entries[] is not an array"
fi

# ---- Assertion: every expected declaration name is present -----------------
ACTUAL_NAMES="$(jq -r '.entries[].name' "$RUN1" | LC_ALL=C sort | tr '\n' ',')"
EXPECTED_NAMES_SORTED="$(printf '%s\n' "${EXPECTED_NAMES[@]}" | LC_ALL=C sort | tr '\n' ',')"
if [[ "$ACTUAL_NAMES" == "$EXPECTED_NAMES_SORTED" ]]; then
  pass "entries[].name == expected set ($EXPECTED_NAMES_SORTED)"
else
  fail "entries[].name mismatch
    expected: $EXPECTED_NAMES_SORTED
    actual:   $ACTUAL_NAMES"
fi

# ---- Assertion: each expected name maps to its expected kind ---------------
# A regression in kind classification (e.g., zod schema misclassified as a
# generic const) would silently break downstream cluster queries that filter
# by kind. Pin the mapping here.
assert_kind() {
  local name="$1" expected_kind="$2"
  local actual
  actual="$(jq -r --arg n "$name" '.entries[] | select(.name == $n) | .kind' "$RUN1")"
  if [[ "$actual" == "$expected_kind" ]]; then
    pass "kind($name) == $expected_kind"
  else
    fail "kind($name): expected $expected_kind, got $actual"
  fi
}

assert_kind "FlowsheetEntry" "interface"
assert_kind "ListenerSchema" "zod-object"
assert_kind "stations"       "drizzle-table"
assert_kind "PageEnvelope"   "type-alias-object"

# ---- Assertion: required-on-every-entry fields are present -----------------
# Per docs/pipeline-contract.md "Required fields" — every entry carries name,
# kind, package, file, line, is_test, extends, references, references_count.
# Catch the regression where one is dropped or nulled.
if jq -e '[.entries[] | (has("name") and has("kind") and has("package") and has("file") and has("line") and has("is_test") and has("extends") and has("references") and has("references_count"))] | all' "$RUN1" >/dev/null; then
  pass "every entry has all contract-required fields"
else
  fail "at least one entry is missing a contract-required field"
fi

# ---- Assertion: extends / references are arrays, never null ----------------
# Contract: "extends and references are arrays (possibly empty) on every entry
# — never null."
if jq -e '[.entries[] | (.extends | type == "array") and (.references | type == "array")] | all' "$RUN1" >/dev/null; then
  pass "extends and references are arrays on every entry"
else
  fail "extends/references is not an array on at least one entry"
fi

# ---- Assertion: determinism (byte-identical across runs) -------------------
if cmp -s "$RUN1" "$RUN2"; then
  pass "byte-identical output across two consecutive runs"
else
  fail "non-deterministic output between runs (diff follows)"
  diff -u "$RUN1" "$RUN2" | head -40 >&2 || true
fi

# ---- Summary ---------------------------------------------------------------
echo
echo "==== test_smoke: $PASS passed, $FAIL failed ===="
[[ "$FAIL" -eq 0 ]]
