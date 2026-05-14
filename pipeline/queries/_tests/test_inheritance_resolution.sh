#!/usr/bin/env bash
# Tests for V7 §6.3 protocol-inheritance resolution.
#
# Drives the swift-catalog extractor over a small fixture tree that exercises
# six resolution-pass behaviors, then asserts properties of the emitted JSON.
# Each fixture protocol is a self-contained probe; the test scripts the
# expected `resolved_from`, `inherited_from`, and field-set shape.
#
# Run from repo root: pipeline/queries/_tests/test_inheritance_resolution.sh
# Requires: swift-catalog binary built (extractors/swift/.build/release/swift-catalog).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SWIFT_BIN="$REPO_ROOT/extractors/swift/.build/release/swift-catalog"
FIXTURE_ROOT="$SCRIPT_DIR/fixtures/protocol-inheritance"

if [[ ! -x "$SWIFT_BIN" ]]; then
  echo "ERROR: swift-catalog binary not built. Run: (cd extractors/swift && swift build -c release)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap "rm -rf $WORK" EXIT

# Extract type catalog from the fixture root. Resolution pass runs as part of
# the `type` subcommand (see main.swift), so the output already carries
# resolved_from / inherited_from where applicable.
"$SWIFT_BIN" type --root "$FIXTURE_ROOT" --output "$WORK/catalog.json" 2>"$WORK/extract.stderr"

PASS=0
FAIL=0

# `record_for NAME` extracts the catalog record with `.name == NAME` and
# `.kind == "interface"`. Returns a JSON object; empty string if not found.
record_for() {
  jq --arg n "$1" '[.[] | select(.name == $n and .kind == "interface")] | .[0] // empty' "$WORK/catalog.json"
}

# `class_record_for NAME` looks up a class record (kind=type-alias-object).
class_record_for() {
  jq --arg n "$1" '[.[] | select(.name == $n and .kind == "type-alias-object")] | .[0] // empty' "$WORK/catalog.json"
}

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s\n     expected: %s\n     actual:   %s\n" "$desc" "$expected" "$actual"
  fi
}

echo "=== Fixture scope: total record count ==="
# Fixture has six declared top-level types (BaseAlpha, ChildBeta,
# GrandchildGamma, ExternallyConformedDelta, CollidingEpsilon,
# ProtocolConformingZeta). Any drift here (e.g., a new auto-emitted
# extension record, or the visitor starting to emit nested types) would
# silently invalidate the per-protocol assertions below. Catch it here.
assert_eq "fixture catalog emits exactly 6 records" \
  "6" \
  "$(jq 'length' "$WORK/catalog.json")"

echo ""
echo "=== BaseAlpha: no inheritance, no resolution ==="
record="$(record_for BaseAlpha)"
assert_eq "BaseAlpha resolved_from is null/absent" \
  "null" \
  "$(echo "$record" | jq '.resolved_from')"
assert_eq "BaseAlpha inherited_from is null/absent" \
  "null" \
  "$(echo "$record" | jq '.inherited_from')"
assert_eq "BaseAlpha declared fields: [alphaCount, alphaName]" \
  '["alphaCount:Int","alphaName:String"]' \
  "$(echo "$record" | jq -c '.fields')"

echo ""
echo "=== ChildBeta: single-step inheritance ==="
record="$(record_for ChildBeta)"
assert_eq "ChildBeta resolved_from = protocol-inheritance" \
  '"protocol-inheritance"' \
  "$(echo "$record" | jq '.resolved_from')"
assert_eq "ChildBeta inherited_from = [BaseAlpha]" \
  '["BaseAlpha"]' \
  "$(echo "$record" | jq -c '.inherited_from')"
assert_eq "ChildBeta fields union [alphaCount, alphaName, betaTag]" \
  '["alphaCount:Int","alphaName:String","betaTag:String"]' \
  "$(echo "$record" | jq -c '.fields')"

echo ""
echo "=== GrandchildGamma: transitive inheritance via fixed-point loop ==="
record="$(record_for GrandchildGamma)"
assert_eq "GrandchildGamma resolved_from = protocol-inheritance" \
  '"protocol-inheritance"' \
  "$(echo "$record" | jq '.resolved_from')"
