#!/usr/bin/env bash
#
# test_function_catalog_short_bodies.sh — integration tests for issue #318
# (contract compliance: function-catalog rows for short bodies + enclosing_type).
# Builds the extractor, runs it against fixtures/short-bodies-and-enclosing-type/,
# and asserts:
#
#   - A row is emitted for a free-function one-liner and for a no-op method
#     (`func noop() {}`) — before this change both were dropped entirely.
#   - Rows below --min-body-lines carry body_hash/body_line_count/body_length/
#     body_lines as an explicit JSON `null` (`has(...)` is `true`, not just
#     `== null` — a missing key also reads as `null` under `.field`, so the
#     `has` check is the one that actually distinguishes "present but null"
#     from "absent," which is the contract this extractor must honor).
#   - A row at/above the threshold still carries all four body fields.
#   - Every row — regardless of body length or declaration kind — has an
#     identical key set, pinned against the contract.
#   - `enclosing_type` is the dotted nameStack join for methods, `Outer.Inner`
#     for nested types, the extended type's text for extension members, and
#     null (but present) for free functions.
#   - Declaration kinds beyond top-level func/method are covered: initializer,
#     deinitializer, subscript, class member, actor member, enum member, and
#     a protocol default implementation (extension on a protocol).
#   - Threshold boundary: bodies at exactly threshold-1 and threshold+1 lines
#     (default --min-body-lines 3), plus a run with a non-default
#     --min-body-lines value in both directions.
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

# The full key set every function-catalog row must carry, per
# docs/pipeline-contract.md. Pinned once here; every row is checked against it
# below so a future field addition/removal that misses one construction path
# (e.g. the makeRecord vs. an ad-hoc emit site) is caught immediately.
EXPECTED_KEYS='["async","body_hash","body_length","body_line_count","body_lines","enclosing_type","exported","file","generated","is_test","kind","line","name","package","param_count","param_names"]'

# Rows now exist for declarations that used to be dropped entirely.
assert_jq "free-function one-liner emits a row" '1' \
    '[.[] | select(.name=="oneLiner")] | length' "$FUNC_OUT"
assert_jq "empty-body function emits a row" '1' \
    '[.[] | select(.name=="donate")] | length' "$FUNC_OUT"
assert_jq "no-op method emits a row" '1' \
    '[.[] | select(.name=="Widget.noop")] | length' "$FUNC_OUT"
assert_jq "one-line computed-property getter emits a row" '1' \
    '[.[] | select(.name=="Widget.value")] | length' "$FUNC_OUT"

# Below --min-body-lines (default 3): body fields are present but null. The
# `has()` checks are the ones that actually discriminate "explicit null" from
# "key omitted" (both read as `null` under `.field`, which is exactly the bug
# a compiler-synthesized Encodable's encodeIfPresent produces).
for name in oneLiner donate; do
    assert_jq "$name: has body_hash key" 'true' \
        "[.[] | select(.name==\"$name\")][0] | has(\"body_hash\")" "$FUNC_OUT"
    assert_jq "$name: has body_line_count key" 'true' \
        "[.[] | select(.name==\"$name\")][0] | has(\"body_line_count\")" "$FUNC_OUT"
    assert_jq "$name: has body_length key" 'true' \
        "[.[] | select(.name==\"$name\")][0] | has(\"body_length\")" "$FUNC_OUT"
    assert_jq "$name: has body_lines key" 'true' \
        "[.[] | select(.name==\"$name\")][0] | has(\"body_lines\")" "$FUNC_OUT"
    assert_jq "$name: has enclosing_type key" 'true' \
        "[.[] | select(.name==\"$name\")][0] | has(\"enclosing_type\")" "$FUNC_OUT"
    assert_jq "$name: body_hash value is null" 'null' \
        "[.[] | select(.name==\"$name\")][0].body_hash" "$FUNC_OUT"
    assert_jq "$name: body_line_count value is null" 'null' \
        "[.[] | select(.name==\"$name\")][0].body_line_count" "$FUNC_OUT"
    assert_jq "$name: body_length value is null" 'null' \
        "[.[] | select(.name==\"$name\")][0].body_length" "$FUNC_OUT"
    assert_jq "$name: body_lines value is null" 'null' \
        "[.[] | select(.name==\"$name\")][0].body_lines" "$FUNC_OUT"
    assert_jq "$name: key set matches contract" "$EXPECTED_KEYS" \
        "[.[] | select(.name==\"$name\")][0] | keys | sort" "$FUNC_OUT"
done

# At/above the threshold: body fields still populated, keys still present.
assert_jq "Widget.longBody: body_line_count == 3" '3' \
    '[.[] | select(.name=="Widget.longBody")][0].body_line_count' "$FUNC_OUT"
assert_jq "Widget.longBody: body_hash non-null" 'true' \
    '[.[] | select(.name=="Widget.longBody")][0].body_hash != null' "$FUNC_OUT"
assert_jq "Widget.longBody: key set matches contract" "$EXPECTED_KEYS" \
    '[.[] | select(.name=="Widget.longBody")][0] | keys | sort' "$FUNC_OUT"

# Threshold boundary at default --min-body-lines 3: exactly one line below
# (twoLiner, 2 normalized lines) and exactly one line above (fourLiner, 4).
assert_jq "twoLiner (threshold-1, 2 lines): body_line_count null" 'null' \
    '[.[] | select(.name=="twoLiner")][0].body_line_count' "$FUNC_OUT"
