#!/usr/bin/env bash
# Tests for V7 §6.6 context flags (#44).
#
# Drives the swift-catalog extractor against a small fixture tree where each
# file is placed under a path that exercises one specific flag heuristic.
# Then asserts the resulting catalog records carry the expected flags. The
# fixture lives at extractors/swift/tests/fixtures/context-flags/.
#
# Path coverage:
#   Sources/Regular/Regular.swift              → all flags false (negative control)
#   Sources/SuffixMock/NameSuffixed.swift      → is_mock from name suffix
#   Tests/RegularTests/RegularTests.swift      → is_test from path + filename
#   Tests/TestingHelpers/Mocks/PathMocked.swift → is_test + is_mock from path
#   Generated/CodegenModels.swift              → is_codegen from path
#   Examples/SampleApp/SampleView.swift        → is_sample_app from path
#
# Run from repo root: pipeline/queries/_tests/test_context_flags.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SWIFT_BIN="$REPO_ROOT/extractors/swift/.build/release/swift-catalog"
FIXTURE_ROOT="$REPO_ROOT/extractors/swift/tests/fixtures/context-flags"

if [[ ! -x "$SWIFT_BIN" ]]; then
  echo "ERROR: swift-catalog binary not built. Run: (cd extractors/swift && swift build -c release)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap "rm -rf $WORK" EXIT

# --include-tests so the Tests/ records appear in the catalog. Without this
# flag the walker skips test files entirely and the assertions on RegularTests
# / PathMocked wouldn't have records to check. Runs both `type` and `func`
# subcommands so the assertions can cover both visitor paths — the
# FunctionCatalogVisitor's is_mock check uses the containing-type segment
# (different from TypeCatalogVisitor's check on the record's own last
# segment), and the divergent logic needs its own coverage.
"$SWIFT_BIN" type --root "$FIXTURE_ROOT" --include-tests --output "$WORK/types.json" 2>"$WORK/type-stderr"
"$SWIFT_BIN" func --root "$FIXTURE_ROOT" --include-tests --output "$WORK/funcs.json" 2>"$WORK/func-stderr"

PASS=0
FAIL=0

# `flag NAME FLAG` extracts a boolean flag value from the first record whose
# name matches NAME. Returns the JSON literal `true` / `false` / `null`.
flag() {
  local name="$1"
  local flag="$2"
  jq --arg n "$name" --arg f "$flag" \
    '[.[] | select(.name == $n)] | .[0] | .[$f]' "$WORK/types.json"
}

# `fn_flag NAME FLAG` does the same against the function catalog. Function
# records' qualified names include containing-type prefix (e.g.,
# `FooMock.executeQuery`); the helper takes that full qualified name.
fn_flag() {
  local name="$1"
  local flag="$2"
  jq --arg n "$name" --arg f "$flag" \
    '[.[] | select(.name == $n)] | .[0] | .[$f]' "$WORK/funcs.json"
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

# Helper: assert all four flags on a single record.
assert_flags() {
  local name="$1"
  local expected_test="$2"
  local expected_codegen="$3"
  local expected_sample="$4"
  local expected_mock="$5"
  assert_eq "$name: is_test = $expected_test"       "$expected_test"    "$(flag "$name" is_test)"
  assert_eq "$name: is_codegen = $expected_codegen" "$expected_codegen" "$(flag "$name" is_codegen)"
  assert_eq "$name: is_sample_app = $expected_sample" "$expected_sample" "$(flag "$name" is_sample_app)"
  assert_eq "$name: is_mock = $expected_mock"       "$expected_mock"    "$(flag "$name" is_mock)"
}

# Same shape for function records — uses the function catalog.
assert_fn_flags() {
  local name="$1"
  local expected_test="$2"
  local expected_codegen="$3"
  local expected_sample="$4"
  local expected_mock="$5"
  assert_eq "fn $name: is_test = $expected_test"       "$expected_test"    "$(fn_flag "$name" is_test)"
  assert_eq "fn $name: is_codegen = $expected_codegen" "$expected_codegen" "$(fn_flag "$name" is_codegen)"
  assert_eq "fn $name: is_sample_app = $expected_sample" "$expected_sample" "$(fn_flag "$name" is_sample_app)"
  assert_eq "fn $name: is_mock = $expected_mock"       "$expected_mock"    "$(fn_flag "$name" is_mock)"
}

echo "=== Negative control: Sources/Regular/Regular.swift (all flags false) ==="
assert_flags Regular false false false false

echo ""
echo "=== Sources/SuffixMock/NameSuffixed.swift (name-suffix is_mock) ==="
# All three protocols in this file should fire is_mock from their name
# suffix, even though the file isn't in a Mocks/ directory. The other three
# flags stay false (file is under Sources/, not Tests/, Generated/, or Examples/).
assert_flags AccountServiceMock false false false true
assert_flags PaymentStub         false false false true
assert_flags AnalyticsFake       false false false true

echo ""
echo "=== Tests/RegularTests/RegularTests.swift (path is_test) ==="
# Both signals fire: path segment 'Tests' AND filename suffix 'Tests.swift'.
# is_mock stays false (the record name is `RegularBehavior`, not mock-shaped).
assert_flags RegularBehavior true false false false

echo ""
echo "=== Tests/TestingHelpers/Mocks/PathMocked.swift (path is_test + is_mock) ==="
# Path carries both 'Tests' segment AND 'Mocks' segment. Both flags fire
# independently — exercises the explicit OR-of-signals contract.
assert_flags AuthClient true false false true

echo ""
echo "=== Generated/CodegenModels.swift (path is_codegen) ==="
# Path segment 'Generated' (capital G) fires the §6.6 superset check; the
# legacy lowercase '/generated/' detection doesn't catch it on its own.
assert_flags CodegenModel false true false false

echo ""
echo "=== Examples/SampleApp/SampleView.swift (path is_sample_app) ==="
# Both 'Examples/' and 'SampleApp/' match; either alone would fire the flag.
assert_flags SampleView false false true false

echo ""
echo "=== Function records: containing-type-segment is_mock check ==="
# Method on `FooMock` (Sources/SuffixMock/NameSuffixed.swift) — is_mock fires
# from the CONTAINING-TYPE name suffix, not the function name. The file isn't
# in a Mocks/ directory, so the path signal doesn't contribute. Confirms the
# FunctionCatalogVisitor's per-record logic strips the function-name segment
# and checks the containing type, as documented.
assert_fn_flags "FooMock.executeQuery" false false false true
assert_fn_flags "FooMock.resetState"   false false false true

# Method on `RegularProvider` in the same file — containing type doesn't end
# with Mock/Stub/Fake, so is_mock stays false even though the file is
# physically adjacent to FooMock.
assert_fn_flags "RegularProvider.providerWork" false false false false

# Free function in Sources/SuffixMock/NameSuffixed.swift — no containing
# type, name doesn't carry a Mock/Stub/Fake suffix, path isn't Mocks/. All
# flags false. Confirms free functions don't inherit is_mock from
# neighbouring mock-suffixed types.
assert_fn_flags "freeHelperFunction" false false false false

# Method on `AuthClient` in Tests/TestingHelpers/Mocks/PathMocked.swift —
# is_mock fires from the PATH (Mocks/ segment), is_test from the path
# (Tests/ segment). Containing type `AuthClient` doesn't end in Mock, so the
# name signal doesn't contribute — this is the path-only path through the
# OR-of-signals logic.
assert_fn_flags "AuthClient.authenticate" true false false true

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
