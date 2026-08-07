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
#   - Every row of the type catalog carries `access`, asserted with has()
#     rather than `== null` because jq cannot tell an absent key from a null
#     one. `access` is a non-optional String today, so a missed emit site is a
#     compile error and this assertion is currently a tautology — it exists to
#     catch a *future* change to `String?` or to a hand-written `encode(to:)`,
#     either of which would start omitting the key with no other test failing.
#     That is exactly how #318 shipped a contract violation through green CI.
#   - Modifier ordering: `access` picks the access modifier, not the first
#     modifier written (`final public class` and `public final class` agree).
#   - The written-syntax caveat is pinned: a type declared inside a
#     `public extension` reports access "internal" (nothing is written at the
#     declaration) while exported resolves true. Deliberate, not incidental.
#   - `exported` is unchanged: regression checks against the pre-existing
#     type-catalog-heritage fixture, and against this fixture's private and
#     fileprivate rows so the `-> false` branch of isExported is covered too.
#     Heritage alone cannot fail on that branch — every declaration there is
#     unmodified, so `isExported` could `return true` unconditionally and stay
#     green.
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

# --- modifier ordering: access is picked by role, not by position ---

assert_jq "PublicFirstFinal.access (public final)" '"public"' \
    '[.[] | select(.name=="PublicFirstFinal")][0].access' "$OUT"
assert_jq "FinalFirstPublic.access (final public)" '"public"' \
    '[.[] | select(.name=="FinalFirstPublic")][0].access' "$OUT"

# --- written syntax, not resolved effective visibility ---
#
# Swift defaults a declaration inside an extension to the EXTENSION's access
# level, so NestedInPublicExtension is genuinely public across modules. No
# modifier is written at the declaration, so `access` reports "internal".
# Pinned deliberately: a query filtering `.access == "public"` will miss this
# row, and that trade is documented in docs/pipeline-contract.md rather than
# discovered downstream. `exported` still resolves true and is the fallback.

assert_jq "NestedInPublicExtension.access (written syntax -> internal)" '"internal"' \
    '[.[] | select(.name | endswith("NestedInPublicExtension"))][0].access' "$OUT"
assert_jq "NestedInPublicExtension.exported (still true)" 'true' \
    '[.[] | select(.name | endswith("NestedInPublicExtension"))][0].exported' "$OUT"
assert_jq "enclosing extension still reports access public" '"public"' \
    '[.[] | select(.kind=="extension" and .name=="ExtensionTarget")][0].access' "$OUT"

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

# The heritage fixture declares no access modifiers at all, so every row there
# is exported == true and the assertions above cannot distinguish a working
# isExported from `return true`. These cover the `-> false` branch, using rows
# from this issue's own fixture.

assert_jq "regression: FileprivateStruct.exported == false" 'false' \
    '[.[] | select(.name=="FileprivateStruct")][0].exported' "$OUT"
assert_jq "regression: PrivateStruct.exported == false" 'false' \
    '[.[] | select(.name=="PrivateStruct")][0].exported' "$OUT"
assert_jq "regression: PrivateEnum.exported == false" 'false' \
    '[.[] | select(.kind=="type-alias-union" and .name=="PrivateEnum")][0].exported' "$OUT"
assert_jq "regression: PrivateAlias.exported == false" 'false' \
    '[.[] | select(.kind=="type-alias-other" and .name=="PrivateAlias")][0].exported' "$OUT"
assert_jq "regression: package/open/public still exported == true" 'true' \
    '[.[] | select(.name=="PackageStruct" or .name=="OpenClass" or .name=="PublicClass")] | length == 3 and all(.[]; .exported == true)' "$OUT"

echo ""
echo "Total: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
