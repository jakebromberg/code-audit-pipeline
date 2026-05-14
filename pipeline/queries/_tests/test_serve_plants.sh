#!/usr/bin/env bash
# Smoke test for scripts/serve-plants-v7.sh.
#
# Constructs a synthetic source-repo + plant-tree pair under a temp dir, runs
# the serving script with overrides pointing at the synthetic inputs, and
# asserts the served tree's invariants per plan §4.2:
#
#   - First-party Swift files copied from the source repo
#   - Plant files overlaid at the manifest-derived paths
#   - .git/ and other dot-state scrubbed (so git status fails)
#   - No `// Plant` / `# Plant` comment leaks
#   - Result chmod-locked read-only
#
# Run from repo root: pipeline/queries/_tests/test_serve_plants.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SERVE_SCRIPT="$REPO_ROOT/scripts/serve-plants-v7.sh"

if [[ ! -x "$SERVE_SCRIPT" ]]; then
  echo "ERROR: serve script not executable at $SERVE_SCRIPT" >&2
  exit 1
fi

WORK="$(mktemp -d)"
# chmod on cleanup — the script chmod-locks the served tree read-only, which
# means `rm -rf` needs the writable bit restored before deletion.
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# --- Synthesize source-repo fixture --------------------------------------
# Looks like a small wxyc-ios-64: a few first-party Swift files plus a
# .git/, .claude/worktrees/, .build/ tree that must NOT propagate.

SRC="$WORK/fake-wxyc-ios"
mkdir -p "$SRC/Shared/Caching/Sources/Caching" \
         "$SRC/Shared/Wallpaper/Sources/Wallpaper/Core" \
         "$SRC/Shared/Playlist/Sources/Playlist" \
         "$SRC/WXYC/iOS" \
         "$SRC/.git/refs" \
         "$SRC/.claude/worktrees/agent-xyz/Shared/Caching/Sources/Caching" \
         "$SRC/.build/x86_64-apple-macosx/release"

echo "public struct Cache {}" > "$SRC/Shared/Caching/Sources/Caching/Cache.swift"
echo "public enum BlendMode {}" > "$SRC/Shared/Wallpaper/Sources/Wallpaper/Core/BlendMode.swift"
echo "public protocol PlaylistEntry {}" > "$SRC/Shared/Playlist/Sources/Playlist/PlaylistEntry.swift"
echo "// iOS app entry" > "$SRC/WXYC/iOS/AppMain.swift"
# Dot-state files that must NOT be copied.
echo "ref: refs/heads/main" > "$SRC/.git/HEAD"
echo "DerivedData/" > "$SRC/.gitignore"
# A worktree clone duplicate that would inflate the served tree if not skipped.
echo "public struct Cache {}" > "$SRC/.claude/worktrees/agent-xyz/Shared/Caching/Sources/Caching/Cache.swift"
echo "BIN" > "$SRC/.build/x86_64-apple-macosx/release/swift-catalog"

# --- Synthesize plant tree fixture ---------------------------------------
PLANTS="$WORK/fake-plant-tree"
mkdir -p "$PLANTS/Shared/Caching/Sources/Caching"
cat > "$PLANTS/Shared/Caching/Sources/Caching/_Plant_IntCache.swift" <<'PLANT'
public struct IntCache: Sendable {
    public init() {}
}
PLANT

# --- Synthesize target -----------------------------------------------------
TARGET="$WORK/served"

# --- Run the serving script -----------------------------------------------
WXYC_ROOT="$SRC" PLANT_TREE="$PLANTS" TARGET="$TARGET" "$SERVE_SCRIPT" \
  2>"$WORK/serve.stderr" \
  || { cat "$WORK/serve.stderr" >&2; echo "ERROR: serve-plants-v7.sh exited non-zero" >&2; exit 1; }

PASS=0
FAIL=0
assert_eq() {
  local desc="$1"; local expected="$2"; local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s\n     expected: %s\n     actual:   %s\n" "$desc" "$expected" "$actual"
  fi
}
assert_file_exists() {
  local desc="$1"; local path="$2"
  if [[ -e "$path" ]]; then
    PASS=$((PASS + 1)); printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1)); printf "  ✗ %s\n     missing: %s\n" "$desc" "$path"
  fi
}
assert_file_absent() {
  local desc="$1"; local path="$2"
  if [[ ! -e "$path" ]]; then
    PASS=$((PASS + 1)); printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1)); printf "  ✗ %s\n     unexpected present: %s\n" "$desc" "$path"
  fi
}

echo "=== Target tree exists and contains real source ==="
assert_file_exists "target directory created" "$TARGET"
assert_file_exists "first-party Swift file copied (Caching)" \
  "$TARGET/Shared/Caching/Sources/Caching/Cache.swift"
assert_file_exists "first-party Swift file copied (Wallpaper)" \
  "$TARGET/Shared/Wallpaper/Sources/Wallpaper/Core/BlendMode.swift"
assert_file_exists "first-party Swift file copied (Playlist)" \
  "$TARGET/Shared/Playlist/Sources/Playlist/PlaylistEntry.swift"
assert_file_exists "first-party Swift file copied (app:iOS)" \
  "$TARGET/WXYC/iOS/AppMain.swift"

echo ""
echo "=== Plant overlay landed ==="
assert_file_exists "plant file overlaid at manifest path" \
  "$TARGET/Shared/Caching/Sources/Caching/_Plant_IntCache.swift"

echo ""
echo "=== Dot-state scrubbed (§10 contamination) ==="
assert_file_absent ".git/ scrubbed" "$TARGET/.git"
assert_file_absent ".gitignore scrubbed" "$TARGET/.gitignore"
assert_file_absent ".claude/ scrubbed (worktree duplicate)" "$TARGET/.claude"
assert_file_absent ".build/ scrubbed" "$TARGET/.build"

# Confirm git fails. The script `cd`s into the target and runs `git status`.
# Expected behavior: git either complains "not a git repository" or finds a
# parent repo. We assert that `git -C "$TARGET" rev-parse --show-toplevel`
# returns something OUTSIDE the served tree, or fails — either way, the
# served tree itself is not its own repo.
echo ""
echo "=== Served tree is not its own git repository ==="
top="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || echo "(none)")"
if [[ "$top" == "$TARGET" ]]; then
  FAIL=$((FAIL + 1))
  printf "  ✗ served tree IS a git repo (rev-parse returned target itself)\n"
else
  PASS=$((PASS + 1))
  printf "  ✓ served tree is not its own git repo (rev-parse: %s)\n" "$top"
fi

echo ""
echo "=== No plant-comment leaks ==="
# `grep -rlE ... || true` because grep exits 1 on "no match", which `set -e`
# + `pipefail` would otherwise treat as a script-aborting failure.
leak_count=$( { grep -rlE '// Plant|# Plant|// PLANT|# PLANT' "$TARGET" 2>/dev/null || true; } | wc -l | tr -d ' ')
assert_eq "no '// Plant' / '# Plant' / variants in served tree" \
  "0" "$leak_count"

echo ""
echo "=== Read-only lockdown ==="
# At least one served file should be non-writable by the owner.
sample="$TARGET/Shared/Caching/Sources/Caching/Cache.swift"
if [[ -w "$sample" ]]; then
  FAIL=$((FAIL + 1))
  printf "  ✗ sample served file is still writable: %s\n" "$sample"
else
  PASS=$((PASS + 1))
  printf "  ✓ sample served file is read-only: %s\n" "$sample"
fi

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
