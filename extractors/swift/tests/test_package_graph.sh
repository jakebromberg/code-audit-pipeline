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

# Cumulative cleanup: every temp resource registers itself here and the single
# EXIT trap walks the list. Using a separate `trap` per resource silently
# overrides the previous handler, which leaks the earlier resources on failure.
CLEANUP_PATHS=()
cleanup() {
    for p in "${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}"; do
        rm -rf -- "$p"
    done
}
trap cleanup EXIT

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
CLEANUP_PATHS+=("$TMPOUT")
"$BIN" package-graph --root "$FIXTURES" --output "$TMPOUT" >/dev/null 2>&1
assert_eq "file written, schema_version=1" "1" "$(jq -r '.schema_version' < "$TMPOUT")"

# ---- Test 3: empty tree exits non-zero -------------------------------------

echo "Test 3: empty tree (no Package.swift, no pbxproj) exits non-zero"
EMPTY_DIR=$(mktemp -d)
CLEANUP_PATHS+=("$EMPTY_DIR")
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

# ---- Test 4: paren-nested brace in pbxproj is not misclassified -------------
#
# Regression: `OTHER_LDFLAGS = ("$(inherited)", { ... }, "-ObjC")` puts a
# `{...}` dict literal inside a `(...)` array. Without paren-depth tracking
# the block scanner pops the dict's `}` against the wrong frame and the
# surrounding PBXNativeTarget can be misclassified. The fixture under
# fixtures/package-graph-parens/ exercises this exact shape.

echo "Test 4: paren-nested brace in pbxproj parses cleanly"
PAREN_FIXTURE="$SCRIPT_DIR/fixtures/package-graph-parens"
OUT_PAREN=$("$BIN" package-graph --root "$PAREN_FIXTURE" 2>/dev/null)
assert_eq "paren fixture schema_version=1" "1" "$(echo "$OUT_PAREN" | jq -r '.schema_version')"

PAREN_APP_COUNT=$(echo "$OUT_PAREN" | jq '[.nodes[] | select(.kind=="app" and .name=="iOS")] | length')
assert_eq "paren fixture: iOS app node present" "1" "$PAREN_APP_COUNT"

PAREN_EDGE=$(echo "$OUT_PAREN" | jq -r '.edges[] | select(.source=="pbxproj") | "\(.from)->\(.to)"')
assert_contains "paren fixture: iOS -> Core edge survived" "$PAREN_EDGE" "iOS->Core"

# ---- Test 5: comments/strings inside pbxproj body don't shadow real keys ----
#
# Regression: pbxValue and pbxArrayValue used to walk block bodies character by
# character tracking only brace/paren depth. A `/* note: name = OldName */`
# block-comment, a `// was: name = X` line-comment, or an `INFOPLIST_KEY_X =
# "name = StringValue";` quoted-string would each get matched as the
# `name = ` key — producing garbage target names like
# `"OldName *\/\n\t\t\tname = iOS"`. A commented-out
# `/* packageProductDependencies = ( ... ); */` similarly shadowed the real
# array. The fixture under fixtures/package-graph-comments/ exercises all
# four shapes in one block.

echo "Test 5: pbxproj body string/comment scanning"
COMMENTS_FIXTURE="$SCRIPT_DIR/fixtures/package-graph-comments"
OUT_COMMENTS=$("$BIN" package-graph --root "$COMMENTS_FIXTURE" 2>/dev/null)

# Live target name is `iOS`, not `OldName`, `AnotherOld`, or `StringValue`.
COMMENTS_APP_NAMES=$(echo "$OUT_COMMENTS" | jq -r '.nodes[] | select(.kind=="app") | .name' | LC_ALL=C sort | tr '\n' ',')
assert_eq "comments fixture: app node name is iOS" "iOS," "$COMMENTS_APP_NAMES"

# Live array resolves to Core, not the commented-out ZZZZ9999.
COMMENTS_EDGES=$(echo "$OUT_COMMENTS" | jq -r '.edges[] | select(.source=="pbxproj") | "\(.from)->\(.to)"' | LC_ALL=C sort | tr '\n' ',')
assert_eq "comments fixture: iOS -> Core (commented-out edge ignored)" "iOS->Core," "$COMMENTS_EDGES"

# No spurious warnings (a shadowed UUID would have logged
# "unknown product uuid ZZZZ9999").
WARN_COUNT=$("$BIN" package-graph --root "$COMMENTS_FIXTURE" 2>&1 >/dev/null | grep -c "unknown product uuid" || true)
assert_eq "comments fixture: no unknown-uuid warnings" "0" "$WARN_COUNT"

# ---- Test 6: external `.package(url:)` deps + dangling pbxproj product ----
#
# V7 §6.5 follow-up #54 S3 + S4. The fixture's Shared/Local Package.swift
# declares two URL-based deps (swift-syntax via .git suffix, plus a name-
# overridden `bar-package` → `CustomNamed`). The fixture's pbxproj references
# an SPM product (`ExternalOnlyPbx`) with no matching in-tree package. The
# extractor must:
#   - emit `kind: "external"` nodes for swift-syntax, CustomNamed, and
#     ExternalOnlyPbx (all three names unique)
#   - keep the graph closed: every edge's `to` resolves to a node in `nodes`

echo "Test 6: external .package(url:) deps + dangling pbxproj product (S3, S4)"
EXTERNALS_FIXTURE="$SCRIPT_DIR/fixtures/package-graph-externals"
OUT_EXT=$("$BIN" package-graph --root "$EXTERNALS_FIXTURE" 2>/dev/null)

