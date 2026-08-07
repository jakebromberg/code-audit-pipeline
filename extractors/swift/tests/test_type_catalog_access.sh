#!/usr/bin/env bash
#
# test_type_catalog_access.sh — integration tests for issue #319
# (`TypeRecord.access`: the Swift access modifier as written, defaulting to
# "internal" when none is present). Builds the extractor, runs it against
# fixtures/type-catalog-access/, and asserts:
#
#   - `public`, `open`, `package`, `fileprivate`, `private` are reproduced
#     verbatim.
#   - No modifier written yields `"internal"`.
#   - All three `TypeRecord(` construction sites emit `access`: the shape-
#     bearing path (struct/class/actor/protocol/extension), the enum path
#     (kind "type-alias-union"), and the typealias path (kind
#     "type-alias-other").
#   - Every row of the type catalog carries `access` (has(), not == null —
#     it's a non-optional field, but presence must still be asserted per-row
#     so a missed emit site can't hide behind a coincidental default).
#   - `exported` is unchanged: a regression check against the pre-existing
#     type-catalog-heritage fixture's values.
#
# Follows the shell-based jq-assertion convention of
# test_type_catalog_heritage.sh. Run from anywhere.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/type-catalog-access"
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

# --- emitShapeBearing path: struct / class / actor / protocol / extension ---

assert_jq "PublicClass.access"              '"public"'   '[.[] | select(.name=="PublicClass")][0].access' "$OUT"
assert_jq "OpenClass.access"                '"open"'     '[.[] | select(.name=="OpenClass")][0].access' "$OUT"
assert_jq "PackageStruct.access"            '"package"'  '[.[] | select(.name=="PackageStruct")][0].access' "$OUT"
assert_jq "ExplicitInternalStruct.access"   '"internal"' '[.[] | select(.name=="ExplicitInternalStruct")][0].access' "$OUT"
assert_jq "ImplicitInternalStruct.access (no modifier -> internal)" '"internal"' \
    '[.[] | select(.name=="ImplicitInternalStruct")][0].access' "$OUT"
assert_jq "FileprivateStruct.access"        '"fileprivate"' '[.[] | select(.name=="FileprivateStruct")][0].access' "$OUT"
assert_jq "PrivateStruct.access"            '"private"'  '[.[] | select(.name=="PrivateStruct")][0].access' "$OUT"
assert_jq "PublicActor.access"              '"public"'   '[.[] | select(.name=="PublicActor")][0].access' "$OUT"
assert_jq "ImplicitInternalActor.access (no modifier -> internal)" '"internal"' \
    '[.[] | select(.name=="ImplicitInternalActor")][0].access' "$OUT"
assert_jq "PublicProto.access"              '"public"'   '[.[] | select(.name=="PublicProto")][0].access' "$OUT"
assert_jq "ImplicitInternalProto.access (no modifier -> internal)" '"internal"' \
    '[.[] | select(.name=="ImplicitInternalProto")][0].access' "$OUT"
assert_jq "extension ExtensionTarget.access" '"public"'  \
    '[.[] | select(.kind=="extension" and .name=="ExtensionTarget")][0].access' "$OUT"

# --- emitEnum path (kind "type-alias-union") ---

assert_jq "PublicEnum.access"  '"public"'  \
    '[.[] | select(.kind=="type-alias-union" and .name=="PublicEnum")][0].access' "$OUT"
assert_jq "PrivateEnum.access" '"private"' \
    '[.[] | select(.kind=="type-alias-union" and .name=="PrivateEnum")][0].access' "$OUT"
assert_jq "ImplicitInternalEnum.access (no modifier -> internal)" '"internal"' \
    '[.[] | select(.kind=="type-alias-union" and .name=="ImplicitInternalEnum")][0].access' "$OUT"

# --- typealias path (kind "type-alias-other") ---

assert_jq "PublicAlias.access"  '"public"'  \
    '[.[] | select(.kind=="type-alias-other" and .name=="PublicAlias")][0].access' "$OUT"
assert_jq "PrivateAlias.access" '"private"' \
    '[.[] | select(.kind=="type-alias-other" and .name=="PrivateAlias")][0].access' "$OUT"
assert_jq "ImplicitInternalAlias.access (no modifier -> internal)" '"internal"' \
    '[.[] | select(.kind=="type-alias-other" and .name=="ImplicitInternalAlias")][0].access' "$OUT"

# --- schema: every row has access, and it's always a string (never absent) ---

row_count="$(echo "$OUT" | jq '[.[]] | length')"
assert_jq "every row has(\"access\")" "$row_count" \
    "[.[] | select(has(\"access\"))] | length" "$OUT"
assert_jq "every row's access is a string" "$row_count" \
    "[.[] | select((.access | type) == \"string\")] | length" "$OUT"

# --- regression: exported unchanged (existing heritage fixture) ---

HERITAGE_OUT="$("$BIN" type --root "$HERITAGE_FIXTURES" 2>/dev/null)"

assert_jq "regression: FooClass.exported unchanged" 'true' \
    '[.[] | select(.name=="FooClass")][0].exported' "$HERITAGE_OUT"
assert_jq "regression: BarObjC.exported unchanged" 'true' \
    '[.[] | select(.name=="BarObjC")][0].exported' "$HERITAGE_OUT"
assert_jq "regression: BazStruct.exported unchanged" 'true' \
    '[.[] | select(.name=="BazStruct" and .kind=="type-alias-object")][0].exported' "$HERITAGE_OUT"
assert_jq "regression: Pproto.exported unchanged" 'true' \
    '[.[] | select(.name=="Pproto")][0].exported' "$HERITAGE_OUT"

# All fixture types in Heritage.swift have no explicit access modifier, so
# they must all default to "internal" for access while keeping exported true
# (the pre-existing "no modifier -> exported true" default is untouched).
assert_jq "regression: FooClass.access defaults internal, exported stays true" 'true' \
    '[.[] | select(.name=="FooClass")][0] | .access == "internal" and .exported == true' "$HERITAGE_OUT"

echo ""
echo "Total: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
