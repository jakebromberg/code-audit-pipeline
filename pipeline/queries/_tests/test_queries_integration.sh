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
INFER_MODEL_SAMPLE_TS="$FIXTURES_DIR/infer-model-sample.ts"
TYPE_CATALOG_BIN="$SCRIPT_DIR/../../../extractors/typescript/type-catalog.mjs"
ORPHAN_INFER_MODEL_FIXTURE="$FIXTURES_DIR/orphan-infer-model.input.json"
IS_TEST_TREE="$FIXTURES_DIR/is-test-tree"
TEST_PROD_DRIFT_FIXTURE="$FIXTURES_DIR/test-prod-drift.input.json"
VERSIONED_TYPE_PAIRS_FIXTURE="$FIXTURES_DIR/versioned-type-pairs.input.json"
COPIED_FROM_HEADER_FIXTURE="$FIXTURES_DIR/copied-from-header.input.json"
MARK_SECTION_DENSITY_FIXTURE="$FIXTURES_DIR/mark-section-density.input.json"
PERSISTENCE_STORE_FIELD_DENSITY_FIXTURE="$FIXTURES_DIR/persistence-store-field-density.input.json"
ALREADY_ABSTRACTED_FIXTURE="$FIXTURES_DIR/already-abstracted.input.json"
SHARED_INTERFACE_FIXTURE="$FIXTURES_DIR/shared-interface-candidates.input.json"
COPIED_LITERAL_FIXTURE="$FIXTURES_DIR/copied-literal-candidates.input.json"
COPIED_LITERAL_STRINGS_FIXTURE="$FIXTURES_DIR/copied-literal-strings.input.json"
MODULE_SYMBOL_DENSITY_FUNCS_FIXTURE="$FIXTURES_DIR/module-symbol-density-functions.input.json"
MODULE_SYMBOL_DENSITY_TYPES_FIXTURE="$FIXTURES_DIR/module-symbol-density-types.input.json"
FCM_FUNCTIONS_FIXTURE="$FIXTURES_DIR/field-copy-mapper-candidates-functions.input.json"
FCM_TYPES_FIXTURE="$FIXTURES_DIR/field-copy-mapper-candidates-types.input.json"

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

