#!/usr/bin/env bash
#
# test_literal_catalog.sh — integration tests for the `literal` subcommand
# (literal-catalog lane). Builds the extractor, runs it against
# fixtures/literal-catalog/, and asserts the emitted literal records:
# the two v1 positions (binding initializer, call argument), value
# normalization (underscores, hex, scientific, trailing zeros, prefix
# minus), context fields, and the positions v1 deliberately omits
# (enum raw values, returns, tuple elements, string literals).
#
# Follows the shell-based jq-assertion convention of
# test_type_catalog_heritage.sh. Run from anywhere.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/literal-catalog"

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

OUT="$("$BIN" literal --root "$FIXTURES" 2>/dev/null)"

# Exact record inventory: 17 rows (13 numeric + 4 binding-position strings; see
# fixture comments). An accidental new emission position (tuple elements,
# attribute args, raw values, string arguments, …) surfaces here first.
assert_jq "total record count" '17' 'length' "$OUT"

# Case 1: static stored constant with type annotation — binding form,
# is_static, no access modifier, float norm drops the trailing .0, enclosing
# type recorded, no enclosing callable. Line is the literal's line.
assert_jq "cornerRadius.form" '"binding"' \
    '[.[] | select(.binding_name=="cornerRadius")][0].form' "$OUT"
assert_jq "cornerRadius.value" '"6.0"' \
    '[.[] | select(.binding_name=="cornerRadius")][0].value' "$OUT"
assert_jq "cornerRadius.value_norm" '"6"' \
    '[.[] | select(.binding_name=="cornerRadius")][0].value_norm' "$OUT"
assert_jq "cornerRadius.value_kind" '"float"' \
    '[.[] | select(.binding_name=="cornerRadius")][0].value_kind' "$OUT"
assert_jq "cornerRadius.is_static" 'true' \
    '[.[] | select(.binding_name=="cornerRadius")][0].is_static' "$OUT"
assert_jq "cornerRadius.access absent" 'null' \
    '[.[] | select(.binding_name=="cornerRadius")][0].access' "$OUT"
assert_jq "cornerRadius.enclosing_type" '"ArtworkStyle"' \
    '[.[] | select(.binding_name=="cornerRadius")][0].enclosing_type' "$OUT"
assert_jq "cornerRadius.enclosing_callable absent" 'null' \
    '[.[] | select(.binding_name=="cornerRadius")][0].enclosing_callable' "$OUT"
assert_jq "cornerRadius.line" '14' \
    '[.[] | select(.binding_name=="cornerRadius")][0].line' "$OUT"
assert_jq "cornerRadius.package (Sources/<X> rule)" '"RowKit"' \
    '[.[] | select(.binding_name=="cornerRadius")][0].package' "$OUT"

# Case 2: the copy-not-link mirror — private, non-static, same value_norm as
# case 1 (the join key the copied-literal query pairs on).
assert_jq "placeholderCornerRadius.access" '"private"' \
    '[.[] | select(.binding_name=="placeholderCornerRadius")][0].access' "$OUT"
assert_jq "placeholderCornerRadius.is_static" 'false' \
    '[.[] | select(.binding_name=="placeholderCornerRadius")][0].is_static' "$OUT"
assert_jq "placeholderCornerRadius.value_norm" '"6"' \
    '[.[] | select(.binding_name=="placeholderCornerRadius")][0].value_norm' "$OUT"

# Case 3: int binding, var not let.
assert_jq "insets.value/kind" '["12","int"]' \
    '[.[] | select(.binding_name=="insets")][0] | [.value, .value_kind]' "$OUT"

# Case 4: labeled argument on an identifier callee, inside a computed
# property — enclosing_callable is the property name.
assert_jq "RoundedRectangle arg" '["argument","cornerRadius","12","SongRowContent","body"]' \
    '[.[] | select(.callee=="RoundedRectangle")][0] | [.form, .arg_label, .value, .enclosing_type, .enclosing_callable]' "$OUT"
assert_jq "RoundedRectangle arg line" '23' \
    '[.[] | select(.callee=="RoundedRectangle")][0].line' "$OUT"

# Case 5: labeled argument, motivating Spacer(minLength: 8).
assert_jq "Spacer arg" '["minLength","8"]' \
    '[.[] | select(.callee=="Spacer")][0] | [.arg_label, .value]' "$OUT"

# Case 6: member-access callee with an UNLABELED literal argument — callee is
# the member name, arg_label null. The non-literal first argument
# (.horizontal) must not emit a row.
assert_jq "padding arg" '[null,"16"]' \
    '[.[] | select(.callee=="padding")][0] | [.arg_label, .value]' "$OUT"
assert_jq "padding emits exactly one row" '1' \
    '[.[] | select(.callee=="padding")] | length' "$OUT"

# Case 7: float normalization trims trailing zeros.
assert_jq "opacity value/norm" '["0.50","0.5"]' \
    '[.[] | select(.callee=="opacity")][0] | [.value, .value_norm]' "$OUT"

# Case 8: prefix minus folds into value and value_norm.
assert_jq "offset arg" '["x","-4","-4"]' \
    '[.[] | select(.callee=="offset")][0] | [.arg_label, .value, .value_norm]' "$OUT"

