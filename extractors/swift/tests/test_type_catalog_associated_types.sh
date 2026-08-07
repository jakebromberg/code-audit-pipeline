#!/usr/bin/env bash
#
# test_type_catalog_associated_types.sh — integration tests for issue #320
# (`TypeRecord.associated_types`, shape and emission rule settled in #321's
# joint decision). Builds the extractor, runs it against
# fixtures/type-catalog-associated-types/, and asserts:
#
#   - Each entry is `{ name, constraints, primary }` — the ratified
#     `{name, constraints}` shape from docs/pipeline-contract-v2-fixtures.jsonl
#     taken as a superset, plus `primary`.
#   - `constraints` comes from `AssociatedTypeDeclSyntax.inheritanceClause`
#     only, sorted; `[]` when the clause is absent.
#   - `primary` is true when the name appears in
#     `ProtocolDeclSyntax.primaryAssociatedTypeClause`, INCLUDING when that
#     name is inherited rather than declared as a member here — Swift permits
#     `protocol Child<Element>: Parent {}`, and dropping Element would report
#     an empty array for a protocol written `<Element>`. One entry per
#     distinct name; a primary-only name carries empty constraints.
#   - `constraints` splits a composition bound (`Codable & Sendable`) into its
#     elements so it agrees with the comma form.
#   - Protocol rows (`kind == "interface"`) ALWAYS emit the array, `[]` when
#     the protocol declares none.
#   - Non-protocol rows OMIT the field entirely — asserted with
#     has("associated_types"), never `== null`, since jq cannot distinguish
#     an absent key from a null one.
#
# Follows the shell-based jq-assertion convention of
# test_type_catalog_access.sh. Run from anywhere.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/type-catalog-associated-types"
HERITAGE_FIXTURES="$SCRIPT_DIR/fixtures/type-catalog-heritage"

cd "$EXTRACTOR_ROOT"
swift build >/dev/null 2>&1 || swift build

BIN="$EXTRACTOR_ROOT/.build/debug/swift-catalog"
if [[ ! -x "$BIN" ]]; then
    echo "FAIL: extractor binary not found at $BIN" >&2
    exit 1
fi

PASS=0
FAIL=0

assert_jq() {
    local label="$1" expected="$2" jq_expr="$3" input="$4"
    local actual
    actual="$(echo "$input" | jq -c "$jq_expr" 2>&1)" || {
        echo "  FAIL: $label (jq crashed: $actual)" >&2
        FAIL=$((FAIL+1))
        return
    }
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL: $label" >&2
        echo "    expected: $expected" >&2
        echo "    actual:   $actual" >&2
        FAIL=$((FAIL+1))
    fi
}

OUT="$("$BIN" type --root "$FIXTURES" 2>/dev/null)"

# Case 1: PrimaryOnly<Element> — the primary-clause name is also declared as
# an associatedtype member, so it collapses to ONE entry with primary true,
# not a separate primary-only and member-only pair.
assert_jq "PrimaryOnly.associated_types" \
    '[{"constraints":[],"name":"Element","primary":true}]' \
    '[.[] | select(.name=="PrimaryOnly")][0].associated_types' "$OUT"

# Case 2: PlainMember — an associatedtype with no primary clause on the
# protocol → primary false.
assert_jq "PlainMember.associated_types" \
    '[{"constraints":[],"name":"Value","primary":false}]' \
    '[.[] | select(.name=="PlainMember")][0].associated_types' "$OUT"

# Case 3: Constrained — an inheritance clause on the associatedtype populates
# constraints, sorted alphabetically regardless of declaration order
# (Item: Hashable, Codable -> ["Codable","Hashable"]).
assert_jq "Constrained.associated_types" \
    '[{"constraints":["Codable","Hashable"],"name":"Item","primary":false}]' \
    '[.[] | select(.name=="Constrained")][0].associated_types' "$OUT"

# Case 4: Empty — a protocol declaring no associated types still emits the
# array as [], not absent. has() must be true.
assert_jq "Empty.associated_types is []" 'true' \
    '[.[] | select(.name=="Empty")][0].associated_types == []' "$OUT"
assert_jq "Empty has(\"associated_types\")" 'true' \
    '[.[] | select(.name=="Empty")][0] | has("associated_types")' "$OUT"

# Case 5: NotAProtocol — a struct. The field must be OMITTED entirely, not
# emitted as null. has() must be false; a naive `== null` check would pass
# even if the encoder started emitting explicit nulls, silently hiding a
# contract violation.
assert_jq "NotAProtocol has(\"associated_types\") is false" 'false' \
    '[.[] | select(.name=="NotAProtocol")][0] | has("associated_types")' "$OUT"

# --- inherited primary associated type (must NOT be discarded) ---
#
# `protocol Child<Element>: Parent {}` names Element in its primary clause and
# declares no member for it — Element is inherited. Swift permits this and
# `any Child<Int>` works, so reporting [] would tell the per-kind-test-doubles
# detector that a protocol written `<Element>` declares no associated type.

