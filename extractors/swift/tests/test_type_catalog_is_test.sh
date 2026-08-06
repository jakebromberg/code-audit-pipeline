#!/usr/bin/env bash
#
# test_type_catalog_is_test.sh — integration tests for issue #317
# (contract compliance: `is_test` tagging + unconditional test-file walk).
# Builds the extractor, runs it against fixtures/is-test-paths/, and asserts:
#
#   - `type` and `func` walk Tests/ files WITHOUT --include-tests (the
#     assertion that fails before this change — Tests/ was pruned by default).
#   - Every row of both catalogs carries `is_test` per the contract's
#     normative directory-segment + basename pattern set, exact-match per
#     segment (a `CoreTesting` / `FooTesting` support target must NOT match).
#   - `--include-tests` is a no-op for `type`/`func`: identical output with
#     and without the flag.
#   - `literal` keeps its exclude-by-default polarity: test-path files are
#     absent unless --include-tests is passed.
#
# Follows the shell-based jq-assertion convention of
# test_type_catalog_heritage.sh. Run from anywhere.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/is-test-paths"

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

TYPE_OUT="$("$BIN" type --root "$FIXTURES" 2>/dev/null)"
TYPE_OUT_INCL="$("$BIN" type --root "$FIXTURES" --include-tests 2>/dev/null)"
FUNC_OUT="$("$BIN" func --root "$FIXTURES" --min-body-lines 1 2>/dev/null)"
FUNC_OUT_INCL="$("$BIN" func --root "$FIXTURES" --include-tests --min-body-lines 1 2>/dev/null)"

# The key regression assertion: a Tests/ file appears in the DEFAULT
# (no --include-tests) catalog at all. Before this change, Walker.swift
# pruned any directory literally named "Tests" unless --include-tests was
# passed, so this returned 0.
assert_jq "Tests/ file present in default type catalog" 'true' \
    '([.[] | select(.name=="CapturingURLProtocol")] | length) > 0' "$TYPE_OUT"
assert_jq "Tests/ file present in default func catalog" 'true' \
    '([.[] | select(.name=="capturingURLProtocolHelper")] | length) > 0' "$FUNC_OUT"

# is_test per the table in issue #317 / docs/pipeline-contract.md
# "Test path patterns" — exact-match-per-segment, so a testing-*support*
# target (CoreTesting, FooTesting) is NOT mistaken for a test target.
assert_jq "CoreTesting support target: is_test false" 'false' \
    '[.[] | select(.name=="QueuedStubURLProtocol")][0].is_test' "$TYPE_OUT"
assert_jq "Tests/ dir segment: is_test true" 'true' \
    '[.[] | select(.name=="CapturingURLProtocol")][0].is_test' "$TYPE_OUT"
assert_jq "Tests/ dir segment + *Tests.swift basename: is_test true" 'true' \
    '[.[] | select(.name=="DefaultAuthNetworkClientTests")][0].is_test' "$TYPE_OUT"
assert_jq "*.mock.swift basename: is_test true" 'true' \
    '[.[] | select(.name=="StubNetworkClient")][0].is_test' "$TYPE_OUT"
assert_jq "FooTesting support target: is_test false" 'false' \
    '[.[] | select(.name=="FooTestingSupport")][0].is_test' "$TYPE_OUT"
assert_jq "ordinary production file: is_test false" 'false' \
    '[.[] | select(.name=="Widget")][0].is_test' "$TYPE_OUT"

# Same predicate, function catalog.
assert_jq "func: CoreTesting support target is_test false" 'false' \
    '[.[] | select(.name=="queuedStubURLProtocolHelper")][0].is_test' "$FUNC_OUT"
assert_jq "func: Tests/ dir segment is_test true" 'true' \
    '[.[] | select(.name=="capturingURLProtocolHelper")][0].is_test' "$FUNC_OUT"
assert_jq "func: *Tests.swift basename is_test true" 'true' \
    '[.[] | select(.name=="defaultAuthNetworkClientTestsHelper")][0].is_test' "$FUNC_OUT"
assert_jq "func: *.mock.swift basename is_test true" 'true' \
    '[.[] | select(.name=="stubNetworkClientHelper")][0].is_test' "$FUNC_OUT"
assert_jq "func: FooTesting support target is_test false" 'false' \
    '[.[] | select(.name=="fooTestingSupportHelper")][0].is_test' "$FUNC_OUT"
assert_jq "func: ordinary production file is_test false" 'false' \
    '[.[] | select(.name=="widgetHelper")][0].is_test' "$FUNC_OUT"

# --include-tests is a documented no-op for type/func: identical output.
if [[ "$TYPE_OUT" == "$TYPE_OUT_INCL" ]]; then
    echo "  PASS: --include-tests is a no-op for type"
    PASS=$((PASS+1))
else
    echo "  FAIL: --include-tests changed type output" >&2
    FAIL=$((FAIL+1))
fi
if [[ "$FUNC_OUT" == "$FUNC_OUT_INCL" ]]; then
    echo "  PASS: --include-tests is a no-op for func"
    PASS=$((PASS+1))
else
    echo "  FAIL: --include-tests changed func output" >&2
    FAIL=$((FAIL+1))
fi

# literal keeps exclude-by-default polarity: test-path files are absent by
# default and present with --include-tests. 3 non-test files (Widget.swift,
# FooTestingSupport.swift, QueuedStubURLProtocol.swift), 6 total.
LITERAL_OUT="$("$BIN" literal --root "$FIXTURES" 2>/dev/null)"
LITERAL_OUT_INCL="$("$BIN" literal --root "$FIXTURES" --include-tests 2>/dev/null)"
assert_jq "literal default: test files excluded" '3' \
    '[.[] | .file] | unique | length' "$LITERAL_OUT"
assert_jq "literal --include-tests: test files included" '6' \
    '[.[] | .file] | unique | length' "$LITERAL_OUT_INCL"
assert_jq "literal records carry no is_test field" 'null' \
    '.[0].is_test' "$LITERAL_OUT"

echo ""
echo "Total: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
