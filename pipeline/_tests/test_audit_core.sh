#!/usr/bin/env bash
# Tests for the audit-core composite action's helper scripts (issue #154).
#
# Currently covers detect-languages.sh — the marker-file → language-list
# resolver. The composite itself is exercised end-to-end by the
# .github/workflows/audit-core-selftest.yml workflow; this file is for
# hermetic unit coverage that runs in <1s and gates merges.
#
# Each test creates a temp dir, populates it with marker files, runs
# detect-languages.sh against it, and asserts stdout. Temp dirs are torn
# down by a trap.
#
# Run:  bash pipeline/_tests/test_audit_core.sh

set -u

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/../.." && pwd)"
DETECT="$REPO_ROOT/.github/actions/audit-core/scripts/detect-languages.sh"
# Real extractors dir for the allowlist tests — only typescript / swift /
# file-hashes manifests ship here; go / python / rust manifests do not.
EXTRACTORS_DIR="$REPO_ROOT/extractors"

PASS=0
FAIL=0
SCRATCH_DIRS=()

cleanup() {
  for d in "${SCRATCH_DIRS[@]+"${SCRATCH_DIRS[@]}"}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

mk_scratch() {
  d=$(mktemp -d "${TMPDIR:-/tmp}/audit-core-test-XXXXXX")
  SCRATCH_DIRS+=("$d")
  printf '%s' "$d"
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $3"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $3"
    echo "      expected: '$1'"
    echo "      actual:   '$2'"
  fi
}

assert_rc() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $3"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $3 (expected rc=$1, got rc=$2)"
  fi
}

# ---------------------------------------------------------------------------

if [ ! -x "$DETECT" ]; then
  echo "FATAL: $DETECT not executable (run: chmod +x $DETECT)" >&2
  exit 2
fi

echo "=== detect-languages.sh — single-language marker detection ==="

t=$(mk_scratch)
: > "$t/tsconfig.json"
got=$("$DETECT" "$t")
assert_eq "typescript" "$got" "tsconfig.json alone → typescript"

t=$(mk_scratch)
: > "$t/package.json"
got=$("$DETECT" "$t")
assert_eq "typescript" "$got" "package.json alone → typescript (CRA/Webpack-shaped repos accepted)"

t=$(mk_scratch)
: > "$t/Package.swift"
got=$("$DETECT" "$t")
assert_eq "swift" "$got" "Package.swift → swift"

t=$(mk_scratch)
: > "$t/go.mod"
got=$("$DETECT" "$t")
assert_eq "go" "$got" "go.mod → go"

t=$(mk_scratch)
: > "$t/pyproject.toml"
got=$("$DETECT" "$t")
assert_eq "python" "$got" "pyproject.toml → python"

t=$(mk_scratch)
: > "$t/setup.py"
got=$("$DETECT" "$t")
assert_eq "python" "$got" "setup.py → python"

t=$(mk_scratch)
: > "$t/Cargo.toml"
got=$("$DETECT" "$t")
assert_eq "rust" "$got" "Cargo.toml → rust"

echo "=== detect-languages.sh — polyglot detection ==="

# Polyglot output order is fixed: typescript, swift, go, python, rust.
# Downstream cache keys and metadata depend on stable ordering, so the
# order is not derived from the order of detection but from a fixed
# priority list.

t=$(mk_scratch)
: > "$t/tsconfig.json"
: > "$t/Package.swift"
got=$("$DETECT" "$t")
assert_eq "typescript,swift" "$got" "TS + Swift → typescript,swift (TS first)"

t=$(mk_scratch)
: > "$t/Package.swift"
: > "$t/tsconfig.json"
got=$("$DETECT" "$t")
assert_eq "typescript,swift" "$got" "Order of file creation doesn't affect output (TS first)"

t=$(mk_scratch)
: > "$t/tsconfig.json"
: > "$t/go.mod"
: > "$t/pyproject.toml"
got=$("$DETECT" "$t")
assert_eq "typescript,go,python" "$got" "TS + Go + Python → typescript,go,python"

t=$(mk_scratch)
: > "$t/tsconfig.json"
: > "$t/Package.swift"
: > "$t/go.mod"
: > "$t/pyproject.toml"
: > "$t/Cargo.toml"
got=$("$DETECT" "$t")
assert_eq "typescript,swift,go,python,rust" "$got" "All 5 languages → full ordered list"

echo "=== detect-languages.sh — TypeScript marker disjunction ==="

