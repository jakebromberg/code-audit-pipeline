#!/usr/bin/env bash
# Integration tests for all cluster queries.
#
# Verifies:
#   1. Each query runs without error in both text and JSONL modes against synthetic fixtures.
#   2. Every JSONL line is valid JSON and carries a `cluster_id` field with the expected prefix.
#   3. Every JSONL output's cluster_id values are unique within that query's run.
#   4. Text-mode output contains `cid=<cluster_id>` markers.
#
# Run from repo root: pipeline/queries/_tests/test_queries_integration.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

TYPES_FIXTURE="$FIXTURES_DIR/types.input.json"
FUNCS_FIXTURE="$FIXTURES_DIR/functions.input.json"
FILES_FIXTURE="$FIXTURES_DIR/files.input.json"
MIGRATION_FIXTURE="$FIXTURES_DIR/migration.input.json"
GENERICS_FIXTURE="$FIXTURES_DIR/generics.input.json"
DEBT_SUMMARY_FIXTURE="$FIXTURES_DIR/debt-summary.input.json"
DEBT_SUMMARY_NO_CONTEXT_FIXTURE="$FIXTURES_DIR/debt-summary-no-context.input.json"

PASS=0
FAIL=0

assert_jsonl_has_prefix() {
  local query="$1"
  local fixture="$2"
  local expected_prefix="$3"
  shift 3
  local extra_args=("$@")

  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r "${extra_args[@]}" -f "$QUERIES_DIR/$query" "$fixture" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ %s: query crashed: %s\n" "$query" "$jsonl"
    return
  }

  if [[ -z "$jsonl" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s: produces no clusters on fixture (acceptable if expected)\n" "$query"
    return
  fi

  # Verify each line is valid JSON
  local line_count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    line_count=$((line_count + 1))
    if ! echo "$line" | jq empty 2>/dev/null; then
      FAIL=$((FAIL + 1))
      printf "  ✗ %s line %d: invalid JSON: %s\n" "$query" "$line_count" "$line"
      return
    fi
    local cid
    cid="$(echo "$line" | jq -r '.cluster_id')"
    if [[ "$cid" != "$expected_prefix"* ]]; then
      FAIL=$((FAIL + 1))
      printf "  ✗ %s line %d: cluster_id '%s' does not start with '%s'\n" "$query" "$line_count" "$cid" "$expected_prefix"
      return
    fi
  done <<< "$jsonl"

  # Verify cluster_id uniqueness within this query's output.
  local total unique
  total=$(echo "$jsonl" | grep -c .)
  unique=$(echo "$jsonl" | jq -r '.cluster_id' | sort -u | grep -c .)
  if [[ "$total" != "$unique" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ %s: %d rows but only %d unique cluster_ids — collision!\n" "$query" "$total" "$unique"
    echo "$jsonl" | jq -r '.cluster_id' | sort | uniq -c | awk '$1 > 1 {print "      duplicate:", $2}'
    return
  fi

  PASS=$((PASS + 1))
  printf "  ✓ %s: %d JSONL row(s), all with cluster_id starting '%s' (unique)\n" "$query" "$line_count" "$expected_prefix"
}

assert_text_has_cid() {
  local query="$1"
  local fixture="$2"
  shift 2
  local extra_args=("$@")

  local text
  text="$(jq -L "$QUERIES_DIR" -r "${extra_args[@]}" -f "$QUERIES_DIR/$query" "$fixture" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ %s text mode crashed: %s\n" "$query" "$text"
    return
  }

  # If the text is empty, skip — query found nothing.
  if [[ -z "$text" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s text mode: empty (no clusters on fixture)\n" "$query"
    return
  fi

  if [[ "$text" == *"cid="* ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s text mode: contains cid= marker\n" "$query"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s text mode: no cid= marker in output:\n%s\n" "$query" "$text"
  fi
}

echo "=== Type-catalog queries ==="
assert_jsonl_has_prefix exact-duplicates.jq "$TYPES_FIXTURE" "exact-duplicates:"
assert_jsonl_has_prefix name-collisions.jq "$TYPES_FIXTURE" "name-collisions:"
assert_jsonl_has_prefix cross-package-shadows.jq "$TYPES_FIXTURE" "cross-package-shadows:"
assert_jsonl_has_prefix cross-package-shadows-any.jq "$TYPES_FIXTURE" "cross-package-shadows-any:"
assert_jsonl_has_prefix near-duplicates.jq "$TYPES_FIXTURE" "near-duplicates:" --argjson threshold 0.5
assert_jsonl_has_prefix near-duplicates-any.jq "$TYPES_FIXTURE" "near-duplicates-any:" --argjson threshold 0.5
assert_jsonl_has_prefix cross-package-shape-near-duplicates.jq "$TYPES_FIXTURE" "cross-package-shape-near-duplicates:" --argjson threshold 0.5
assert_jsonl_has_prefix cross-package-shape-near-duplicates-any.jq "$TYPES_FIXTURE" "cross-package-shape-near-duplicates-any:" --argjson threshold 0.5
assert_jsonl_has_prefix subset-pairs.jq "$TYPES_FIXTURE" "subset-pairs:"
assert_jsonl_has_prefix protocol-inheritance-candidates.jq "$TYPES_FIXTURE" "protocol-inheritance-candidates:" --argjson min_overlap 2
assert_jsonl_has_prefix pat-candidates.jq "$TYPES_FIXTURE" "pat-candidates:" --argjson max_slot_diffs 1
assert_jsonl_has_prefix generic-struct-candidates.jq "$TYPES_FIXTURE" "generic-struct-candidates:" --argjson max_slot_diffs 1

echo ""
echo "=== Function-catalog query ==="
assert_jsonl_has_prefix function-duplicates.jq "$FUNCS_FIXTURE" "function-duplicates-" --argjson threshold 0.5
assert_jsonl_has_prefix default-impl-candidates.jq "$FUNCS_FIXTURE" "default-impl-candidates:" --argjson min_conformers 2
assert_jsonl_has_prefix generic-function-candidates.jq "$FUNCS_FIXTURE" "generic-function-candidates:" --argjson threshold 0.5 --argjson max_subs 2

echo ""
echo "=== File-hash query ==="
assert_jsonl_has_prefix file-duplicates.jq "$FILES_FIXTURE" "file-duplicates-"

echo ""
echo "=== Migration-progress queries ==="
assert_jsonl_has_prefix migration-progress.jq "$MIGRATION_FIXTURE" "migration-progress:" \
  --arg old_sig "id:number" --arg new_sig "id:string" --arg label "Id-migration"
assert_jsonl_has_prefix shape-sig-frequency.jq "$MIGRATION_FIXTURE" "shape-sig-frequency:"

# Semantic correctness for migration-progress. The fixture is hand-tuned:
#   id:number — OldA (touched), OldB             → 2 on old, 1 straggler
#   id:string — NewA, NewB (touched), SharedNewA → 3 on new
#   GeneratedOld is excluded by default (generated:true).
# With package="main" filter, SharedNewA drops out: 2 on old, 2 on new = 50%, straggler = OldA.
assert_migration_progress_semantic() {
  local label="$1"; shift
  local expected_on_old="$1"; shift
  local expected_on_new="$1"; shift
  local expected_pct="$1"; shift
  local expected_stragglers="$1"; shift   # comma-separated names, "" for none
  # Arg shape: [ENV=val ...] -- [--arg key val ...]
  # Tokens before "--" become env-var prefix; tokens after are jq args.
  local env_prefix=()
  while (( $# > 0 )) && [[ "$1" != "--" ]]; do
    env_prefix+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  local jq_args=("$@")

  local result
  result="$(env OUTPUT_FORMAT=jsonl "${env_prefix[@]}" \
    jq -L "$QUERIES_DIR" -r "${jq_args[@]}" \
    -f "$QUERIES_DIR/migration-progress.jq" "$MIGRATION_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ migration-progress (%s): crashed: %s\n" "$label" "$result"
    return
  }

  local on_old on_new pct stragglers
  IFS=$'\t' read -r on_old on_new pct stragglers < <(echo "$result" \
    | jq -r '[.on_old, .on_new, .percent_migrated, (.stragglers | map(.name) | join(","))] | @tsv')

  if [[ "$on_old" == "$expected_on_old" \
     && "$on_new" == "$expected_on_new" \
     && "$pct"    == "$expected_pct" \
     && "$stragglers" == "$expected_stragglers" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ migration-progress (%s): on_old=%s on_new=%s pct=%s stragglers=[%s]\n" \
      "$label" "$on_old" "$on_new" "$pct" "$stragglers"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ migration-progress (%s): got (on_old=%s on_new=%s pct=%s stragglers=[%s]), expected (on_old=%s on_new=%s pct=%s stragglers=[%s])\n" \
      "$label" "$on_old" "$on_new" "$pct" "$stragglers" \
      "$expected_on_old" "$expected_on_new" "$expected_pct" "$expected_stragglers"
  fi
}

# Baseline (no filters): default excludes generated. main has 2 old + 2 new; shared adds 1 new → 2/3, 60%.
assert_migration_progress_semantic "baseline" 2 3 60 "OldA" \
  -- --arg old_sig "id:number" --arg new_sig "id:string" --arg label "Id-migration"

# Package filter restricts to main: 2 old + 2 new = 50%.
assert_migration_progress_semantic "PACKAGE=main" 2 2 50 "OldA" \
  PACKAGE=main \
  -- --arg old_sig "id:number" --arg new_sig "id:string" --arg label "Id-migration"

# Include generated: GeneratedOld also matches id:number → 3 old, 3 new (still 50%, +1 GeneratedOld on old).
assert_migration_progress_semantic "INCLUDE_GENERATED=true" 3 3 50 "OldA" \
  INCLUDE_GENERATED=true \
  -- --arg old_sig "id:number" --arg new_sig "id:string" --arg label "Id-migration"

# 100% migrated: no rows match old_sig.
assert_migration_progress_semantic "100pct" 0 3 100 "" \
  -- --arg old_sig "does:not:exist" --arg new_sig "id:string" --arg label "Hypothetical"

# 0% migrated: no rows match new_sig. OldA is the only touched-in-window straggler.
assert_migration_progress_semantic "0pct" 2 0 0 "OldA" \
  -- --arg old_sig "id:number" --arg new_sig "does:not:exist" --arg label "Hypothetical"

# No matches at all: division-by-zero guard. Both sigs absent → 0/0 collapses to 0% (denom guard).
assert_migration_progress_semantic "no_matches" 0 0 0 "" \
  -- --arg old_sig "no:match:a" --arg new_sig "no:match:b" --arg label "Nothing"

# Sigs identical: should emit a warning row. The JSONL surface still has on_old/on_new
# populated, but sigs_identical=true. Verify the flag.
assert_migration_progress_sigs_identical() {
  local result flag on_old on_new pct
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    --arg old_sig "id:number" --arg new_sig "id:number" --arg label "Degenerate" \
    -f "$QUERIES_DIR/migration-progress.jq" "$MIGRATION_FIXTURE" 2>&1)"
  IFS=$'\t' read -r flag on_old on_new pct < <(echo "$result" \
    | jq -r '[.sigs_identical, .on_old, .on_new, .percent_migrated] | @tsv')
  # When sigs match, the numeric fields should zero out so JSONL consumers don't
  # silently consume double-counted on_old/on_new and a meaningless 50% pct.
  if [[ "$flag" == "true" && "$on_old" == "0" && "$on_new" == "0" && "$pct" == "0" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ migration-progress (sigs_identical): flag set, numerics zeroed\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ migration-progress (sigs_identical): expected flag=true with on_old/on_new/pct all 0, got flag=%s on_old=%s on_new=%s pct=%s\n" \
      "$flag" "$on_old" "$on_new" "$pct"
  fi
}
assert_migration_progress_sigs_identical

# JSONL row-count invariant: migration-progress emits exactly one row per
# invocation (it's a single-cluster query keyed on the user's label). Lock this
# in so a future refactor that accidentally fans out is caught.
assert_migration_progress_single_row() {
  local result line_count
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    --arg old_sig "id:number" --arg new_sig "id:string" --arg label "Id-migration" \
    -f "$QUERIES_DIR/migration-progress.jq" "$MIGRATION_FIXTURE" 2>&1)"
  line_count="$(echo "$result" | grep -c .)"
  if [[ "$line_count" == "1" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ migration-progress (single-row invariant): 1 JSONL row\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ migration-progress (single-row invariant): expected 1 row, got %s\n" "$line_count"
  fi
}
assert_migration_progress_single_row

# KIND_PREFIX filter: with zod-object rows in the fixture (sigs x:zod-string and
# x:zod-number), KIND_PREFIX=zod restricts $all to the two zod rows; setting old
# and new to those sigs yields 1/1, 50%, ZodOldX as straggler (touched_in_window).
assert_migration_progress_semantic "KIND_PREFIX=zod" 1 1 50 "ZodOldX" \
  KIND_PREFIX=zod \
  -- --arg old_sig "x:zod-string" --arg new_sig "x:zod-number" --arg label "Zod-shape-migration"

# Cluster_id slug: spaces and other non-identifier chars in the label must not
# leak into the cluster_id (downstream parsers split on whitespace).
assert_migration_progress_cluster_id_slug() {
  local result cid
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    --arg old_sig "id:number" --arg new_sig "id:string" --arg label "Id type migration" \
    -f "$QUERIES_DIR/migration-progress.jq" "$MIGRATION_FIXTURE" 2>&1)"
  cid="$(echo "$result" | jq -r '.cluster_id')"
  if [[ "$cid" == "migration-progress:Id-type-migration" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ migration-progress (cluster_id slug): '%s' (label normalized)\n" "$cid"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ migration-progress (cluster_id slug): expected 'migration-progress:Id-type-migration', got '%s'\n" "$cid"
  fi
}
assert_migration_progress_cluster_id_slug

# Text-mode straggler line: the cid= marker assertion only checks for one
# substring; lock in the actual straggler-row format too so a future refactor
# that drops the file:line tail or the [kind] brackets is caught.
assert_migration_progress_text_straggler() {
  local text
  text="$(jq -L "$QUERIES_DIR" -r \
    --arg old_sig "id:number" --arg new_sig "id:string" --arg label "Id-migration" \
    -f "$QUERIES_DIR/migration-progress.jq" "$MIGRATION_FIXTURE" 2>&1)"
  if [[ "$text" == *"    OldA [interface] — main:a.ts:1"* ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ migration-progress (text straggler line): rendered\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ migration-progress (text straggler line): missing 'OldA [interface] — main:a.ts:1' in:\n%s\n" "$text"
  fi
}
assert_migration_progress_text_straggler

# shape-sig-frequency knob coverage. The bare prefix/cid assertions above don't
# exercise PACKAGE / KIND_PREFIX / INCLUDE_GENERATED / MIN_COUNT / SAMPLE_SIZE.
# These mirror the migration-progress.jq coverage so the discovery sibling
# carries the same regression net.
#
# Reads one shape-sig-frequency row whose shape_sig matches the target and
# returns its `count` field. Returns empty string if no row matches.
shape_sig_count() {
  local target_sig="$1"
  local jsonl="$2"
  echo "$jsonl" | jq -rs --arg sig "$target_sig" '.[] | select(.shape_sig == $sig) | .count'
}

assert_shape_sig_frequency_knob() {
  local label="$1"; shift
  local target_sig="$1"; shift
  local expected_count="$1"; shift
  local env_prefix=()
  while (( $# > 0 )) && [[ "$1" != "--" ]]; do
    env_prefix+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  local jq_args=("$@")

  local result actual
  result="$(env OUTPUT_FORMAT=jsonl "${env_prefix[@]}" \
    jq -L "$QUERIES_DIR" -r "${jq_args[@]}" \
    -f "$QUERIES_DIR/shape-sig-frequency.jq" "$MIGRATION_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ shape-sig-frequency (%s): crashed: %s\n" "$label" "$result"
    return
  }
  actual="$(shape_sig_count "$target_sig" "$result")"
  if [[ "$actual" == "$expected_count" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ shape-sig-frequency (%s): %s count=%s\n" "$label" "$target_sig" "$actual"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ shape-sig-frequency (%s): %s count=%s, expected %s. full output:\n%s\n" \
      "$label" "$target_sig" "$actual" "$expected_count" "$result"
  fi
}

# Default excludes generated: id:number has OldA + OldB = 2 (GeneratedOld is filtered).
assert_shape_sig_frequency_knob "baseline excludes generated" "id:number" 2 --

# INCLUDE_GENERATED=true: GeneratedOld also matches id:number → 3.
assert_shape_sig_frequency_knob "INCLUDE_GENERATED=true" "id:number" 3 \
  INCLUDE_GENERATED=true --

# PACKAGE=shared: only SharedNewA matches id:string → fixture row needs MIN_COUNT=1 to surface.
assert_shape_sig_frequency_knob "PACKAGE=shared" "id:string" 1 \
  PACKAGE=shared MIN_COUNT=1 --

# KIND_PREFIX=zod: restricts to the two zod-object rows; each shape_sig appears once,
# so MIN_COUNT=1 needed to keep the rows.
assert_shape_sig_frequency_knob "KIND_PREFIX=zod" "x:zod-string" 1 \
  KIND_PREFIX=zod MIN_COUNT=1 --

# MIN_COUNT=3 floor: only id:string clears (3 rows); id:number (2) drops out.
assert_shape_sig_frequency_knob "MIN_COUNT=3 keeps id:string" "id:string" 3 \
  MIN_COUNT=3 --
assert_shape_sig_frequency_knob "MIN_COUNT=3 drops id:number" "id:number" "" \
  MIN_COUNT=3 --

# Cluster_id slug: when shape_sig carries whitespace (allowed by the canonical
# contract — TS-normalized union types like `string | null` propagate spaces),
# the cluster_id must still be a single whitespace-free token. Construct a
# minimal synthetic fixture and check the slugged id.
assert_shape_sig_frequency_cluster_id_slug() {
  local tmp_fixture result cid sig
  tmp_fixture="$(mktemp)"
  cat > "$tmp_fixture" <<'EOF'
[
  {"name":"A","kind":"interface","package":"main","file":"a.ts","line":1,"shape_sig":"foo:bar | baz","fields":["foo:bar | baz"],"touched_in_window":false,"generated":false},
  {"name":"B","kind":"interface","package":"main","file":"b.ts","line":2,"shape_sig":"foo:bar | baz","fields":["foo:bar | baz"],"touched_in_window":false,"generated":false}
]
EOF
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/shape-sig-frequency.jq" "$tmp_fixture" 2>&1)"
  rm -f "$tmp_fixture"
  cid="$(echo "$result" | jq -r '.cluster_id')"
  sig="$(echo "$result" | jq -r '.shape_sig')"
  # cluster_id must be whitespace-free; verbatim shape_sig is preserved in the data field.
  if [[ "$cid" == "shape-sig-frequency:foo:bar-|-baz" && "$sig" == "foo:bar | baz" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ shape-sig-frequency (cluster_id slug): cid='%s' shape_sig='%s'\n" "$cid" "$sig"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ shape-sig-frequency (cluster_id slug): expected cid='shape-sig-frequency:foo:bar-|-baz' shape_sig='foo:bar | baz', got cid='%s' shape_sig='%s'\n" \
      "$cid" "$sig"
  fi
}
assert_shape_sig_frequency_cluster_id_slug

echo ""
echo "=== Generic-parameter queries ==="
assert_jsonl_has_prefix generic-arity-drift.jq "$GENERICS_FIXTURE" "generic-arity-drift:"
assert_jsonl_has_prefix generic-convention-bound.jq "$GENERICS_FIXTURE" "generic-convention-bound:"

assert_generic_arity_drift_present() {
  local label="$1"; shift
  local target_name="$1"; shift
  local expected_arities_csv="$1"; shift

  local result actual
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/generic-arity-drift.jq" "$GENERICS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ generic-arity-drift (%s): crashed: %s\n" "$label" "$result"
    return
  }
  actual="$(echo "$result" | jq -rs --arg n "$target_name" \
    '.[] | select(.name == $n) | (.decls | map(.arity) | sort | join(","))')"

  if [[ "$actual" == "$expected_arities_csv" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ generic-arity-drift (%s): %s arities=%s\n" "$label" "$target_name" "$actual"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ generic-arity-drift (%s): %s expected arities=%s, got '%s'\n" \
      "$label" "$target_name" "$expected_arities_csv" "$actual"
  fi
}

assert_generic_arity_drift_absent() {
  local label="$1"; shift
  local target_name="$1"; shift

  local result count
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/generic-arity-drift.jq" "$GENERICS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ generic-arity-drift (%s): crashed: %s\n" "$label" "$result"
    return
  }
  count="$(echo "$result" | jq -rs --arg n "$target_name" \
    '[.[] | select(.name == $n)] | length')"

  if [[ "$count" == "0" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ generic-arity-drift (%s): %s absent\n" "$label" "$target_name"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ generic-arity-drift (%s): %s should be absent, but %s row(s) match\n" \
      "$label" "$target_name" "$count"
  fi
}

assert_generic_arity_drift_present "Repository present"  "Repository"     "1,2"
assert_generic_arity_drift_present "Foo cross-kind"      "Foo"            "1,2"
assert_generic_arity_drift_absent  "SyncResult single"   "SyncResult"
assert_generic_arity_drift_absent  "Bar single"          "Bar"
assert_generic_arity_drift_absent  "ShouldNotGroup kind" "ShouldNotGroup"

# Arg shape (both helpers): label target_name [expected_suspects_csv]
#   [ENV=val ...] -- [--arg key val ...]
# Tokens before "--" become env-var prefix; tokens after are jq args.
_parse_env_and_jq_args() {
  env_prefix=()
  while (( $# > 0 )) && [[ "$1" != "--" ]]; do
    env_prefix+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  jq_args=("$@")
}

assert_generic_convention_bound_present() {
  local label="$1"; shift
  local target_name="$1"; shift
  local expected_suspects_csv="$1"; shift
  local env_prefix jq_args
  _parse_env_and_jq_args "$@"

  local result actual
  result="$(env OUTPUT_FORMAT=jsonl "${env_prefix[@]}" \
    jq -L "$QUERIES_DIR" -r "${jq_args[@]}" \
    -f "$QUERIES_DIR/generic-convention-bound.jq" "$GENERICS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ generic-convention-bound (%s): crashed: %s\n" "$label" "$result"
    return
  }
  actual="$(echo "$result" | jq -rs --arg n "$target_name" \
    '.[] | select(.name == $n) | (.suspects | sort | join(","))')"

  if [[ "$actual" == "$expected_suspects_csv" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ generic-convention-bound (%s): %s suspects=%s\n" "$label" "$target_name" "$actual"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ generic-convention-bound (%s): %s expected suspects=%s, got '%s'\n" \
      "$label" "$target_name" "$expected_suspects_csv" "$actual"
  fi
}

assert_generic_convention_bound_absent() {
  local label="$1"; shift
  local target_name="$1"; shift
  local env_prefix jq_args
  _parse_env_and_jq_args "$@"

  local result count
  result="$(env OUTPUT_FORMAT=jsonl "${env_prefix[@]}" \
    jq -L "$QUERIES_DIR" -r "${jq_args[@]}" \
    -f "$QUERIES_DIR/generic-convention-bound.jq" "$GENERICS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ generic-convention-bound (%s): crashed: %s\n" "$label" "$result"
    return
  }
  count="$(echo "$result" | jq -rs --arg n "$target_name" \
    '[.[] | select(.name == $n)] | length')"

  if [[ "$count" == "0" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ generic-convention-bound (%s): %s absent\n" "$label" "$target_name"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ generic-convention-bound (%s): %s should be absent, but %s row(s) match\n" \
      "$label" "$target_name" "$count"
  fi
}

assert_generic_convention_bound_present "SyncResult TStats"   "SyncResult"  "TStats"  --
assert_generic_convention_bound_present "BackfillJob TOutput" "BackfillJob" "TOutput" --

assert_generic_convention_bound_absent "Bar bound T"        "Bar"               --
assert_generic_convention_bound_absent "Repository bound"   "Repository"        --
assert_generic_convention_bound_absent "Baz built-ins only" "Baz"               --
assert_generic_convention_bound_absent "Order app types"    "Order"             --
assert_generic_convention_bound_absent "Foo bound T,U"      "Foo"               --
assert_generic_convention_bound_absent "BuiltinExhaustion"  "BuiltinExhaustion" --

# EXTRA_BUILTINS extends the allowlist via comma-joined env var.
assert_generic_convention_bound_absent "EXTRA_BUILTINS=TStats drops SyncResult" \
  "SyncResult"  EXTRA_BUILTINS=TStats --
assert_generic_convention_bound_absent "EXTRA_BUILTINS=TStats,TOutput drops SyncResult" \
  "SyncResult"  EXTRA_BUILTINS=TStats,TOutput --
assert_generic_convention_bound_absent "EXTRA_BUILTINS=TStats,TOutput drops BackfillJob" \
  "BackfillJob" EXTRA_BUILTINS=TStats,TOutput --

# Whitespace tolerance: humans naturally write `Foo, Bar` (with a space) from
# the shell. Each split-on-comma site must trim surrounding whitespace so the
# allowlist subtraction matches `Bar` regardless of how the user spaced it.
assert_generic_convention_bound_absent "EXTRA_BUILTINS='TStats, TOutput' (whitespace) drops SyncResult" \
  "SyncResult"  "EXTRA_BUILTINS=TStats, TOutput" --
assert_generic_convention_bound_absent "EXTRA_BUILTINS='TStats, TOutput' (whitespace) drops BackfillJob" \
  "BackfillJob" "EXTRA_BUILTINS=TStats, TOutput" --

# Whitespace tolerance: bound `generics` field. Current TS/Swift extractors
# emit comma-only joins, but the contract does not pin whitespace and a
# hand-edited fixture or a future extractor could emit `"T, K"`. The query
# must still treat K as bound (not as an unbound suspect).
assert_generic_convention_bound_whitespace_generics() {
  local tmp_fixture result count
  tmp_fixture="$(mktemp)"
  cat > "$tmp_fixture" <<'EOF'
[
  {"name":"WithSpaces","kind":"interface","package":"main","file":"a.ts","line":1,"shape_sig":"x:T|y:K","fields":["x:T","y:K"],"generics":"T, K","touched_in_window":false,"generated":false}
]
EOF
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/generic-convention-bound.jq" "$tmp_fixture" 2>&1)"
  rm -f "$tmp_fixture"
  count="$(echo "$result" | jq -rs 'length')"
  if [[ "$count" == "0" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ generic-convention-bound (generics='T, K' whitespace): K treated as bound, no suspects\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ generic-convention-bound (generics='T, K' whitespace): expected no rows, got %s. output:\n%s\n" \
      "$count" "$result"
  fi
}
assert_generic_convention_bound_whitespace_generics

echo ""
echo "=== Touched-window debt summary ==="
assert_jsonl_has_prefix touched-window-debt-summary.jq "$DEBT_SUMMARY_FIXTURE" "touched-window-debt-summary:"

# Fixture cross-pollination is intentionally suppressed for deterministic
# counts: the User cross-package-shadow rows share file="user.ts" across
# packages so name-collisions's ≥2-distinct-files filter drops them.
# Expected per-type: exact-duplicates 1/2, name-collisions 1/2,
# cross-package-shadows 0/1, near-duplicates 1/2.
_debt_summary_run() {
  env OUTPUT_FORMAT=jsonl "${env_prefix[@]}" \
    jq -L "$QUERIES_DIR" -r "${jq_args[@]}" \
    -f "$QUERIES_DIR/touched-window-debt-summary.jq" "$DEBT_SUMMARY_FIXTURE" 2>&1
}

assert_debt_summary_row() {
  local label="$1"; shift
  local cluster_type="$1"; shift
  local expected_touched="$1"; shift
  local expected_total="$1"; shift
  local env_prefix jq_args
  _parse_env_and_jq_args "$@"

  local result actual_touched actual_total
  result="$(_debt_summary_run)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ debt-summary-row (%s): crashed: %s\n" "$label" "$result"
    return
  }
  IFS=$'\t' read -r actual_touched actual_total < <(echo "$result" \
    | jq -rs --arg ct "$cluster_type" '.[] | select(.cluster_type == $ct) | [.touched, .total] | @tsv')

  if [[ "$actual_touched" == "$expected_touched" && "$actual_total" == "$expected_total" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ debt-summary-row (%s): %s touched=%s/total=%s\n" \
      "$label" "$cluster_type" "$actual_touched" "$actual_total"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ debt-summary-row (%s): %s expected touched=%s/total=%s, got touched=%s/total=%s\n" \
      "$label" "$cluster_type" "$expected_touched" "$expected_total" "$actual_touched" "$actual_total"
  fi
}

assert_debt_summary_row "baseline exact-duplicates"      "exact-duplicates"      1 2 --
assert_debt_summary_row "baseline name-collisions"       "name-collisions"       1 2 --
assert_debt_summary_row "baseline cross-package-shadows" "cross-package-shadows" 0 1 --
assert_debt_summary_row "baseline near-duplicates"       "near-duplicates"       1 2 --

assert_debt_summary_touched_cluster() {
  local label="$1"; shift
  local cluster_type="$1"; shift
  local cid_substring="$1"; shift
  local env_prefix=() jq_args=()

  local result has_match
  result="$(_debt_summary_run)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ debt-summary-touched-cluster (%s): crashed: %s\n" "$label" "$result"
    return
  }
  has_match="$(echo "$result" \
    | jq -rs --arg ct "$cluster_type" --arg s "$cid_substring" \
      '.[] | select(.cluster_type == $ct) | .touched_clusters | any(.cluster_id | contains($s))')"

  if [[ "$has_match" == "true" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ debt-summary-touched-cluster (%s): %s contains source cid matching '%s'\n" \
      "$label" "$cluster_type" "$cid_substring"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ debt-summary-touched-cluster (%s): %s expected a touched cluster with cid containing '%s'. output:\n%s\n" \
      "$label" "$cluster_type" "$cid_substring" "$result"
  fi
}

assert_debt_summary_touched_cluster "Foo in exact-duplicates"        "exact-duplicates"  "Foo"
assert_debt_summary_touched_cluster "Repository in name-collisions"  "name-collisions"   "Repository"
assert_debt_summary_touched_cluster "Person in near-duplicates"      "near-duplicates"   "Person"

# Banner grep matches `--touched <pr.json>` — the actionable CLI invariant —
# rather than the prose phrasing, so paraphrasing the banner copy doesn't
# silently invalidate the test.
assert_debt_summary_no_context_banner() {
  local text
  text="$(jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/touched-window-debt-summary.jq" "$DEBT_SUMMARY_NO_CONTEXT_FIXTURE" 2>&1)"
  if [[ "$text" == *"--touched <pr.json>"* ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ debt-summary (no-context banner): rendered\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ debt-summary (no-context banner): expected banner in:\n%s\n" "$text"
  fi
}
assert_debt_summary_no_context_banner

assert_debt_summary_no_context_jsonl_zeros() {
  local result max_touched
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/touched-window-debt-summary.jq" "$DEBT_SUMMARY_NO_CONTEXT_FIXTURE" 2>&1)"
  max_touched="$(echo "$result" | jq -rs '[.[].touched] | max')"
  if [[ "$max_touched" == "0" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ debt-summary (no-context JSONL): all rows have touched=0\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ debt-summary (no-context JSONL): expected max touched=0, got %s. output:\n%s\n" \
      "$max_touched" "$result"
  fi
}
assert_debt_summary_no_context_jsonl_zeros

# Two invocations are needed: this assertion is presence-vs-absence on the
# detail block, which can only be observed by diffing baseline against the
# ONLY_TOUCHED=true run.
assert_debt_summary_only_touched_text() {
  local with_only_touched without_only_touched
  with_only_touched="$(env OUTPUT_FORMAT=text ONLY_TOUCHED=true jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/touched-window-debt-summary.jq" "$DEBT_SUMMARY_FIXTURE" 2>&1)"
  without_only_touched="$(env OUTPUT_FORMAT=text jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/touched-window-debt-summary.jq" "$DEBT_SUMMARY_FIXTURE" 2>&1)"
  if [[ "$with_only_touched"    != *"cross-package-shadows detail"* \
     && "$without_only_touched" == *"cross-package-shadows detail"* \
     && "$with_only_touched"    == *"cross-package-shadows: 0 touched"* ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ debt-summary (ONLY_TOUCHED=true): cross-package-shadows detail suppressed, header row kept\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ debt-summary (ONLY_TOUCHED=true): expected detail block suppressed but header kept. with_only_touched:\n%s\n" "$with_only_touched"
  fi
}
assert_debt_summary_only_touched_text

# THRESHOLD=0.99 lifts the Jaccard floor above both fixture pairs (each at
# 0.8), so the near-duplicates row collapses to 0/0.
assert_debt_summary_row "THRESHOLD=0.99 collapses near-duplicates" \
  "near-duplicates" 0 0 \
  THRESHOLD=0.99 --

echo ""
echo "=== Text-mode cid= markers ==="
assert_text_has_cid exact-duplicates.jq "$TYPES_FIXTURE"
assert_text_has_cid name-collisions.jq "$TYPES_FIXTURE"
assert_text_has_cid cross-package-shadows.jq "$TYPES_FIXTURE"
assert_text_has_cid cross-package-shadows-any.jq "$TYPES_FIXTURE"
assert_text_has_cid near-duplicates.jq "$TYPES_FIXTURE" --argjson threshold 0.5
assert_text_has_cid near-duplicates-any.jq "$TYPES_FIXTURE" --argjson threshold 0.5
assert_text_has_cid cross-package-shape-near-duplicates.jq "$TYPES_FIXTURE" --argjson threshold 0.5
assert_text_has_cid cross-package-shape-near-duplicates-any.jq "$TYPES_FIXTURE" --argjson threshold 0.5
assert_text_has_cid subset-pairs.jq "$TYPES_FIXTURE"
assert_text_has_cid protocol-inheritance-candidates.jq "$TYPES_FIXTURE" --argjson min_overlap 2
assert_text_has_cid pat-candidates.jq "$TYPES_FIXTURE" --argjson max_slot_diffs 1
assert_text_has_cid generic-struct-candidates.jq "$TYPES_FIXTURE" --argjson max_slot_diffs 1
assert_text_has_cid function-duplicates.jq "$FUNCS_FIXTURE" --argjson threshold 0.5
assert_text_has_cid default-impl-candidates.jq "$FUNCS_FIXTURE" --argjson min_conformers 2
assert_text_has_cid generic-function-candidates.jq "$FUNCS_FIXTURE" --argjson threshold 0.5 --argjson max_subs 2
assert_text_has_cid file-duplicates.jq "$FILES_FIXTURE"
assert_text_has_cid migration-progress.jq "$MIGRATION_FIXTURE" \
  --arg old_sig "id:number" --arg new_sig "id:string" --arg label "Id-migration"
assert_text_has_cid shape-sig-frequency.jq "$MIGRATION_FIXTURE"
assert_text_has_cid generic-arity-drift.jq "$GENERICS_FIXTURE"
assert_text_has_cid generic-convention-bound.jq "$GENERICS_FIXTURE"
assert_text_has_cid touched-window-debt-summary.jq "$DEBT_SUMMARY_FIXTURE"

echo ""
echo "=== Cross-catalog queries ==="
# cross-catalog queries take two slurped catalogs rather than a single input,
# so the assert_jsonl_has_prefix helper doesn't fit — inline the assertion.
# The TYPES_FIXTURE has `package: "main"` and `package: "shared"` records; we
# split into two synthetic catalogs for the test.
CROSS_LEFT="$(mktemp)"
CROSS_RIGHT="$(mktemp)"
trap 'rm -f "$CROSS_LEFT" "$CROSS_RIGHT"' EXIT
jq '[.[] | select(.package == "main")]'   "$TYPES_FIXTURE" > "$CROSS_LEFT"
jq '[.[] | select(.package == "shared")]' "$TYPES_FIXTURE" > "$CROSS_RIGHT"

assert_cross_catalog_jsonl() {
  local query="$1"
  local expected_prefix="$2"
  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl LEFT_LABEL=left RIGHT_LABEL=right \
    jq -n -L "$QUERIES_DIR" \
      --slurpfile left "$CROSS_LEFT" --slurpfile right "$CROSS_RIGHT" \
      -rf "$QUERIES_DIR/$query" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ %s: query crashed: %s\n" "$query" "$jsonl"
    return
  }
  if [[ -z "$jsonl" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ %s: produced no clusters (fixture has ShadowedName in both packages — should match)\n" "$query"
    return
  fi
  local line_count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    line_count=$((line_count + 1))
    if ! echo "$line" | jq empty 2>/dev/null; then
      FAIL=$((FAIL + 1))
      printf "  ✗ %s line %d: invalid JSON\n" "$query" "$line_count"
      return
    fi
    local cid
    cid="$(echo "$line" | jq -r '.cluster_id')"
    if [[ "$cid" != "$expected_prefix"* ]]; then
      FAIL=$((FAIL + 1))
      printf "  ✗ %s line %d: cluster_id '%s' does not start with '%s'\n" "$query" "$line_count" "$cid" "$expected_prefix"
      return
    fi
  done <<< "$jsonl"
  PASS=$((PASS + 1))
  printf "  ✓ %s: %d JSONL row(s), all with cluster_id starting '%s'\n" "$query" "$line_count" "$expected_prefix"
}

assert_cross_catalog_jsonl cross-catalog-name-collisions.jq "cross-catalog-name-collisions:"

# Verdict-assignment assertion. The verdict branching (FIELD_NAMES_MATCH /
# FIELD_NAMES_DIVERGE / COMPARISON_UNAVAILABLE) is the query's load-bearing
# classifier — the bare cluster_id-prefix check above doesn't exercise it.
# The fixture's `ShadowedName` declares `[x:Int]` in main and again as
# `[x:Int, y:String]` in main, and `[x:Int]` in shared. Per-catalog union:
#   left  (main)   → ["x", "y"]
#   right (shared) → ["x"]
# → expected verdict: FIELD_NAMES_DIVERGE.
assert_cross_catalog_verdict() {
  local query="$1"
  local target_name="$2"
  local expected_verdict="$3"
  local actual
  actual="$(OUTPUT_FORMAT=jsonl LEFT_LABEL=left RIGHT_LABEL=right \
    jq -n -L "$QUERIES_DIR" \
      --slurpfile left "$CROSS_LEFT" --slurpfile right "$CROSS_RIGHT" \
      -rf "$QUERIES_DIR/$query" 2>/dev/null \
    | jq -rs --arg name "$target_name" '.[] | select(.name == $name) | .verdict' 2>/dev/null)"
  if [[ "$actual" == "$expected_verdict" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s: %s verdict = %s\n" "$query" "$target_name" "$expected_verdict"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s: %s verdict was '%s', expected '%s'\n" "$query" "$target_name" "$actual" "$expected_verdict"
  fi
}

assert_cross_catalog_verdict cross-catalog-name-collisions.jq ShadowedName FIELD_NAMES_DIVERGE

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
