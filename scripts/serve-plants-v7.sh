#!/usr/bin/env bash
#
# serve-plants-v7.sh — assemble the V7 audit tree under TARGET.
#
# Copies the wxyc-ios-64 first-party source over, then overlays the planted
# `_Plant_*.swift` files from `examples/swift-plants-v7/`. Scrubs git history,
# IDE/agent state, and build artifacts so the served tree is a flat non-git
# directory per methodology §10 contamination-vectors mitigation. Chmod-locks
# read-only so a stray `rm -rf` or careless edit doesn't perturb the audit.
#
# Inputs (env overrides):
#   WXYC_ROOT   absolute path to wxyc-ios-64 checkout
#               default: /Users/jake/Developer/WXYC/wxyc-ios-64
#   PLANT_TREE  absolute path to the V7 plant overlay
#               default: <repo>/examples/swift-plants-v7
#   TARGET      where to assemble the served tree
#               default: /tmp/wxyc-audit/plants-v7
#
# Idempotent: rerunning overwrites the previous TARGET. Read-only files from
# a prior run are made writable first so removal succeeds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WXYC_ROOT="${WXYC_ROOT:-/Users/jake/Developer/WXYC/wxyc-ios-64}"
PLANT_TREE="${PLANT_TREE:-$REPO_ROOT/examples/swift-plants-v7}"
TARGET="${TARGET:-/tmp/wxyc-audit/plants-v7}"

# --- Validate inputs -------------------------------------------------------

if [[ ! -d "$WXYC_ROOT" ]]; then
  echo "ERROR: WXYC_ROOT not found: $WXYC_ROOT" >&2
  exit 1
fi

if [[ ! -d "$PLANT_TREE" ]]; then
  echo "ERROR: PLANT_TREE not found: $PLANT_TREE" >&2
  exit 1
fi

# Submodule sanity. Wallpaper (and any other submodule) must be initialized;
# otherwise Wallpaper-package plants are unreachable in the audit tree and
# category recall under-reports. We don't fail here — the submodule may be
# absent intentionally on some hosts — but we warn loudly enough that an
# operator who's missing init runs sees it.
if [[ -f "$WXYC_ROOT/.gitmodules" ]]; then
  while IFS= read -r submodule_path; do
    if [[ ! -d "$WXYC_ROOT/$submodule_path" || -z "$(ls -A "$WXYC_ROOT/$submodule_path" 2>/dev/null)" ]]; then
      echo "WARNING: submodule '$submodule_path' looks uninitialized at $WXYC_ROOT/$submodule_path" >&2
      echo "         Run: git -C \"$WXYC_ROOT\" submodule update --init --recursive" >&2
    fi
  done < <(awk -F' = ' '/^[[:space:]]*path[[:space:]]*=/ {print $2}' "$WXYC_ROOT/.gitmodules")
fi

# --- Clean target ----------------------------------------------------------

if [[ -e "$TARGET" ]]; then
  chmod -R u+w "$TARGET" 2>/dev/null || true
  rm -rf "$TARGET"
fi
mkdir -p "$TARGET"

# --- Copy source repo, scrubbing git/IDE/build/agent state ----------------
#
# Excludes:
#   .git/           — git history (the §10 git-tooling leak)
#   .gitignore      — could leak path patterns specific to the planted state
#   .gitmodules     — same
#   .github/        — CI/workflow metadata not relevant to substrate
#   .claude/        — agent-state worktrees with duplicate Swift files
#   .build/         — SwiftPM build artifacts (binaries, .o files)
#   .swiftpm/       — SwiftPM workspace state
#   DerivedData/    — Xcode derived data
#   *.xcuserdata    — per-user IDE state
#   .DS_Store       — macOS Finder cruft
#   node_modules/   — JS package state if any helper script pulled deps
#   .home/          — local fixture root present in wxyc-ios-64
#   .periphery.yml  — Periphery config; not load-bearing for the substrate
#   .sentryclirc    — Sentry CLI config
#   .swift-version  — toolchain pin marker; not source
#   worklog         — symlink out to user's worklog dir; not source
#
# rsync's `-a` preserves symlinks (doesn't follow), so any in-tree symlinks
# remain as symlinks, which is fine — the SwiftSyntax walker skips them.

rsync -a \
  --exclude='.git' \
  --exclude='.gitignore' \
  --exclude='.gitmodules' \
  --exclude='.github' \
  --exclude='.claude' \
  --exclude='.build' \
  --exclude='.swiftpm' \
  --exclude='DerivedData' \
  --exclude='*.xcuserdata' \
  --exclude='.DS_Store' \
  --exclude='node_modules' \
  --exclude='.home' \
  --exclude='.periphery.yml' \
  --exclude='.sentryclirc' \
  --exclude='.swift-version' \
  --exclude='worklog' \
  "$WXYC_ROOT/" "$TARGET/"

# --- Overlay plant files ---------------------------------------------------
#
# rsync without --delete: plants land on top of any pre-existing files at the
# same path. None should collide in practice — plant filenames carry the
# `_Plant_` prefix — but the overlay semantics is what plan §4.2 specifies.

rsync -a "$PLANT_TREE/" "$TARGET/"

# --- Acceptance sanity: no plant-comment leaks -----------------------------

if grep -rlE '// Plant|# Plant|// PLANT|# PLANT' "$TARGET" 2>/dev/null | head -1 | grep -q .; then
  echo "ERROR: plant-comment leak detected in served tree" >&2
  echo "       Files with leaked comments:" >&2
  grep -rlE '// Plant|# Plant|// PLANT|# PLANT' "$TARGET" >&2
  exit 1
fi

# --- Read-only lockdown ----------------------------------------------------

chmod -R a-w "$TARGET"

# --- Summary ---------------------------------------------------------------

swift_count="$(find "$TARGET" -name '*.swift' -type f | wc -l | tr -d ' ')"
plant_count="$(find "$TARGET" -name '_Plant_*.swift' -type f | wc -l | tr -d ' ')"

echo "Served plant tree → $TARGET"
echo "  source repo:  $WXYC_ROOT"
echo "  plant tree:   $PLANT_TREE"
echo "  swift files:  $swift_count total"
echo "  plant files:  $plant_count overlaid"
