#!/usr/bin/env bash
# Unit test for verify-reproducibility.sh — exercises the YAML region-parsing
# logic and the actionable-failure paths against synthetic fixtures, so a
# regression in either is caught without needing a full substrate re-run.
#
# Run from repo root: pipeline/queries/_tests/test_verify_reproducibility.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VERIFIER="$REPO_ROOT/scripts/verify-reproducibility.sh"

if [[ ! -x "$VERIFIER" ]]; then
  echo "ERROR: $VERIFIER not executable" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap "rm -rf $WORK" EXIT

PASS=0
FAIL=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS+1))
    printf "  OK  %s\n" "$desc"
  else
    FAIL=$((FAIL+1))
    printf "  FAIL %s\n     needle: %s\n     haystack: %s\n" "$desc" "$needle" "${haystack:0:300}"
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS+1))
    printf "  OK  %s\n" "$desc"
  else
    FAIL=$((FAIL+1))
    printf "  FAIL %s\n     expected exit: %s\n     actual exit:   %s\n" "$desc" "$expected" "$actual"
  fi
}

echo "=== Missing served tree produces exit 2 with actionable message ==="
SCRATCH_REPO="$WORK/repo1"
mkdir -p "$SCRATCH_REPO/scripts" "$SCRATCH_REPO/experiments/v7-refactor-recommendation"
cp "$VERIFIER" "$SCRATCH_REPO/scripts/verify-reproducibility.sh"
chmod +x "$SCRATCH_REPO/scripts/verify-reproducibility.sh"
echo "stub" > "$SCRATCH_REPO/experiments/v7-refactor-recommendation/reproducibility.yaml"
SERVED_TREE="$WORK/does-not-exist" "$SCRATCH_REPO/scripts/verify-reproducibility.sh" 2>"$WORK/err1"; rc=$?
err1=$(cat "$WORK/err1")
assert_exit_code "missing-served-tree exits 2" 2 "$rc"
assert_contains "error mentions serve-plants-v7.sh" "serve-plants-v7.sh" "$err1"

echo ""
echo "=== Missing catalogs dir produces exit 2 with actionable message ==="
SCRATCH_REPO2="$WORK/repo2"
mkdir -p "$SCRATCH_REPO2/scripts" "$SCRATCH_REPO2/experiments/v7-refactor-recommendation"
cp "$VERIFIER" "$SCRATCH_REPO2/scripts/verify-reproducibility.sh"
chmod +x "$SCRATCH_REPO2/scripts/verify-reproducibility.sh"
echo "stub" > "$SCRATCH_REPO2/experiments/v7-refactor-recommendation/reproducibility.yaml"
mkdir -p "$WORK/fake-served-tree"
SERVED_TREE="$WORK/fake-served-tree" "$SCRATCH_REPO2/scripts/verify-reproducibility.sh" 2>"$WORK/err2"; rc=$?
err2=$(cat "$WORK/err2")
assert_exit_code "missing-catalogs exits 2" 2 "$rc"
assert_contains "error mentions generate-clusters-v7.sh" "generate-clusters-v7.sh" "$err2"

echo ""
echo "=== Region parser: S1 / S2 hashes extracted from realistic YAML ==="
# Build a fixture YAML matching the real reproducibility.yaml structure,
# then a one-file served tree + minimal catalog/cluster dirs whose hashes
# we control. The point is to verify the awk region-parsers find the right
# hashes under each section AND don't bleed across sections.
SCRATCH_REPO3="$WORK/repo3"
mkdir -p "$SCRATCH_REPO3/scripts"
cp "$VERIFIER" "$SCRATCH_REPO3/scripts/verify-reproducibility.sh"
chmod +x "$SCRATCH_REPO3/scripts/verify-reproducibility.sh"

EXP3="$SCRATCH_REPO3/experiments/v7-refactor-recommendation"
mkdir -p "$EXP3/catalogs" "$EXP3/clusters-s1" "$EXP3/clusters-s2"

# Pre-compute hashes by writing known contents.
echo "alpha" > "$EXP3/catalogs/type-catalog.json"
echo "beta"  > "$EXP3/catalogs/function-catalog.json"
echo "gamma" > "$EXP3/catalogs/file-hashes.json"
echo "s1-only-content" > "$EXP3/clusters-s1/q1.jsonl"
echo "shared-content"  > "$EXP3/clusters-s1/q2.jsonl"
echo "shared-content"  > "$EXP3/clusters-s2/q2.jsonl"
echo "s2-only-content" > "$EXP3/clusters-s2/q3.jsonl"

H_TYPE=$(shasum -a 256 "$EXP3/catalogs/type-catalog.json" | awk '{print $1}')
H_FUNC=$(shasum -a 256 "$EXP3/catalogs/function-catalog.json" | awk '{print $1}')
H_FILE=$(shasum -a 256 "$EXP3/catalogs/file-hashes.json" | awk '{print $1}')
H_S1Q1=$(shasum -a 256 "$EXP3/clusters-s1/q1.jsonl" | awk '{print $1}')
H_SHARED=$(shasum -a 256 "$EXP3/clusters-s1/q2.jsonl" | awk '{print $1}')
H_S2Q3=$(shasum -a 256 "$EXP3/clusters-s2/q3.jsonl" | awk '{print $1}')

