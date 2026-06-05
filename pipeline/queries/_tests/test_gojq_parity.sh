#!/usr/bin/env bash
# Parity test: every runnable query must produce identical normalized output
# under gojq and system jq.
#
# Why: per docs/adr/0005-go-binary-gojq-engine.md, the code-audit binary embeds
# `itchyny/gojq` to evaluate queries without shelling out to system jq. That
# only works if gojq's output is byte-equivalent to jq's for our queries. Any
# query that diverges must declare `#! engine: jq` so the binary shells out
# to system jq for that query specifically.
#
# Protocol (per ADR-0005 'Consequences'):
#   1. For each query × output-format (text, jsonl), invoke under both engines
#      with the same fixture / args / slurpfile mounts / env vars.
#   2. Normalize output (sort lines + strip trailing whitespace).
#   3. Compare sha256. Match → parity. Mismatch → divergence.
#   4. JSONL parity is the gating verdict (the binary consumes jsonl
#      internally). Text-mode parity is informational.
#
# The fixture set under fixtures/ is curated to exercise every query's
# edge cases (see test_queries_integration.sh) — reusing it here means
# the parity test inherits the same coverage.
#
# Run from repo root:
#   pipeline/queries/_tests/test_gojq_parity.sh

# `-e` is omitted on purpose: run_parity captures jq/gojq exit codes via $?
# to report which engine crashed, which set -e would short-circuit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

command -v gojq >/dev/null 2>&1 || {
  echo "ERROR: gojq not installed. Install with: brew install gojq" >&2
  exit 2
}

TYPES_FIXTURE="$FIXTURES_DIR/types.input.json"
FUNCS_FIXTURE="$FIXTURES_DIR/functions.input.json"
FILES_FIXTURE="$FIXTURES_DIR/files.input.json"
MIGRATION_FIXTURE="$FIXTURES_DIR/migration.input.json"
GENERICS_FIXTURE="$FIXTURES_DIR/generics.input.json"
DEBT_SUMMARY_FIXTURE="$FIXTURES_DIR/debt-summary.input.json"
ORPHAN_INFER_MODEL_FIXTURE="$FIXTURES_DIR/orphan-infer-model.input.json"
TEST_PROD_DRIFT_FIXTURE="$FIXTURES_DIR/test-prod-drift.input.json"
DEAD_CODE_CATALOG_FIXTURE="$FIXTURES_DIR/dead-code-catalog.input.json"
DEAD_CODE_REFS_FIXTURE="$FIXTURES_DIR/dead-code-references.input.json"
LEAKS_FUNCTIONS_FIXTURE="$FIXTURES_DIR/public-api-leaks-functions.input.json"
LEAKS_TYPES_FIXTURE="$FIXTURES_DIR/public-api-leaks-types.input.json"
BACKWARD_IMPORTS_FIXTURE="$FIXTURES_DIR/cross-package-backward-imports-files.input.json"
VERSIONED_TYPE_PAIRS_FIXTURE="$FIXTURES_DIR/versioned-type-pairs.input.json"

# Split TYPES_FIXTURE into two synthetic per-package catalogs for the
# cross-catalog-name-collisions query (mirrors the integration test).
CROSS_CAT_WORK="$(mktemp -d -t gojq-parity-cross-cat.XXXXXX)"
trap 'rm -rf "$CROSS_CAT_WORK"' EXIT
CROSS_CAT_LEFT="$CROSS_CAT_WORK/left.json"
CROSS_CAT_RIGHT="$CROSS_CAT_WORK/right.json"
# Mirror test_queries_integration.sh: TYPES_FIXTURE is a bare array (v1.0
# catalog), and the split produces bare-array sub-catalogs.
jq '[.[] | select(.package == "main")]'   "$TYPES_FIXTURE" > "$CROSS_CAT_LEFT"
jq '[.[] | select(.package == "shared")]' "$TYPES_FIXTURE" > "$CROSS_CAT_RIGHT"
[[ -s "$CROSS_CAT_LEFT" && -s "$CROSS_CAT_RIGHT" ]] \
  || { echo "ERROR: cross-catalog split produced an empty file; check TYPES_FIXTURE" >&2; exit 2; }

# Expected invocations = 2 (text + jsonl) per runnable query. Computed from
# the queries dir so adding a query without a both_modes row is caught.
EXPECTED_INVOCATIONS=$(( 2 * $(find "$QUERIES_DIR" -maxdepth 1 -name '[!_]*.jq' | wc -l | tr -d ' ') ))

PASS=0
FAIL=0

# Normalize output for semantic comparison.
# JSONL mode: pipe the whole stream through `jq -cS` to sort object keys —
# gojq alphabetizes keys when serializing while jq preserves insertion order,
# so byte comparison would spuriously fail on semantically identical records.
# Text mode: pass through untouched (the queries' text output is hand-formatted
# and already byte-identical between engines).
normalize() {
  local format="$1"
  if [[ "$format" == jsonl ]]; then
    jq -cS .
  else
    cat
  fi | sed -e 's/[[:space:]]*$//' | sort
}

