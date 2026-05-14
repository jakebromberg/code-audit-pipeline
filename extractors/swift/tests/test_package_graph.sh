#!/usr/bin/env bash
#
# test_package_graph.sh — integration tests for the `swift-catalog package-graph`
# subcommand. Builds the extractor (release-flag-less debug build), runs it
# against synthetic fixtures under fixtures/package-graph/, and asserts the
# emitted JSON against expected nodes/edges.
#
# Run from anywhere; the script resolves its own location.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/package-graph"

cd "$EXTRACTOR_ROOT"
swift build >/dev/null 2>&1 || swift build  # surface errors if build fails

BIN="$EXTRACTOR_ROOT/.build/debug/swift-catalog"
if [[ ! -x "$BIN" ]]; then
    echo "FAIL: extractor binary not found at $BIN" >&2
    exit 1
fi

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
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

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q -- "$needle"; then
        echo "  PASS: $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL: $label" >&2
        echo "    needle:   $needle" >&2
        echo "    haystack: $haystack" >&2
        FAIL=$((FAIL+1))
    fi
}

# ---- Test 1: full fixture (3 Package.swift + 1 pbxproj) ---------------------

echo "Test 1: full fixture (Shared packages + pbxproj app targets)"
OUT=$("$BIN" package-graph --root "$FIXTURES" 2>/dev/null)

# schema_version present
assert_eq "schema_version=1" "1" "$(echo "$OUT" | jq -r '.schema_version')"

# Node names: Shared/Core, Shared/Caching, Shared/Networking, iOS, watchOS, widget.
# Use LC_ALL=C to match Swift's ASCII-ordered string sort (uppercase before lowercase),
# so this assertion is locale-independent.
NODE_NAMES=$(echo "$OUT" | jq -r '.nodes[].name' | LC_ALL=C sort | tr '\n' ',')
assert_eq "node names" \
    "Shared/Caching,Shared/Core,Shared/Networking,iOS,watchOS,widget," \
    "$NODE_NAMES"

# Node kinds: 3 packages + 3 apps
PKG_COUNT=$(echo "$OUT" | jq '[.nodes[] | select(.kind=="package")] | length')
APP_COUNT=$(echo "$OUT" | jq '[.nodes[] | select(.kind=="app")] | length')
assert_eq "package node count" "3" "$PKG_COUNT"
assert_eq "app node count" "3" "$APP_COUNT"

# Expected Package.swift edges
EDGES_PKG=$(echo "$OUT" | jq -r '.edges[] | select(.source=="Package.swift") | "\(.from)->\(.to)"' | sort)
assert_contains "Shared/Caching -> Shared/Core" "$EDGES_PKG" "Shared/Caching->Shared/Core"
assert_contains "Shared/Networking -> Shared/Core" "$EDGES_PKG" "Shared/Networking->Shared/Core"
assert_contains "Shared/Networking -> Shared/Caching" "$EDGES_PKG" "Shared/Networking->Shared/Caching"

# Expected pbxproj edges
EDGES_PBX=$(echo "$OUT" | jq -r '.edges[] | select(.source=="pbxproj") | "\(.from)->\(.to)"' | sort)
assert_contains "iOS -> Shared/Core" "$EDGES_PBX" "iOS->Shared/Core"
assert_contains "iOS -> Shared/Networking" "$EDGES_PBX" "iOS->Shared/Networking"
assert_contains "watchOS -> Shared/Core" "$EDGES_PBX" "watchOS->Shared/Core"
assert_contains "widget -> Shared/Core" "$EDGES_PBX" "widget->Shared/Core"
assert_contains "widget -> Shared/Caching" "$EDGES_PBX" "widget->Shared/Caching"

# ---- Test 2: --output flag writes to file ----------------------------------

echo "Test 2: --output writes to file"
TMPOUT=$(mktemp)
trap 'rm -f "$TMPOUT"' EXIT
"$BIN" package-graph --root "$FIXTURES" --output "$TMPOUT" >/dev/null 2>&1
assert_eq "file written, schema_version=1" "1" "$(jq -r '.schema_version' < "$TMPOUT")"

# ---- Test 3: empty tree exits non-zero -------------------------------------

echo "Test 3: empty tree (no Package.swift, no pbxproj) exits non-zero"
EMPTY_DIR=$(mktemp -d)
trap 'rm -rf "$EMPTY_DIR"; rm -f "$TMPOUT"' EXIT
set +e
"$BIN" package-graph --root "$EMPTY_DIR" >/dev/null 2>&1
EXITCODE=$?
set -e
if [[ "$EXITCODE" -ne 0 ]]; then
    echo "  PASS: empty tree exits non-zero (exit=$EXITCODE)"
    PASS=$((PASS+1))
else
    echo "  FAIL: empty tree should exit non-zero, got 0" >&2
    FAIL=$((FAIL+1))
fi

# ---- Summary ---------------------------------------------------------------

echo
echo "==== test_package_graph: $PASS passed, $FAIL failed ===="
[[ "$FAIL" -eq 0 ]]
