#!/usr/bin/env bash
#
# test_type_catalog_heritage.sh — integration tests for the V7+ heritage
# extraction (issues #217, #222). Builds the extractor, runs it against
# fixtures under fixtures/type-catalog-heritage/, and asserts the emitted
# extends / conforms_to / wraps_notification_name fields.
#
# Follows the precedent set by test_package_graph.sh: shell-based, jq-based
# JSON assertions, out-of-process invocation. See plans/issue-217-222-*.md
# for the rationale (sticks with the existing extractor test convention
# rather than introducing a swift test target).
#
# Run from anywhere; the script resolves its own location.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/type-catalog-heritage"

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

# Case 1: FooClass — default-both (neither BaseClass nor ProtoA is in the
# curated sets, so both arrays carry both names).
assert_jq "FooClass.extends"      '["BaseClass","ProtoA"]' \
    '[.[] | select(.name=="FooClass")][0].extends' "$OUT"
assert_jq "FooClass.conforms_to"  '["BaseClass","ProtoA"]' \
    '[.[] | select(.name=="FooClass")][0].conforms_to' "$OUT"

# Case 2: BarObjC — NSObject is class-only, Identifiable is protocol-only.
# (NSObject already provides Equatable; the fixture picks Identifiable to
# avoid SourceKit's redundant-conformance warning. Either marker exercises
# the curated split — the test asserts the partition, not the specific name.)
assert_jq "BarObjC.extends"       '["NSObject"]' \
    '[.[] | select(.name=="BarObjC")][0].extends' "$OUT"
assert_jq "BarObjC.conforms_to"   '["Identifiable"]' \
    '[.[] | select(.name=="BarObjC")][0].conforms_to' "$OUT"

# Case 3: BazStruct (the struct decl, before extension) — structs can't class-
# inherit; Sendable & Hashable are both curated protocols.
assert_jq "BazStruct.extends"     '[]' \
    '[.[] | select(.name=="BazStruct" and .kind=="type-alias-object")][0].extends' "$OUT"
assert_jq "BazStruct.conforms_to" '["Hashable","Sendable"]' \
    '[.[] | select(.name=="BazStruct" and .kind=="type-alias-object")][0].conforms_to' "$OUT"

# Case 4: Pproto — protocol decl, heritage list is conformance-only.
assert_jq "Pproto.extends"        '[]' \
    '[.[] | select(.name=="Pproto")][0].extends' "$OUT"
assert_jq "Pproto.conforms_to"    '["Qproto","Rproto"]' \
    '[.[] | select(.name=="Pproto")][0].conforms_to' "$OUT"

# Case 5: extension BazStruct: Codable — extends records the extended type,
# conforms_to records the explicit conformance.
assert_jq "ext BazStruct.extends"     '["BazStruct"]' \
    '[.[] | select(.kind=="extension" and .name=="BazStruct")][0].extends' "$OUT"
assert_jq "ext BazStruct.conforms_to" '["Codable"]' \
    '[.[] | select(.kind=="extension" and .name=="BazStruct")][0].conforms_to' "$OUT"

# Case 6: NotifMsg — wraps_notification_name records the body expression.
assert_jq "NotifMsg.conforms_to"  '["SomeNotificationMessage"]' \
    '[.[] | select(.name=="NotifMsg")][0].conforms_to' "$OUT"
assert_jq "NotifMsg.wraps_notification_name" '"AVPlayer.rateDidChangeNotification"' \
    '[.[] | select(.name=="NotifMsg")][0].wraps_notification_name' "$OUT"

# Case 7: NoNameMsg — a struct that doesn't conform to *NotificationMessage
# and doesn't declare static var name → wraps_notification_name MUST be
# absent (jq surfaces this as null). The conforms_to set should also be
# empty, confirming detection didn't fire on heritage-less rows.
assert_jq "NoNameMsg.wraps_notification_name absent" 'null' \
    '[.[] | select(.name=="NoNameMsg")][0].wraps_notification_name' "$OUT"
assert_jq "NoNameMsg.conforms_to"   '[]' \
    '[.[] | select(.name=="NoNameMsg")][0].conforms_to' "$OUT"

# Schema: every type row carries extends and conforms_to as arrays (never null).
# Typealiases are exempt — they have no inheritance clause syntactically.
non_alias_count="$(echo "$OUT" | jq '[.[] | select(.kind != "type-alias-other")] | length')"
assert_jq "every non-alias row has extends:[]"     "$non_alias_count" \
    "[.[] | select(.kind != \"type-alias-other\" and (.extends | type)==\"array\")] | length" "$OUT"
assert_jq "every non-alias row has conforms_to:[]" "$non_alias_count" \
    "[.[] | select(.kind != \"type-alias-other\" and (.conforms_to | type)==\"array\")] | length" "$OUT"

echo ""
echo "Total: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
