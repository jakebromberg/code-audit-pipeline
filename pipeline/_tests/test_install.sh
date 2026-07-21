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
# Isolation: every install targets a scratch $GOBIN, and installs run with
# --no-generate so the suite never rewrites this checkout's embed trees.
# The one default-mode (generate) test is guarded — it runs only when the
# embed-relevant paths are clean, because `go generate ./...` rewrites the
# tracked trees under cmd/code-audit/ in place. CI checkouts are always
# clean, so CI always exercises the default path.
#
# errexit is deliberate: infrastructure failures (mktemp, ln) abort the
# suite immediately, while test assertions are counted and summarized.
# Commands that may legitimately fail are individually guarded.
#
# Run:  bash pipeline/_tests/test_install.sh

set -euo pipefail

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
trap cleanup EXIT
# Clean up, then RE-RAISE: a bare `trap cleanup INT` handler returns and
# bash resumes the suite — against scratch dirs the handler just deleted.
trap 'cleanup; trap - INT; kill -INT $$' INT
trap 'cleanup; trap - TERM; kill -TERM $$' TERM

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

assert_not_contains() {
  case "$2" in
    *"$1"*)
      FAIL=$((FAIL + 1))
      echo "  ✗ $3"
      echo "      must not contain: '$1'"
      echo "      haystack: '$2'"
      ;;
    *)
      PASS=$((PASS + 1))
      echo "  ✓ $3"
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
assert_contains "no-generate" "$out" "--help documents --no-generate"

set +e
out=$("$INSTALL" --no-such-flag 2>&1)
rc=$?
set -e
assert_rc 2 "$rc" "unknown flag → exit 2"
assert_contains "Usage" "$out" "unknown flag prints usage"

echo "=== install.sh — install into \$GOBIN (--no-generate) ==="

mk_scratch
t="$SCRATCH"
set +e
out=$(GOBIN="$t/bin" "$INSTALL" --no-generate 2>&1)
rc=$?
set -e
assert_rc 0 "$rc" "--no-generate install → exit 0"
assert_not_contains "regenerating" "$out" "--no-generate skips embed regeneration"
if [ -x "$t/bin/code-audit" ]; then
  PASS=$((PASS + 1))
  echo "  ✓ binary installed at \$GOBIN/code-audit"
else
  FAIL=$((FAIL + 1))
  echo "  ✗ binary missing at $t/bin/code-audit"
  echo "      install output: $out"
fi

echo "=== install.sh — truthful version stamp ==="

# Mirror install.sh's stamp logic exactly: trust describe only when
# REPO_ROOT is itself a git toplevel, and append -dirty when porcelain
# reports anything (untracked files count — `git describe --dirty` would
# miss them). Every git call is guarded so a non-git tree lands on the
# same "unknown" fallback install.sh uses instead of aborting the suite
# under set -e.
if [ "$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || true)" = "$(cd "$REPO_ROOT" && pwd -P)" ]; then
  expected=$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || echo unknown)
  if [ "$expected" != "unknown" ] && [ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]; then
    expected="${expected}-dirty"
  fi
else
  expected="unknown"
fi
set +e
got=$("$t/bin/code-audit" version 2>&1 | tr -d '[:space:]')
rc=$?
set -e
assert_rc 0 "$rc" "installed binary runs (version → exit 0)"
assert_eq "$expected" "$got" "installed binary reports git describe of this checkout"

echo "=== install.sh — default install regenerates embeds ==="

# Default mode runs `go generate ./...` against THIS checkout, rewriting
# the tracked embed trees (byte-identical only when canonical sources and
# embeds are in sync). Run it only when the relevant paths are clean so
# the suite never rewrites uncommitted work.
embed_status=$(git -C "$REPO_ROOT" status --porcelain -- pipeline/queries extractors cmd/code-audit internal/genembed 2>/dev/null || true)
if [ -n "$embed_status" ]; then
  echo "  - skipped: embed-relevant paths have local changes; a default-mode install would rewrite them"
else
  mk_scratch
  t2="$SCRATCH"
  set +e
  out=$(GOBIN="$t2/bin" "$INSTALL" 2>&1)
  rc=$?
  set -e
  assert_rc 0 "$rc" "default install → exit 0"
  assert_contains "regenerating" "$out" "default install announces embed regeneration"
  if [ -x "$t2/bin/code-audit" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ binary installed at \$GOBIN/code-audit"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ binary missing at $t2/bin/code-audit"
    echo "      install output: $out"
  fi
fi

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