# Served tree of one file so plant_tree_sha computes deterministically.
SERVED3="$WORK/served3"
mkdir -p "$SERVED3"
echo "delta" > "$SERVED3/probe.txt"
H_TREE=$(cd "$SERVED3" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')

cat > "$EXP3/reproducibility.yaml" <<YAMLEOF
pre_registration:
  plant_tree_sha: $H_TREE
  catalog_hashes:
    type-catalog.json: $H_TYPE
    function-catalog.json: $H_FUNC
    file-hashes.json: $H_FILE
  query_output_hashes:
    s1:
      q1.jsonl: $H_S1Q1
      q2.jsonl: $H_SHARED
    s2:
      q2.jsonl: $H_SHARED
      q3.jsonl: $H_S2Q3
  cluster_row_counts:
    s1_total: 1
    s2_total: 1
YAMLEOF

SERVED_TREE="$SERVED3" "$SCRATCH_REPO3/scripts/verify-reproducibility.sh" >"$WORK/out3" 2>&1; rc=$?
out3=$(cat "$WORK/out3")
assert_exit_code "all-match fixture exits 0" 0 "$rc"
assert_contains "plant_tree_sha matched"      "OK  plant_tree_sha"           "$out3"
assert_contains "type-catalog matched"        "OK  catalogs/type-catalog.json" "$out3"
assert_contains "s1/q1.jsonl matched"         "OK  s1/q1.jsonl"              "$out3"
assert_contains "s1/q2.jsonl matched"         "OK  s1/q2.jsonl"              "$out3"
assert_contains "s2/q2.jsonl matched"         "OK  s2/q2.jsonl"              "$out3"
assert_contains "s2/q3.jsonl matched"         "OK  s2/q3.jsonl"              "$out3"
# Sentinel: if the S2 region parser leaked into s1, it'd grab q3's hash for
# a non-existent "s1/q3"; the test would never instantiate that case. So this
# assertion verifies clean separation: total pass count == # of probed files.
assert_contains "all 8 checks passed (1 tree + 3 catalogs + 2 s1 + 2 s2)" "Passed: 8" "$out3"
assert_contains "zero failures"                "Failed: 0"                   "$out3"

echo ""
echo "=== Region parser: latent-bug guard — adding a new top-level subsection after query_output_hashes does NOT break s2 detection ==="
# This is the bug the review flagged: the old terminator '/^[^[:space:]]/'
# fires on any non-whitespace first column. The fixed parser uses positive
# sibling-key patterns, so inserting cluster_row_counts AFTER query_output_hashes
# (the current layout) and adding ANOTHER top-level subsection (a future
# methodology field) both work. Add 'plant_recall:' as the new top-level
# subsection and confirm s2 hashes still get found.
EXP4="$SCRATCH_REPO3/experiments/v7-refactor-recommendation"
cat > "$EXP4/reproducibility.yaml" <<YAMLEOF
pre_registration:
  plant_tree_sha: $H_TREE
  catalog_hashes:
    type-catalog.json: $H_TYPE
    function-catalog.json: $H_FUNC
    file-hashes.json: $H_FILE
  query_output_hashes:
    s1:
      q1.jsonl: $H_S1Q1
      q2.jsonl: $H_SHARED
    s2:
      q2.jsonl: $H_SHARED
      q3.jsonl: $H_S2Q3
  cluster_row_counts:
    s1_total: 1
    s2_total: 1
  plant_recall:
    s1: "0/0"
    s2: "0/0"
  rubric_version: 1
YAMLEOF

SERVED_TREE="$SERVED3" "$SCRATCH_REPO3/scripts/verify-reproducibility.sh" >"$WORK/out4" 2>&1; rc=$?
out4=$(cat "$WORK/out4")
assert_exit_code "extra-subsections still exit 0" 0 "$rc"
assert_contains "s2/q3.jsonl still matched after new subsections" "OK  s2/q3.jsonl" "$out4"

echo ""
echo "=== Region parser: a hash typo surfaces as a FAIL with both expected and actual ==="
# Flip the expected s2/q3 hash to confirm the failure path is intact.
SED_RE="s|^      q3.jsonl: $H_S2Q3|      q3.jsonl: 0000000000000000000000000000000000000000000000000000000000000000|"
sed -i.bak "$SED_RE" "$EXP4/reproducibility.yaml"

SERVED_TREE="$SERVED3" "$SCRATCH_REPO3/scripts/verify-reproducibility.sh" >"$WORK/out5" 2>&1; rc=$?
out5=$(cat "$WORK/out5")
assert_exit_code "typo'd hash exits 1" 1 "$rc"
assert_contains "FAIL line for s2/q3"     "FAIL s2/q3.jsonl"                            "$out5"
assert_contains "expected hash shown"     "expected: 00000000"                          "$out5"
assert_contains "actual hash shown"       "actual:   $H_S2Q3"                           "$out5"

echo ""
echo "=== Region parser: missing YAML entry surfaces as 'no expected hash' FAIL, not a silent OK ==="
# Remove the entry entirely; the script should detect empty EXPECTED and flag it.
sed -i.bak "/^      q2.jsonl: $H_SHARED$/d" "$EXP4/reproducibility.yaml"

SERVED_TREE="$SERVED3" "$SCRATCH_REPO3/scripts/verify-reproducibility.sh" >"$WORK/out6" 2>&1; rc=$?
out6=$(cat "$WORK/out6")
assert_exit_code "missing-yaml-entry exits 1" 1 "$rc"
assert_contains "missing-entry FAIL is explicit" "no expected hash found in reproducibility.yaml" "$out6"

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