sha() { shasum -a 256 | awk '{print $1}'; }

# run_parity <label> <format:text|jsonl> <query_path> <input:path-or-"-n"> [jq-args...]
run_parity() {
  local label="$1"
  local format="$2"
  local query_path="$3"
  local input="$4"
  shift 4
  local args=("$@")

  local null_flag=() input_args=()
  if [[ "$input" == "-n" ]]; then
    null_flag=(-n)
  else
    input_args=("$input")
  fi

  local out_jq out_gojq jq_rc gojq_rc
  out_jq="$(OUTPUT_FORMAT="$format" jq   "${null_flag[@]}" -L "$QUERIES_DIR" -r "${args[@]}" -f "$query_path" "${input_args[@]}" 2>&1)"
  jq_rc=$?
  out_gojq="$(OUTPUT_FORMAT="$format" gojq "${null_flag[@]}" -L "$QUERIES_DIR" -r "${args[@]}" -f "$query_path" "${input_args[@]}" 2>&1)"
  gojq_rc=$?

  if (( jq_rc != 0 )); then
    FAIL=$((FAIL + 1))
    printf '  ✗ %s [%s]: jq crashed (rc=%d): %s\n' "$label" "$format" "$jq_rc" "$out_jq"
    return
  fi
  if (( gojq_rc != 0 )); then
    FAIL=$((FAIL + 1))
    printf '  ✗ %s [%s]: gojq crashed (rc=%d): %s\n' "$label" "$format" "$gojq_rc" "$out_gojq"
    return
  fi

  local hash_jq hash_gojq
  hash_jq="$(printf '%s' "$out_jq"   | normalize "$format" | sha)"
  hash_gojq="$(printf '%s' "$out_gojq" | normalize "$format" | sha)"

  if [[ "$hash_jq" == "$hash_gojq" ]]; then
    PASS=$((PASS + 1))
    if [[ "$out_jq" == "$out_gojq" ]]; then
      printf '  ✓ %s [%s] — byte-identical\n' "$label" "$format"
    else
      printf '  ✓ %s [%s] — set-equal after normalization\n' "$label" "$format"
    fi
  else
    FAIL=$((FAIL + 1))
    printf '  ✗ %s [%s]: outputs differ\n' "$label" "$format"
    diff <(printf '%s' "$out_jq" | normalize "$format") <(printf '%s' "$out_gojq" | normalize "$format") \
      | head -30 | sed 's/^/      /'
  fi
}

# Shorthand: run both modes (text + jsonl) for a query.
both_modes() {
  local label="$1"
  shift
  run_parity "$label" jsonl "$@"
  run_parity "$label" text  "$@"
}

echo "=== Type-catalog queries ==="
both_modes exact-duplicates                          "$QUERIES_DIR/exact-duplicates.jq"                          "$TYPES_FIXTURE"
both_modes name-collisions                           "$QUERIES_DIR/name-collisions.jq"                           "$TYPES_FIXTURE"
both_modes cross-package-shadows                     "$QUERIES_DIR/cross-package-shadows.jq"                     "$TYPES_FIXTURE"
both_modes cross-package-shadows-any                 "$QUERIES_DIR/cross-package-shadows-any.jq"                 "$TYPES_FIXTURE"
both_modes near-duplicates                           "$QUERIES_DIR/near-duplicates.jq"                           "$TYPES_FIXTURE" --argjson threshold 0.5
both_modes near-duplicates-any                       "$QUERIES_DIR/near-duplicates-any.jq"                       "$TYPES_FIXTURE" --argjson threshold 0.5
both_modes cross-package-shape-near-duplicates       "$QUERIES_DIR/cross-package-shape-near-duplicates.jq"       "$TYPES_FIXTURE" --argjson threshold 0.5
both_modes cross-package-shape-near-duplicates-any   "$QUERIES_DIR/cross-package-shape-near-duplicates-any.jq"   "$TYPES_FIXTURE" --argjson threshold 0.5
both_modes subset-pairs                              "$QUERIES_DIR/subset-pairs.jq"                              "$TYPES_FIXTURE"
both_modes protocol-inheritance-candidates           "$QUERIES_DIR/protocol-inheritance-candidates.jq"           "$TYPES_FIXTURE" --argjson min_overlap 2
both_modes pat-candidates                            "$QUERIES_DIR/pat-candidates.jq"                            "$TYPES_FIXTURE" --argjson max_slot_diffs 1
both_modes generic-struct-candidates                 "$QUERIES_DIR/generic-struct-candidates.jq"                 "$TYPES_FIXTURE" --argjson max_slot_diffs 1
both_modes symbol-id-collisions                      "$QUERIES_DIR/symbol-id-collisions.jq"                      "$TYPES_FIXTURE"
# Hit-path coverage for symbol-id-collisions (planted 4-tuple collision + a
# slash-flatten-only ambiguity that the pre-NUL formula would have falsely
# collided) lives in test_queries_integration.sh's semantic assertion.
# Parity contract here is "jq and gojq agree on the empty-result fixture,"
# which is sufficient because the engine doesn't care about input shape.

