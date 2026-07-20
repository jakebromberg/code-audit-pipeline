#!/usr/bin/env bash
# install.sh — build and install the code-audit binary from this checkout.
#
# What it does, in order:
#   1. Regenerates the embedded query/extractor trees from their canonical
#      sources (`go generate ./...`), so the installed binary always embeds
#      what this checkout's extractors/ and pipeline/queries/ actually
#      contain — not whatever was last committed under cmd/code-audit/.
#   2. Stamps internal/cli.Version with `git describe --tags --always
#      --dirty` from THIS checkout. The Go toolchain's own VCS stamp locates
#      the repo by looking for a .git directory, so a build inside a linked
#      worktree (whose .git is a file) gets attributed to the parent
#      checkout's HEAD and marked dirty by its untracked files. git
#      describe, run here, sees the worktree's true state.
#   3. `go install ./cmd/code-audit` into $GOBIN (or $GOPATH/bin), then
#      verifies the binary landed and warns if that directory is not on
#      PATH.
#
# Usage: ./install.sh [--no-generate] [-h|--help]
#
#   --no-generate   Skip step 1 and install with the committed embed trees
#                   as-is (what a release build of this commit would embed).

set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/as-is/s/^#[ ]\{0,1\}//p' "${BASH_SOURCE[0]}"
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

STAMP="$(git describe --tags --always --dirty 2>/dev/null || true)"
if [ -z "$STAMP" ]; then
  STAMP="unknown"
fi

echo "code-audit install: building ${STAMP}"
go install -ldflags "-X github.com/jakebromberg/code-audit-pipeline/internal/cli.Version=${STAMP}" ./cmd/code-audit

BIN_DIR="$(go env GOBIN)"
if [ -z "$BIN_DIR" ]; then
  BIN_DIR="$(go env GOPATH)/bin"
fi
BIN="$BIN_DIR/code-audit"

if [ ! -x "$BIN" ]; then
  echo "code-audit install: expected binary at $BIN but it is missing" >&2
  exit 1
fi

echo "code-audit install: installed $BIN"
echo "code-audit install: version $("$BIN" version)"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "code-audit install: warning: $BIN_DIR is not on PATH — add it to your shell profile" >&2
    ;;
esac