# Transitive: iteration 1 pulls ChildBeta's declared fields (which at that
# point are just betaTag — ChildBeta's own resolution hasn't run yet because
# of iteration order). Iteration 2 sees ChildBeta now has BaseAlpha's fields
# too, and pulls them into GrandchildGamma. Order of inherited_from
# accumulation is iteration-order — ChildBeta is added in iter 1 (when it
# contributes betaTag), then BaseAlpha is added in iter 2 (when its fields
# arrive transitively through ChildBeta).
assert_eq "GrandchildGamma inherited_from = [ChildBeta, BaseAlpha]" \
  '["ChildBeta","BaseAlpha"]' \
  "$(echo "$record" | jq -c '.inherited_from')"
assert_eq "GrandchildGamma fields union all four" \
  '["alphaCount:Int","alphaName:String","betaTag:String","gammaIndex:Int"]' \
  "$(echo "$record" | jq -c '.fields')"

echo ""
echo "=== ExternallyConformedDelta: external SDK parent skip ==="
record="$(record_for ExternallyConformedDelta)"
assert_eq "ExternallyConformedDelta conforms_to = [Codable]" \
  '["Codable"]' \
  "$(echo "$record" | jq -c '.conforms_to')"
assert_eq "ExternallyConformedDelta resolved_from is null/absent" \
  "null" \
  "$(echo "$record" | jq '.resolved_from')"
assert_eq "ExternallyConformedDelta inherited_from is null/absent" \
  "null" \
  "$(echo "$record" | jq '.inherited_from')"
assert_eq "ExternallyConformedDelta fields are declared-only" \
  '["deltaPayload:String"]' \
  "$(echo "$record" | jq -c '.fields')"

echo ""
echo "=== CollidingEpsilon: same-name field, child-wins ==="
record="$(record_for CollidingEpsilon)"
assert_eq "CollidingEpsilon resolved_from = protocol-inheritance" \
  '"protocol-inheritance"' \
  "$(echo "$record" | jq '.resolved_from')"
# Both BaseAlpha and CollidingEpsilon declare alphaName:String. The merged
# fields contains exactly ONE alphaName entry (no duplication).
assert_eq "CollidingEpsilon alphaName appears exactly once in fields" \
  "1" \
  "$(echo "$record" | jq '[.fields[] | select(startswith("alphaName:"))] | length')"
assert_eq "CollidingEpsilon fields are union, deduped on name" \
  '["alphaCount:Int","alphaName:String","epsilonExtra:Int"]' \
  "$(echo "$record" | jq -c '.fields')"

echo ""
echo "=== ProtocolConformingZeta: class with protocol parent, NOT resolved ==="
record="$(class_record_for ProtocolConformingZeta)"
assert_eq "ProtocolConformingZeta conforms_to = [BaseAlpha]" \
  '["BaseAlpha"]' \
  "$(echo "$record" | jq -c '.conforms_to')"
assert_eq "ProtocolConformingZeta resolved_from is null (class kind skipped)" \
  "null" \
  "$(echo "$record" | jq '.resolved_from')"
assert_eq "ProtocolConformingZeta inherited_from is null (class kind skipped)" \
  "null" \
  "$(echo "$record" | jq '.inherited_from')"
# Class fields should be the declared ones only — none unioned in from BaseAlpha.
assert_eq "ProtocolConformingZeta fields are declared-only (no BaseAlpha contribution)" \
  '["alphaCount:Int","alphaName:String","zetaSpecific:Bool"]' \
  "$(echo "$record" | jq -c '.fields')"

echo ""
echo "=== Resolution summary ==="
# The extractor's stderr summary line includes the resolved count; pluck it.
resolved_count_line="$(grep -o 'protocol-inheritance-resolved: [0-9]*' "$WORK/extract.stderr" || echo 'protocol-inheritance-resolved: missing')"
echo "  $resolved_count_line"
expected_resolved=3  # ChildBeta, GrandchildGamma, CollidingEpsilon. (BaseAlpha has no parent. ExternallyConformedDelta's parent is external. ProtocolConformingZeta is a class.)
assert_eq "extractor stderr reports protocol-inheritance-resolved: $expected_resolved" \
  "protocol-inheritance-resolved: $expected_resolved" \
  "$resolved_count_line"

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
