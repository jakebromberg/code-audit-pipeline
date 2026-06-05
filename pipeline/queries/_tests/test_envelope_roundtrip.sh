#!/usr/bin/env bash
# Tests for the schema 1.1+ envelope round-trip stability KPI from #141.
#
# A pre-1.1 bare array wrapped into a 1.1 envelope and then unwrapped via
# `.entries` must be byte-identical to the input. Confirms the envelope
# adds no information beyond the wrapper itself.
#
# Run from repo root: pipeline/queries/_tests/test_envelope_roundtrip.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

assert_files_equal() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if diff -q "$expected" "$actual" >/dev/null; then
    PASS=$((PASS + 1))
    printf "  ok %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL %s\n" "$desc"
    diff -u "$expected" "$actual" | head -20 | sed 's/^/    /'
  fi
}

echo "=== envelope round-trip stability ==="

# Tiny bare-array catalog.
cat > "$TMP/bare.json" <<'EOF'
[
  {"name": "Foo", "kind": "interface", "package": "main", "file": "src/foo.ts", "line": 10},
  {"name": "Bar", "kind": "interface", "package": "main", "file": "src/bar.ts", "line": 7}
]
EOF

# Wrap: bare array → 1.1 envelope with schema_version + entries.
jq '{schema_version: "1.1", entries: .}' "$TMP/bare.json" > "$TMP/wrapped.json"

# Unwrap: pull entries back out.
jq '.entries' "$TMP/wrapped.json" > "$TMP/unwrapped.json"

# Both should be byte-identical when re-pretty-printed through jq with same
# formatting. jq normalizes whitespace and trailing newline so the comparison
# is robust.
jq '.' "$TMP/bare.json" > "$TMP/bare.norm.json"
jq '.' "$TMP/unwrapped.json" > "$TMP/unwrapped.norm.json"

assert_files_equal \
  "bare → wrap → unwrap is byte-identical (modulo jq pretty-print)" \
  "$TMP/bare.norm.json" "$TMP/unwrapped.norm.json"

# Also for 1.2 envelopes (with fingerprint_v + generated_at + extractor metadata):
# the round trip via .entries still drops only the envelope metadata.
cat > "$TMP/wrapped12.json" <<'EOF'
{
  "schema_version": "1.2",
  "extractor": {"language": "typescript", "name": "type-catalog", "version": "0.4.0", "source_sha": "abcdef0123456789abcdef0123456789abcdef01"},
  "fingerprint_v": "shape_sig:1",
  "generated_at": "2026-06-04T19:00:00Z",
  "entries": [
    {"name": "Foo", "kind": "interface", "package": "main", "file": "src/foo.ts", "line": 10}
  ]
}
EOF

jq '.entries' "$TMP/wrapped12.json" > "$TMP/unwrapped12.json"
cat > "$TMP/expected12.json" <<'EOF'
[
  {"name": "Foo", "kind": "interface", "package": "main", "file": "src/foo.ts", "line": 10}
]
EOF
jq '.' "$TMP/expected12.json" > "$TMP/expected12.norm.json"
jq '.' "$TMP/unwrapped12.json" > "$TMP/unwrapped12.norm.json"

assert_files_equal \
  "1.2 envelope → .entries returns the bare entries array unchanged" \
  "$TMP/expected12.norm.json" "$TMP/unwrapped12.norm.json"

echo
echo "=== summary ==="
printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then exit 1; fi
exit 0
