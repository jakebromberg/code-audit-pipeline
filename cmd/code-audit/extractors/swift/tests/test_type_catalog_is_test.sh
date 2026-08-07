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
#   - The full 17-pattern normative set (10 directory segments, 7 basename
#     suffixes) is covered, not just the 3 spot-checked in the initial cut.
#   - No row of either catalog is missing `is_test`.
#   - `resolvePackage` distinguishes distinct top-level SwiftPM test targets
#     (`Tests/FooTests/...` vs `Tests/BarTests/...`) instead of collapsing
#     them into one synthetic "Tests" package (PR #322 review finding).
#   - `--include-tests` is a no-op for `type`/`func`: identical output with
#     and without the flag.
#   - `literal` keeps its exclude-by-default polarity: test-path files are
#     absent unless --include-tests is passed, AND the legacy `.test.` /
#     `.spec.` basename-substring markers stay excluded even for a file
#     that isn't a "test path" by the contract's suffix-only rule (PR #322
#     review finding — the exclusion set must stay a strict superset of the
#     pre-#317 implementation's).
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

# Full coverage of the contract's 17-pattern normative set: 10 directory
# segments + 7 basename suffixes. The initial cut spot-checked 3 (Tests/,
# *Tests.swift, *.mock.swift, all already asserted above); this covers the
# remaining 14. Asserted by `.file` path (not `.name`) against the type
# catalog only — the mechanism is identical for func (same `file.isTest`
# propagated to both record types), already spot-checked above.
DIR_SEGMENT_CASES=(
    "tests|Sources/Foo/tests/LowerTestsDirCase.swift"
    "test|Sources/Foo/test/SingularTestDirCase.swift"
    "__tests__|Sources/Foo/__tests__/DunderTestsDirCase.swift"
    "__test__|Sources/Foo/__test__/DunderTestDirCase.swift"
    "spec|Sources/Foo/spec/SpecDirCase.swift"
    "__mocks__|Sources/Foo/__mocks__/MocksDirCase.swift"
    "__fixtures__|Sources/Foo/__fixtures__/FixturesDunderDirCase.swift"
    "fixtures|Sources/Foo/fixtures/FixturesDirCase.swift"
    "e2e|Sources/Foo/e2e/E2EDirCase.swift"
)
for entry in "${DIR_SEGMENT_CASES[@]}"; do
    segment="${entry%%|*}"
    path="${entry##*|}"
    assert_jq "dir segment '$segment': is_test true" 'true' \
        "[.[] | select(.file==\"$path\")][0].is_test" "$TYPE_OUT"
done

SUFFIX_CASES=(
    ".test.swift|Sources/Foo/SuffixTestCase.test.swift"
    ".spec.swift|Sources/Foo/SuffixSpecCase.spec.swift"
    ".fixture.swift|Sources/Foo/SuffixFixtureCase.fixture.swift"
    ".fixtures.swift|Sources/Foo/SuffixFixturesCase.fixtures.swift"
    ".mocks.swift|Sources/Foo/SuffixMocksCase.mocks.swift"
)
for entry in "${SUFFIX_CASES[@]}"; do
    suffix="${entry%%|*}"
    path="${entry##*|}"
    assert_jq "basename suffix '$suffix': is_test true" 'true' \
        "[.[] | select(.file==\"$path\")][0].is_test" "$TYPE_OUT"
done

# No row of either catalog is missing is_test (every WalkedFile is tagged,
# every emit site sets it — a bulk check for a missed emit site).
assert_jq "no type row missing is_test" '0' \
    '[.[] | select(.is_test == null)] | length' "$TYPE_OUT"
assert_jq "no func row missing is_test" '0' \
    '[.[] | select(.is_test == null)] | length' "$FUNC_OUT"

# resolvePackage: Tests/<X>/... resolves to package "<X>", not the
# synthetic "Tests" fallback both distinct top-level test targets used to
# collapse into (PR #322 review — BLOCKING). Fails without the
# `Tests/<X>/...` arm in resolvePackage.
assert_jq "Tests/FooTests/...: package is FooTests" '"FooTests"' \
    '[.[] | select(.file=="Tests/FooTests/FooTestsCase.swift")][0].package' "$TYPE_OUT"
assert_jq "Tests/BarTests/...: package is BarTests" '"BarTests"' \
    '[.[] | select(.file=="Tests/BarTests/BarTestsCase.swift")][0].package' "$TYPE_OUT"
assert_jq "Tests/FooTests/... and Tests/BarTests/... resolve to DIFFERENT packages" 'true' \
    '(([.[] | select(.file=="Tests/FooTests/FooTestsCase.swift")][0].package)
      != ([.[] | select(.file=="Tests/BarTests/BarTestsCase.swift")][0].package))' "$TYPE_OUT"
assert_jq "Tests/FooTests/...: is_test true (Tests dir segment)" 'true' \
    '[.[] | select(.file=="Tests/FooTests/FooTestsCase.swift")][0].is_test' "$TYPE_OUT"
assert_jq "Tests/BarTests/...: is_test true (Tests dir segment)" 'true' \
    '[.[] | select(.file=="Tests/BarTests/BarTestsCase.swift")][0].is_test' "$TYPE_OUT"

# Suffix-only rule vs legacy substring rule diverge on this file: it
# contains ".test." but doesn't END with ".test.swift", so isTestPath (the
# contract's suffix-only rule, which drives is_test) says false — but
# literal's legacy substring carve-out still excludes it. See the fixture's
# own comment and isLiteralExcludedPath in Walker.swift.
assert_jq "Legacy.test.helpers.swift: is_test false (suffix-only rule doesn't match)" 'false' \
    '[.[] | select(.file=="Sources/Foo/Legacy.test.helpers.swift")][0].is_test' "$TYPE_OUT"

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
# default and present with --include-tests. All other new fixtures added
# for the 17-pattern / package-resolution coverage above are deliberately
# literal-catalog-inert (no bare-literal bindings), so they don't perturb
# these counts. Only Legacy.test.helpers.swift is literal-bearing: default
# 3 non-test files (Widget.swift, FooTestingSupport.swift,
# QueuedStubURLProtocol.swift); --include-tests 7 total (the pre-existing 6
# plus Legacy.test.helpers.swift, which is_test-false but still excluded by
# default via the legacy substring carve-out).
LITERAL_OUT="$("$BIN" literal --root "$FIXTURES" 2>/dev/null)"
LITERAL_OUT_INCL="$("$BIN" literal --root "$FIXTURES" --include-tests 2>/dev/null)"
assert_jq "literal default: test files excluded" '3' \
    '[.[] | .file] | unique | length' "$LITERAL_OUT"
assert_jq "literal --include-tests: test files included" '7' \
    '[.[] | .file] | unique | length' "$LITERAL_OUT_INCL"
assert_jq "literal records carry no is_test field" 'null' \
    '.[0].is_test' "$LITERAL_OUT"

# Legacy substring carve-out (PR #322 review — Required): literal's
# exclusion set must stay a strict superset of the pre-#317 implementation,
# which matched ".test." / ".spec." anywhere in the basename. This file
# isn't a "test path" by the contract's suffix-only rule (is_test is false,
# asserted above) but must still be excluded from literal by default.
assert_jq "literal default: legacy-substring file excluded" '0' \
    '[.[] | select(.file | endswith("Legacy.test.helpers.swift"))] | length' "$LITERAL_OUT"
assert_jq "literal --include-tests: legacy-substring file included" '1' \
    '[.[] | select(.file | endswith("Legacy.test.helpers.swift"))] | length' "$LITERAL_OUT_INCL"

echo ""
echo "Total: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
