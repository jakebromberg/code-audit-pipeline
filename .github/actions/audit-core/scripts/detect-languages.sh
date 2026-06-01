#!/usr/bin/env bash
# detect-languages.sh — emit a stable, deduped, ordered comma-separated list
# of languages detected at <root> via marker files.
#
# Usage: detect-languages.sh <repo-root> [--extractors-dir <dir>]
#
# Stdout: zero-or-more languages from the priority list, joined by ",". Empty
#         output is a valid result (no markers found) and exits 0 —
#         informational only; the caller decides whether to fail or proceed
#         with the polyglot file-hashes extractor alone.
#
# Stderr: one diagnostic line on usage error or unsupported argument; quiet
#         otherwise.
#
# Exit:
#   0  any case where <root> is a real directory (zero-or-more languages emitted)
#   2  <root> missing or not a directory; or unknown flag
#
# Priority order (the order languages appear in the output):
#   typescript, swift, go, python, rust
#
# Output is deduped across multi-marker languages (e.g. typescript triggers
# on either tsconfig.json or package.json, but a repo with both still emits
# "typescript" once). Order is from this priority list, not from filesystem
# walk order — so the same repo always produces the same string regardless
# of the underlying filesystem's directory-entry ordering.
#
# Allowlist: when --extractors-dir is supplied, the output is filtered to
# languages that have a manifest.toml under that directory. This keeps the
# composite's "detect → extract" loop from ever trying to run an extractor
# that does not exist in this checkout — a real concern today because
# detection covers five languages and only three extractors (typescript,
# swift, file-hashes) ship. Without --extractors-dir, no filter is applied
# (backwards-compatible for direct calls in tests and consumer-side
# detection-only jobs).

set -Eeuo pipefail

root=""
extractors_dir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --extractors-dir)
      extractors_dir="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --*)
      echo "detect-languages.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [ -n "$root" ]; then
        echo "detect-languages.sh: extra positional argument: $1" >&2
        exit 2
      fi
      root="$1"
      shift
      ;;
  esac
done

if [ -z "$root" ]; then
  echo "detect-languages.sh: missing required argument <root>" >&2
  echo "usage: detect-languages.sh <repo-root> [--extractors-dir <dir>]" >&2
  exit 2
fi

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

# Allowlist filter — returns 0 iff a manifest exists for <lang> in
# $extractors_dir. When $extractors_dir is empty, the filter is a no-op
# (every language passes), which is the legacy behavior callers without
# the new flag still see.
has_extractor() {
  if [ -z "$extractors_dir" ]; then
    return 0
  fi
  [ -f "$extractors_dir/$1/manifest.toml" ]
}

emit=()

# Priority order is hard-coded below — do not derive from filesystem walks.
# Each `has X || has Y` is short-circuited; the language is added once even
# if both markers are present. The allowlist filter applies on top so that
# detected-but-unsupported languages drop quietly here rather than crashing
# the extract step later.
if { has tsconfig.json || has package.json; } && has_extractor typescript; then
  emit+=("typescript")
fi
if has Package.swift && has_extractor swift; then
  emit+=("swift")
fi
if has go.mod && has_extractor go; then
  emit+=("go")
fi
if { has pyproject.toml || has setup.py; } && has_extractor python; then
  emit+=("python")
fi
if has Cargo.toml && has_extractor rust; then
  emit+=("rust")
fi

# Empty result is valid output; printing an empty line is *not* what we want
# (would print "\n" and the caller's $(...) would have a single newline).
# Print only when non-empty.
if [ "${#emit[@]}" -gt 0 ]; then
  (IFS=,; printf '%s\n' "${emit[*]}")
fi
