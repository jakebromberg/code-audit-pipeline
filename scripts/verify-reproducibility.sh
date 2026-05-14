#!/usr/bin/env bash
# Smoke test: re-hash every artifact and compare against reproducibility.yaml.
# Exits 0 on match, 1 on any divergence.
#
# `set -e` is deliberately omitted so all FAILs accumulate and surface in
# one run; with `-e` the first hash divergence would short-circuit the rest.
#
# Prerequisite: a clean `serve-plants-v7.sh + generate-clusters-v7.sh` cycle
# has run, populating /tmp/wxyc-audit/plants-v7/ and
# experiments/v7-refactor-recommendation/{catalogs,clusters-s1,clusters-s2}/.
# Methodology §10 replay: this script's PASS=31/FAIL=0 result is the
# substrate-reproducibility check the §5.1 gate asserts.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXP="$REPO/experiments/v7-refactor-recommendation"
YAML="$EXP/reproducibility.yaml"
SERVED_TREE="${SERVED_TREE:-/tmp/wxyc-audit/plants-v7}"

if [[ ! -d "$SERVED_TREE" ]]; then
  echo "ERROR: served plant tree not found at $SERVED_TREE" >&2
  echo "       run scripts/serve-plants-v7.sh first" >&2
  exit 2
fi
if [[ ! -d "$EXP/catalogs" || ! -d "$EXP/clusters-s1" || ! -d "$EXP/clusters-s2" ]]; then
  echo "ERROR: catalogs/clusters not populated under $EXP/" >&2
  echo "       run scripts/generate-clusters-v7.sh first" >&2
  exit 2
fi

PASS=0
FAIL=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ -z "$expected" ]]; then
    FAIL=$((FAIL+1))
    printf "  FAIL %s\n     no expected hash found in reproducibility.yaml — YAML parsing missed the entry\n" "$label"
  elif [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS+1))
    printf "  OK  %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    printf "  FAIL %s\n     expected: %s\n     actual:   %s\n" "$label" "$expected" "$actual"
  fi
}

echo "=== plant_tree_sha ==="
ACTUAL=$(cd "$SERVED_TREE" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
EXPECTED=$(awk '/plant_tree_sha:/ { print $2; exit }' "$YAML")
check "plant_tree_sha" "$EXPECTED" "$ACTUAL"

echo "=== catalog_hashes ==="
for f in type-catalog.json function-catalog.json file-hashes.json; do
  ACTUAL=$(shasum -a 256 "$EXP/catalogs/$f" | awk '{print $1}')
  EXPECTED=$(awk -v f="$f" '$0 ~ "    "f":" { print $2; exit }' "$YAML")
  check "catalogs/$f" "$EXPECTED" "$ACTUAL"
done

# query_output_hashes sub-sections are nested two levels under
# pre_registration. The section terminator is any sibling key at the same
# indentation as `s1:` / `s2:` (4-space indent), or any shallower top-level
# key under pre_registration (2-space indent). The positive-pattern approach
# avoids the fragility of "first non-whitespace column": if reproducibility.yaml
# grows new sibling sections it stays correct.
echo "=== query_output_hashes (S1) ==="
for f in "$EXP"/clusters-s1/*.jsonl; do
  base=$(basename "$f")
  ACTUAL=$(shasum -a 256 "$f" | awk '{print $1}')
  EXPECTED=$(awk -v base="$base" '
    /^    s1:/ { in_block=1; next }
    in_block && (/^    [a-z_]+:/ || /^  [a-z_]+:/ || /^[^[:space:]]/) { in_block=0 }
    in_block && $0 ~ "      "base":" { print $2; exit }
  ' "$YAML")
  check "s1/$base" "$EXPECTED" "$ACTUAL"
done

echo "=== query_output_hashes (S2) ==="
for f in "$EXP"/clusters-s2/*.jsonl; do
  base=$(basename "$f")
  ACTUAL=$(shasum -a 256 "$f" | awk '{print $1}')
  EXPECTED=$(awk -v base="$base" '
    /^    s2:/ { in_block=1; next }
    in_block && (/^    [a-z_]+:/ || /^  [a-z_]+:/ || /^[^[:space:]]/) { in_block=0 }
    in_block && $0 ~ "      "base":" { print $2; exit }
  ' "$YAML")
  check "s2/$base" "$EXPECTED" "$ACTUAL"
done

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