# Case 9: local binding inside a function — enclosing_callable is the function.
assert_jq "localSpacing.enclosing_callable" '"pad"' \
    '[.[] | select(.binding_name=="localSpacing")][0].enclosing_callable' "$OUT"

# Case 10: extension member — enclosing_type is the extended type.
assert_jq "extensionPad context" '["SongRowContent",true]' \
    '[.[] | select(.binding_name=="extensionPad")][0] | [.enclosing_type, .is_static]' "$OUT"

# Cases 11-13: normalization — underscores stripped, hex to decimal,
# scientific notation to plain decimal (colliding with the int spelling).
assert_jq "big value/norm" '["1_000","1000"]' \
    '[.[] | select(.binding_name=="big")][0] | [.value, .value_norm]' "$OUT"
assert_jq "mask norm (hex)" '"255"' \
    '[.[] | select(.binding_name=="mask")][0].value_norm' "$OUT"
assert_jq "scientific value/norm/kind" '["1e3","1000","float"]' \
    '[.[] | select(.binding_name=="scientific")][0] | [.value, .value_norm, .value_kind]' "$OUT"

# Not-emitted positions: enum raw values, return statements, tuple elements.
assert_jq "enum raw value not emitted" '0' \
    '[.[] | select(.value_norm=="99")] | length' "$OUT"
assert_jq "return literal not emitted" '0' \
    '[.[] | select(.value_norm=="424242")] | length' "$OUT"
assert_jq "tuple elements not emitted" '0' \
    '[.[] | select(.value_norm=="7001" or .value_norm=="7002")] | length' "$OUT"

# --- String literals (v1 widening): binding position emits, others do not ---

# The "6" text binding now emits as a STRING — value keeps its quotes,
# value_kind distinguishes it from the numeric 6s (same value_norm).
assert_jq "text emits as string" '["binding","string","\"6\"","6"]' \
    '[.[] | select(.binding_name=="text")][0] | [.form, .value_kind, .value, .value_norm]' "$OUT"

# Mirrored string constant across two types (Slice A motivating case): static,
# different enclosing types, containing binding names, same value_norm.
assert_jq "stationCapFlagKey string row" '["\"on_tour_for_you_station_cap\"","on_tour_for_you_station_cap","string","FlagKeys",true]' \
    '[.[] | select(.binding_name=="stationCapFlagKey")][0] | [.value, .value_norm, .value_kind, .enclosing_type, .is_static]' "$OUT"
assert_jq "onTourStationCapFlagKey mirror row" '["on_tour_for_you_station_cap","string","FlagKeyMirror"]' \
    '[.[] | select(.binding_name=="onTourStationCapFlagKey")][0] | [.value_norm, .value_kind, .enclosing_type]' "$OUT"
assert_jq "mirror pair shares value_norm (2 string rows)" '2' \
    '[.[] | select(.value_kind=="string" and .value_norm=="on_tour_for_you_station_cap")] | length' "$OUT"

# Escapes are NOT decoded: "a\tb" stays the four chars a \ t b (value_norm
# preserves source spelling). The probe returns [length, codepoint-at-index-1]
# = [4, 92] (92 = backslash), locking the no-decode contract.
assert_jq "escaped value_norm preserves the backslash (no decode)" '[4,92]' \
    '[.[] | select(.binding_name=="escaped")][0].value_norm | [length, (.[1:2] | explode[0])]' "$OUT"
assert_jq "escaped is a string row" '"string"' \
    '[.[] | select(.binding_name=="escaped")][0].value_kind' "$OUT"

# NOT emitted: interpolated, multiline, and raw string literals, and strings in
# ARGUMENT position (the widening is binding-only).
assert_jq "interpolated string not emitted" '0' \
    '[.[] | select(.binding_name=="interpolated")] | length' "$OUT"
assert_jq "multiline string not emitted" '0' \
    '[.[] | select(.binding_name=="multiline")] | length' "$OUT"
assert_jq "raw string not emitted" '0' \
    '[.[] | select(.binding_name=="raw")] | length' "$OUT"
assert_jq "string argument not emitted (binding-only)" '0' \
    '[.[] | select(.form=="argument" and .value_kind=="string")] | length' "$OUT"

# Form-field discipline: binding rows omit argument fields; argument rows omit
# binding fields. (Absent keys surface as null through jq.)
assert_jq "binding rows carry no callee/arg_label" '0' \
    '[.[] | select(.form=="binding" and (.callee != null or .arg_label != null))] | length' "$OUT"
assert_jq "argument rows carry no binding fields" '0' \
    '[.[] | select(.form=="argument" and (.binding_name != null or .is_static != null or .access != null))] | length' "$OUT"

# Schema: every row carries the core projection + value triple.
assert_jq "every row has core fields" '17' \
    '[.[] | select(.package and .file and (.line | type=="number") and .value and .value_norm and (.value_kind=="int" or .value_kind=="float" or .value_kind=="string") and (.form=="binding" or .form=="argument"))] | length' "$OUT"

echo ""
echo "Total: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