assert_jq "Child: inherited primary emitted, not discarded" \
    '[{"constraints":[],"name":"Element","primary":true}]' \
    '[.[] | select(.name=="Child")][0].associated_types' "$OUT"
assert_jq "Parent: the declaring side keeps its constraints" \
    '[{"constraints":["Equatable"],"name":"Element","primary":false}]' \
    '[.[] | select(.name=="Parent")][0].associated_types' "$OUT"

# --- sort-by-name is exercised (needs >1 entry, declared out of order) ---
#
# SortOrder declares Zed then Alpha. Without this, every fixture protocol has a
# single associated type, the sort is unreachable, and `result.sorted { ... }`
# could be deleted with the suite still green.

assert_jq "SortOrder: entries sorted by name, not declaration order" '["Alpha","Zed"]' \
    '[.[] | select(.name=="SortOrder")][0].associated_types | map(.name)' "$OUT"
assert_jq "SortOrder: more than one entry (sort is reachable)" 'true' \
    '([.[] | select(.name=="SortOrder")][0].associated_types | length) > 1' "$OUT"

# --- composition and comma bounds normalize identically ---

assert_jq "CompositionBound: A & B splits into names" '["Codable","Sendable"]' \
    '[.[] | select(.name=="CompositionBound")][0].associated_types[0].constraints' "$OUT"
assert_jq "composition and comma forms agree" 'true' \
    '([.[] | select(.name=="CompositionBound")][0].associated_types[0].constraints)
     == ([.[] | select(.name=="CommaBound")][0].associated_types[0].constraints)' "$OUT"

# --- generics is untouched on protocol rows ---
#
# #320 calls this the single most load-bearing constraint: generic-arity-drift.jq,
# generic-convention-bound.jq and generic-struct-candidates.jq all consume
# `generics`, protocol rows carry none today, and populating it would silently
# change all three queries' inputs. Asserted so that leaking associated-type
# names into `generics` fails here rather than downstream.

assert_jq "no protocol row carries generics" '0' \
    '[.[] | select(.kind=="interface" and has("generics"))] | length' "$OUT"
assert_jq "protocol rows exist (the generics guard is reachable)" 'true' \
    '([.[] | select(.kind=="interface")] | length) > 0' "$OUT"

# --- pre-existing fields unchanged on protocol rows ---

assert_jq "PrimaryOnly.exported unchanged (no modifier -> true)" 'true' \
    '[.[] | select(.name=="PrimaryOnly")][0].exported' "$OUT"
assert_jq "PrimaryOnly.access unchanged (no modifier -> internal)" '"internal"' \
    '[.[] | select(.name=="PrimaryOnly")][0].access' "$OUT"
assert_jq "PrimaryOnly.kind unchanged" '"interface"' \
    '[.[] | select(.name=="PrimaryOnly")][0].kind' "$OUT"
assert_jq "PrimaryOnly.conforms_to unchanged" '[]' \
    '[.[] | select(.name=="PrimaryOnly")][0].conforms_to' "$OUT"

# --- schema: every interface row has() associated_types, every other kind doesn't ---
#
# Guards against the #329-style "guard that cannot fail": if every row here
# happened to be an interface, has("associated_types") could be replaced by
# `return true` and stay green. NotAProtocol (kind "type-alias-object") makes
# the false branch reachable.

interface_count="$(echo "$OUT" | jq '[.[] | select(.kind=="interface")] | length')"
non_interface_count="$(echo "$OUT" | jq '[.[] | select(.kind!="interface")] | length')"
assert_jq "every interface row has(\"associated_types\")" "$interface_count" \
    '[.[] | select(.kind=="interface" and has("associated_types"))] | length' "$OUT"
assert_jq "every non-interface row lacks associated_types" "$non_interface_count" \
    '[.[] | select(.kind!="interface" and (has("associated_types")|not))] | length' "$OUT"
assert_jq "non_interface_count is nonzero (guard is reachable)" 'true' \
    "$non_interface_count > 0" "$OUT"

# --- regression: heritage fixture protocol/non-protocol rows ---

HERITAGE_OUT="$("$BIN" type --root "$HERITAGE_FIXTURES" 2>/dev/null)"

# Pproto declares no associated types -> [], present, not absent.
assert_jq "regression: Pproto.associated_types is []" 'true' \
    '[.[] | select(.name=="Pproto")][0].associated_types == []' "$HERITAGE_OUT"
assert_jq "regression: Pproto.conforms_to unchanged" '["Qproto","Rproto"]' \
    '[.[] | select(.name=="Pproto")][0].conforms_to' "$HERITAGE_OUT"

# FooClass (a class, kind "type-alias-object") must not carry the field.
assert_jq "regression: FooClass has(\"associated_types\") is false" 'false' \
    '[.[] | select(.name=="FooClass")][0] | has("associated_types")' "$HERITAGE_OUT"

# The extension row for BazStruct is kind "extension", not "interface" —
# must not carry the field either.
assert_jq "regression: ext BazStruct has(\"associated_types\") is false" 'false' \
    '[.[] | select(.kind=="extension" and .name=="BazStruct")][0] | has("associated_types")' "$HERITAGE_OUT"

echo ""
echo "Total: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
