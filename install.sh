#!/usr/bin/env bash
# install.sh — build and install the code-audit binary from this checkout.
#
# What it does, in order:
#   1. Regenerates the embedded query/extractor trees from their canonical
#      sources (`go generate ./...`), so the installed binary always embeds
#      what this checkout's extractors/ and pipeline/queries/ actually
#      contain — not whatever was last committed under cmd/code-audit/.
#      This rewrites the TRACKED trees under cmd/code-audit/{queries,
#      extractors}/ in place; on a clean checkout the rewrite is
#      byte-identical.
#   2. Stamps internal/cli.Version with `git describe --tags --always` from
#      THIS checkout, appending -dirty when `git status --porcelain`
#      reports anything. Porcelain counts untracked files, which `git
#      describe --dirty` ignores even though step 1 happily embeds them.
#      The Go toolchain's own VCS stamp locates the repo by looking for a
#      .git directory, so a build inside a linked worktree (whose .git is
#      a file) gets attributed to the parent checkout's HEAD; git
#      describe, run here, sees the worktree's true state.
#   3. `go install ./cmd/code-audit`, then verifies the binary landed and
#      warns if its directory is not on PATH.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [--no-generate] [-h|--help]

  --no-generate   Skip the go-generate step and install the embed trees
                  currently on disk, without regenerating them from the
                  canonical sources.
  -h, --help      Show this help and exit.
EOF
}

GENERATE=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-generate) GENERATE=0 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "code-audit install: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

if ! command -v go >/dev/null 2>&1; then
  echo "code-audit install: no Go toolchain on PATH. Install Go 1.24+ (https://go.dev/dl) and re-run." >&2
  exit 1
fi

if [ "$GENERATE" -eq 1 ]; then
  echo "code-audit install: regenerating embedded queries + extractors from canonical sources"
  go generate ./...
fi

# Trust git describe only when this checkout is itself the top of a git
# repo. Without the toplevel check, a non-git checkout (release-tarball
# extract) nested anywhere under a git-tracked tree would inherit the
# ENCLOSING repo's describe output — a plausible-looking foreign version.
STAMP=""
if [ "$(git rev-parse --show-toplevel 2>/dev/null || true)" = "$(pwd -P)" ]; then
  STAMP="$(git describe --tags --always 2>/dev/null || true)"
  if [ -n "$STAMP" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    STAMP="${STAMP}-dirty"
  fi
fi
if [ -z "$STAMP" ]; then
  STAMP="unknown"
fi

MODULE="$(go list -m)"
echo "code-audit install: building ${STAMP}"
go install -ldflags "-X ${MODULE}/internal/cli.Version=${STAMP}" ./cmd/code-audit

BIN_DIR="$(go env GOBIN)"
CROSS=0
if [ -z "$BIN_DIR" ]; then
  # `go env GOPATH` returns the full colon-separated list for a
  # multi-element GOPATH; `go install` writes to the FIRST element's bin.
  BIN_DIR="$(go env GOPATH)"
  BIN_DIR="${BIN_DIR%%:*}/bin"
  # With GOBIN unset, cross-compiled binaries land in a per-platform
  # subdir. (With GOBIN set, `go install` refuses cross-compilation
  # outright and set -e has already stopped the script.)
  TARGET_OS="$(go env GOOS)"
  TARGET_ARCH="$(go env GOARCH)"
  if [ "$TARGET_OS" != "$(go env GOHOSTOS)" ] || [ "$TARGET_ARCH" != "$(go env GOHOSTARCH)" ]; then
    CROSS=1
    BIN_DIR="${BIN_DIR}/${TARGET_OS}_${TARGET_ARCH}"
  fi
fi
BIN="$BIN_DIR/code-audit"

if [ ! -x "$BIN" ]; then
  echo "code-audit install: expected binary at $BIN but it is missing" >&2
  exit 1
fi

echo "code-audit install: installed $BIN"
if [ "$CROSS" -eq 1 ]; then
  echo "code-audit install: cross-compiled for ${TARGET_OS}/${TARGET_ARCH}; skipping version check"
else
  # Assignment, not interpolation inside echo: a broken binary must fail
  # the install under set -e instead of being masked by echo's exit 0.
  VERSION_OUT="$("$BIN" version)"
  echo "code-audit install: version ${VERSION_OUT}"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "code-audit install: warning: $BIN_DIR is not on PATH — add it to your shell profile" >&2
    ;;
esac
