#!/usr/bin/env bash
#
# test_smoke.sh — fixture-based smoke test for the TypeScript type-catalog
# extractor. Runs `node type-catalog.mjs --root <fixture>` against a small
# multi-file fixture and asserts contract conformance + cross-run determinism.
#
# The CI workflow's existing `node --check` step only confirms the extractor
# parses; this script confirms it still emits a contract-conformant catalog.
#
# Design note: the assertion phase runs under `set +e` so every assertion
# fires and the final PASS/FAIL tally is the source of truth. `set -e` covers
# the setup phase (precondition checks + the two extractor runs).
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
  ListenerProfile
  ListenerSchema
  PageEnvelope
  SyncResult
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
# stderr flows to the terminal (and the CI log) — the extractor's WARNING and
# per-file ERR lines are the most useful artifacts when an assertion below
# fails. If `node` exits non-zero, `set -e` aborts here with the extractor's
# diagnostic still visible in CI.
RUN1="$WORK_DIR/run1.json"
RUN2="$WORK_DIR/run2.json"

node "$EXTRACTOR" --root "$FIXTURE_ROOT" >"$RUN1"
node "$EXTRACTOR" --root "$FIXTURE_ROOT" >"$RUN2"

# Assertion phase: every assertion runs to completion, jq failures become
# FAIL lines instead of script aborts. The wrapper's design is "run all
# assertions, sum FAIL"; `set -e` here would defeat it.
set +e

# ---- Assertion: schema_version matches contract ----------------------------
ACTUAL_SCHEMA="$(jq -r '.schema_version' "$RUN1")"
if [[ "$ACTUAL_SCHEMA" == "$EXPECTED_SCHEMA_VERSION" ]]; then
  pass "schema_version == $EXPECTED_SCHEMA_VERSION"
else
  fail "schema_version: expected $EXPECTED_SCHEMA_VERSION, got $ACTUAL_SCHEMA"
fi

# ---- Assertion: extractor provenance block is well-formed ------------------
# The version regex is end-anchored: trailing garbage (build labels,
# whitespace, partial bumps) should not pass.
if jq -e '.extractor.language == "typescript" and .extractor.name == "type-catalog" and (.extractor.version | test("^\\d+\\.\\d+\\.\\d+$"))' "$RUN1" >/dev/null; then
  pass "extractor block: language=typescript, name=type-catalog, version=semver"
else
  fail "extractor block malformed: $(jq -c .extractor "$RUN1")"
fi

# ---- Assertion: entries[] is a non-empty array -----------------------------
# `length > 0` matters: the downstream array-comprehension assertions are
# vacuously true on an empty array, so a regression that empties entries[]
# would otherwise produce misleading PASSes.
if jq -e '(.entries | type == "array") and (.entries | length > 0)' "$RUN1" >/dev/null; then
  pass "entries[] is a non-empty array"
else
  fail "entries[] is not a non-empty array"
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
# by kind. Pin the mapping here. The cardinality check disambiguates
# duplicates from missing-entry regressions.
assert_kind() {
  local name="$1" expected_kind="$2"
  local count actual
  count="$(jq --arg n "$name" '[.entries[] | select(.name == $n)] | length' "$RUN1")"
  if [[ "$count" != "1" ]]; then
    fail "kind($name): expected exactly 1 entry, found $count"
    return
  fi
  actual="$(jq -r --arg n "$name" '.entries[] | select(.name == $n) | .kind' "$RUN1")"
  if [[ "$actual" == "$expected_kind" ]]; then
    pass "kind($name) == $expected_kind"
  else
    fail "kind($name): expected $expected_kind, got $actual"
  fi
}

assert_kind "FlowsheetEntry"  "interface"
assert_kind "ListenerSchema"  "zod-object"
assert_kind "stations"        "drizzle-table"
assert_kind "PageEnvelope"    "type-alias-object"
assert_kind "ListenerProfile" "interface"
assert_kind "SyncResult"      "type-alias-union"

# ---- Assertion: required-on-every-entry fields are non-null ----------------
# Per docs/pipeline-contract.md "Required fields" — every entry carries name,
# kind, package, file, line, is_test, extends, references, references_count.
# `!= null` (vs `has`) catches the regression where a field is present but
# silently nulled. `length > 0` guards against vacuous truth on empty input.
if jq -e '(.entries | length > 0) and ([.entries[] | (.name != null and .kind != null and .package != null and .file != null and .line != null and .is_test != null and .extends != null and .references != null and .references_count != null)] | all)' "$RUN1" >/dev/null; then
  pass "every entry has all contract-required fields (non-null)"
else
  fail "at least one entry is missing or has a null contract-required field"
fi

# ---- Assertion: extends / references are arrays ----------------------------
# Contract: "extends and references are arrays (possibly empty) on every entry
# — never null." Catches the "field exists but is wrong type" regression.
if jq -e '(.entries | length > 0) and ([.entries[] | (.extends | type == "array") and (.references | type == "array")] | all)' "$RUN1" >/dev/null; then
  pass "extends and references are arrays on every entry"
else
  fail "extends/references is not an array on at least one entry"
fi

# ---- Assertion: references walker emits expected self-reference ------------
# FlowsheetEntry has `previous_entry: FlowsheetEntry | null` — the contract
# documents self-references as emitted. A regression that drops them (or that
# breaks the references walker entirely) shows up here, where every other
# entry would still have references: [].
if jq -e '[.entries[] | select(.name == "FlowsheetEntry") | .references | map(.name) | index("FlowsheetEntry")] | all(. != null)' "$RUN1" >/dev/null; then
  pass "FlowsheetEntry.references contains self-reference"
else
  fail "FlowsheetEntry.references missing self-reference: $(jq -c '.entries[] | select(.name == "FlowsheetEntry") | .references' "$RUN1")"
fi

# ---- Assertion: drizzle table carries db_table_name and populated fields ---
# Field-presence alone isn't enough — a regression in extractDrizzleTableFields
# or the first-arg pull would emit structurally-complete entries with degraded
# content. Pin the content the contract documents.
if jq -e '.entries[] | select(.name == "stations") | (.db_table_name == "stations") and (.fields | type == "array") and (.fields | length > 0)' "$RUN1" >/dev/null; then
  pass "stations has db_table_name=\"stations\" and non-empty fields"
else
  fail "stations content degraded: $(jq -c '.entries[] | select(.name == "stations") | {db_table_name, fields}' "$RUN1")"
fi

# ---- Assertion: zod schema has populated fields ----------------------------
if jq -e '.entries[] | select(.name == "ListenerSchema") | (.fields | type == "array") and (.fields | length > 0)' "$RUN1" >/dev/null; then
  pass "ListenerSchema has non-empty fields"
else
  fail "ListenerSchema fields degraded: $(jq -c '.entries[] | select(.name == "ListenerSchema") | .fields' "$RUN1")"
fi

# ---- Assertion: determinism (byte-identical across runs) -------------------
# The fixture is intentionally multi-file so this guard exercises inter-file
# ordering, not just a single file's source-position order. A regression that
# breaks cross-file determinism (e.g., parallel processing) would surface here.
if cmp -s "$RUN1" "$RUN2"; then
  pass "byte-identical output across two consecutive runs"
else
  fail "non-deterministic output between runs (diff follows)"
  diff -u "$RUN1" "$RUN2" | head -40 >&2
fi

# Re-enable -e for the final exit-code propagation.
set -e

# ---- Summary ---------------------------------------------------------------
echo
echo "==== test_smoke: $PASS passed, $FAIL failed ===="
[[ "$FAIL" -eq 0 ]]