echo ""
echo "=== Function-catalog queries ==="
both_modes function-duplicates                       "$QUERIES_DIR/function-duplicates.jq"                       "$FUNCS_FIXTURE" --argjson threshold 0.5
both_modes default-impl-candidates                   "$QUERIES_DIR/default-impl-candidates.jq"                   "$FUNCS_FIXTURE" --argjson min_conformers 2
both_modes generic-function-candidates               "$QUERIES_DIR/generic-function-candidates.jq"               "$FUNCS_FIXTURE" --argjson threshold 0.5 --argjson max_subs 2

echo ""
echo "=== File-hash queries ==="
both_modes file-duplicates                           "$QUERIES_DIR/file-duplicates.jq"                           "$FILES_FIXTURE"

echo ""
echo "=== Migration-progress queries ==="
both_modes migration-progress                        "$QUERIES_DIR/migration-progress.jq"                        "$MIGRATION_FIXTURE" --arg old_sig "id:number" --arg new_sig "id:string" --arg label "Id-migration"
both_modes shape-sig-frequency                       "$QUERIES_DIR/shape-sig-frequency.jq"                       "$MIGRATION_FIXTURE"
both_modes versioned-type-pairs                      "$QUERIES_DIR/versioned-type-pairs.jq"                      "$VERSIONED_TYPE_PAIRS_FIXTURE"

echo ""
echo "=== Generic-drift queries ==="
both_modes generic-arity-drift                       "$QUERIES_DIR/generic-arity-drift.jq"                       "$GENERICS_FIXTURE"
both_modes generic-convention-bound                  "$QUERIES_DIR/generic-convention-bound.jq"                  "$GENERICS_FIXTURE"

echo ""
echo "=== Debt-summary query ==="
both_modes touched-window-debt-summary               "$QUERIES_DIR/touched-window-debt-summary.jq"               "$DEBT_SUMMARY_FIXTURE"

echo ""
echo "=== Orphan-infer-model query ==="
both_modes orphan-infer-model                        "$QUERIES_DIR/orphan-infer-model.jq"                        "$ORPHAN_INFER_MODEL_FIXTURE"

echo ""
echo "=== Test-prod-drift query ==="
both_modes test-prod-drift                           "$QUERIES_DIR/test-prod-drift.jq"                           "$TEST_PROD_DRIFT_FIXTURE" --argjson threshold 0.5

echo ""
echo "=== Multi-catalog: dead-code (type-catalog + references-graph) ==="
both_modes dead-code                                 "$QUERIES_DIR/dead-code.jq"                                 "$DEAD_CODE_CATALOG_FIXTURE" --slurpfile refs "$DEAD_CODE_REFS_FIXTURE"

echo ""
echo "=== Multi-catalog: public-api-leaks (function-catalog + type-catalog) ==="
both_modes public-api-leaks                          "$QUERIES_DIR/public-api-leaks.jq"                          "$LEAKS_FUNCTIONS_FIXTURE" --slurpfile types "$LEAKS_TYPES_FIXTURE"

echo ""
echo "=== Files-catalog query ==="
both_modes cross-package-backward-imports            "$QUERIES_DIR/cross-package-backward-imports.jq"            "$BACKWARD_IMPORTS_FIXTURE"

echo ""
echo "=== Cross-catalog (null-input, two slurps) ==="
both_modes cross-catalog-name-collisions             "$QUERIES_DIR/cross-catalog-name-collisions.jq"             "-n" --slurpfile left "$CROSS_CAT_LEFT" --slurpfile right "$CROSS_CAT_RIGHT"

echo ""
echo "=== Summary ==="
printf '  PASS: %d\n  FAIL: %d\n' "$PASS" "$FAIL"

if (( PASS + FAIL != EXPECTED_INVOCATIONS )); then
  printf '\nERROR: ran %d invocations, expected %d (2 × %d queries).\n' \
    "$((PASS + FAIL))" "$EXPECTED_INVOCATIONS" "$((EXPECTED_INVOCATIONS / 2))" >&2
  printf '       A new query was likely added without a corresponding both_modes row.\n' >&2
  exit 2
fi

if (( FAIL > 0 )); then
  echo ""
  echo "Divergent jsonl-mode queries should declare '#! engine: jq' in front-matter."
  echo "Text-mode divergences are informational and may not require an annotation."
  exit 1
fi

echo ""
echo "All queries parity-clean. gojq is safe to use as the binary's default engine."