EXT_NODE_COUNT=$(echo "$OUT_EXT" | jq '[.nodes[] | select(.kind=="external")] | length')
assert_eq "externals fixture: 3 external nodes emitted" "3" "$EXT_NODE_COUNT"

EXT_NAMES=$(echo "$OUT_EXT" | jq -r '.nodes[] | select(.kind=="external") | .name' | LC_ALL=C sort | tr '\n' ',')
assert_eq "externals fixture: node names match" "CustomNamed,ExternalOnlyPbx,swift-syntax," "$EXT_NAMES"

# Verify path preservation: swift-syntax keeps its URL (with .git stripped from
# the NAME but preserved in the path), CustomNamed uses the explicit name with
# its URL, ExternalOnlyPbx (pbxproj-only) has an empty path.
SS_PATH=$(echo "$OUT_EXT" | jq -r '.nodes[] | select(.name=="swift-syntax") | .path')
assert_eq "externals fixture: swift-syntax path = URL" "https://github.com/swiftlang/swift-syntax.git" "$SS_PATH"
CN_PATH=$(echo "$OUT_EXT" | jq -r '.nodes[] | select(.name=="CustomNamed") | .path')
assert_eq "externals fixture: CustomNamed path = URL" "https://github.com/example/bar-package" "$CN_PATH"
EO_PATH=$(echo "$OUT_EXT" | jq -r '.nodes[] | select(.name=="ExternalOnlyPbx") | .path')
assert_eq "externals fixture: ExternalOnlyPbx (pbxproj-only) has empty path" "" "$EO_PATH"

# Graph closure: every edge's `to` resolves to an emitted node.
EXT_EDGE_TOS=$(echo "$OUT_EXT" | jq -r '.edges[] | .to' | LC_ALL=C sort -u)
EXT_NODE_NAMES=$(echo "$OUT_EXT" | jq -r '.nodes[] | .name' | LC_ALL=C sort -u)
DANGLING=$(comm -23 <(echo "$EXT_EDGE_TOS") <(echo "$EXT_NODE_NAMES") | wc -l | tr -d ' ')
assert_eq "externals fixture: every edge target resolves to a node (no dangling)" "0" "$DANGLING"

# ---- Test 7: cycle detection (S2) ------------------------------------------
#
# V7 §6.5 follow-up #54 S2. Two packages mutually depending on each other
# form a 2-cycle. Swift's compiler would reject this, but the substrate
# parses any Swift source and must detect + warn.

echo "Test 7: cycle detection emits warning (S2)"
CYCLE_FIXTURE="$SCRIPT_DIR/fixtures/package-graph-cycle"
CYCLE_STDERR=$("$BIN" package-graph --root "$CYCLE_FIXTURE" >/dev/null 2>&1; "$BIN" package-graph --root "$CYCLE_FIXTURE" 2>&1 >/dev/null)
assert_contains "cycle fixture: stderr names both cycle members" "$CYCLE_STDERR" "Packages/Alpha, Packages/Beta"
assert_contains "cycle fixture: stderr labels the warning a cycle" "$CYCLE_STDERR" "cycle detected"

# Graph JSON still emits cleanly despite the cycle.
CYCLE_OUT=$("$BIN" package-graph --root "$CYCLE_FIXTURE" 2>/dev/null)
assert_eq "cycle fixture: graph still emitted, schema_version=1" "1" "$(echo "$CYCLE_OUT" | jq -r '.schema_version')"
assert_eq "cycle fixture: 2 nodes" "2" "$(echo "$CYCLE_OUT" | jq '.nodes | length')"
assert_eq "cycle fixture: 2 edges" "2" "$(echo "$CYCLE_OUT" | jq '.edges | length')"

# ---- Test 8: .gitmodules-driven submodule warning (S1) ---------------------
#
# V7 §6.5 follow-up #54 S1. The fixture declares two submodules:
#   Shared/Wallpaper   → directory doesn't exist (uninitialized state)
#   Vendor/Initialized → directory exists with its own Package.swift
# The extractor must warn about the missing one and stay silent on the
# initialized one.

echo "Test 8: .gitmodules-driven uninitialized-submodule warning (S1)"
SUBMODULE_FIXTURE="$SCRIPT_DIR/fixtures/package-graph-submodule"
SUBMODULE_STDERR=$("$BIN" package-graph --root "$SUBMODULE_FIXTURE" 2>&1 >/dev/null)
assert_contains "submodule fixture: warning names Shared/Wallpaper" "$SUBMODULE_STDERR" "Shared/Wallpaper"
assert_contains "submodule fixture: warning suggests git submodule update" "$SUBMODULE_STDERR" "git submodule update"

# Must NOT warn about Vendor/Initialized (which has its Package.swift).
INIT_WARN_COUNT=$(echo "$SUBMODULE_STDERR" | grep -c "Vendor/Initialized" || true)
assert_eq "submodule fixture: no warning about initialized submodule" "0" "$INIT_WARN_COUNT"

# Total uninitialized-submodule warnings is exactly 1.
UNINIT_WARN_COUNT=$(echo "$SUBMODULE_STDERR" | grep -c "declared in .gitmodules" || true)
assert_eq "submodule fixture: exactly one uninitialized-submodule warning" "1" "$UNINIT_WARN_COUNT"

# ---- Summary ---------------------------------------------------------------

echo
echo "==== test_package_graph: $PASS passed, $FAIL failed ===="
[[ "$FAIL" -eq 0 ]]
