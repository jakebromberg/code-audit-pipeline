#!/usr/bin/env bash
# Bash shim for the Phase D harness unit tests. The test logic lives in
# test_phase_d_harness.py — this script exists so the test suite stays
# uniform across bash and python conventions.
#
# Run from repo root: pipeline/queries/_tests/test_phase_d_harness.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

cd "$REPO_ROOT"
exec python3 "$SCRIPT_DIR/test_phase_d_harness.py" "$@"
