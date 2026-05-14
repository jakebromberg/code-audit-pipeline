#!/usr/bin/env bash
# Smoke test: re-hash every artifact and compare against reproducibility.yaml.
# Exits 0 on match, 1 on any divergence.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXP="$REPO/experiments/v7-refactor-recommendation"
YAML="$EXP/reproducibility.yaml"

PASS=0
FAIL=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS+1))
    printf "  OK  %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    printf "  FAIL %s\n     expected: %s\n     actual:   %s\n" "$label" "$expected" "$actual"
  fi
}

extract_yaml_hash() {
  local key="$1"
  awk -v key="$key" '$1 == key ":" { print $2; exit }' "$YAML"
}

echo "=== plant_tree_sha ==="
ACTUAL=$(cd /tmp/wxyc-audit/plants-v7 && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
EXPECTED=$(awk '/plant_tree_sha:/ { print $2; exit }' "$YAML")
check "plant_tree_sha" "$EXPECTED" "$ACTUAL"

echo "=== catalog_hashes ==="
for f in type-catalog.json function-catalog.json file-hashes.json; do
  ACTUAL=$(shasum -a 256 "$EXP/catalogs/$f" | awk '{print $1}')
  EXPECTED=$(awk -v f="$f" '$0 ~ "    "f":" { print $2; exit }' "$YAML")
  check "catalogs/$f" "$EXPECTED" "$ACTUAL"
done

echo "=== query_output_hashes (S1) ==="
for f in "$EXP"/clusters-s1/*.jsonl; do
  base=$(basename "$f")
  ACTUAL=$(shasum -a 256 "$f" | awk '{print $1}')
  # First occurrence under s1: section (lines after `    s1:`)
  EXPECTED=$(awk -v base="$base" '
    /^    s1:/ { in_s1=1; next }
    /^    s2:/ { in_s1=0 }
    in_s1 && $0 ~ "      "base":" { print $2; exit }
  ' "$YAML")
  check "s1/$base" "$EXPECTED" "$ACTUAL"
done

echo "=== query_output_hashes (S2) ==="
for f in "$EXP"/clusters-s2/*.jsonl; do
  base=$(basename "$f")
  ACTUAL=$(shasum -a 256 "$f" | awk '{print $1}')
  EXPECTED=$(awk -v base="$base" '
    /^    s2:/ { in_s2=1; next }
    in_s2 && /^[^[:space:]]/ { in_s2=0 }
    in_s2 && $0 ~ "      "base":" { print $2; exit }
  ' "$YAML")
  check "s2/$base" "$EXPECTED" "$ACTUAL"
done

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
