#!/usr/bin/env bash
# detect-languages.sh — emit a stable, deduped, ordered comma-separated list
# of languages detected at <root> via marker files.
#
# Usage: detect-languages.sh <repo-root>
#
# Stdout: zero-or-more languages from the priority list, joined by ",". Empty
#         output is a valid result (no markers found) and exits 0 —
#         informational only; the caller decides whether to fail or proceed
#         with the polyglot file-hashes extractor alone.
#
# Stderr: one diagnostic line on usage error; quiet otherwise.
#
# Exit:
#   0  any case where <root> is a real directory (zero-or-more languages emitted)
#   2  <root> missing or not a directory
#
# Priority order (the order languages appear in the output):
#   typescript, swift, go, python, rust
#
# Output is deduped across multi-marker languages (e.g. typescript triggers
# on either tsconfig.json or package.json, but a repo with both still emits
# "typescript" once). Order is from this priority list, not from filesystem
# walk order — so the same repo always produces the same string regardless
# of the underlying filesystem's directory-entry ordering.

set -Eeuo pipefail

if [ "$#" -lt 1 ]; then
  echo "detect-languages.sh: missing required argument <root>" >&2
  echo "usage: detect-languages.sh <repo-root>" >&2
  exit 2
fi

root="$1"

if [ ! -d "$root" ]; then
  echo "detect-languages.sh: not a directory: $root" >&2
  exit 2
fi

# Single-file existence test, scoped to the *root* — markers nested in
# subdirectories don't count. (A repo's marker files always live at the
# top level; deep matches catch monorepo subprojects we don't want to
# treat as the dominant language of the outer repo.)
has() {
  [ -f "$root/$1" ]
}

emit=()

# Priority order is hard-coded below — do not derive from filesystem walks.
# Each `has X || has Y` is short-circuited; the language is added once even
# if both markers are present.
if has tsconfig.json || has package.json; then
  emit+=("typescript")
fi
if has Package.swift; then
  emit+=("swift")
fi
if has go.mod; then
  emit+=("go")
fi
if has pyproject.toml || has setup.py; then
  emit+=("python")
fi
if has Cargo.toml; then
  emit+=("rust")
fi

# Empty result is valid output; print an empty line is *not* what we want
# (would print "\n" and the caller's $(...) would have a single newline).
# Print only when non-empty.
if [ "${#emit[@]}" -gt 0 ]; then
  (IFS=,; printf '%s\n' "${emit[*]}")
fi
