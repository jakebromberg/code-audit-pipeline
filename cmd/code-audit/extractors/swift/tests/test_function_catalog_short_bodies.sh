#!/usr/bin/env bash
#
# test_function_catalog_short_bodies.sh — integration tests for issue #318
# (contract compliance: function-catalog rows for short bodies + enclosing_type).
# Builds the extractor, runs it against fixtures/short-bodies-and-enclosing-type/,
# and asserts:
#
#   - A row is emitted for a free-function one-liner and for a no-op method
#     (`func noop() {}`) — before this change both were dropped entirely.
#   - Rows below --min-body-lines carry no body_hash/body_line_count/
#     body_length/body_lines (jq sees them as null via `.field // null`).
#   - A row at/above the threshold still carries all four body fields.
#   - `enclosing_type` is the dotted nameStack join for methods, `Outer.Inner`
#     for nested types, the extended type's text for extension members, and
#     null for free functions.
#   - `function-duplicates.jq`, `generic-function-candidates.jq`, and
#     `default-impl-candidates.jq` all run cleanly against a catalog containing
#     the new null-body rows (regression: the line-count gate keeps them out
#     of any body_hash cluster).
#
# Follows the shell-based jq-assertion convention of
# test_type_catalog_is_test.sh. Run from anywhere.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUERIES_DIR="$(cd "$EXTRACTOR_ROOT/../../pipeline/queries" && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/short-bodies-and-enclosing-type"

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

FUNC_OUT="$("$BIN" func --root "$FIXTURES" 2>/dev/null)"

# Rows now exist for declarations that used to be dropped entirely.
assert_jq "free-function one-liner emits a row" '1' \
    '[.[] | select(.name=="oneLiner")] | length' "$FUNC_OUT"
assert_jq "empty-body function emits a row" '1' \
    '[.[] | select(.name=="donate")] | length' "$FUNC_OUT"
assert_jq "no-op method emits a row" '1' \
    '[.[] | select(.name=="Widget.noop")] | length' "$FUNC_OUT"
assert_jq "one-line computed-property getter emits a row" '1' \
    '[.[] | select(.name=="Widget.value")] | length' "$FUNC_OUT"

# Below --min-body-lines (default 3): body fields absent (jq reads a missing
# key the same as null).
for name in oneLiner donate; do
    assert_jq "$name: body_hash null" 'null' \
        "[.[] | select(.name==\"$name\")][0].body_hash" "$FUNC_OUT"
    assert_jq "$name: body_line_count null" 'null' \
        "[.[] | select(.name==\"$name\")][0].body_line_count" "$FUNC_OUT"
    assert_jq "$name: body_length null" 'null' \
        "[.[] | select(.name==\"$name\")][0].body_length" "$FUNC_OUT"
    assert_jq "$name: body_lines null" 'null' \
        "[.[] | select(.name==\"$name\")][0].body_lines" "$FUNC_OUT"
done

# At/above the threshold: body fields still populated.
assert_jq "Widget.longBody: body_line_count == 3" '3' \
    '[.[] | select(.name=="Widget.longBody")][0].body_line_count' "$FUNC_OUT"
assert_jq "Widget.longBody: body_hash non-null" 'true' \
    '[.[] | select(.name=="Widget.longBody")][0].body_hash != null' "$FUNC_OUT"

# enclosing_type: nil for free functions, dotted nameStack for methods,
# nested-type join for Outer.Inner, extended-type text for extension members.
assert_jq "oneLiner (free function): enclosing_type null" 'null' \
    '[.[] | select(.name=="oneLiner")][0].enclosing_type' "$FUNC_OUT"
assert_jq "Widget.noop: enclosing_type Widget" '"Widget"' \
    '[.[] | select(.name=="Widget.noop")][0].enclosing_type' "$FUNC_OUT"
assert_jq "Outer.Inner.method: enclosing_type Outer.Inner" '"Outer.Inner"' \
    '[.[] | select(.name=="Outer.Inner.method")][0].enclosing_type' "$FUNC_OUT"
assert_jq "extension Array<Concert>.helper: enclosing_type Array<Concert>" '"Array<Concert>"' \
    '[.[] | select(.name=="Array<Concert>.helper")][0].enclosing_type' "$FUNC_OUT"

# Regression: the three body-clustering queries must run cleanly on a catalog
# that now contains null-body rows — the (.body_line_count // 0) >= 3 gate
# should filter them out before any group_by(.body_hash).
if jq -L "$QUERIES_DIR" -r --argjson threshold 0.7 -f "$QUERIES_DIR/function-duplicates.jq" <<<"$FUNC_OUT" >/dev/null 2>&1; then
    echo "  PASS: function-duplicates.jq runs cleanly on null-body rows"
    PASS=$((PASS+1))
else
    echo "  FAIL: function-duplicates.jq crashed on null-body rows" >&2
    FAIL=$((FAIL+1))
fi
if jq -L "$QUERIES_DIR" -r --argjson threshold 0.7 --argjson max_subs 2 -f "$QUERIES_DIR/generic-function-candidates.jq" <<<"$FUNC_OUT" >/dev/null 2>&1; then
    echo "  PASS: generic-function-candidates.jq runs cleanly on null-body rows"
    PASS=$((PASS+1))
else
    echo "  FAIL: generic-function-candidates.jq crashed on null-body rows" >&2
    FAIL=$((FAIL+1))
fi
if jq -L "$QUERIES_DIR" -r --argjson min_conformers 3 -f "$QUERIES_DIR/default-impl-candidates.jq" <<<"$FUNC_OUT" >/dev/null 2>&1; then
    echo "  PASS: default-impl-candidates.jq runs cleanly on null-body rows"
    PASS=$((PASS+1))
else
    echo "  FAIL: default-impl-candidates.jq crashed on null-body rows" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Total: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
