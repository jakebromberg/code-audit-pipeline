#!/usr/bin/env bash
# Tests for install.sh — the from-source build-and-install script at the
# repo root.
#
# Covers flag handling, installation into $GOBIN, the truthful version
# stamp (git describe of *this* checkout — the property that motivated the
# script: the Go toolchain's own VCS stamp resolves to the parent repo when
# building inside a linked worktree), and the friendly failure when no Go
# toolchain is on PATH.
#
# Each install test targets a scratch $GOBIN so the developer's real
# GOBIN/GOPATH bin is never touched. Temp dirs are torn down by a trap.
#
# Run:  bash pipeline/_tests/test_install.sh

set -u

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/../.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

PASS=0
FAIL=0
SCRATCH_DIRS=()

cleanup() {
  for d in "${SCRATCH_DIRS[@]+"${SCRATCH_DIRS[@]}"}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

# Sets $SCRATCH to a fresh temp dir and registers it for the cleanup trap.
# Deliberately NOT invoked via command substitution: $(mk_scratch) would run
# in a subshell, the SCRATCH_DIRS+= registration would be discarded, and the
# trap would tear down nothing.
mk_scratch() {
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/install-test-XXXXXX")
  SCRATCH_DIRS+=("$SCRATCH")
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

assert_contains() {
  case "$2" in
    *"$1"*)
      PASS=$((PASS + 1))
      echo "  ✓ $3"
      ;;
    *)
      FAIL=$((FAIL + 1))
      echo "  ✗ $3"
      echo "      needle: '$1'"
      echo "      haystack: '$2'"
      ;;
  esac
}

# ---------------------------------------------------------------------------

if [ ! -x "$INSTALL" ]; then
  echo "FATAL: $INSTALL not executable (run: chmod +x $INSTALL)" >&2
  exit 2
fi

echo "=== install.sh — flag handling ==="

set +e
out=$("$INSTALL" --help 2>&1)
rc=$?
set -e
assert_rc 0 "$rc" "--help → exit 0"
assert_contains "Usage" "$out" "--help prints usage"

set +e
out=$("$INSTALL" --no-such-flag 2>&1)
rc=$?
set -e
assert_rc 2 "$rc" "unknown flag → exit 2"
assert_contains "Usage" "$out" "unknown flag prints usage"

echo "=== install.sh — install into \$GOBIN ==="

mk_scratch
t="$SCRATCH"
set +e
out=$(GOBIN="$t/bin" "$INSTALL" 2>&1)
rc=$?
set -e
assert_rc 0 "$rc" "default install → exit 0"
if [ -x "$t/bin/code-audit" ]; then
  PASS=$((PASS + 1))
  echo "  ✓ binary installed at \$GOBIN/code-audit"
else
  FAIL=$((FAIL + 1))
  echo "  ✗ binary missing at $t/bin/code-audit"
  echo "      install output: $out"
fi

echo "=== install.sh — truthful version stamp ==="

# The stamp must reflect THIS checkout (git describe), not whatever the Go
# toolchain's VCS detection resolves to — inside a linked worktree those
# differ. Expected value is computed after the install so both sides see
# the same tree state.
expected=$(cd "$REPO_ROOT" && git describe --tags --always --dirty)
got=$("$t/bin/code-audit" version | tr -d '[:space:]')
assert_eq "$expected" "$got" "installed binary reports git describe of this checkout"

echo "=== install.sh — --no-generate fast path ==="

mk_scratch
t2="$SCRATCH"
set +e
GOBIN="$t2/bin" "$INSTALL" --no-generate >/dev/null 2>&1
rc=$?
set -e
assert_rc 0 "$rc" "--no-generate install → exit 0"

echo "=== install.sh — missing Go toolchain ==="

# Shim PATH with only dirname (the sole external the script needs before
# its Go preflight) so `command -v go` fails deterministically on both
# macOS and Linux runners regardless of where their real go lives.
mk_scratch
shim="$SCRATCH"
ln -s "$(command -v dirname)" "$shim/dirname"
set +e
out=$(PATH="$shim" /bin/bash "$INSTALL" 2>&1)
rc=$?
set -e
assert_rc 1 "$rc" "no go on PATH → exit 1"
assert_contains "Go" "$out" "missing-go error mentions Go"

# ---------------------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
