#!/usr/bin/env bash
# Smoke test for examples/swift-plants-v7/analyzer.py.
#
# Builds a synthetic manifest + cluster JSONL pair under a temp dir, runs the
# analyzer, and asserts that:
#   - Plants whose files appear in their expected_substrate_signals surface as ✓
#   - Plants whose files don't surface anywhere are reported ✗
#   - Plants annotated with expected_substrate_gap: true count as effective recall
#   - The S2 threshold gate triggers correctly
#
# Run from repo root: pipeline/queries/_tests/test_analyzer.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ANALYZER="$REPO_ROOT/examples/swift-plants-v7/analyzer.py"

if [[ ! -x "$ANALYZER" ]]; then
  echo "ERROR: analyzer not executable: $ANALYZER" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Build synthetic manifest ---------------------------------------------
cat > "$WORK/manifest.yaml" <<'YAML'
plants:
  - plant_id: "A.1"
    category: extract-to-common
    source_files:
      - "pkg/A.swift"
      - "pkg/B.swift"
    expected_substrate_signals:
      - exact-duplicates
    primary_answer:
      category: extract-to-common
  - plant_id: "A.2"
    category: protocol-inheritance
    source_files:
      - "pkg/C.swift"
    expected_substrate_signals:
      - protocol-inheritance-candidates
    primary_answer:
      category: protocol-inheritance
  - plant_id: "A.3"
    category: pat-introduction
    source_files:
      - "pkg/Z.swift"
    expected_substrate_signals:
      - pat-candidates
    expected_substrate_gap: true
    primary_answer:
      category: pat-introduction
YAML

# --- Build synthetic cluster outputs --------------------------------------
mkdir -p "$WORK/s1" "$WORK/s2"

# S1: only the V6 query exact-duplicates fires on A.1.
cat > "$WORK/s1/exact-duplicates.jsonl" <<'JSONL'
{"cluster_id":"exact-duplicates:pkg/A.swift:1+pkg/B.swift:1","query":"exact-duplicates","decls":[{"name":"X","file":"pkg/A.swift","line":1},{"name":"X","file":"pkg/B.swift","line":1}]}
JSONL

# S2: V6 + V7. exact-duplicates fires on A.1, protocol-inheritance-candidates
# fires on A.2. A.3 is annotated as a gap so it counts even without a row.
cat > "$WORK/s2/exact-duplicates.jsonl" <<'JSONL'
{"cluster_id":"exact-duplicates:pkg/A.swift:1+pkg/B.swift:1","query":"exact-duplicates","decls":[{"name":"X","file":"pkg/A.swift","line":1},{"name":"X","file":"pkg/B.swift","line":1}]}
JSONL
cat > "$WORK/s2/protocol-inheritance-candidates.jsonl" <<'JSONL'
{"cluster_id":"protocol-inheritance-candidates:pkg/C.swift:5","query":"protocol-inheritance-candidates","a":{"name":"P","file":"pkg/C.swift","line":5},"b":{"name":"Q","file":"pkg/C.swift","line":20}}
JSONL
# pat-candidates exists but doesn't reference Z.swift, so A.3 wouldn't surface
# absent its `expected_substrate_gap: true` annotation.
cat > "$WORK/s2/pat-candidates.jsonl" <<'JSONL'
{"cluster_id":"pat-candidates:unrelated","query":"pat-candidates","a":{"name":"Other","file":"pkg/Other.swift","line":1},"b":{"name":"Another","file":"pkg/Another.swift","line":1}}
JSONL

# --- Run analyzer ---------------------------------------------------------
OUT="$WORK/out.txt"
ERR="$WORK/err.txt"

# Threshold is set to 2 so the manifest's 3-plant count + 2 surfacing + 1 gap = 3 effective → 3 ≥ 2.
# The `&& EXIT=$? || EXIT=$?` dance preserves the analyzer's exit code under
# `set -e`; otherwise a non-zero exit would abort the test before the assertion
# below could report it as a FAIL.
"$ANALYZER" \
  --manifest "$WORK/manifest.yaml" \
  --clusters-s1 "$WORK/s1/" \
  --clusters-s2 "$WORK/s2/" \
  --threshold 2 \
  >"$OUT" 2>"$ERR" \
  && EXIT=$? \
  || EXIT=$?

PASS=0
FAIL=0
assert_contains() {
  local desc="$1"; local needle="$2"; local hay="$3"
  if grep -qF -- "$needle" "$hay"; then
    PASS=$((PASS + 1))
    printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s\n     looked for: %s\n     in: %s\n" "$desc" "$needle" "$hay"
    cat "$hay" >&2
  fi
}

echo "=== Exit code ==="
if [[ "$EXIT" == "0" ]]; then
  PASS=$((PASS + 1))
  printf "  ✓ analyzer exited 0 (S2 effective recall met threshold)\n"
else
  FAIL=$((FAIL + 1))
  printf "  ✗ analyzer exited %s\n" "$EXIT"
  cat "$ERR" >&2
fi

echo ""
echo "=== S1 condition (V6) ==="
assert_contains "A.1 surfaces in S1 via exact-duplicates" "A.1" "$OUT"
assert_contains "S1 prints recalled count out of 3" "S1: 1/3" "$OUT"

echo ""
echo "=== S2 condition (V7) ==="
assert_contains "A.1 still surfaces in S2 via exact-duplicates" \
  "exact-duplicates" "$OUT"
assert_contains "A.2 surfaces in S2 via protocol-inheritance-candidates" \
  "protocol-inheritance-candidates" "$OUT"
assert_contains "A.3 reported as annotated gap (not surfaced)" \
  "annotated gap" "$OUT"
assert_contains "S2 prints recalled + annotated breakdown" \
  "S2: 2/3 plants recalled" "$OUT"
assert_contains "S2 reports effective recall after annotations" \
  "+1 annotated gaps → 3/3 effective" "$OUT"
assert_contains "S2 acceptance line present" \
  "S2 acceptance:" "$OUT"

# Now run again with a higher threshold and confirm exit code flips to 1.
echo ""
echo "=== Threshold failure ==="
"$ANALYZER" \
  --manifest "$WORK/manifest.yaml" \
  --clusters-s1 "$WORK/s1/" \
  --clusters-s2 "$WORK/s2/" \
  --threshold 5 \
  >"$WORK/out2.txt" 2>"$WORK/err2.txt" \
  && EXIT2=$? \
  || EXIT2=$?
if [[ "$EXIT2" == "1" ]]; then
  PASS=$((PASS + 1))
  printf "  ✓ threshold 5 produces exit 1 (3 effective < 5)\n"
else
  FAIL=$((FAIL + 1))
  printf "  ✗ expected exit 1 at threshold 5; got %s\n" "$EXIT2"
fi

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
