#!/usr/bin/env bash
# Tests for pipeline/validate-catalog.mjs — the v1.1/v1.2 catalog validator
# introduced by #141. Verifies acceptance of valid catalogs (wrapped + bare),
# rejection of malformed envelopes, and the symbol_id formula mismatch guard.
#
# Run from repo root: pipeline/queries/_tests/test_validate_catalog.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VALIDATOR="$REPO_ROOT/pipeline/validate-catalog.mjs"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# Compute symbol_id with node's createHash to match the validator's formula.
# NUL-byte joined; see extractors/typescript/type-catalog.mjs::computeSymbolId
# for the rationale and pipeline/validate-catalog.mjs for the reference impl.
symbol_id() {
  local pkg="$1" file="$2" name="$3" kind="$4"
  node -e "const c=require('node:crypto'); const args=process.argv.slice(1); console.log(c.createHash('sha1').update(args.join('\x00')).digest('hex'))" "$pkg" "$file" "$name" "$kind"
}

run_validator() {
  # Captures exit code without -e killing the script.
  set +e
  node "$VALIDATOR" "$@" > "$TMP/out.txt" 2> "$TMP/err.txt"
  local rc=$?
  set -e
  echo "$rc"
}

assert_exit() {
  local desc="$1"
  local expected_rc="$2"
  local actual_rc="$3"
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    PASS=$((PASS + 1))
    printf "  ok %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL %s (expected exit=%s, got %s)\n" "$desc" "$expected_rc" "$actual_rc"
    sed 's/^/    out: /' "$TMP/out.txt"
    sed 's/^/    err: /' "$TMP/err.txt"
  fi
}

assert_stderr_contains() {
  local desc="$1"
  local needle="$2"
  if grep -q -- "$needle" "$TMP/err.txt"; then
    PASS=$((PASS + 1))
    printf "  ok %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL %s (stderr did not contain %q)\n" "$desc" "$needle"
    sed 's/^/    err: /' "$TMP/err.txt"
  fi
}

echo "=== validate-catalog.mjs ==="

# --- valid 1.2 wrapper, no symbol_ids ---
cat > "$TMP/valid12.json" <<'EOF'
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
assert_exit "valid 1.2 catalog" "0" "$(run_validator "$TMP/valid12.json")"

# --- valid 1.1 wrapper (no fingerprint_v / generated_at — they're optional) ---
cat > "$TMP/valid11.json" <<'EOF'
{
  "schema_version": "1.1",
  "extractor": {"language": "typescript", "name": "type-catalog", "version": "0.4.0"},
  "entries": [
    {"name": "Foo", "kind": "interface", "package": "main", "file": "src/foo.ts", "line": 10}
  ]
}
EOF
assert_exit "valid 1.1 catalog (back-compat)" "0" "$(run_validator "$TMP/valid11.json")"

# --- bare-array catalog (pre-1.1) — passes with stderr warning ---
cat > "$TMP/bare.json" <<'EOF'
[
  {"name": "Foo", "kind": "interface", "package": "main", "file": "src/foo.ts", "line": 10}
]
EOF
assert_exit "bare-array catalog accepted" "0" "$(run_validator "$TMP/bare.json")"
assert_stderr_contains "bare-array emits deprecation warning" "pre-1.1 bare-array"

# --- missing schema_version on wrapper ---
cat > "$TMP/no-version.json" <<'EOF'
{"entries": [{"name": "Foo", "kind": "interface", "package": "main", "file": "src/foo.ts", "line": 1}]}
EOF
assert_exit "wrapper missing schema_version is rejected" "1" "$(run_validator "$TMP/no-version.json")"
assert_stderr_contains "error mentions schema_version" "schema_version"

# --- malformed schema_version (v1.2 instead of 1.2) ---
cat > "$TMP/bad-version-format.json" <<'EOF'
{"schema_version": "v1.2", "entries": []}
EOF
assert_exit "malformed schema_version is rejected" "1" "$(run_validator "$TMP/bad-version-format.json")"

# --- entries not an array ---
cat > "$TMP/bad-entries.json" <<'EOF'
{"schema_version": "1.2", "extractor": {"name": "type-catalog", "language": "typescript", "version": "0.4.0", "source_sha": "unknown"}, "entries": {"foo": "bar"}}
EOF
assert_exit "non-array .entries rejected" "1" "$(run_validator "$TMP/bad-entries.json")"

# --- missing required entry field ---
cat > "$TMP/missing-line.json" <<'EOF'
{"schema_version": "1.2", "extractor": {"name": "type-catalog", "language": "typescript", "version": "0.4.0", "source_sha": "unknown"}, "entries": [{"name": "Foo", "kind": "interface", "package": "main", "file": "src/foo.ts"}]}
EOF
assert_exit "entry missing line is rejected" "1" "$(run_validator "$TMP/missing-line.json")"
assert_stderr_contains "error mentions line field" '"line"'

