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
EXPECTED_SCHEMA_VERSION="1.2"

# Declaration names the fixture is expected to produce. Order doesn't matter;
# the assertion sorts both sides.
EXPECTED_NAMES=(
  FlowsheetEntry
  FlowsheetEntryWithStation
  InternalDraftEntry
  ListenerProfile
  ListenerSchema
  PageEnvelope
  Station
  SyncResult
  stations
)

# Pulled from package.json at script start so the assertion below catches the
# "stale hardcoded literal" regression a semver regex would miss — a refactor
# that replaces the dynamic `JSON.parse(readFileSync(...)).version` read in
# type-catalog.mjs with a baked-in string passes a regex check forever.
EXPECTED_VERSION="$(jq -r .version "$EXTRACTOR_ROOT/package.json")"

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
# Pin extractor.version to the exact `package.json.version` read at script
# start — a regex check passes forever on a stale hardcoded literal, but the
# extractor reads the live package.json on every run.
if jq -e --arg v "$EXPECTED_VERSION" '.extractor.language == "typescript" and .extractor.name == "type-catalog" and .extractor.version == $v' "$RUN1" >/dev/null; then
  pass "extractor block: language=typescript, name=type-catalog, version=$EXPECTED_VERSION"
else
  fail "extractor block malformed (expected version=$EXPECTED_VERSION): $(jq -c .extractor "$RUN1")"
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

assert_kind "FlowsheetEntry"             "interface"
assert_kind "ListenerSchema"             "zod-object"
assert_kind "stations"                   "drizzle-table"
assert_kind "PageEnvelope"               "type-alias-object"
assert_kind "ListenerProfile"            "interface"
assert_kind "SyncResult"                 "type-alias-union"
assert_kind "FlowsheetEntryWithStation"  "type-alias-intersection"
assert_kind "Station"                    "type-alias-infer-model"
assert_kind "InternalDraftEntry"         "interface"

# ---- Assertion: exported flag, both branches -------------------------------
# A regression in exportedMod() that flipped the default (always-true or
# always-false — plausible after a TS lib upgrade changes how modifiers are
# exposed via getModifiers()) would be invisible to a fixture where every
# entry is exported. Pin one positive and one negative.
assert_exported() {
  local name="$1" expected="$2"
  local count actual
  count="$(jq --arg n "$name" '[.entries[] | select(.name == $n)] | length' "$RUN1")"
  if [[ "$count" != "1" ]]; then
    fail "exported($name): expected exactly 1 entry, found $count"
    return
  fi
  actual="$(jq -r --arg n "$name" '.entries[] | select(.name == $n) | .exported' "$RUN1")"
  if [[ "$actual" == "$expected" ]]; then
    pass "exported($name) == $expected"
  else
    fail "exported($name): expected $expected, got $actual"
  fi
}

assert_exported "FlowsheetEntry"     "true"
assert_exported "InternalDraftEntry" "false"

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
#
# The `length > 0` guard prevents vacuous truth when no entry is named
# FlowsheetEntry — `[] | all(...)` is true in jq; without the guard, a
# regression that dropped the entry entirely would silently pass.
if jq -e '
  ([.entries[] | select(.name == "FlowsheetEntry")] | length > 0) and
  ([.entries[] | select(.name == "FlowsheetEntry") | .references | any(.name == "FlowsheetEntry")] | all)
' "$RUN1" >/dev/null; then
  pass "FlowsheetEntry.references contains self-reference"
else
  fail "FlowsheetEntry.references missing self-reference: $(jq -c '.entries[] | select(.name == "FlowsheetEntry") | .references' "$RUN1")"
fi

# ---- Assertion: drizzle table carries db_table_name and populated fields ---
# Field-presence alone isn't enough — a regression in extractDrizzleTableFields
# or the first-arg pull would emit structurally-complete entries with degraded
# content. Pin the content the contract documents.
#
# `[...] | all` (vs streaming `select | <predicate>`) matters because
# `jq -e` on a multi-output stream returns success based on the LAST output
# only — one degraded entry followed by a valid one would silently PASS.
# `length > 0` guards against vacuous truth when no `stations` entry exists.
if jq -e '
  ([.entries[] | select(.name == "stations")] | length > 0) and
  ([.entries[] | select(.name == "stations") | (.db_table_name == "stations") and (.fields | type == "array") and (.fields | length > 0)] | all)
' "$RUN1" >/dev/null; then
  pass "stations has db_table_name=\"stations\" and non-empty fields"
else
  fail "stations content degraded: $(jq -c '[.entries[] | select(.name == "stations") | {db_table_name, fields}]' "$RUN1")"
fi

# ---- Assertion: zod schema has populated fields ----------------------------
# Same length+all pattern as the drizzle assertion above — guards against both
# vacuous truth (no ListenerSchema entry) and `jq -e` last-output masking
# (one degraded + one valid).
if jq -e '
  ([.entries[] | select(.name == "ListenerSchema")] | length > 0) and
  ([.entries[] | select(.name == "ListenerSchema") | (.fields | type == "array") and (.fields | length > 0)] | all)
' "$RUN1" >/dev/null; then
  pass "ListenerSchema has non-empty fields"
else
  fail "ListenerSchema fields degraded: $(jq -c '[.entries[] | select(.name == "ListenerSchema") | .fields]' "$RUN1")"
fi

# ---- Assertion: determinism (structurally identical across runs) -----------
# The fixture is intentionally multi-file so this guard exercises inter-file
# ordering, not just a single file's source-position order. A regression that
# breaks cross-file determinism (e.g., parallel processing) would surface here.
#
# The v1.2 envelope's `generated_at` is wall-clock and will differ between
# runs; strip it before comparison so the rest of the envelope (extractor
# block, fingerprint_v, entries) remains a determinism guard.
RUN1_STRIPPED="$WORK_DIR/run1-stripped.json"
RUN2_STRIPPED="$WORK_DIR/run2-stripped.json"
jq 'del(.generated_at)' "$RUN1" > "$RUN1_STRIPPED"
jq 'del(.generated_at)' "$RUN2" > "$RUN2_STRIPPED"
if cmp -s "$RUN1_STRIPPED" "$RUN2_STRIPPED"; then
  pass "byte-identical output across two consecutive runs (excluding generated_at)"
else
  fail "non-deterministic output between runs (diff follows)"
  diff -u "$RUN1_STRIPPED" "$RUN2_STRIPPED" | head -40 >&2
fi

# Re-enable -e for the final exit-code propagation.
set -e

# ---- Summary ---------------------------------------------------------------
echo
echo "==== test_smoke: $PASS passed, $FAIL failed ===="
[[ "$FAIL" -eq 0 ]]