assert_jq "twoLiner (threshold-1): has body_hash key" 'true' \
    '[.[] | select(.name=="twoLiner")][0] | has("body_hash")' "$FUNC_OUT"
assert_jq "fourLiner (threshold+1, 4 lines): body_line_count == 4" '4' \
    '[.[] | select(.name=="fourLiner")][0].body_line_count' "$FUNC_OUT"
assert_jq "fourLiner (threshold+1): body_hash non-null" 'true' \
    '[.[] | select(.name=="fourLiner")][0].body_hash != null' "$FUNC_OUT"

# enclosing_type: nil (but present) for free functions, dotted nameStack for
# methods, nested-type join for Outer.Inner, extended-type text for extension
# members.
assert_jq "oneLiner (free function): enclosing_type null" 'null' \
    '[.[] | select(.name=="oneLiner")][0].enclosing_type' "$FUNC_OUT"
assert_jq "oneLiner (free function): has enclosing_type key" 'true' \
    '[.[] | select(.name=="oneLiner")][0] | has("enclosing_type")' "$FUNC_OUT"
assert_jq "Widget.noop: enclosing_type Widget" '"Widget"' \
    '[.[] | select(.name=="Widget.noop")][0].enclosing_type' "$FUNC_OUT"
assert_jq "Outer.Inner.method: enclosing_type Outer.Inner" '"Outer.Inner"' \
    '[.[] | select(.name=="Outer.Inner.method")][0].enclosing_type' "$FUNC_OUT"
assert_jq "extension Array<Concert>.helper: enclosing_type Array<Concert>" '"Array<Concert>"' \
    '[.[] | select(.name=="Array<Concert>.helper")][0].enclosing_type' "$FUNC_OUT"

# Declaration kinds previously uncovered by this suite: initializer,
# deinitializer, subscript, class member, actor member, enum member, and a
# protocol default implementation.
assert_jq "Gadget.init(count:): kind initializer" '"initializer"' \
    '[.[] | select(.name=="Gadget.init(count:)")][0].kind' "$FUNC_OUT"
assert_jq "Gadget.init(count:): enclosing_type Gadget" '"Gadget"' \
    '[.[] | select(.name=="Gadget.init(count:)")][0].enclosing_type' "$FUNC_OUT"
assert_jq "Gadget.deinit: kind deinitializer" '"deinitializer"' \
    '[.[] | select(.name=="Gadget.deinit")][0].kind' "$FUNC_OUT"
assert_jq "Gadget.deinit: enclosing_type Gadget" '"Gadget"' \
    '[.[] | select(.name=="Gadget.deinit")][0].enclosing_type' "$FUNC_OUT"
assert_jq "Gadget.subscript: kind subscript" '"subscript"' \
    '[.[] | select(.name=="Gadget.subscript")][0].kind' "$FUNC_OUT"
assert_jq "Gadget.subscript: enclosing_type Gadget" '"Gadget"' \
    '[.[] | select(.name=="Gadget.subscript")][0].enclosing_type' "$FUNC_OUT"
assert_jq "Gadget.poke (class member): enclosing_type Gadget" '"Gadget"' \
    '[.[] | select(.name=="Gadget.poke")][0].enclosing_type' "$FUNC_OUT"
assert_jq "Counter.bump (actor member): enclosing_type Counter" '"Counter"' \
    '[.[] | select(.name=="Counter.bump")][0].enclosing_type' "$FUNC_OUT"
assert_jq "Direction.opposite (enum member): enclosing_type Direction" '"Direction"' \
    '[.[] | select(.name=="Direction.opposite")][0].enclosing_type' "$FUNC_OUT"
assert_jq "Greeter.greet (protocol default impl): enclosing_type Greeter" '"Greeter"' \
    '[.[] | select(.name=="Greeter.greet")][0].enclosing_type' "$FUNC_OUT"
assert_jq "Greeter.greet (protocol default impl): kind method" '"method"' \
    '[.[] | select(.name=="Greeter.greet")][0].kind' "$FUNC_OUT"

# Non-default --min-body-lines: the threshold is a run-time flag, not a
# compile-time constant, so exercise it in both directions.
LOWER_THRESHOLD_OUT="$("$BIN" func --root "$FIXTURES" --min-body-lines 2 2>/dev/null)"
assert_jq "--min-body-lines 2: twoLiner (2 lines) now populated" '2' \
    '[.[] | select(.name=="twoLiner")][0].body_line_count' "$LOWER_THRESHOLD_OUT"
assert_jq "--min-body-lines 2: oneLiner (1 line) still null" 'null' \
    '[.[] | select(.name=="oneLiner")][0].body_line_count' "$LOWER_THRESHOLD_OUT"

HIGHER_THRESHOLD_OUT="$("$BIN" func --root "$FIXTURES" --min-body-lines 4 2>/dev/null)"
assert_jq "--min-body-lines 4: Widget.longBody (3 lines) now null" 'null' \
    '[.[] | select(.name=="Widget.longBody")][0].body_line_count' "$HIGHER_THRESHOLD_OUT"
assert_jq "--min-body-lines 4: fourLiner (4 lines) still populated" '4' \
    '[.[] | select(.name=="fourLiner")][0].body_line_count' "$HIGHER_THRESHOLD_OUT"

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