# --- valid symbol_id (matches formula) ---
CORRECT_ID="$(symbol_id main src/foo.ts Foo interface)"
cat > "$TMP/valid-symbol-id.json" <<EOF
{
  "schema_version": "1.2",
  "extractor": {"name": "type-catalog", "language": "typescript", "version": "0.4.0", "source_sha": "unknown"},
  "entries": [
    {"name": "Foo", "kind": "interface", "package": "main", "file": "src/foo.ts", "line": 10, "symbol_id": "$CORRECT_ID"}
  ]
}
EOF
assert_exit "valid symbol_id (matches formula)" "0" "$(run_validator "$TMP/valid-symbol-id.json")"

# --- symbol_id mismatch ---
cat > "$TMP/bad-symbol-id.json" <<'EOF'
{
  "schema_version": "1.2",
  "extractor": {"name": "type-catalog", "language": "typescript", "version": "0.4.0", "source_sha": "unknown"},
  "entries": [
    {"name": "Foo", "kind": "interface", "package": "main", "file": "src/foo.ts", "line": 10, "symbol_id": "0000000000000000000000000000000000000000"}
  ]
}
EOF
assert_exit "mismatched symbol_id rejected" "1" "$(run_validator "$TMP/bad-symbol-id.json")"
assert_stderr_contains "error mentions symbol_id mismatch" "symbol_id mismatch"

# --- symbol_id mismatch applies to bare-array catalogs too ---
cat > "$TMP/bare-bad-symbol.json" <<'EOF'
[
  {"name": "Foo", "kind": "interface", "package": "main", "file": "src/foo.ts", "line": 10, "symbol_id": "0000000000000000000000000000000000000000"}
]
EOF
assert_exit "symbol_id mismatch rejected on bare-array catalog" "1" "$(run_validator "$TMP/bare-bad-symbol.json")"

# --- Tightening: schema_version="1.0" on a wrapper is malformed ---
# v1.0 was bare-array only; a wrapper labeled "1.0" is impossible by contract.
cat > "$TMP/wrapper-1.0.json" <<'EOF'
{"schema_version": "1.0", "entries": []}
EOF
assert_exit "schema_version 1.0 on wrapper is rejected" "1" "$(run_validator "$TMP/wrapper-1.0.json")"
assert_stderr_contains "1.0 wrapper error mentions bare-array-only" "bare-array-only"

# --- Tightening: extractor block is required on wrapper form ---
cat > "$TMP/no-extractor.json" <<'EOF'
{"schema_version": "1.2", "entries": []}
EOF
assert_exit "wrapper without extractor block is rejected" "1" "$(run_validator "$TMP/no-extractor.json")"
assert_stderr_contains "missing-extractor error names the block" "extractor block is required"

# --- Tightening: extractor.{name,language,version} are required ---
cat > "$TMP/empty-extractor.json" <<'EOF'
{"schema_version": "1.2", "extractor": {}, "entries": []}
EOF
assert_exit "empty extractor block is rejected" "1" "$(run_validator "$TMP/empty-extractor.json")"
assert_stderr_contains "empty-extractor error names the missing field" "extractor.name"

# --- Tightening: extractor.source_sha shape must be 40-hex or "unknown" ---
cat > "$TMP/malformed-source-sha.json" <<'EOF'
{
  "schema_version": "1.2",
  "extractor": {"name": "type-catalog", "language": "typescript", "version": "0.1.0", "source_sha": "I am a teapot"},
  "entries": []
}
EOF
assert_exit "malformed source_sha is rejected" "1" "$(run_validator "$TMP/malformed-source-sha.json")"
assert_stderr_contains "malformed-sha error mentions source_sha shape" "source_sha"
# "unknown" sentinel must be accepted
cat > "$TMP/unknown-source-sha.json" <<'EOF'
{
  "schema_version": "1.2",
  "extractor": {"name": "type-catalog", "language": "typescript", "version": "0.1.0", "source_sha": "unknown"},
  "entries": []
}
EOF
assert_exit "source_sha=unknown is accepted" "0" "$(run_validator "$TMP/unknown-source-sha.json")"

# --- NUL-formula regression: slash-flatten-only ambiguity does NOT collide ---
# (package="Shared", file="Generated/X.ts") vs (package="Shared/Generated",
# file="X.ts") share a slash-joined string but distinct 4-tuples. Both rows
# carry their own correct sha1; the validator must accept both.
ID_A="$(symbol_id "Shared" "Generated/X.ts" "X" "interface")"
ID_B="$(symbol_id "Shared/Generated" "X.ts" "X" "interface")"
cat > "$TMP/slash-flatten-distinct.json" <<EOF
{
  "schema_version": "1.2",
  "extractor": {"name": "type-catalog", "language": "typescript", "version": "0.1.0", "source_sha": "unknown"},
  "entries": [
    {"name": "X", "kind": "interface", "package": "Shared", "file": "Generated/X.ts", "line": 1, "symbol_id": "$ID_A"},
    {"name": "X", "kind": "interface", "package": "Shared/Generated", "file": "X.ts", "line": 2, "symbol_id": "$ID_B"}
  ]
}
EOF
assert_exit "NUL formula: slash-flatten-only ambiguity accepted (distinct symbol_ids)" "0" "$(run_validator "$TMP/slash-flatten-distinct.json")"

echo
echo "=== summary ==="
printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then exit 1; fi
exit 0