assert_envelope_shape() {
  local query="$1"
  local fixture="$2"
  shift 2
  local extra_args=("$@")

  local result
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r "${extra_args[@]}" \
    -f "$QUERIES_DIR/$query" "$fixture" 2>&1 \
    | jq -s 'all(.shape == "cluster" and (.members | length == 1))')"
  if [[ "$result" == "true" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s (envelope): every row has shape:cluster and members of length 1\n" "$query"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s (envelope): expected uniform shape:cluster, members[0]; got %s\n" "$query" "$result"
  fi
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
assert_jsonl_has_prefix shared-interface-candidates.jq "$SHARED_INTERFACE_FIXTURE" "shared-interface-candidates:" --argjson min_intersection 5

# Semantic checks for shared-interface-candidates. Fixture is hand-tuned so
# exactly TWO pairs fire and every exclusion rule is exercised by a pair that
# would otherwise qualify:
#   FIRES  Playcut <-> LikedSongSnapshot   ∩=7 ∪=10 jacc=0.7, conflicting id
#          slot (UInt64 vs String), demoted:false (Sendable is a marker)
#   FIRES  CachedFeed <-> LiveFeed         ∩=5 ∪=7, demoted:true — shared
#          FeedRepresentable conformance, declared via EXTENSION on LiveFeed
#          (pins the conformance_index merge)
#   ---    UserSummary ⊂ UserDetail        no left residue → subset-pairs lane
#   ---    BoundaryLeft/BoundaryRight      jacc exactly 0.9 → near-duplicates lane
#   ---    GodModelA/GodModelB             ∩=5 but jacc≈0.24 < 0.25 floor
#   ---    MediaPlayable/StreamPlayable    both kind:interface → protocol-inheritance lane
#   ---    SettingsModel/SettingsModel     same name → cross-package-shadows lane
#   ---    GeneratedSnapshotDTO            generated:true filtered
#   ---    ThemeOverride/ThemeResolved     every shared slot type-conflicts →
#          all-conflicting (authored-override vs resolved-value) gate
#   ---    EngineCore/EngineController     controller holds core:EngineCore? →
#          containment (wrapper-over-composition) gate
assert_shared_interface_semantic() {
  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --argjson min_intersection 5 \
    -f "$QUERIES_DIR/shared-interface-candidates.jq" "$SHARED_INTERFACE_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ shared-interface-candidates (semantic): crashed: %s\n" "$jsonl"
    return
  }
  local count expected=2
  # `|| true`: grep -c exits 1 on zero matches, which under `set -e` would
  # abort the whole script instead of reaching the row-count diagnostic below.
  count="$(printf '%s\n' "$jsonl" | grep -c . || true)"
  if [[ "$count" != "$expected" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ shared-interface-candidates (semantic): expected %d rows, got %d\n%s\n" "$expected" "$count" "$jsonl"
    return
  fi
  # Un-demoted rows sort first: row 1 must be the Playcut pair.
  local first_ok
  first_ok="$(printf '%s\n' "$jsonl" | head -1 | jq -r \
    '(.left.name == "Playcut" and .right.name == "LikedSongSnapshot" and .demoted == false
      and .intersection == 7 and .union == 10 and .jacc == 0.7) | tostring')"
  if [[ "$first_ok" != "true" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ shared-interface-candidates (semantic): row 1 is not the un-demoted Playcut pair\n%s\n" "$jsonl"
    return
  fi
  # The conflicting id slot is the machine-visible merge blocker.
  local conflict
  conflict="$(printf '%s\n' "$jsonl" | head -1 | jq -c '.conflicting_slots')"
  if [[ "$conflict" != '[{"name":"id","left_type":"UInt64","right_type":"String"}]' ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ shared-interface-candidates (semantic): expected conflicting id slot, got %s\n" "$conflict"
    return
  fi
  # Agreeing slots exclude the conflicting one.
  local shared_names
  shared_names="$(printf '%s\n' "$jsonl" | head -1 | jq -c '[.shared_slots[].name]')"
  if [[ "$shared_names" != '["artistName","artworkURL","labelName","releaseTitle","songTitle","spotifyURL"]' ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ shared-interface-candidates (semantic): unexpected shared_slots names: %s\n" "$shared_names"
    return
  fi
  # Row 2: the feed pair, demoted via extension-declared conformance.
  local second_ok
  second_ok="$(printf '%s\n' "$jsonl" | sed -n 2p | jq -r \
    '(.left.name == "CachedFeed" and .right.name == "LiveFeed" and .demoted == true
      and .intersection == 5 and (.conflicting_slots | length == 0)) | tostring')"
  if [[ "$second_ok" != "true" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ shared-interface-candidates (semantic): row 2 is not the demoted feed pair\n%s\n" "$jsonl"
    return
  fi
  # None of the excluded names may appear on any endpoint.
  local leaked
  leaked="$(printf '%s\n' "$jsonl" | jq -r '.left.name, .right.name' \
    | grep -x -e UserSummary -e UserDetail -e BoundaryLeft -e BoundaryRight \
      -e GodModelA -e GodModelB -e MediaPlayable -e StreamPlayable \
      -e SettingsModel -e GeneratedSnapshotDTO -e FeedRepresentable \
      -e ThemeOverride -e ThemeResolved -e EngineCore -e EngineController || true)"
  if [[ -n "$leaked" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ shared-interface-candidates (semantic): excluded rows leaked into output: %s\n" "$leaked"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ shared-interface-candidates (semantic): 2 rows; Playcut pair first with conflicting id slot; feed pair demoted via extension conformance; all 8 exclusion lanes clean\n"
}
assert_shared_interface_semantic

# symbol-id-collisions hit-path semantic test: the fixture is hand-tuned to
# exercise (a) a real 4-tuple collision (two Y rows with identical package /
# file / name / kind) and (b) a slash-flatten-only ambiguity that the OLD
# slash-joined formula would have falsely collided (Shared / Generated/X.ts
# vs Shared/Generated / X.ts). Asserts exactly 1 collision cluster of 2.
SYMBOL_ID_COLLISIONS_FIXTURE="$FIXTURES_DIR/symbol-id-collisions.input.json"
assert_symbol_id_collisions_semantic() {
  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/symbol-id-collisions.jq" "$SYMBOL_ID_COLLISIONS_FIXTURE")" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ symbol-id-collisions (semantic): query crashed\n"
    return
  }
  local count
  count="$(printf '%s\n' "$jsonl" | grep -c .)"
  if [[ "$count" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ symbol-id-collisions (semantic): expected 1 collision cluster, got %d\n%s\n" "$count" "$jsonl"
    return
  fi
  local members_len
  members_len="$(printf '%s\n' "$jsonl" | jq '.members | length')"
  if [[ "$members_len" != "2" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ symbol-id-collisions (semantic): expected 2 members in collision cluster, got %d\n" "$members_len"
    return
  fi
  local cluster_name
  cluster_name="$(printf '%s\n' "$jsonl" | jq -r '.members[0].name')"
  if [[ "$cluster_name" != "Y" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ symbol-id-collisions (semantic): expected the Y/main/src/y.ts collision; got %s\n" "$cluster_name"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ symbol-id-collisions (semantic): 1 cluster of 2 (Y); slash-flatten-only X pair NOT collided\n"
}
assert_symbol_id_collisions_semantic

echo ""
echo "=== notification-wrapper-grouping query (issue #222) ==="
# Hand-crafted synthetic catalog with two cross-module wrappers for the same
# Notification.Name (expect to cluster), one lone wrapper for a different name
# (expect dropped), and a row without wraps_notification_name (expect ignored).
NOTIF_FIXTURE_TMP="$(mktemp)"
trap 'rm -f "$NOTIF_FIXTURE_TMP"' EXIT
cat > "$NOTIF_FIXTURE_TMP" <<'JSON'
[
  {"name":"PlayerRateDidChangeMessage","kind":"type-alias-object","package":"PlayerCore","file":"PlayerRateDidChangeMessage.swift","line":3,"wraps_notification_name":"AVPlayer.rateDidChangeNotification","touched_in_window":false,"generated":false},
  {"name":"HLSRateDidChangeMessage","kind":"type-alias-object","package":"HLSPlayer","file":"HLSRateDidChangeMessage.swift","line":7,"wraps_notification_name":"AVPlayer.rateDidChangeNotification","touched_in_window":true,"generated":false},
  {"name":"LoneWrapper","kind":"type-alias-object","package":"Other","file":"LoneWrapper.swift","line":2,"wraps_notification_name":".someOtherNotification","touched_in_window":false,"generated":false},
  {"name":"BlankNameMsg","kind":"type-alias-object","package":"Other","file":"BlankNameMsg.swift","line":2,"touched_in_window":false,"generated":false}
]
JSON
assert_jsonl_has_prefix notification-wrapper-grouping.jq "$NOTIF_FIXTURE_TMP" "notification-wrapper-grouping:"

# Semantic: exactly one cluster of two members, named AVPlayer.rateDidChangeNotification.
notif_rows="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r -f "$QUERIES_DIR/notification-wrapper-grouping.jq" "$NOTIF_FIXTURE_TMP")"
notif_count="$(printf '%s\n' "$notif_rows" | grep -c .)"
if [[ "$notif_count" == "1" ]]; then
  PASS=$((PASS + 1))
  printf "  ✓ notification-wrapper-grouping: exactly one cluster row emitted\n"
else
  FAIL=$((FAIL + 1))
  printf "  ✗ notification-wrapper-grouping: expected 1 row, got %s\n%s\n" "$notif_count" "$notif_rows"
fi

cluster_name="$(printf '%s\n' "$notif_rows" | jq -r '.wraps_notification_name')"
member_count="$(printf '%s\n' "$notif_rows" | jq -r '.members | length')"
if [[ "$cluster_name" == "AVPlayer.rateDidChangeNotification" && "$member_count" == "2" ]]; then
  PASS=$((PASS + 1))
  printf "  ✓ notification-wrapper-grouping: cluster keyed on AVPlayer.rateDidChangeNotification with 2 members\n"
else
  FAIL=$((FAIL + 1))
  printf "  ✗ notification-wrapper-grouping: expected name=AVPlayer.rateDidChangeNotification members=2, got name=%s members=%s\n" "$cluster_name" "$member_count"
fi

# Negative cases: LoneWrapper and BlankNameMsg must not appear anywhere.
if ! printf '%s\n' "$notif_rows" | jq -e '.members[] | select(.name=="LoneWrapper" or .name=="BlankNameMsg")' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  printf "  ✓ notification-wrapper-grouping: lone wrapper and null-wrap rows correctly dropped\n"
else
  FAIL=$((FAIL + 1))
  printf "  ✗ notification-wrapper-grouping: lone or null-wrap rows leaked into output:\n%s\n" "$notif_rows"
fi

echo ""
echo "=== already-abstracted demotion (issue #217) ==="
# Per the fixture: SpotifyClient/AppleMusicClient both conform to the real
# protocol MusicService (3 declared fields) → demoted=true. ColdPair1/2 have
# no conforms_to → demoted=false. SendableA/B share only the Sendable marker
# (0 fields, fails the "non-trivial" check) → demoted=false.
assert_demoted_partition() {
  local query="$1"; shift
  local extra_args=("$@")
  local result
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r "${extra_args[@]}" \
    -f "$QUERIES_DIR/$query" "$ALREADY_ABSTRACTED_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ %s demotion: query crashed: %s\n" "$query" "$result"
    return
  }

  local demoted_count not_demoted_count
  demoted_count="$(printf '%s\n' "$result" | jq -s '[.[] | select(.demoted == true)] | length')"
  not_demoted_count="$(printf '%s\n' "$result" | jq -s '[.[] | select(.demoted == false)] | length')"

  if (( demoted_count >= 1 && not_demoted_count >= 1 )); then
    PASS=$((PASS + 1))
    printf "  ✓ %s demotion: %s demoted row(s), %s non-demoted row(s)\n" \
      "$query" "$demoted_count" "$not_demoted_count"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s demotion: expected ≥1 of each, got demoted=%s non-demoted=%s\n%s\n" \
      "$query" "$demoted_count" "$not_demoted_count" "$result"
  fi
}

assert_demoted_partition exact-duplicates.jq
assert_demoted_partition name-collisions.jq
assert_demoted_partition near-duplicates.jq --argjson threshold 0.5

# near-duplicates regression: confirm the MusicService pair (real-protocol)
# is demoted, the ColdPair (no conformance) is not, the Sendable pair (marker
# only) is not, AND the sort order puts un-demoted rows before demoted rows.
nd_result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --argjson threshold 0.5 \
  -f "$QUERIES_DIR/near-duplicates.jq" "$ALREADY_ABSTRACTED_FIXTURE")"
music_demoted="$(printf '%s\n' "$nd_result" \
  | jq -rs '.[] | select((.left.name == "SpotifyClient" and .right.name == "AppleMusicClient") or (.left.name == "AppleMusicClient" and .right.name == "SpotifyClient")) | .demoted')"
cold_demoted="$(printf '%s\n' "$nd_result" \
  | jq -rs '.[] | select((.left.name == "ColdPair1" and .right.name == "ColdPair2") or (.left.name == "ColdPair2" and .right.name == "ColdPair1")) | .demoted')"
sendable_demoted="$(printf '%s\n' "$nd_result" \
  | jq -rs '.[] | select((.left.name == "SendableA" and .right.name == "SendableB") or (.left.name == "SendableB" and .right.name == "SendableA")) | .demoted')"
last_demoted="$(printf '%s\n' "$nd_result" | jq -s '.[-1].demoted')"

if [[ "$music_demoted" == "true" && "$cold_demoted" == "false" \
   && "$sendable_demoted" == "false" && "$last_demoted" == "true" ]]; then
  PASS=$((PASS + 1))
  printf "  ✓ near-duplicates demotion: MusicService pair demoted, ColdPair + Sendable-marker pairs not, demoted sorted to tail\n"
else
  FAIL=$((FAIL + 1))
  printf "  ✗ near-duplicates demotion regression: MusicService=%s ColdPair=%s Sendable=%s last_demoted=%s\n%s\n" \
    "$music_demoted" "$cold_demoted" "$sendable_demoted" "$last_demoted" "$nd_result"
fi

echo ""
echo "=== Function-catalog query ==="
assert_jsonl_has_prefix function-duplicates.jq "$FUNCS_FIXTURE" "function-duplicates-" --argjson threshold 0.5
assert_jsonl_has_prefix default-impl-candidates.jq "$FUNCS_FIXTURE" "default-impl-candidates:" --argjson min_conformers 2
assert_jsonl_has_prefix generic-function-candidates.jq "$FUNCS_FIXTURE" "generic-function-candidates:" --argjson threshold 0.5 --argjson max_subs 2

echo ""
echo "=== File-hash query ==="
assert_jsonl_has_prefix file-duplicates.jq "$FILES_FIXTURE" "file-duplicates-"
assert_jsonl_has_prefix copied-from-header.jq "$COPIED_FROM_HEADER_FIXTURE" "copied-from-header:"
assert_envelope_shape    copied-from-header.jq "$COPIED_FROM_HEADER_FIXTURE"

# Semantic checks for copied-from-header. Fixture has 4 rows:
#   - main:Sources/UI/DebugHUD.swift           — phrase: "copied from"
#   - main:Sources/UI/Plain.swift              — header_match: null (filtered)
#   - shared:Sources/Net/AnyHttpClient.swift   — phrase: "based on" (license-attribution, still surfaces in v1)
#   - main:Sources/UI/Generated.swift          — phrase: "copied from", generated: true (filtered by default)
# Default invocation: 2 rows (DebugHUD, AnyHttpClient). With INCLUDE_GENERATED=true: 3 rows.
assert_copied_from_header_semantic() {
  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/copied-from-header.jq" "$COPIED_FROM_HEADER_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-from-header (semantic): crashed: %s\n" "$jsonl"
    return
  }
  local count expected=2
  count="$(printf '%s\n' "$jsonl" | grep -c .)"
  if [[ "$count" != "$expected" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-from-header (semantic): expected %d rows (default), got %d\n%s\n" "$expected" "$count" "$jsonl"
    return
  fi
  if ! printf '%s\n' "$jsonl" | jq -r '.cluster_id' | grep -qx "copied-from-header:main:Sources/UI/DebugHUD.swift"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-from-header (semantic): missing DebugHUD cluster\n"
    return
  fi
  if printf '%s\n' "$jsonl" | jq -r '.file' | grep -qx "Sources/UI/Plain.swift"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-from-header (semantic): Plain.swift should be filtered (header_match null)\n"
    return
  fi
  if printf '%s\n' "$jsonl" | jq -r '.file' | grep -qx "Sources/UI/Generated.swift"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-from-header (semantic): Generated.swift should be filtered (generated:true)\n"
    return
  fi
  # INCLUDE_GENERATED=true picks up the generated row.
  local jsonl_gen count_gen
  jsonl_gen="$(OUTPUT_FORMAT=jsonl INCLUDE_GENERATED=true jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/copied-from-header.jq" "$COPIED_FROM_HEADER_FIXTURE" 2>&1)"
  count_gen="$(printf '%s\n' "$jsonl_gen" | grep -c .)"
  if [[ "$count_gen" != "3" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-from-header (semantic, INCLUDE_GENERATED): expected 3 rows, got %d\n" "$count_gen"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ copied-from-header (semantic): default %d rows, INCLUDE_GENERATED=true %d rows; Plain/Generated correctly gated\n" "$count" "$count_gen"
}
assert_copied_from_header_semantic

assert_jsonl_has_prefix mark-section-density.jq "$MARK_SECTION_DENSITY_FIXTURE" "mark-section-density:" \
  --argjson min_marks 6 --argjson min_lines 400
assert_envelope_shape    mark-section-density.jq "$MARK_SECTION_DENSITY_FIXTURE" \
  --argjson min_marks 6 --argjson min_lines 400

# Semantic checks for mark-section-density. Fixture has 4 rows:
#   - app:iOS:Sources/Audio/AudioPlayerController.swift  — 13 marks / 812 lines (PASSES defaults)
#   - app:iOS:Sources/UI/Short.swift                     — 8 marks / 200 lines  (filtered at default 400 min_lines)
#   - main:Sources/Data/Sparse.swift                     — 3 marks / 900 lines  (filtered at default 6 min_marks)
#   - main:Sources/Util/NoMarks.swift                    — no mark_count field  (filtered: null mark_count)
# At defaults: exactly 1 row (AudioPlayerController). At min_marks=2/min_lines=100: 3 rows.
assert_mark_section_density_semantic() {
  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    --argjson min_marks 6 --argjson min_lines 400 \
    -f "$QUERIES_DIR/mark-section-density.jq" "$MARK_SECTION_DENSITY_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ mark-section-density (semantic): crashed: %s\n" "$jsonl"
    return
  }
  local count
  count="$(printf '%s\n' "$jsonl" | grep -c .)"
  if [[ "$count" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ mark-section-density (semantic, defaults): expected 1 row, got %d\n%s\n" "$count" "$jsonl"
    return
  fi
  if ! printf '%s\n' "$jsonl" | jq -r '.file' | grep -qx "Sources/Audio/AudioPlayerController.swift"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ mark-section-density (semantic, defaults): missing AudioPlayerController\n"
    return
  fi
  local low_jsonl low_count
  low_jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    --argjson min_marks 2 --argjson min_lines 100 \
    -f "$QUERIES_DIR/mark-section-density.jq" "$MARK_SECTION_DENSITY_FIXTURE" 2>&1)"
  low_count="$(printf '%s\n' "$low_jsonl" | grep -c .)"
  if [[ "$low_count" != "3" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ mark-section-density (semantic, low thresholds): expected 3 rows, got %d\n" "$low_count"
    return
  fi
  # Densest-first ordering: first row must be AudioPlayerController (13 marks).
  local first_file
  first_file="$(printf '%s\n' "$low_jsonl" | head -1 | jq -r '.file')"
  if [[ "$first_file" != "Sources/Audio/AudioPlayerController.swift" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ mark-section-density (semantic): densest-first ordering broken; first file = %s\n" "$first_file"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ mark-section-density (semantic): defaults emit %d row, low thresholds emit %d, densest-first holds\n" "$count" "$low_count"
}
assert_mark_section_density_semantic

# Contract-lock: mark-section-density.jq's docstring promises raw jq invocations
# REQUIRE --argjson min_marks / --argjson min_lines (because jq rejects undefined
# variables at parse time, before any try / catch could run). Running without
# either flag must fail at compile time. The intent here is to detect any future
# change that re-introduces a fragile in-jq fallback claim.
assert_mark_section_density_argjson_required() {
  local err
  if err="$(jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/mark-section-density.jq" \
    "$MARK_SECTION_DENSITY_FIXTURE" 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ mark-section-density (argjson-required): expected compile error, got success\n%s\n" "$err"
    return
  fi
  if ! printf '%s' "$err" | grep -q "is not defined"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ mark-section-density (argjson-required): expected 'is not defined' error, got:\n%s\n" "$err"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ mark-section-density (argjson-required): raw jq without --argjson correctly fails at compile time\n"
}
assert_mark_section_density_argjson_required

echo ""
echo "=== Literal-catalog query ==="
assert_jsonl_has_prefix copied-literal-candidates.jq "$COPIED_LITERAL_FIXTURE" "copied-literal-" \
  --argjson min_sites 3 --argjson min_files 2

# Semantic checks for copied-literal-candidates. The fixture is hand-tuned so
# exactly THREE clusters and THREE pairs fire at defaults, and every gate is
# exercised by a group that would otherwise qualify:
#
# Cluster section (group by value_norm + label; ≥3 sites across ≥2
# package-qualified files):
#   FIRES  padding = 12            3 sites / 3 files; one site spelled "12.0"
#                                  (value_norm collapses spellings)
#   FIRES  animationDuration = 0.3 3 binding sites / 3 files; one spelled "0.30"
#   FIRES  iconSize = 20           3 sites over main:Sources/UI/Icons.swift and
#                                  shared:Sources/UI/Icons.swift — same relative
#                                  path in two packages counts as TWO files
#                                  (min_files counting is package-qualified)
#   ---    frame(width:) = 44      3 sites but 1 file → min_files gate
#   ---    opacity = 0.8           2 sites → min_sites gate (fires at min_sites 2)
#   ---    spacing = 2             3 sites / 3 files but value_norm "2" is denied
#   ---    lineLimit = 3           3rd site is generated:true → only 2 counted
#
# Pair section (bindings only, equal value_norm, different package-qualified
# file or enclosing type, lowercased-substring name match with contained
# length ≥ 4):
#   FIRES  cornerRadius (6.0, ArtworkStyle) <-> placeholderCornerRadius (6)
#          — the wxyc-ios-64 PR #565 motivating case
#   FIRES  gutterWidth <-> contentGutterWidth (16) — same file, different
#          enclosing types
#   FIRES  panelCornerRadius (main) <-> panelCornerRadius (shared) — same
#          relative path AND same enclosing_type but different packages: the
#          copied-file case; only the package distinguishes the two files
#   ---    animationDuration bindings   covered by their fired cluster
#   ---    iconSize bindings            covered by their fired cluster
#   ---    maxRetries = 6               name unrelated to cornerRadius
#   ---    cornerRadius = 8 (CardStyle) value_norm differs from the 6s
#   ---    badgeSize/badgeSizeCompact   same file AND same enclosing_type
#                                       (and same package) → suppressed
#   ---    cap/capacity                 contained name "cap" shorter than 4
#   ---    retryCount/maxRetryCount     value_norm "1" is denied
assert_copied_literal_semantic() {
  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    --argjson min_sites 3 --argjson min_files 2 \
    -f "$QUERIES_DIR/copied-literal-candidates.jq" "$COPIED_LITERAL_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (semantic): crashed: %s\n" "$jsonl"
    return
  }
  local count
  count="$(printf '%s\n' "$jsonl" | grep -c . || true)"
  if [[ "$count" != "6" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (semantic): expected 6 rows, got %d\n%s\n" "$count" "$jsonl"
    return
  fi

  local cluster_ids
  cluster_ids="$(printf '%s\n' "$jsonl" | jq -rs '[.[] | select(.shape == "cluster") | .cluster_id] | sort | join(",")')"
  if [[ "$cluster_ids" != "copied-literal-cluster:animationDuration=0.3,copied-literal-cluster:iconSize=20,copied-literal-cluster:padding=12" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (semantic): unexpected cluster set: %s\n%s\n" "$cluster_ids" "$jsonl"
    return
  fi

  # Package-qualified min_files: the iconSize cluster spans one relative path
  # in two packages and must report file_count 2, not 1.
  local icon_file_count
  icon_file_count="$(printf '%s\n' "$jsonl" | jq -rs \
    '[.[] | select(.cluster_id == "copied-literal-cluster:iconSize=20")][0].file_count')"
  if [[ "$icon_file_count" != "2" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (semantic): iconSize file_count was %s, expected 2 (package-qualified)\n%s\n" "$icon_file_count" "$jsonl"
    return
  fi

  # Spelling collapse: the padding cluster must contain the "12.0" site.
  local has_float_spelling
  has_float_spelling="$(printf '%s\n' "$jsonl" | jq -rs \
    '[.[] | select(.cluster_id == "copied-literal-cluster:padding=12") | .members[] | select(.name == "padding(12.0)")] | length')"
  if [[ "$has_float_spelling" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (semantic): padding cluster lost the 12.0-spelled site\n%s\n" "$jsonl"
    return
  fi

  # Pair section: the cornerRadius mirror, the gutter pair, and the
  # cross-package same-relative-path panelCornerRadius pair.
  local pair_names
  pair_names="$(printf '%s\n' "$jsonl" | jq -rs \
    '[.[] | select(.shape == "pair") | [.left.binding_name, .right.binding_name] | sort | join("+")] | sort | join(",")')"
  if [[ "$pair_names" != "contentGutterWidth+gutterWidth,cornerRadius+placeholderCornerRadius,panelCornerRadius+panelCornerRadius" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (semantic): unexpected pair set: %s\n%s\n" "$pair_names" "$jsonl"
    return
  fi

  # Loosening min_sites to 2 must surface the opacity cluster (2 sites / 2 files).
  local low_has_opacity
  low_has_opacity="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    --argjson min_sites 2 --argjson min_files 2 \
    -f "$QUERIES_DIR/copied-literal-candidates.jq" "$COPIED_LITERAL_FIXTURE" \
    | jq -rs '[.[] | select(.cluster_id == "copied-literal-cluster:opacity=0.8")] | length')"
  if [[ "$low_has_opacity" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (semantic): min_sites=2 did not surface the opacity cluster\n"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ copied-literal-candidates (semantic): 3 clusters + 3 pairs at defaults; all gates hold; min_sites=2 surfaces opacity\n"
}
assert_copied_literal_semantic

# String support (kind-class guard + string deny-list). The query consumes
# string rows once the Swift extractor emits them; this guard is schema-first
# and lands before emission. The hand-tuned copied-literal-strings fixture
# fires exactly FOUR clusters + ONE pair:
#
#   FIRES  playEventName = "wxyc.event.play"  3 string sites / 3 files -> "#str"
#   FIRES  version (int 100)                  3 sites -> numeric cluster
#   FIRES  version (string "100")             3 sites -> DISTINCT "#str" cluster
#          (cross-kind collision guard: identical label+value_norm, two ids)
#   FIRES  sentinel = "-1"                    3 string sites -> "#str" cluster.
#          The numeric deny-list -1/0/1/2 is numeric-only, so a string "-1"
#          (a value, not a structural number) is NOT dropped.
#   FIRES  stationCapFlagKey <-> onTourStationCapFlagKey  the mirrored constant
#
#   ---    blankKey ("")  sepChar (",")  boolFlag ("true")   string deny-list
#   ---    answer (int 42) <-> answerText (string "42")  cross-kind pair guard
#          (equal value_norm + containing names, but different kinds -> no pair)
assert_copied_literal_strings() {
  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    --argjson min_sites 3 --argjson min_files 2 \
    -f "$QUERIES_DIR/copied-literal-candidates.jq" "$COPIED_LITERAL_STRINGS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (strings): crashed: %s\n" "$jsonl"
    return
  }

  local count
  count="$(printf '%s\n' "$jsonl" | grep -c . || true)"
  if [[ "$count" != "5" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (strings): expected 5 rows, got %d\n%s\n" "$count" "$jsonl"
    return
  fi

  local cluster_ids
  cluster_ids="$(printf '%s\n' "$jsonl" | jq -rs '[.[] | select(.shape == "cluster") | .cluster_id] | sort | join(",")')"
  if [[ "$cluster_ids" != "copied-literal-cluster:playEventName=wxyc.event.play#str,copied-literal-cluster:sentinel=-1#str,copied-literal-cluster:version=100,copied-literal-cluster:version=100#str" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (strings): unexpected cluster set: %s\n%s\n" "$cluster_ids" "$jsonl"
    return
  fi

  # The numeric deny-list (-1/0/1/2) is numeric-only: a string "-1" is a value,
  # not a structural number, so it must survive and cluster.
  local sentinel_present
  sentinel_present="$(printf '%s\n' "$jsonl" | jq -rs '[.[] | select(.cluster_id == "copied-literal-cluster:sentinel=-1#str")] | length')"
  if [[ "$sentinel_present" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (strings): string \"-1\" dropped by the numeric deny-list\n%s\n" "$jsonl"
    return
  fi

  # Cross-kind cluster_id collision guard: the string "100" and numeric 100
  # clusters share label+value_norm but MUST stay two distinct ids (the string
  # one suffixed "#str"), never merged into one.
  local num_v str_v
  num_v="$(printf '%s\n' "$jsonl" | jq -rs '[.[] | select(.cluster_id == "copied-literal-cluster:version=100")] | length')"
  str_v="$(printf '%s\n' "$jsonl" | jq -rs '[.[] | select(.cluster_id == "copied-literal-cluster:version=100#str")] | length')"
  if [[ "$num_v" != "1" || "$str_v" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (strings): cross-kind collision not split into distinct ids (num=%s str=%s)\n%s\n" "$num_v" "$str_v" "$jsonl"
    return
  fi

  # The mirrored string constant pairs; value keeps its quotes, value_norm is
  # the decoded (quote-stripped, un-folded) content.
  local pair_ok
  pair_ok="$(printf '%s\n' "$jsonl" | jq -rs '
    [.[] | select(.shape == "pair")
         | select([.left.binding_name, .right.binding_name] | sort == ["onTourStationCapFlagKey", "stationCapFlagKey"])
         | select(.value_norm == "on_tour_for_you_station_cap")
         | select((.left.value | test("^\"")) and (.right.value | test("^\"")))]
    | length')"
  if [[ "$pair_ok" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (strings): mirrored string pair missing/malformed\n%s\n" "$jsonl"
    return
  fi

  # Deny-list: empty, single-char, and boolean-word strings never surface.
  if printf '%s\n' "$jsonl" | grep -Eq 'blankKey|sepChar|boolFlag'; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (strings): a denied string value surfaced\n%s\n" "$jsonl"
    return
  fi

  # Kind-class pair guard: answer (int 42) and answerText (string "42") share
  # value_norm and have containing names but MUST NOT pair across kinds, so the
  # only pair present is the mirrored-constant one (exactly one pair total).
  local pair_count
  pair_count="$(printf '%s\n' "$jsonl" | jq -rs '[.[] | select(.shape == "pair")] | length')"
  if [[ "$pair_count" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ copied-literal-candidates (strings): expected exactly 1 pair (cross-kind pair guard), got %s\n%s\n" "$pair_count" "$jsonl"
    return
  fi

  PASS=$((PASS + 1))
  printf "  ✓ copied-literal-candidates (strings): string cluster + mirrored pair fire; kind-class splits cross-kind ids; deny-list and cross-kind pair guard hold\n"
}
assert_copied_literal_strings

echo ""
echo "=== persistence-store-field-density query (Detector A) ==="
# Fixture has 7 type-alias-object rows:
#   (a) main:AppSettings        — DefaultsStorage? store + 3 stored props + 1 COMPUTED
#                                 (`summary`) + 1 static: spc=3, computed excluded (HIT)
#   (b) main:SessionCache       — UserDefaults store + 2 stored props (threshold-2 only)
#   (c1) main:GeneratedSettings — store + 3 props but generated:true (filtered)
#   (c2) main:SettingsStoreTests— store + 3 props but is_test:true    (filtered)
#   (d) main:PlainModel         — 4 stored props but no store field   (no store)
#   (e) main:ExistentialCache   — `any DefaultsStorage` store + 2 stored props
#                                 (threshold-2 only; proves existential store matches)
#   (f) main:ComputedStoreModel — COMPUTED `defaults: UserDefaults` + 3 stored props:
#                                 the store-typed member is computed, so it is NOT a
#                                 handle and the type is never flagged.
# At the default threshold of 3, exactly one row is flagged: AppSettings.
assert_jsonl_has_prefix persistence-store-field-density.jq "$PERSISTENCE_STORE_FIELD_DENSITY_FIXTURE" \
  "persistence-store-field-density:" --argjson threshold 3
assert_envelope_shape    persistence-store-field-density.jq "$PERSISTENCE_STORE_FIELD_DENSITY_FIXTURE" \
  --argjson threshold 3
assert_text_has_cid      persistence-store-field-density.jq "$PERSISTENCE_STORE_FIELD_DENSITY_FIXTURE" \
  --argjson threshold 3

assert_persistence_store_field_density_semantic() {
  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --argjson threshold 3 \
    -f "$QUERIES_DIR/persistence-store-field-density.jq" \
    "$PERSISTENCE_STORE_FIELD_DENSITY_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (semantic): crashed: %s\n" "$jsonl"
    return
  }
  local count
  count="$(printf '%s\n' "$jsonl" | grep -c .)"
  if [[ "$count" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (semantic): expected exactly 1 flagged row, got %d\n%s\n" "$count" "$jsonl"
    return
  fi
  # The single flagged type must be AppSettings, with stored_property_count 3
  # (the store field and the static `shared` member are both excluded).
  local name spc
  name="$(printf '%s\n' "$jsonl" | jq -r '.name')"
  spc="$(printf '%s\n' "$jsonl" | jq -r '.stored_property_count')"
  if [[ "$name" != "AppSettings" || "$spc" != "3" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (semantic): expected AppSettings/spc=3, got %s/spc=%s\n%s\n" "$name" "$spc" "$jsonl"
    return
  fi
  # The optional store field (DefaultsStorage?) must be recognised after
  # trailing-`?` stripping and surfaced by name.
  if ! printf '%s\n' "$jsonl" | jq -e '.store_fields | any(.name == "defaults")' >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (semantic): optional store field not recognised:\n%s\n" "$jsonl"
    return
  fi
  # The store field must NOT appear among the candidate stored members.
  if printf '%s\n' "$jsonl" | jq -e '.stored_members | any(.name == "defaults")' >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (semantic): store field leaked into stored_members:\n%s\n" "$jsonl"
    return
  fi
  # The computed property 'summary' must NOT be counted as persisted state
  # (is_computed excluded), so spc stays 3 and it never reaches stored_members.
  if printf '%s\n' "$jsonl" | jq -e '.stored_members | any(.name == "summary")' >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (semantic): computed property leaked into stored_members:\n%s\n" "$jsonl"
    return
  fi
  # touched_in_window must flow through.
  if [[ "$(printf '%s\n' "$jsonl" | jq -r '.touched_in_window')" != "true" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (semantic): touched_in_window not carried through:\n%s\n" "$jsonl"
    return
  fi
  # None of the filtered/negative types may leak into any output row. This
  # includes ComputedStoreModel (its only store-typed member is computed, so it
  # has no real handle) and ExistentialCache (below threshold at 3).
  if printf '%s\n' "$jsonl" | jq -e '.name | . == "SessionCache" or . == "GeneratedSettings" or . == "SettingsStoreTests" or . == "PlainModel" or . == "ExistentialCache" or . == "ComputedStoreModel"' >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (semantic): a below-threshold/filtered/no-store type leaked:\n%s\n" "$jsonl"
    return
  fi
  # Lowering the threshold to 2 now flags SessionCache (2 props) and
  # ExistentialCache ('any DefaultsStorage' store + 2 props) alongside AppSettings.
  local low_jsonl low_count
  low_jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --argjson threshold 2 \
    -f "$QUERIES_DIR/persistence-store-field-density.jq" \
    "$PERSISTENCE_STORE_FIELD_DENSITY_FIXTURE" 2>&1)"
  low_count="$(printf '%s\n' "$low_jsonl" | grep -c .)"
  if [[ "$low_count" != "3" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (semantic, threshold=2): expected 3 rows, got %d\n%s\n" "$low_count" "$low_jsonl"
    return
  fi
  # The existential-typed store handle ('any DefaultsStorage') must be
  # recognised after leading-keyword stripping and surfaced verbatim.
  if ! printf '%s\n' "$low_jsonl" | jq -e 'select(.name == "ExistentialCache") | .store_fields | any(.type == "any DefaultsStorage")' >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (semantic, threshold=2): existential store not recognised:\n%s\n" "$low_jsonl"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ persistence-store-field-density (semantic): threshold 3 flags only AppSettings (computed excluded, spc=3); threshold=2 also flags SessionCache + ExistentialCache (existential store matched)\n"
}
assert_persistence_store_field_density_semantic

# Contract-lock: the query parameterizes its numeric threshold the same way
# mark-section-density does, so raw jq without --argjson threshold must fail at
# compile time (jq rejects undefined variables before execution). Guards against
# a future fragile in-jq fallback.
assert_persistence_store_field_density_argjson_required() {
  local err
  if err="$(jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/persistence-store-field-density.jq" \
    "$PERSISTENCE_STORE_FIELD_DENSITY_FIXTURE" 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (argjson-required): expected compile error, got success\n%s\n" "$err"
    return
  fi
  if ! printf '%s' "$err" | grep -q "is not defined"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ persistence-store-field-density (argjson-required): expected 'is not defined' error, got:\n%s\n" "$err"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ persistence-store-field-density (argjson-required): raw jq without --argjson threshold correctly fails at compile time\n"
}
assert_persistence_store_field_density_argjson_required

echo ""
echo "=== module-symbol-density query (god-module before-shape) ==="
# Cross-KIND query: primary input is the function-catalog; the type-catalog is
# mounted via `--slurpfile types` (the binary auto-wires it from the second
# `#! catalog:` kind, mirroring public-api-leaks). The two fixtures encode a
# merged decl-count-per-package-qualified-file distribution whose median is 3:
#
#   main   lookup/orchestrator.py   12  (9 func + 1 method + 2 types; touched)  god → FIRES
#   shared lookup/orchestrator.py    8  (6 func + 2 types)   god in shared → FIRES; proves
#                                       package-qualified grouping (NOT merged with main)
#   main   lookup/mid.py             6  (4 func + 2 types)   ratio boundary (2×3) → FIRES at base,
#                                       filtered by the FLOOR at min_decls 7
#   main   common/util.py            3   shared common/util.py 3  (same rel path, two packages)
#   main   lookup/a.py               2   main lookup/b.py 2   main lookup/c.py 3
#   main   tests/test_orchestrator.py 10  is_test → excluded by default, opt-in via INCLUDE_TESTS
#   main   generated/models_gen.py   15  generated → excluded outright AND kept out of the median
#
# At base args (min_decls=5, ratio=2): effective bar decl>=6; exactly 3 rows.
MSD_ARGS=(--slurpfile types "$MODULE_SYMBOL_DENSITY_TYPES_FIXTURE" --argjson min_decls 5 --argjson ratio 2)
assert_jsonl_has_prefix module-symbol-density.jq "$MODULE_SYMBOL_DENSITY_FUNCS_FIXTURE" \
  "module-symbol-density:" "${MSD_ARGS[@]}"
assert_envelope_shape    module-symbol-density.jq "$MODULE_SYMBOL_DENSITY_FUNCS_FIXTURE" "${MSD_ARGS[@]}"
assert_text_has_cid      module-symbol-density.jq "$MODULE_SYMBOL_DENSITY_FUNCS_FIXTURE" "${MSD_ARGS[@]}"

assert_module_symbol_density_semantic() {
  local F="$MODULE_SYMBOL_DENSITY_FUNCS_FIXTURE"
  local T="$MODULE_SYMBOL_DENSITY_TYPES_FIXTURE"
  local jsonl
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --slurpfile types "$T" \
    --argjson min_decls 5 --argjson ratio 2 \
    -f "$QUERIES_DIR/module-symbol-density.jq" "$F" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (semantic): crashed: %s\n" "$jsonl"
    return
  }
  local count
  count="$(printf '%s\n' "$jsonl" | grep -c .)"
  if [[ "$count" != "3" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (semantic, base): expected 3 flagged rows, got %d\n%s\n" "$count" "$jsonl"
    return
  fi
  # Every row reports the codebase-wide median of 3.
  if [[ "$(printf '%s\n' "$jsonl" | jq -s 'all(.median_decls == 3)')" != "true" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (semantic): median_decls should be 3 on every row\n%s\n" "$jsonl"
    return
  fi
  # Densest-first: row 1 is the main god module — 12 decls, ratio 4×, touched,
  # body_lines_total 185 (8 bodies@20 + 1 null-body@0 + 1 method@25), and the
  # merge across BOTH catalogs is visible in kind_breakdown.
  local first_ok
  first_ok="$(printf '%s\n' "$jsonl" | head -1 | jq -r \
    '(.cluster_id == "module-symbol-density:main__lookup/orchestrator.py"
      and .decl_count == 12 and .ratio_to_median == 4 and .touched_in_window == true
      and .body_lines_total == 185
      and .kind_breakdown.function == 9 and .kind_breakdown.method == 1
      and .kind_breakdown["type-alias-object"] == 2) | tostring')"
  if [[ "$first_ok" != "true" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (semantic): row 1 is not the expected main god module\n%s\n" "$jsonl"
    return
  fi
  # Package-qualified grouping: main and shared orchestrator.py are TWO clusters
  # with distinct counts (12 vs 8), never merged into one 20-decl group.
  local shared_decl
  shared_decl="$(printf '%s\n' "$jsonl" | jq -rs \
    '[.[] | select(.cluster_id == "module-symbol-density:shared__lookup/orchestrator.py")][0].decl_count')"
  if [[ "$shared_decl" != "8" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (semantic): shared orchestrator not a distinct group of 8 (got %s)\n%s\n" "$shared_decl" "$jsonl"
    return
  fi
  # mid.py fires exactly at the ratio boundary (6 == 2 × median 3).
  local mid_ratio
  mid_ratio="$(printf '%s\n' "$jsonl" | jq -rs \
    '[.[] | select(.cluster_id == "module-symbol-density:main__lookup/mid.py")][0].ratio_to_median')"
  if [[ "$mid_ratio" != "2" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (semantic): mid.py should fire at ratio 2 boundary, got %s\n%s\n" "$mid_ratio" "$jsonl"
    return
  fi
  # None of the below-bar / excluded files may leak: the small files, either
  # util.py, the test file (is_test), or the generated file.
  if printf '%s\n' "$jsonl" | jq -e '.file | test("(^|/)(a|b|c)\\.py$|util\\.py$|test_orchestrator\\.py$|models_gen\\.py$")' >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (semantic): a below-bar/excluded file leaked into output\n%s\n" "$jsonl"
    return
  fi
  # FLOOR gate, exercised independently of the ratio gate: raise min_decls to 7
  # with a lax ratio 1.5 (ratio bar 4.5). mid.py (6) clears the ratio bar but is
  # now below the floor → drops. Only the two orchestrators survive.
  local floor_jsonl floor_count floor_has_mid
  floor_jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --slurpfile types "$T" \
    --argjson min_decls 7 --argjson ratio 1.5 \
    -f "$QUERIES_DIR/module-symbol-density.jq" "$F" 2>&1)"
  floor_count="$(printf '%s\n' "$floor_jsonl" | grep -c .)"
  floor_has_mid="$(printf '%s\n' "$floor_jsonl" | jq -rs '[.[] | select(.file == "lookup/mid.py")] | length')"
  if [[ "$floor_count" != "2" || "$floor_has_mid" != "0" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (semantic, floor gate): expected 2 rows with mid.py dropped, got %d rows (mid present=%s)\n%s\n" "$floor_count" "$floor_has_mid" "$floor_jsonl"
    return
  fi
  # is_test opt-in: default excludes the test file; INCLUDE_TESTS=true surfaces
  # it (median stays 3, so the base bar still yields 4 rows including it).
  local incl_jsonl incl_count incl_has_test
  incl_jsonl="$(OUTPUT_FORMAT=jsonl INCLUDE_TESTS=true jq -L "$QUERIES_DIR" -r --slurpfile types "$T" \
    --argjson min_decls 5 --argjson ratio 2 \
    -f "$QUERIES_DIR/module-symbol-density.jq" "$F" 2>&1)"
  incl_count="$(printf '%s\n' "$incl_jsonl" | grep -c .)"
  incl_has_test="$(printf '%s\n' "$incl_jsonl" | jq -rs '[.[] | select(.file == "tests/test_orchestrator.py")] | length')"
  if [[ "$incl_count" != "4" || "$incl_has_test" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (semantic, INCLUDE_TESTS): expected 4 rows incl. the test file, got %d (test present=%s)\n%s\n" "$incl_count" "$incl_has_test" "$incl_jsonl"
    return
  fi
  # Loosening both thresholds (min_decls=3, ratio=1) surfaces every >=3-decl
  # file: both orchestrators, mid, both util.py, and c.py = 6 rows.
  local low_count
  low_count="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --slurpfile types "$T" \
    --argjson min_decls 3 --argjson ratio 1 \
    -f "$QUERIES_DIR/module-symbol-density.jq" "$F" | grep -c .)"
  if [[ "$low_count" != "6" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (semantic, low thresholds): expected 6 rows, got %s\n" "$low_count"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ module-symbol-density (semantic): base flags 3 (main god first, spc merge across catalogs, pkg-qualified split, mid at ratio boundary); floor gate drops mid; INCLUDE_TESTS surfaces the test file; low thresholds emit 6\n"
}
assert_module_symbol_density_semantic

# Contract-lock: module-symbol-density parameterizes two numeric thresholds the
# same way mark-section-density / persistence-store-field-density do, so raw jq
# without --argjson must fail at compile time (jq rejects undefined variables
# before execution). Guards against a future fragile in-jq fallback.
assert_module_symbol_density_argjson_required() {
  local err
  if err="$(jq -L "$QUERIES_DIR" -r --slurpfile types "$MODULE_SYMBOL_DENSITY_TYPES_FIXTURE" \
    -f "$QUERIES_DIR/module-symbol-density.jq" "$MODULE_SYMBOL_DENSITY_FUNCS_FIXTURE" 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (argjson-required): expected compile error, got success\n%s\n" "$err"
    return
  fi
  if ! printf '%s' "$err" | grep -q "is not defined"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ module-symbol-density (argjson-required): expected 'is not defined' error, got:\n%s\n" "$err"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ module-symbol-density (argjson-required): raw jq without --argjson min_decls/ratio correctly fails at compile time\n"
}
assert_module_symbol_density_argjson_required

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
echo "=== Versioned-type-pairs query ==="
assert_jsonl_has_prefix versioned-type-pairs.jq "$VERSIONED_TYPE_PAIRS_FIXTURE" "versioned-type-pairs:"
assert_text_has_cid     versioned-type-pairs.jq "$VERSIONED_TYPE_PAIRS_FIXTURE"

# Envelope conformance: every JSONL row must carry the cluster-trio
# (cluster_id, query, shape) per ADR-0003 plus the query-specific
# fields downstream consumers (renderer, scorers) read by name.
assert_versioned_type_pairs_envelope() {
  local result conforms
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/versioned-type-pairs.jq" "$VERSIONED_TYPE_PAIRS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ versioned-type-pairs (envelope): crashed: %s\n" "$result"
    return
  }
  conforms="$(echo "$result" | jq -s '
    all(
      .cluster_id != null
      and .query == "versioned-type-pairs"
      and .shape == "cluster"
      and (.base_name | type == "string")
      and (.package | type == "string")
      and (.shapes_observed | type == "boolean")
      and (.shapes_match | type == "boolean")
      and (.members | type == "array")
      and (.members | length >= 2)
    )')"
  if [[ "$conforms" == "true" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ versioned-type-pairs (envelope): every row carries the cluster trio + payload\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ versioned-type-pairs (envelope): non-conforming rows present. output:\n%s\n" "$result"
  fi
}
assert_versioned_type_pairs_envelope

# Semantic correctness for versioned-type-pairs. The fixture is hand-tuned:
#   Track / TrackV2                (main, shapes match)         → cluster, shapes_match=true,  versions 0,2
#   Episode / EpV2 / EpV3          (main, shapes diverge)       → cluster, shapes_match=false, versions 0,2,3
#   Listener                       (main, no sibling)           → not emitted
#   IPv4 / IPv6                    (main, protocol-suffix FP)   → cluster, shapes_match=true,  versions 4,6
#   OldZ / OldZV2                  (shared, shapes diverge)     → cluster in shared
#   GenZ / GenZV2                  (main, generated)            → excluded by default; surfaced under INCLUDE_GENERATED
#   ZodFoo / ZodFooV2              (main, zod-object)           → cluster; dropped under KIND_PREFIX=interface
#   Theme / Themev2                (main, lowercase-v positive) → cluster, shapes_match=true
#   Schema / SchemaV0              (main, V0 baseline anchor)   → cluster, shapes_match=false (intentional V0 differs)
#   EmptyShape / EmptyShapeV2      (main, empty shape_sig)      → cluster, shapes_observed=false, shapes_match=false
#   NullSig / NullSigV2            (main, null shape_sig)       → cluster, shapes_observed=false, shapes_match=false
#   NoKind / NoKindV2              (main, kind missing)         → not emitted (positive whitelist drops null-kind safely)
#   V2 / V3                        (main, empty base after strip) → not emitted (empty base_name dropped)
#   Snapshot / SnapshotV2          (Shared/Generated package)   → cluster with `/`-containing package, cluster_id splits on `__`
# Baseline (no env): 10 clusters; INCLUDE_GENERATED=true: 11; PACKAGE=main: 8 (drops OldZ + Snapshot); KIND_PREFIX=interface: 8 (drops ZodFoo + NullSig).
#
# Arg shape: label expected_count [ENV=val ...] -- [--arg key val ...]
# Tokens before "--" become the env-var prefix; tokens after are jq args.
# Matches the convention used by assert_migration_progress_semantic (via _parse_env_and_jq_args, defined later in this file but reused via late binding).
assert_versioned_type_pairs_count() {
  local label="$1"; shift
  local expected_count="$1"; shift
  local env_prefix=()
  while (( $# > 0 )) && [[ "$1" != "--" ]]; do
    env_prefix+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  local jq_args=("$@")

  local result count
  result="$(env OUTPUT_FORMAT=jsonl "${env_prefix[@]+"${env_prefix[@]}"}" \
    jq -L "$QUERIES_DIR" -r "${jq_args[@]+"${jq_args[@]}"}" \
    -f "$QUERIES_DIR/versioned-type-pairs.jq" "$VERSIONED_TYPE_PAIRS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ versioned-type-pairs (%s): crashed: %s\n" "$label" "$result"
    return
  }
  count="$(echo "$result" | grep -c .)"
  if [[ "$count" == "$expected_count" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ versioned-type-pairs (%s): %s clusters\n" "$label" "$count"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ versioned-type-pairs (%s): expected %s clusters, got %s. output:\n%s\n" \
      "$label" "$expected_count" "$count" "$result"
  fi
}

assert_versioned_type_pairs_count "baseline"              10
assert_versioned_type_pairs_count "INCLUDE_GENERATED"     11 INCLUDE_GENERATED=true
assert_versioned_type_pairs_count "PACKAGE=main"           8 PACKAGE=main
assert_versioned_type_pairs_count "KIND_PREFIX=interface"  8 KIND_PREFIX=interface

# Specific-cluster semantic checks: shapes_match flag and version-sorted members.
assert_versioned_type_pairs_cluster() {
  local label="$1"; shift
  local target_cid="$1"; shift
  local expected_shapes_match="$1"; shift     # "true" | "false"
  local expected_shapes_observed="$1"; shift  # "true" | "false"
  local expected_versions_csv="$1"; shift     # e.g. "0,2"

  local result actual_shapes actual_observed actual_versions
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/versioned-type-pairs.jq" "$VERSIONED_TYPE_PAIRS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ versioned-type-pairs (%s): crashed: %s\n" "$label" "$result"
    return
  }
  actual_shapes="$(echo "$result" | jq -rs --arg c "$target_cid" \
    '.[] | select(.cluster_id == $c) | .shapes_match')"
  actual_observed="$(echo "$result" | jq -rs --arg c "$target_cid" \
    '.[] | select(.cluster_id == $c) | .shapes_observed')"
  actual_versions="$(echo "$result" | jq -rs --arg c "$target_cid" \
    '.[] | select(.cluster_id == $c) | (.members | map(.version | tostring) | join(","))')"

  if [[ "$actual_shapes"   == "$expected_shapes_match" \
     && "$actual_observed" == "$expected_shapes_observed" \
     && "$actual_versions" == "$expected_versions_csv" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ versioned-type-pairs (%s): cid=%s shapes_match=%s shapes_observed=%s versions=[%s]\n" \
      "$label" "$target_cid" "$actual_shapes" "$actual_observed" "$actual_versions"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ versioned-type-pairs (%s): cid=%s expected shapes_match=%s shapes_observed=%s versions=[%s], got shapes_match=%s shapes_observed=%s versions=[%s]\n" \
      "$label" "$target_cid" \
      "$expected_shapes_match" "$expected_shapes_observed" "$expected_versions_csv" \
      "$actual_shapes" "$actual_observed" "$actual_versions"
  fi
}

assert_versioned_type_pairs_cluster "Track same-shape pair"     "versioned-type-pairs:main__Track"    "true"  "true"  "0,2"
assert_versioned_type_pairs_cluster "Episode diverged triple"   "versioned-type-pairs:main__Episode"  "false" "true"  "0,2,3"
assert_versioned_type_pairs_cluster "IPv4/IPv6 false positive"  "versioned-type-pairs:main__IP"       "true"  "true"  "4,6"
assert_versioned_type_pairs_cluster "OldZ in shared package"    "versioned-type-pairs:shared__OldZ"   "false" "true"  "0,2"
assert_versioned_type_pairs_cluster "Theme/Themev2 lowercase-v" "versioned-type-pairs:main__Theme"    "true"  "true"  "0,2"
assert_versioned_type_pairs_cluster "Schema/SchemaV0 baseline"  "versioned-type-pairs:main__Schema"   "false" "true"  "0,0"
assert_versioned_type_pairs_cluster "EmptyShape empty sentinel" "versioned-type-pairs:main__EmptyShape" "false" "false" "0,2"
assert_versioned_type_pairs_cluster "NullSig null shape_sig"    "versioned-type-pairs:main__NullSig"  "false" "false" "0,2"

# `/`-containing package round-trip: cluster_id uses `__` between package and
# base_name precisely so a downstream parser can split on `__` and recover
# both components verbatim, even when the package contains `/`.
assert_versioned_type_pairs_scoped_package() {
  local result cid package base_name
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/versioned-type-pairs.jq" "$VERSIONED_TYPE_PAIRS_FIXTURE" 2>&1)"
  cid="$(echo "$result" | jq -rs '.[] | select(.base_name == "Snapshot") | .cluster_id')"
  package="$(echo "$result" | jq -rs '.[] | select(.base_name == "Snapshot") | .package')"
  base_name="$(echo "$result" | jq -rs '.[] | select(.base_name == "Snapshot") | .base_name')"
  if [[ "$cid" == "versioned-type-pairs:Shared/Generated__Snapshot" \
     && "$package" == "Shared/Generated" \
     && "$base_name" == "Snapshot" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ versioned-type-pairs (scoped-package): cid=%s preserves '/'-bearing package via __ separator\n" "$cid"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ versioned-type-pairs (scoped-package): expected cid='versioned-type-pairs:Shared/Generated__Snapshot' package='Shared/Generated' base_name='Snapshot', got cid='%s' package='%s' base_name='%s'\n" \
      "$cid" "$package" "$base_name"
  fi
}
assert_versioned_type_pairs_scoped_package

# Confirm the single-decl case (Listener), the no-kind-no-crash case, the
# generated-excluded case, and the empty-base-after-strip case (V2/V3) all
# emit zero rows under any filter.
assert_versioned_type_pairs_absent_base() {
  local label="$1"; shift
  local target_base="$1"; shift

  local result count
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/versioned-type-pairs.jq" "$VERSIONED_TYPE_PAIRS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ versioned-type-pairs (%s): crashed: %s\n" "$label" "$result"
    return
  }
  count="$(echo "$result" | jq -rs --arg b "$target_base" '[.[] | select(.base_name == $b)] | length')"
  if [[ "$count" == "0" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ versioned-type-pairs (%s): base_name=%s absent\n" "$label" "$target_base"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ versioned-type-pairs (%s): base_name=%s should be absent, but %s row(s) match\n" \
      "$label" "$target_base" "$count"
  fi
}

assert_versioned_type_pairs_absent_base "Listener has no sibling"       "Listener"
assert_versioned_type_pairs_absent_base "GenZ excluded by default"      "GenZ"
assert_versioned_type_pairs_absent_base "NoKind dropped by whitelist"   "NoKind"
assert_versioned_type_pairs_absent_base "V2/V3 empty-base dropped"      ""

# A `has_suffix:false`-only group must be dropped — but a `Foo`+`FooV0` group
# (both parse to version 0; FooV0 carries has_suffix:true) must NOT be dropped.
# The Schema/SchemaV0 cluster covers this; double-check via the has_suffix flag
# on the SchemaV0 member.
assert_versioned_type_pairs_schema_v0_has_suffix() {
  local result has_suffix
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/versioned-type-pairs.jq" "$VERSIONED_TYPE_PAIRS_FIXTURE" 2>&1)"
  has_suffix="$(echo "$result" | jq -rs \
    '.[] | select(.base_name == "Schema") | .members[] | select(.name == "SchemaV0") | .has_suffix')"
  if [[ "$has_suffix" == "true" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ versioned-type-pairs (V0 baseline): SchemaV0 carries has_suffix=true, anchors the group\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ versioned-type-pairs (V0 baseline): expected SchemaV0.has_suffix=true, got '%s'\n" "$has_suffix"
  fi
}
assert_versioned_type_pairs_schema_v0_has_suffix

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
    '.[] | select(.name == $n) | (.members | map(.arity) | sort | join(","))')"

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
    '.[] | select(.members[0].name == $n) | (.suspects | sort | join(","))')"

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
    '[.[] | select(.members[0].name == $n)] | length')"

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

# JSONL row-count invariant: the meta-query emits exactly four rows per
# invocation (one per indexed cluster type), regardless of how many touched
# clusters each row contains. Lock this in so a future refactor that drops
# a cluster type or fans out the array is caught — the per-row count tests
# above lookup by cluster_type and would still pass if a row vanished.
assert_debt_summary_jsonl_row_count() {
  local env_prefix=() jq_args=()
  local result line_count cluster_types
  result="$(_debt_summary_run)"
  line_count="$(echo "$result" | grep -c .)"
  cluster_types="$(echo "$result" | jq -rs 'map(.cluster_type) | sort | join(",")')"
  local expected="cross-package-shadows,exact-duplicates,name-collisions,near-duplicates"
  if [[ "$line_count" == "4" && "$cluster_types" == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ debt-summary (JSONL row-count invariant): 4 rows covering all four cluster types\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ debt-summary (JSONL row-count invariant): expected 4 rows with cluster_types=[%s], got %s rows with [%s]\n" \
      "$expected" "$line_count" "$cluster_types"
  fi
}
assert_debt_summary_jsonl_row_count

# Text-mode header-table coverage: the four cluster-type names must each
# appear as a header row in default text output. The cid= marker test only
# checks for a single substring, so a future refactor that drops a row from
# the literal cluster_types array (or its header rendering) would slip past.
assert_debt_summary_text_header_rows() {
  local text missing=""
  text="$(jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/touched-window-debt-summary.jq" "$DEBT_SUMMARY_FIXTURE" 2>&1)"
  for ct in exact-duplicates name-collisions cross-package-shadows near-duplicates; do
    if [[ "$text" != *"$ct: "*" touched / "*" total ("*"%) cid=touched-window-debt-summary:$ct"* ]]; then
      missing="${missing}${ct} "
    fi
  done
  if [[ -z "$missing" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ debt-summary (text header rows): all four cluster types present in header table\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ debt-summary (text header rows): missing header rows for: %s. output:\n%s\n" "$missing" "$text"
  fi
}
assert_debt_summary_text_header_rows

# Detail-block ordering: each cluster type's touched_clusters list must be
# sorted to match the source query's documented order. Source orderings:
#   exact-duplicates       — sort_by(-(.members | length))
#   name-collisions        — sort_by(-(.members | length), .name)
#   cross-package-shadows  — sort_by(.name)
#   near-duplicates        — sort_by(-(.jacc))
#
# The baseline fixture has 1 touched cluster per type, so the divergence is
# only visible when multiple clusters exist. Use a small synthetic fixture
# that has both a 3-decl and a 2-decl exact-duplicates cluster, both touched.
# group_by(.shape_sig) would order them alphabetically (A first); source
# sort puts the 3-decl one first (Z first).
assert_debt_summary_detail_sort_order() {
  local tmp_fixture result first_cid
  tmp_fixture="$(mktemp)"
  cat > "$tmp_fixture" <<'EOF'
[
  {"name":"AAA","kind":"interface","package":"main","file":"a.ts","line":1,"fields":["x:int"],"shape_sig":"a:int","touched_in_window":true,"generated":false},
  {"name":"AAB","kind":"interface","package":"main","file":"b.ts","line":1,"fields":["x:int"],"shape_sig":"a:int","touched_in_window":true,"generated":false},
  {"name":"ZZA","kind":"interface","package":"main","file":"c.ts","line":1,"fields":["y:string"],"shape_sig":"z:string","touched_in_window":true,"generated":false},
  {"name":"ZZB","kind":"interface","package":"main","file":"d.ts","line":1,"fields":["y:string"],"shape_sig":"z:string","touched_in_window":true,"generated":false},
  {"name":"ZZC","kind":"interface","package":"main","file":"e.ts","line":1,"fields":["y:string"],"shape_sig":"z:string","touched_in_window":true,"generated":false}
]
EOF
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/touched-window-debt-summary.jq" "$tmp_fixture" 2>&1)"
  rm -f "$tmp_fixture"
  # The 3-decl cluster (Z*) should appear first in touched_clusters per
  # source-query sort_by(-(.members | length)).
  first_cid="$(echo "$result" \
    | jq -rs '.[] | select(.cluster_type == "exact-duplicates") | .touched_clusters[0].cluster_id')"
  if [[ "$first_cid" == "exact-duplicates:ZZA+ZZB+ZZC" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ debt-summary (detail sort order): exact-duplicates ordered by -size (3-decl cluster first)\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ debt-summary (detail sort order): expected first touched_clusters cid='exact-duplicates:ZZA+ZZB+ZZC', got '%s'. output:\n%s\n" \
      "$first_cid" "$result"
  fi
}
assert_debt_summary_detail_sort_order

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
assert_text_has_cid shared-interface-candidates.jq "$SHARED_INTERFACE_FIXTURE" --argjson min_intersection 5
assert_text_has_cid function-duplicates.jq "$FUNCS_FIXTURE" --argjson threshold 0.5
assert_text_has_cid default-impl-candidates.jq "$FUNCS_FIXTURE" --argjson min_conformers 2
assert_text_has_cid generic-function-candidates.jq "$FUNCS_FIXTURE" --argjson threshold 0.5 --argjson max_subs 2
assert_text_has_cid file-duplicates.jq "$FILES_FIXTURE"
assert_text_has_cid copied-from-header.jq "$COPIED_FROM_HEADER_FIXTURE"
assert_text_has_cid mark-section-density.jq "$MARK_SECTION_DENSITY_FIXTURE" --argjson min_marks 6 --argjson min_lines 400
assert_text_has_cid copied-literal-candidates.jq "$COPIED_LITERAL_FIXTURE" --argjson min_sites 3 --argjson min_files 2
assert_text_has_cid migration-progress.jq "$MIGRATION_FIXTURE" \
  --arg old_sig "id:number" --arg new_sig "id:string" --arg label "Id-migration"
assert_text_has_cid shape-sig-frequency.jq "$MIGRATION_FIXTURE"
assert_text_has_cid generic-arity-drift.jq "$GENERICS_FIXTURE"
assert_text_has_cid generic-convention-bound.jq "$GENERICS_FIXTURE"
assert_text_has_cid touched-window-debt-summary.jq "$DEBT_SUMMARY_FIXTURE"

echo ""
echo "=== Extractor: \$inferSelect / \$inferInsert recognition ==="
# Runs the TypeScript extractor against an isolated tmpdir holding the
# infer-model sample. Asserts the catalog carries `type-alias-infer-model` rows
# for both the legacy InferSelectModel/InferInsertModel API and the modern
# `typeof T.$inferSelect` / `typeof T.$inferInsert` API, with `infer_ref.table`
# resolving to the drizzle table variable name (`users`).
assert_infer_model_extractor() {
  if ! command -v node >/dev/null 2>&1; then
    printf "  SKIP infer-model extractor smoke test: node not on PATH\n"
    return
  fi
  if [[ ! -f "$TYPE_CATALOG_BIN" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ infer-model extractor: type-catalog.mjs not found at %s\n" "$TYPE_CATALOG_BIN"
    return
  fi
  local tmp catalog
  tmp="$(mktemp -d)"
  cp "$INFER_MODEL_SAMPLE_TS" "$tmp/sample.ts"
  catalog="$(node "$TYPE_CATALOG_BIN" --root "$tmp" 2>/dev/null)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ infer-model extractor: type-catalog.mjs crashed on sample.ts\n"
    rm -rf "$tmp"
    return
  }
  rm -rf "$tmp"

  # Build the expected pair set as JSON, then ask jq once which pairs are
  # present in the catalog. Returns the comma-joined missing set, or empty.
  local missing
  missing="$(echo "$catalog" | jq -r '
    [
      {"k":"InferSelectModel","n":"LegacyUser"},
      {"k":"InferInsertModel","n":"LegacyNewUser"},
      {"k":"$inferSelect","n":"ModernUser"},
      {"k":"$inferInsert","n":"ModernNewUser"}
    ] as $expected
    | .entries as $catalog
    | [ $expected[]
        | . as $e
        | select(
            [ $catalog[]
              | select(
                  .kind == "type-alias-infer-model"
                  and .name == $e.n
                  and .infer_ref.kind == $e.k
                  and .infer_ref.table == "users"
                )
            ] | length != 1)
        | "\($e.k)/\($e.n)" ]
    | join(", ")')"

  if [[ -z "$missing" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ infer-model extractor: all four infer_ref kinds present\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ infer-model extractor: missing rows for: %s\n" "$missing"
    printf "    catalog:\n%s\n" "$(echo "$catalog" | jq '[.entries[] | select(.kind == "type-alias-infer-model" or .kind == "type-alias-other" or .kind == "drizzle-table") | {name, kind, infer_ref}]')"
  fi
}
assert_infer_model_extractor

echo ""
echo "=== Orphan-InferModel query ==="
assert_jsonl_has_prefix orphan-infer-model.jq "$ORPHAN_INFER_MODEL_FIXTURE" "orphan-infer-model:"

# Semantic correctness for orphan-infer-model. Fixture (orphan-infer-model.input.json):
#   user_archive  — drizzle-table, no derivation             → orphan, "no either"
#   user          — drizzle-table + Legacy + LegacyNew       → not reported
#   session       — drizzle-table + SessionView (Sel only)   → orphan, "no InferInsert"
#   post          — drizzle-table + PostRow ($inferSelect)   → orphan, "no InferInsert"
#   shared_thing  — drizzle-table in shared + SharedDerived ($inferSelect) in main → not reported
#   empty         — drizzle-table with empty fields, no derivation → orphan, "no either"
#   legacy_table  — drizzle-table with generated:true, no derivation → not reported by default
assert_orphan_infer_model_baseline() {
  local result rows
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/orphan-infer-model.jq" "$ORPHAN_INFER_MODEL_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ orphan-infer-model (baseline): crashed: %s\n" "$result"
    return
  }
  rows="$(echo "$result" | grep -c .)"
  if [[ "$rows" != "4" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ orphan-infer-model (baseline): expected 4 rows, got %s:\n%s\n" "$rows" "$result"
    return
  fi
  # One jq pass: for each expected (name, label) pair, emit "name [want=L got=G]"
  # if the catalog disagrees, otherwise emit nothing. Per the cluster envelope,
  # the decl identity lives in members[0]; the missing label stays at the top.
  local mismatches
  mismatches="$(echo "$result" | jq -rs '
    [
      {"n":"user_archive","l":"no either"},
      {"n":"session","l":"no InferInsert"},
      {"n":"post","l":"no InferInsert"},
      {"n":"empty","l":"no either"}
    ] as $expected
    | . as $rows
    | [ $expected[]
        | . as $e
        | ($rows | map(select(.members[0].name == $e.n)) | first | .missing // "<missing>") as $got
        | select($got != $e.l)
        | "\($e.n) [want=\($e.l) got=\($got)]" ]
    | join("; ")')"
  if [[ -z "$mismatches" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ orphan-infer-model (baseline): 4 orphans with expected missing labels\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ orphan-infer-model (baseline): label mismatch: %s\n" "$mismatches"
  fi
}
assert_orphan_infer_model_baseline

assert_orphan_infer_model_include_generated() {
  local result rows has_legacy_table
  result="$(OUTPUT_FORMAT=jsonl INCLUDE_GENERATED=true jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/orphan-infer-model.jq" "$ORPHAN_INFER_MODEL_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ orphan-infer-model (INCLUDE_GENERATED=true): crashed: %s\n" "$result"
    return
  }
  rows="$(echo "$result" | grep -c .)"
  has_legacy_table="$(echo "$result" | jq -rs '[.[] | select(.members[0].name == "legacy_table")] | length')"
  if [[ "$rows" == "5" && "$has_legacy_table" == "1" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ orphan-infer-model (INCLUDE_GENERATED=true): 5 rows including legacy_table\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ orphan-infer-model (INCLUDE_GENERATED=true): expected 5 rows with legacy_table present, got %s rows (legacy_table count=%s)\n" \
      "$rows" "$has_legacy_table"
  fi
}
assert_orphan_infer_model_include_generated

# Cross-package join, bidirectional: the baseline test already covers the
# fully-covered case (shared_thing has both Sel and Ins derivations in main, so
# it stays out of the orphan list — if cross-package were broken, baseline
# would fail with an extra row). This test removes SharedDerivedInsert from the
# fixture, so shared_thing should now surface as a "no InferInsert" half-orphan
# — exercising the Insert side of the join independently from the Select side.
assert_orphan_infer_model_cross_package_half() {
  local fixture_no_insert result missing_label
  fixture_no_insert="$(mktemp)"
  jq '[.[] | select(.name != "SharedDerivedInsert")]' \
    "$ORPHAN_INFER_MODEL_FIXTURE" > "$fixture_no_insert"
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/orphan-infer-model.jq" "$fixture_no_insert" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ orphan-infer-model (cross-package half-orphan): crashed: %s\n" "$result"
    rm -f "$fixture_no_insert"
    return
  }
  rm -f "$fixture_no_insert"
  missing_label="$(echo "$result" \
    | jq -rs '.[] | select(.members[0].name == "shared_thing") | .missing')"
  if [[ "$missing_label" == "no InferInsert" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ orphan-infer-model (cross-package half-orphan): shared_thing surfaces as 'no InferInsert' when only the Sel derivation remains\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ orphan-infer-model (cross-package half-orphan): expected shared_thing.missing == 'no InferInsert', got '%s'. output:\n%s\n" \
      "$missing_label" "$result"
  fi
}
assert_orphan_infer_model_cross_package_half

# Touched-window marker: session.touched_in_window=true in the fixture; text
# mode must prefix its row with '*'. Locks in the touched-marker convention
# shared with every other query in this directory.
assert_orphan_infer_model_touched_marker() {
  local text
  text="$(jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/orphan-infer-model.jq" "$ORPHAN_INFER_MODEL_FIXTURE" 2>&1)"
  if [[ "$text" == *"* session [no InferInsert]"* ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ orphan-infer-model (touched marker): session row prefixed with '*'\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ orphan-infer-model (touched marker): expected '* session [no InferInsert]' in text output:\n%s\n" "$text"
  fi
}
assert_orphan_infer_model_touched_marker

assert_text_has_cid orphan-infer-model.jq "$ORPHAN_INFER_MODEL_FIXTURE"

echo ""
echo "=== is_test extractor + test-prod-drift query ==="

# Drives the TypeScript extractor against the synthetic is-test-tree/ fixture
# and asserts each file's expected is_test classification. The tree exercises:
#   - non-test prod file (src/foo.ts)
#   - dot-suffix patterns (.test, .spec, .mock)
#   - lowercase fixtures/ subdir
#   - underscored test/fixture dirs (__tests__, __fixtures__)
#   - non-underscored test dir (tests/) at any depth
#   - e2e/ dir
assert_is_test_extractor() {
  if ! command -v node >/dev/null 2>&1; then
    printf "  SKIP is_test extractor smoke test: node not on PATH\n"
    return
  fi
  if [[ ! -f "$TYPE_CATALOG_BIN" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ is_test extractor: type-catalog.mjs not found at %s\n" "$TYPE_CATALOG_BIN"
    return
  fi
  local catalog
  catalog="$(node "$TYPE_CATALOG_BIN" --root "$IS_TEST_TREE" 2>/dev/null)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ is_test extractor: type-catalog.mjs crashed on is-test-tree\n"
    return
  }

  # One jq pass: emit the mis-classified set as "file [want=W got=G]" joined by ", ".
  # Empty string means every file's is_test matched expectation.
  local mismatched
  mismatched="$(echo "$catalog" | jq -r '
    [
      {"f":"src/foo.ts",                 "t":false},
      {"f":"src/foo.test.ts",            "t":true},
      {"f":"src/foo.spec.ts",            "t":true},
      {"f":"src/foo.mock.ts",            "t":true},
      {"f":"src/fixtures/data.ts",       "t":true},
      {"f":"tests/integration/bar.ts",   "t":true},
      {"f":"__tests__/baz.ts",           "t":true},
      {"f":"__fixtures__/factory.ts",    "t":true},
      {"f":"e2e/login.ts",               "t":true}
    ] as $expected
    | .entries as $catalog
    | [ $expected[]
        | . as $e
        # NB: jq `//` treats `false` as nullish — use `==` directly so false-vs-missing stays distinguishable.
        | ([$catalog[] | select(.file == $e.f)] | first) as $row
        | if $row == null then "\($e.f) [want=\($e.t) got=missing]"
          elif $row.is_test == null then "\($e.f) [want=\($e.t) got=missing-field]"
          elif $row.is_test != $e.t then "\($e.f) [want=\($e.t) got=\($row.is_test)]"
          else empty
          end ]
    | join(", ")')"

  if [[ -z "$mismatched" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ is_test extractor: all 9 file classifications correct\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ is_test extractor: %s\n" "$mismatched"
    printf "    catalog:\n%s\n" "$(echo "$catalog" | jq '[.entries[] | {file, name, is_test}]')"
  fi
}
assert_is_test_extractor

assert_jsonl_has_prefix test-prod-drift.jq "$TEST_PROD_DRIFT_FIXTURE" "test-prod-drift:" --argjson threshold 0.5

# Semantic correctness for test-prod-drift. Fixture (test-prod-drift.input.json):
#   User <-> UserFixture       — XOR matches, jaccard 0.75      → emit (prod-first: User)
#   Address <-> AddressTest    — XOR matches, jaccard 1.0       → exclude (< 1.0 clause)
#   Order <-> OrderDraft       — both is_test=false             → exclude (XOR)
#   Legacy1 <-> Legacy2        — neither carries is_test field  → exclude (back-compat: both default false)
#   GeneratedProd <-> TestThing — GeneratedProd.generated=true  → exclude (candidate filter)
# Net: exactly one row, with prod-side (User) reported as `a`, fixture-side (UserFixture) as `b`.
assert_test_prod_drift_baseline() {
  local result rows
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --argjson threshold 0.5 \
    -f "$QUERIES_DIR/test-prod-drift.jq" "$TEST_PROD_DRIFT_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ test-prod-drift (baseline): crashed: %s\n" "$result"
    return
  }
  rows="$(echo "$result" | grep -c .)"
  if [[ "$rows" != "1" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ test-prod-drift (baseline): expected 1 row, got %s:\n%s\n" "$rows" "$result"
    return
  fi
  # Verify the row: left.name=User (prod), right.name=UserFixture (test),
  # left.is_test=false, right.is_test=true. Envelope convention for
  # test-prod-drift is asymmetric: left=prod, right=test (per the query header).
  local diag
  diag="$(echo "$result" | jq -r '
    . as $r
    | if ($r.left.name == "User" and $r.right.name == "UserFixture"
           and ($r.left.is_test // false) == false
           and ($r.right.is_test // false) == true) then ""
      else "left=\($r.left.name)(is_test=\($r.left.is_test // "null")) right=\($r.right.name)(is_test=\($r.right.is_test // "null"))"
      end')"
  if [[ -z "$diag" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ test-prod-drift (baseline): emits User (prod) <-> UserFixture (test)\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ test-prod-drift (baseline): wrong row ordering — %s\n" "$diag"
  fi
}
assert_test_prod_drift_baseline

assert_text_has_cid test-prod-drift.jq "$TEST_PROD_DRIFT_FIXTURE" --argjson threshold 0.5

echo ""
echo "=== dead-code query (catalog + references.json join) ==="
# Two-file fixture: dead-code.jq takes the wrapped catalog as its primary input
# and pulls the resolved-edges from references.json via --slurpfile refs <path>.
# The existing assert_jsonl_has_prefix / assert_text_has_cid helpers pass any
# trailing args through to jq verbatim, so the --slurpfile flag rides through
# cleanly with no helper-signature changes.
DEAD_CODE_CATALOG_FIXTURE="$FIXTURES_DIR/dead-code-catalog.input.json"
DEAD_CODE_REFS_FIXTURE="$FIXTURES_DIR/dead-code-references.input.json"

assert_jsonl_has_prefix dead-code.jq "$DEAD_CODE_CATALOG_FIXTURE" "dead-code:" \
  --slurpfile refs "$DEAD_CODE_REFS_FIXTURE"

assert_envelope_shape dead-code.jq "$DEAD_CODE_CATALOG_FIXTURE" --slurpfile refs "$DEAD_CODE_REFS_FIXTURE"

# Semantic correctness. Fixture (dead-code-catalog.input.json + edges):
#   ZombieType (main, exported, 0 refs in)            → flag dead
#   LiveType (main, exported, 1 ref from SomeConsumer) → not flagged
#   Tree (main, exported, self-ref only)              → flag dead (self-ref filter)
#   InternalType (main, NOT exported, 0 refs in)      → not flagged (non-exported)
#   GeneratedType (main, exported, generated=true)    → not flagged (generated filter)
#   CommonType (shared, exported, 1 ref from main)    → not flagged (cross-pkg consumer)
#   UnresolvedOnly (main, exported, 1 unresolved in)  → flag dead (resolved=false filter)
#   LonelyShared (shared, exported, 0 refs in)        → flag dead
#   SyntheticInline (main, synthetic=true)            → not flagged (synthetic filter)
# Expected flagged set: {(main, ZombieType), (main, Tree), (main, UnresolvedOnly), (shared, LonelyShared)}
assert_dead_code_baseline() {
  local result rows actual_set expected_set
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --slurpfile refs "$DEAD_CODE_REFS_FIXTURE" \
    -f "$QUERIES_DIR/dead-code.jq" "$DEAD_CODE_CATALOG_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ dead-code (baseline): crashed: %s\n" "$result"
    return
  }
  rows="$(echo "$result" | grep -c .)"
  if [[ "$rows" != "4" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ dead-code (baseline): expected 4 rows, got %s:\n%s\n" "$rows" "$result"
    return
  fi
  actual_set="$(echo "$result" | jq -r '"\(.members[0].package):\(.members[0].name)"' | sort | tr '\n' ',' | sed 's/,$//')"
  expected_set="main:Tree,main:UnresolvedOnly,main:ZombieType,shared:LonelyShared"
  if [[ "$actual_set" == "$expected_set" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ dead-code (baseline): emits exactly {ZombieType, Tree, UnresolvedOnly, LonelyShared}\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ dead-code (baseline): row set mismatch\n      expected: %s\n      actual:   %s\n" "$expected_set" "$actual_set"
  fi
}
assert_dead_code_baseline

assert_text_has_cid dead-code.jq "$DEAD_CODE_CATALOG_FIXTURE" --slurpfile refs "$DEAD_CODE_REFS_FIXTURE"

# End-to-end smoke: run the actual TS extractor over a real fixture, emit both
# catalog and references.json, then run dead-code.jq on the pair. Proves the
# query interops with the live extractor's output shape (not just hand-edited
# fixtures). If #146's emitted JSON shape ever drifts from the hand-edited
# fixture, this catches it before the unit tests start lying.
assert_dead_code_e2e_extractor() {
  local extractor_dir tmp_root tmp_catalog tmp_refs result
  extractor_dir="$(cd "$SCRIPT_DIR/../../../extractors/typescript" && pwd)"
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN
  tmp_catalog="$tmp_root/catalog.json"
  tmp_refs="$tmp_root/refs.json"
  cp "$extractor_dir/fixtures/02-interface-extends.ts" "$tmp_root/02-interface-extends.ts"
  if ! node "$extractor_dir/type-catalog.mjs" --root "$tmp_root" --output "$tmp_catalog" --emit-references-graph "$tmp_refs" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    printf "  ✗ dead-code (e2e): extractor crashed\n"
    return
  fi
  if ! result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --slurpfile refs "$tmp_refs" \
    -f "$QUERIES_DIR/dead-code.jq" "$tmp_catalog" 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ dead-code (e2e): query crashed against real extractor output:\n%s\n" "$result"
    return
  fi
  if [[ -n "$result" ]] && ! echo "$result" | jq -e -s 'all(type == "object")' >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "  ✗ dead-code (e2e): non-object JSONL emitted:\n%s\n" "$result"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ dead-code (e2e): query runs cleanly against real extractor output\n"
}
assert_dead_code_e2e_extractor

echo ""
echo "=== public-api-leaks query (function-catalog + type-catalog join) ==="
# Two-file fixture pair: function-catalog primary, type-catalog slurped via
# --slurpfile types. Same harness trick as dead-code in PR #176 — extra_args
# pass through to jq verbatim.
LEAKS_FUNCTIONS_FIXTURE="$FIXTURES_DIR/public-api-leaks-functions.input.json"
LEAKS_TYPES_FIXTURE="$FIXTURES_DIR/public-api-leaks-types.input.json"

assert_envelope_shape public-api-leaks.jq "$LEAKS_FUNCTIONS_FIXTURE" --slurpfile types "$LEAKS_TYPES_FIXTURE"

assert_jsonl_has_prefix public-api-leaks.jq "$LEAKS_FUNCTIONS_FIXTURE" "public-api-leaks:" \
  --slurpfile types "$LEAKS_TYPES_FIXTURE"

# Semantic correctness. Planted set (functions side):
#   cleanFn (exported, refs all exported)                   → no leak
#   leakyParam (exported, param refs un-exported InternalReq) → flag
#   leakyReturn (exported, return un-exported InternalResp)   → flag
#   leakyBoth (exported, both un-exported)                    → flag (2 leak entries)
#   nonExportedFn (NOT exported, refs un-exported)            → no leak (caller-export filter)
#   genericFn (exported, refs only generic bindings)          → no leak (binding filter)
#   crossPkgClean (exported, refs shared:CommonType exported) → no leak
#   anonymousParam (exported, type_ref: null)                 → no leak (skipped — nothing to resolve)
#   leakyMethodSkipped (kind:method, exported, leaky)         → no leak (kind:method skipped in v1)
#   leakyFunctionVerifies (kind:function, leaky, same type as method) → flag (proves the method skip is *query-side*)
# Expected flag set: {leakyParam, leakyReturn, leakyBoth, leakyFunctionVerifies}.
assert_public_api_leaks_baseline() {
  local result rows actual_set expected_set
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --slurpfile types "$LEAKS_TYPES_FIXTURE" \
    -f "$QUERIES_DIR/public-api-leaks.jq" "$LEAKS_FUNCTIONS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ public-api-leaks (baseline): crashed: %s\n" "$result"
    return
  }
  rows="$(echo "$result" | grep -c .)"
  if [[ "$rows" != "4" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ public-api-leaks (baseline): expected 4 rows, got %s:\n%s\n" "$rows" "$result"
    return
  fi
  actual_set="$(echo "$result" | jq -r '"\(.members[0].package):\(.members[0].name)"' | sort | tr '\n' ',' | sed 's/,$//')"
  expected_set="main:leakyBoth,main:leakyFunctionVerifies,main:leakyParam,main:leakyReturn"
  if [[ "$actual_set" == "$expected_set" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ public-api-leaks (baseline): emits exactly {leakyParam, leakyReturn, leakyBoth, leakyFunctionVerifies}\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ public-api-leaks (baseline): row set mismatch\n      expected: %s\n      actual:   %s\n" "$expected_set" "$actual_set"
  fi
}
assert_public_api_leaks_baseline

# leakyBoth must report TWO leak entries (param + return), not one.
assert_public_api_leaks_leakyboth_has_two_entries() {
  local count
  count="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --slurpfile types "$LEAKS_TYPES_FIXTURE" \
    -f "$QUERIES_DIR/public-api-leaks.jq" "$LEAKS_FUNCTIONS_FIXTURE" 2>&1 \
    | jq -r 'select(.members[0].name == "leakyBoth") | .leaks | length')"
  if [[ "$count" == "2" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ public-api-leaks (leakyBoth): reports 2 leak entries (param + return)\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ public-api-leaks (leakyBoth): expected 2 leak entries, got %s\n" "$count"
  fi
}
assert_public_api_leaks_leakyboth_has_two_entries

assert_text_has_cid public-api-leaks.jq "$LEAKS_FUNCTIONS_FIXTURE" --slurpfile types "$LEAKS_TYPES_FIXTURE"

# End-to-end smoke. Run live extractor over 21-function-signatures.ts + a
# minimal type fixture (using fixture 01-simple-interface.ts for the type
# half). The leakyHandler in 21 references InternalRequest (declared in 21
# itself, not exported), so a leak should fire.
assert_public_api_leaks_e2e_extractor() {
  local extractor_dir tmp_root tmp_functions tmp_types result
  extractor_dir="$(cd "$SCRIPT_DIR/../../../extractors/typescript" && pwd)"
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN
  tmp_functions="$tmp_root/functions.json"
  tmp_types="$tmp_root/types.json"
  cp "$extractor_dir/fixtures/21-function-signatures.ts" "$tmp_root/21-function-signatures.ts"
  if ! node "$extractor_dir/function-catalog.mjs" --root "$tmp_root" --output "$tmp_functions" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    printf "  ✗ public-api-leaks (e2e): function-catalog crashed\n"
    return
  fi
  if ! node "$extractor_dir/type-catalog.mjs" --root "$tmp_root" --output "$tmp_types" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    printf "  ✗ public-api-leaks (e2e): type-catalog crashed\n"
    return
  fi
  if ! result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --slurpfile types "$tmp_types" \
    -f "$QUERIES_DIR/public-api-leaks.jq" "$tmp_functions" 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ public-api-leaks (e2e): query crashed:\n%s\n" "$result"
    return
  fi
  if [[ -z "$result" ]] || ! echo "$result" | jq -e -s 'any(.members[0].name == "leakyHandler")' >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "  ✗ public-api-leaks (e2e): expected leakyHandler in output, got:\n%s\n" "$result"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ public-api-leaks (e2e): query flags leakyHandler against real extractor output\n"
}
assert_public_api_leaks_e2e_extractor

echo ""
echo "=== field-copy-mapper-candidates query (function-catalog + type-catalog join) ==="
# Function-catalog primary (rows carrying field_copy_map), type-catalog slurped
# via --slurpfile types. Plant + restraint fixture — exactly TWO rows fire and
# every gate is exercised by a mapper that would otherwise qualify:
#   FLAG     Identity → IdentityResponse  constructor, copied 8, cov 100% — the
#            LML#610 before-shape; residue is the dropped DB key `id`
#   DEMOTED  Profile  → ProfileResponse   model_validate (already-fixed
#            from_attributes form) — surfaced demoted, not re-recommended
#   ---      Order → OrderDto             only 2 identity copies < min_copied 3
#   ---      Thing → BigModel             copied 3 but cov 3/10 = 30% < floor
#   ---      Widget → TestOnlyModel       dest is_test → dropped
#   ---      Ghost → OrderDto             source unresolved in type-catalog
#   ---      plain_helper                 no field_copy_map → filtered
assert_jsonl_has_prefix field-copy-mapper-candidates.jq "$FCM_FUNCTIONS_FIXTURE" \
  "field-copy-mapper-candidates:" --slurpfile types "$FCM_TYPES_FIXTURE" \
  --argjson min_copied 3 --argjson min_coverage 0.9

assert_field_copy_mapper_semantic() {
  local jsonl count first_ok second_ok
  jsonl="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r --slurpfile types "$FCM_TYPES_FIXTURE" \
    --argjson min_copied 3 --argjson min_coverage 0.9 \
    -f "$QUERIES_DIR/field-copy-mapper-candidates.jq" "$FCM_FUNCTIONS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ field-copy-mapper-candidates (semantic): crashed: %s\n" "$jsonl"
    return
  }
  count="$(printf '%s\n' "$jsonl" | grep -c . || true)"
  if [[ "$count" != "2" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ field-copy-mapper-candidates (semantic): expected 2 rows, got %d\n%s\n" "$count" "$jsonl"
    return
  fi
  # Row 1: the un-demoted LML#610 plant. Coverage is a near-total mirror (100%),
  # copied is the full eight-field run, and the residue recovers the dropped id.
  first_ok="$(printf '%s\n' "$jsonl" | head -1 | jq -r \
    '(.left.name == "Identity" and .right.name == "IdentityResponse"
      and .demoted == false and .form == "constructor"
      and (.copied_fields | length) == 8 and .dest_coverage == 1
      and .residue == ["id"] and .mapper.name == "_identity_to_response") | tostring')"
  if [[ "$first_ok" != "true" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ field-copy-mapper-candidates (semantic): row 1 is not the un-demoted Identity plant\n%s\n" "$jsonl"
    return
  fi
  # Row 2: the already-fixed model_validate mapper, surfaced demoted.
  second_ok="$(printf '%s\n' "$jsonl" | sed -n 2p | jq -r \
    '(.left.name == "Profile" and .right.name == "ProfileResponse"
      and .demoted == true and .form == "model_validate"
      and (.copied_fields | length) == 0
      and .mapper.name == "ProfileResponse.from_profile") | tostring')"
  if [[ "$second_ok" != "true" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ field-copy-mapper-candidates (semantic): row 2 is not the demoted Profile mapper\n%s\n" "$jsonl"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ field-copy-mapper-candidates (semantic): flags the Identity plant, demotes the model_validate mapper, drops all four restraint cases\n"
}
assert_field_copy_mapper_semantic

assert_text_has_cid field-copy-mapper-candidates.jq "$FCM_FUNCTIONS_FIXTURE" \
  --slurpfile types "$FCM_TYPES_FIXTURE" --argjson min_copied 3 --argjson min_coverage 0.9

echo ""
echo "=== cross-package-backward-imports query (files.json layering check) ==="
# Single-input query: takes a wrapped files.json (no slurp needed). Flags any
# shared/* file that imports from main/* — the layering violation that
# motivates the `--shared` split. v1 does not filter type_only / is_test /
# dynamic-import; consumers can post-filter via `.backward_imports[]`.
BACKWARD_IMPORTS_FIXTURE="$FIXTURES_DIR/cross-package-backward-imports-files.input.json"

assert_jsonl_has_prefix cross-package-backward-imports.jq "$BACKWARD_IMPORTS_FIXTURE" \
  "cross-package-backward-imports:"

# Semantic correctness. Fixture (cross-package-backward-imports-files.input.json):
#   shared:src/dto/lifted.ts             → flag (2 backward edges to main)
#   shared:src/dto/clean.ts              → NOT flag (forward shared+extern only)
#   shared:src/dto/primitives.ts         → NOT flag (no imports)
#   shared:src/test/shared-test.test.ts  → flag (1 backward edge; is_test:true exposed but not filtered in v1)
#   main:src/main-file.ts                → NOT flag (forward main→shared is allowed)
#   main:src/internal/state.ts           → NOT flag (no imports)
#   main:src/services/foo.ts             → NOT flag (no imports)
# Expected flagged set: {shared:src/dto/lifted.ts, shared:src/test/shared-test.test.ts}.
assert_backward_imports_baseline() {
  local result rows actual_set expected_set
  result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/cross-package-backward-imports.jq" "$BACKWARD_IMPORTS_FIXTURE" 2>&1)" || {
    FAIL=$((FAIL + 1))
    printf "  ✗ cross-package-backward-imports (baseline): crashed: %s\n" "$result"
    return
  }
  rows="$(echo "$result" | grep -c .)"
  if [[ "$rows" != "2" ]]; then
    FAIL=$((FAIL + 1))
    printf "  ✗ cross-package-backward-imports (baseline): expected 2 rows, got %s:\n%s\n" "$rows" "$result"
    return
  fi
  actual_set="$(echo "$result" | jq -r '.members[0].path' | sort | tr '\n' ',' | sed 's/,$//')"
  expected_set="src/dto/lifted.ts,src/test/shared-test.test.ts"
  if [[ "$actual_set" == "$expected_set" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ cross-package-backward-imports (baseline): flags exactly {lifted.ts, shared-test.test.ts}\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ cross-package-backward-imports (baseline): row set mismatch\n      expected: %s\n      actual:   %s\n" \
      "$expected_set" "$actual_set"
  fi
}
assert_backward_imports_baseline

# lifted.ts must report TWO backward_imports entries — proves grouping is per-file, not per-edge.
assert_backward_imports_lifted_has_two_entries() {
  local count
  count="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/cross-package-backward-imports.jq" "$BACKWARD_IMPORTS_FIXTURE" 2>&1 \
    | jq -r 'select(.members[0].path == "src/dto/lifted.ts") | .backward_imports | length')"
  if [[ "$count" == "2" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ cross-package-backward-imports (lifted.ts): reports 2 backward edges grouped on one row\n"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ cross-package-backward-imports (lifted.ts): expected 2 backward edges, got %s\n" "$count"
  fi
}
assert_backward_imports_lifted_has_two_entries

assert_text_has_cid cross-package-backward-imports.jq "$BACKWARD_IMPORTS_FIXTURE"

# End-to-end smoke: run the live type-catalog extractor against an in-tree
# fixture tree with a planted shared→main edge, emit files.json, run the
# query. Proves the query interops with the real extractor's output, not
# just hand-edited fixtures. If --emit-files's shape ever drifts, this
# catches it before the extractor unit tests start lying.
assert_backward_imports_e2e_extractor() {
  local extractor_dir tree_dir tmp_root tmp_files result
  extractor_dir="$(cd "$SCRIPT_DIR/../../../extractors/typescript" && pwd)"
  tree_dir="$FIXTURES_DIR/cross-package-backward-imports-fixture-tree"
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN
  tmp_files="$tmp_root/files.json"
  if ! node "$extractor_dir/type-catalog.mjs" \
       --root "$tree_dir/main" --shared "$tree_dir/shared" \
       --output "$tmp_root/catalog.json" --emit-files "$tmp_files" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    printf "  ✗ cross-package-backward-imports (e2e): extractor crashed\n"
    return
  fi
  if ! result="$(OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -r \
    -f "$QUERIES_DIR/cross-package-backward-imports.jq" "$tmp_files" 2>&1)"; then
    FAIL=$((FAIL + 1))
    printf "  ✗ cross-package-backward-imports (e2e): query crashed:\n%s\n" "$result"
    return
  fi
  if [[ -z "$result" ]] || ! echo "$result" | jq -e -s 'any(.members[0].path == "src/dtos/lifted.ts")' >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "  ✗ cross-package-backward-imports (e2e): expected lifted.ts in output, got:\n%s\n" "$result"
    return
  fi
  PASS=$((PASS + 1))
  printf "  ✓ cross-package-backward-imports (e2e): query flags planted backward edge against real extractor output\n"
}
assert_backward_imports_e2e_extractor

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

# ─── Front-matter well-formedness (PR 2) ─────────────────────────────────
# Each runnable query (every `.jq` under pipeline/queries/ except _canonical.jq)
# must carry a complete `#!`-prefixed front-matter block. See plans/pr2-front-
# matter.md and ADR-0002 for the grammar. PR 3's binary parser will run these
# same checks at registration time.
echo ""
echo "=== Front-matter well-formedness ==="

assert_front_matter_well_formed() {
  local errors=0
  local seen_query_values=()
  # Leading-underscore filenames are libraries (_canonical.jq, future _*.jq),
  # not runnable queries, and do not carry front-matter. Glob excludes them.
  for f in "$QUERIES_DIR"/[!_]*.jq; do
    local base
    base="$(basename "$f")"

    # Required keys: query, shape, catalog, formats, desc.
    for key in query shape catalog formats desc; do
      if ! grep -q "^#! ${key}:" "$f"; then
        printf "  ✗ %s: missing `#! %s:` line\n" "$base" "$key"
        errors=$((errors + 1))
      fi
    done

    # `query:` value must be unique.
    local qval
    qval="$(awk '/^#! query:/ { sub(/^#! query:[[:space:]]*/, ""); print; exit }' "$f")"
    for prior in "${seen_query_values[@]}"; do
      if [[ "$prior" == "$qval" ]]; then
        printf "  ✗ %s: duplicate `#! query: %s` (seen earlier)\n" "$base" "$qval"
        errors=$((errors + 1))
      fi
    done
    seen_query_values+=("$qval")

    # `shape:` value must be one of cluster / pair / metric (or comma combos).
    local svals
    svals="$(awk '/^#! shape:/ { sub(/^#! shape:[[:space:]]*/, ""); print; exit }' "$f")"
    local IFS=,
    for s in $svals; do
      s="$(echo "$s" | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }')"
      case "$s" in
        cluster|pair|metric) ;;
        *)
          printf "  ✗ %s: `#! shape:` contains unknown token %s (expected cluster/pair/metric)\n" "$base" "$s"
          errors=$((errors + 1))
          ;;
      esac
    done

    # Every `arg: <name>` must appear as --argjson <name> or --arg <name>
    # somewhere in the file (the prose `Run:` block, the body, or both).
    while IFS= read -r argline; do
      local argname
      argname="$(echo "$argline" | awk '{ print $3 }')"
      [[ -z "$argname" ]] && continue
      if ! grep -qE "(--argjson|--arg) ${argname}([[:space:]]|$)" "$f"; then
        printf "  ✗ %s: 'arg: %s' declared but no '--argjson %s' or '--arg %s' found in file\n" "$base" "$argname" "$argname" "$argname"
        errors=$((errors + 1))
      fi
    done < <(grep '^#! arg:' "$f")

    # Every `env: <NAME>` must be referenced from the query body as
    # `$ENV.NAME` or `env.NAME`. Uppercase identifiers + the leading `$ENV.`/
    # `env.` qualifier rule out false positives from prose comments or unrelated
    # shell-style assignments.
    while IFS= read -r envline; do
      local envname
      envname="$(echo "$envline" | awk '{ print $3 }')"
      [[ -z "$envname" ]] && continue
      if ! grep -qE "(\\\$ENV\\.${envname}|env\\.${envname})" "$f"; then
        printf "  ✗ %s: 'env: %s' declared but no \$ENV.%s reference found\n" "$base" "$envname" "$envname"
        errors=$((errors + 1))
      fi
    done < <(grep '^#! env:' "$f")
  done

  if [[ "$errors" -eq 0 ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ front-matter: all queries pass shape, uniqueness, arg and env cross-checks\n"
  else
    FAIL=$((FAIL + errors))
  fi
}
assert_front_matter_well_formed

# ─── Extractor manifest.toml well-formedness (PR 2) ─────────────────────
# Each extractor directory now carries a manifest.toml (per ADR-0002). PR 3's
# binary parser will read these to discover invocations. Until then, this check
# ensures the files at least parse as valid TOML.
echo ""
echo "=== Extractor manifest.toml well-formedness ==="

assert_manifests_parse() {
  local manifests=(
    "$(cd "$SCRIPT_DIR/../../../extractors/typescript" && pwd)/manifest.toml"
    "$(cd "$SCRIPT_DIR/../../../extractors/swift" && pwd)/manifest.toml"
    "$(cd "$SCRIPT_DIR/../../../extractors/file-hashes" && pwd)/manifest.toml"
  )
  if ! command -v python3 >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf "  ✓ manifest.toml: skipped (python3 not available)\n"
    return
  fi
  local errors=0
  for m in "${manifests[@]}"; do
    if ! python3 -c "import tomllib; tomllib.load(open('$m', 'rb'))" 2>/dev/null; then
      printf "  ✗ %s: failed to parse as TOML\n" "$m"
      errors=$((errors + 1))
    fi
  done
  if [[ "$errors" -eq 0 ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ manifest.toml: all three extractor manifests parse cleanly\n"
  else
    FAIL=$((FAIL + errors))
  fi
}
assert_manifests_parse

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