# tsconfig.json AND package.json both present → still one "typescript"
# entry, not two. Dedup is silent.

t=$(mk_scratch)
: > "$t/tsconfig.json"
: > "$t/package.json"
got=$("$DETECT" "$t")
assert_eq "typescript" "$got" "tsconfig.json + package.json → typescript (deduped, not 'typescript,typescript')"

echo "=== detect-languages.sh — Python marker disjunction ==="

# pyproject.toml AND setup.py both present → one "python".

t=$(mk_scratch)
: > "$t/pyproject.toml"
: > "$t/setup.py"
got=$("$DETECT" "$t")
assert_eq "python" "$got" "pyproject.toml + setup.py → python (deduped)"

echo "=== detect-languages.sh — empty / no-markers case ==="

t=$(mk_scratch)
got=$("$DETECT" "$t")
assert_eq "" "$got" "Empty dir → empty stdout (no markers found)"
"$DETECT" "$t" >/dev/null
assert_rc 0 $? "Empty dir exit code is 0 (informational, not an error)"

echo "=== detect-languages.sh — path with spaces ==="

t=$(mk_scratch)
mkdir -p "$t/dir with spaces"
: > "$t/dir with spaces/Package.swift"
got=$("$DETECT" "$t/dir with spaces")
assert_eq "swift" "$got" "Path containing spaces is handled (quoted internally)"

echo "=== detect-languages.sh — usage / missing argument ==="

set +e
"$DETECT" 2>/dev/null
rc=$?
set -e
# Either we default to '.', or we exit non-zero. The script must NOT crash.
if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
  PASS=$((PASS + 1))
  echo "  ✓ No-argument invocation exits cleanly (rc=$rc)"
else
  FAIL=$((FAIL + 1))
  echo "  ✗ No-argument invocation should default-to-cwd or refuse, got rc=$rc"
fi

set +e
"$DETECT" /nonexistent/path/that/does/not/exist 2>/dev/null
rc=$?
set -e
assert_rc 2 "$rc" "Nonexistent root path exits 2 (refuses, doesn't crash)"

echo "=== detect-languages.sh — only matches at exact root ==="

# A marker file deep inside the tree is NOT a marker. Only the root counts.
t=$(mk_scratch)
mkdir -p "$t/subdir"
: > "$t/subdir/Package.swift"
got=$("$DETECT" "$t")
assert_eq "" "$got" "Package.swift in subdir is not a root marker"

echo "=== detect-languages.sh — --extractors-dir allowlist ==="

# Without --extractors-dir, every detected language is emitted (legacy
# behavior). With --extractors-dir pointing at the real extractors/ tree,
# only typescript / swift survive because no go / python / rust manifests
# exist.

t=$(mk_scratch)
: > "$t/go.mod"
got_unfiltered=$("$DETECT" "$t")
got_filtered=$("$DETECT" "$t" --extractors-dir "$EXTRACTORS_DIR")
assert_eq "go" "$got_unfiltered" "no --extractors-dir flag → 'go' detected (legacy unfiltered behavior)"
assert_eq "" "$got_filtered" "with real --extractors-dir → 'go' dropped (no extractors/go/manifest.toml)"

t=$(mk_scratch)
: > "$t/tsconfig.json"
: > "$t/Package.swift"
: > "$t/go.mod"
: > "$t/Cargo.toml"
got=$("$DETECT" "$t" --extractors-dir "$EXTRACTORS_DIR")
assert_eq "typescript,swift" "$got" "polyglot repo filtered to languages with manifest.toml present"

# A synthetic extractors-dir containing only python proves that the allowlist
# is checked per-language and adds 'python' once a manifest appears.
t=$(mk_scratch)
: > "$t/pyproject.toml"
: > "$t/go.mod"
fake_xdir=$(mk_scratch)
mkdir -p "$fake_xdir/python"
: > "$fake_xdir/python/manifest.toml"
got=$("$DETECT" "$t" --extractors-dir "$fake_xdir")
assert_eq "python" "$got" "synthetic --extractors-dir with only python manifest → python only (go dropped)"

# Unknown flag is refused (exit 2), not silently ignored.
set +e
"$DETECT" "$t" --no-such-flag 2>/dev/null
rc=$?
set -e
assert_rc 2 "$rc" "Unknown flag → exit 2"

# Extra positional arg is refused.
set +e
"$DETECT" "$t" extra-arg 2>/dev/null
rc=$?
set -e
assert_rc 2 "$rc" "Extra positional argument → exit 2"

# ---------------------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
