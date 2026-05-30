#!/usr/bin/env bash
# Tests for the cross-repo substrate tooling (issue #153).
# Covers fetch-catalogs.sh, refresh-index.mjs, publish-catalog.sh,
# verify-index.sh under a hermetic file:// mock bucket.
#
# Run:  bash pipeline/_tests/test_substrate.sh

set -u

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/../.." && pwd)"
MOCK="$THIS_DIR/fixtures/mock-substrate"
PIPELINE="$REPO_ROOT/pipeline"

PASS=0
FAIL=0

# Each test runs in its own scratch dir so warm-cache state doesn't bleed.
mk_scratch() {
  mktemp -d "${TMPDIR:-/tmp}/substrate-test-XXXXXX"
}

# `assert_eq EXPECTED ACTUAL LABEL` — fail-fast on string inequality.
assert_eq() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $3"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $3"
    echo "      expected: $1"
    echo "      actual:   $2"
  fi
}

assert_file_exists() {
  if [ -f "$1" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ exists: $2"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ missing: $2 ($1)"
  fi
}

assert_nonzero_exit() {
  if [ "$1" -ne 0 ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $2"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $2 (got exit 0, expected nonzero)"
  fi
}

assert_contains() {
  if printf '%s' "$1" | grep -F -q "$2"; then
    PASS=$((PASS + 1))
    echo "  ✓ $3"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $3 (substring not found)"
    echo "      looking for: $2"
    echo "      in:          $1"
  fi
}

# ====================================================================
# fetch-catalogs.sh
# ====================================================================

echo "=== fetch-catalogs.sh: cold fetch reads all ok repos ==="
SCRATCH=$(mk_scratch)
out=$(AUDIT_BUCKET_URL="file://$MOCK" AUDIT_LOCAL_CACHE="$SCRATCH" \
  bash "$PIPELINE/fetch-catalogs.sh" --quiet 2>&1)
rc=$?
assert_eq "0" "$rc" "cold fetch exits 0"
assert_file_exists "$SCRATCH/index.json" "index.json in cache"
assert_file_exists "$SCRATCH/by-repo/fake-repo-a/2026-05-30T10-00-00Z_aaa1111/type-catalog.json" \
  "fake-repo-a type-catalog"
assert_file_exists "$SCRATCH/by-repo/fake-repo-a/2026-05-30T10-00-00Z_aaa1111/function-catalog.json" \
  "fake-repo-a function-catalog"
assert_file_exists "$SCRATCH/by-repo/fake-repo-b/2026-05-30T11-00-00Z_bbb2222/type-catalog.json" \
  "fake-repo-b type-catalog"
# Stale repo should not have catalogs fetched.
if [ -d "$SCRATCH/by-repo/stale-repo" ] && [ "$(ls "$SCRATCH/by-repo/stale-repo")" != "" ]; then
  FAIL=$((FAIL + 1))
  echo "  ✗ stale-repo had files fetched (should have been skipped)"
else
  PASS=$((PASS + 1))
  echo "  ✓ stale-repo correctly skipped"
fi
rm -rf "$SCRATCH"

echo "=== fetch-catalogs.sh: warm fetch issues zero downloads ==="
SCRATCH=$(mk_scratch)
# Prime the cache.
AUDIT_BUCKET_URL="file://$MOCK" AUDIT_LOCAL_CACHE="$SCRATCH" \
  bash "$PIPELINE/fetch-catalogs.sh" --quiet >/dev/null 2>&1
# Second invocation: expect "3 cached / 0 fetched" in the summary.
out=$(AUDIT_BUCKET_URL="file://$MOCK" AUDIT_LOCAL_CACHE="$SCRATCH" \
  bash "$PIPELINE/fetch-catalogs.sh" 2>&1)
assert_contains "$out" "3 cached" "warm-cache summary reports cached count"
assert_contains "$out" "0 fetched" "warm-cache summary reports zero fetched"
rm -rf "$SCRATCH"

echo "=== fetch-catalogs.sh: --repos filter ==="
SCRATCH=$(mk_scratch)
out=$(AUDIT_BUCKET_URL="file://$MOCK" AUDIT_LOCAL_CACHE="$SCRATCH" \
  bash "$PIPELINE/fetch-catalogs.sh" --quiet --repos wxyc/fake-repo-b 2>&1)
rc=$?
assert_eq "0" "$rc" "filtered fetch exits 0"
assert_file_exists "$SCRATCH/by-repo/fake-repo-b/2026-05-30T11-00-00Z_bbb2222/type-catalog.json" \
  "filtered repo present"
if [ -d "$SCRATCH/by-repo/fake-repo-a" ]; then
  FAIL=$((FAIL + 1))
  echo "  ✗ unfiltered repo also fetched"
else
  PASS=$((PASS + 1))
  echo "  ✓ unfiltered repo absent"
fi
rm -rf "$SCRATCH"

echo "=== fetch-catalogs.sh: missing AUDIT_BUCKET_URL ==="
SCRATCH=$(mk_scratch)
out=$(AUDIT_BUCKET_URL="" AUDIT_LOCAL_CACHE="$SCRATCH" \
  bash "$PIPELINE/fetch-catalogs.sh" 2>&1)
rc=$?
assert_nonzero_exit "$rc" "missing bucket-url exits nonzero"
assert_contains "$out" "AUDIT_BUCKET_URL is required" "error message names the missing env"
rm -rf "$SCRATCH"

echo "=== fetch-catalogs.sh: malformed index.json ==="
SCRATCH=$(mk_scratch)
BAD_MOCK=$(mk_scratch)
mkdir -p "$BAD_MOCK"
printf '{not-valid-json' > "$BAD_MOCK/index.json"
out=$(AUDIT_BUCKET_URL="file://$BAD_MOCK" AUDIT_LOCAL_CACHE="$SCRATCH" \
  bash "$PIPELINE/fetch-catalogs.sh" 2>&1)
rc=$?
assert_nonzero_exit "$rc" "malformed index exits nonzero"
assert_contains "$out" "malformed index.json" "error message mentions malformed"
rm -rf "$SCRATCH" "$BAD_MOCK"

echo "=== fetch-catalogs.sh: sha256 mismatch handled ==="
SCRATCH=$(mk_scratch)
TAMPER_MOCK=$(mk_scratch)
cp -r "$MOCK/." "$TAMPER_MOCK/"
# Corrupt one catalog so its sha won't match the index claim.
printf 'tampered bytes\n' \
  > "$TAMPER_MOCK/by-repo/fake-repo-b/2026-05-30T11-00-00Z_bbb2222/type-catalog.json"
out=$(AUDIT_BUCKET_URL="file://$TAMPER_MOCK" AUDIT_LOCAL_CACHE="$SCRATCH" \
  bash "$PIPELINE/fetch-catalogs.sh" 2>&1)
rc=$?
# Exit is still 0 because the OTHER repo fetched fine; mismatch surfaces
# in stderr and the corrupted file is discarded.
assert_eq "0" "$rc" "partial-failure run exits 0"
assert_contains "$out" "SHA MISMATCH" "mismatch logged"
if [ -f "$SCRATCH/by-repo/fake-repo-b/2026-05-30T11-00-00Z_bbb2222/type-catalog.json" ]; then
  FAIL=$((FAIL + 1))
  echo "  ✗ tampered file left in cache (should have been removed)"
else
  PASS=$((PASS + 1))
  echo "  ✓ tampered file discarded"
fi
rm -rf "$SCRATCH" "$TAMPER_MOCK"

# ====================================================================
# refresh-index.mjs (filesystem backend)
# ====================================================================

echo "=== refresh-index.mjs: rebuild index from a clean mock ==="
SCRATCH=$(mk_scratch)
cp -r "$MOCK/." "$SCRATCH/"
rm -f "$SCRATCH/index.json"
out=$(node "$PIPELINE/refresh-index.mjs" --bucket-fs "$SCRATCH" 2>&1)
rc=$?
assert_eq "0" "$rc" "rebuild exits 0"
assert_file_exists "$SCRATCH/index.json" "rebuilt index.json present"
schema=$(jq -r '.schema_version' "$SCRATCH/index.json")
assert_eq "1.0" "$schema" "schema_version is 1.0"
repos=$(jq -r '.repos | length' "$SCRATCH/index.json")
# stale-repo has no snapshots -> not surfaced unless --known-repos lists it.
# Mock has fake-repo-a + fake-repo-b -> 2 entries.
assert_eq "2" "$repos" "rebuilt index covers the 2 repos with snapshots"
ok_count=$(jq -r '.coverage.ok' "$SCRATCH/index.json")
assert_eq "2" "$ok_count" "coverage.ok counts both repos"
a_catalogs=$(jq -r '.repos[] | select(.repo == "wxyc/fake-repo-a") | .latest.catalogs | length' "$SCRATCH/index.json")
assert_eq "2" "$a_catalogs" "fake-repo-a has 2 catalogs in rebuilt latest"
a_sha=$(jq -r '.repos[] | select(.repo == "wxyc/fake-repo-a") | .latest.catalogs[] | select(.kind == "type-catalog") | .sha256' "$SCRATCH/index.json")
assert_eq "0d733bd04c183bd79e59774d8e9a7cf20cd46463abfb8f8489491fb8030dce63" "$a_sha" \
  "rebuilt sha256 matches the canonical fixture value"
rm -rf "$SCRATCH"

echo "=== refresh-index.mjs: --known-repos surfaces missing repos ==="
SCRATCH=$(mk_scratch)
cp -r "$MOCK/." "$SCRATCH/"
rm -f "$SCRATCH/index.json"
known="$SCRATCH/known.json"
printf '["wxyc/fake-repo-a","wxyc/fake-repo-b","wxyc/ghost-repo"]\n' > "$known"
node "$PIPELINE/refresh-index.mjs" --bucket-fs "$SCRATCH" --known-repos "$known" >/dev/null 2>&1
missing=$(jq -r '.repos[] | select(.status == "missing") | .repo' "$SCRATCH/index.json")
assert_eq "wxyc/ghost-repo" "$missing" "ghost-repo flagged as missing"
total=$(jq -r '.coverage.total_known_repos' "$SCRATCH/index.json")
assert_eq "3" "$total" "coverage.total_known_repos reflects the known list"
missing_count=$(jq -r '.coverage.missing // 0' "$SCRATCH/index.json")
assert_eq "1" "$missing_count" "coverage.missing tally"
rm -rf "$SCRATCH"

echo "=== refresh-index.mjs: stale snapshot -> status: stale ==="
SCRATCH=$(mk_scratch)
# Synthesize a single old-timestamp snapshot. The script computes age from
# the embedded timestamp, so this won't drift with clock time.
mkdir -p "$SCRATCH/by-repo/ancient-repo/2024-01-01T00-00-00Z_old1234"
cat > "$SCRATCH/by-repo/ancient-repo/2024-01-01T00-00-00Z_old1234/type-catalog.json" <<'JSON'
{
  "schema_version": "1.1",
  "extractor": {"language": "typescript", "name": "type-catalog", "version": "0.5.0"},
  "entries": []
}
JSON
node "$PIPELINE/refresh-index.mjs" --bucket-fs "$SCRATCH" >/dev/null 2>&1
status=$(jq -r '.repos[] | select(.path_segment == "ancient-repo") | .status' "$SCRATCH/index.json")
assert_eq "stale" "$status" "old snapshot flagged as stale"
rm -rf "$SCRATCH"

echo "=== refresh-index.mjs: --dry-run does not write ==="
SCRATCH=$(mk_scratch)
cp -r "$MOCK/." "$SCRATCH/"
existing_sha=$(sha256_of_file() { shasum -a 256 "$1" | awk '{print $1}'; }; sha256_of_file "$SCRATCH/index.json")
out=$(node "$PIPELINE/refresh-index.mjs" --bucket-fs "$SCRATCH" --dry-run 2>/dev/null | head -c 30)
post_sha=$(shasum -a 256 "$SCRATCH/index.json" | awk '{print $1}')
assert_eq "$existing_sha" "$post_sha" "--dry-run leaves the on-disk index untouched"
assert_contains "$out" '"schema_version"' "--dry-run prints index JSON to stdout"
rm -rf "$SCRATCH"

# ====================================================================
# verify-index.sh
# ====================================================================

echo "=== verify-index.sh: clean mock reports no drift ==="
out=$(bash "$PIPELINE/verify-index.sh" --bucket-fs "$MOCK" 2>&1)
rc=$?
assert_eq "0" "$rc" "no-drift case exits 0"
assert_contains "$out" "no drift" "no-drift summary line"

echo "=== verify-index.sh: orphan prefix detected ==="
SCRATCH=$(mk_scratch)
cp -r "$MOCK/." "$SCRATCH/"
# Plant a phantom snapshot that's not in the index.
mkdir -p "$SCRATCH/by-repo/fake-repo-a/2099-01-01T00-00-00Z_phantom"
cat > "$SCRATCH/by-repo/fake-repo-a/2099-01-01T00-00-00Z_phantom/type-catalog.json" <<'JSON'
{"schema_version":"1.1","extractor":{"name":"type-catalog","language":"typescript","version":"0.5.0"},"entries":[]}
JSON
out=$(bash "$PIPELINE/verify-index.sh" --bucket-fs "$SCRATCH" 2>&1)
rc=$?
assert_nonzero_exit "$rc" "orphan prefix exits nonzero"
assert_contains "$out" "2099-01-01" "orphan prefix listed"
rm -rf "$SCRATCH"

echo "=== verify-index.sh: dangling reference detected ==="
SCRATCH=$(mk_scratch)
cp -r "$MOCK/." "$SCRATCH/"
# Mutate the index to claim a prefix that doesn't exist.
jq '.repos[0].latest.prefix = "by-repo/fake-repo-a/9999-12-31T23-59-59Z_zzzzzzz/"' \
  "$SCRATCH/index.json" > "$SCRATCH/index.json.tmp"
mv "$SCRATCH/index.json.tmp" "$SCRATCH/index.json"
out=$(bash "$PIPELINE/verify-index.sh" --bucket-fs "$SCRATCH" 2>&1)
rc=$?
assert_nonzero_exit "$rc" "dangling ref exits nonzero"
assert_contains "$out" "dangling" "dangling ref reported"
rm -rf "$SCRATCH"

# ====================================================================
# publish-catalog.sh
# ====================================================================

echo "=== publish-catalog.sh: round-trip publish + fetch ==="
PUB_BUCKET=$(mk_scratch)
PUB_CAT=$(mk_scratch)
cat > "$PUB_CAT/type-catalog.json" <<'JSON'
{"schema_version":"1.1","extractor":{"language":"typescript","name":"type-catalog","version":"0.5.0"},"entries":[{"name":"Zeta","kind":"interface","package":"main","file":"src/zeta.ts","line":1,"is_test":false,"extends":[],"references":[],"references_count":0}]}
JSON
cat > "$PUB_CAT/function-catalog.json" <<'JSON'
{"schema_version":"1.1","extractor":{"language":"typescript","name":"function-catalog","version":"0.5.0"},"entries":[]}
JSON
bash "$PIPELINE/publish-catalog.sh" \
  --repo wxyc/round-trip --sha 1234567890abcdef --catalogs-dir "$PUB_CAT" \
  --bucket-fs "$PUB_BUCKET" >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "publish exits 0"
assert_file_exists "$PUB_BUCKET/by-repo/wxyc-round-trip/latest.json" "latest.json written"
assert_file_exists "$PUB_BUCKET/index.json" "index.json refreshed by publish"
# Round-trip: fetch from what we just published.
PUB_FETCH=$(mk_scratch)
AUDIT_BUCKET_URL="file://$PUB_BUCKET" AUDIT_LOCAL_CACHE="$PUB_FETCH" \
  bash "$PIPELINE/fetch-catalogs.sh" --quiet >/dev/null 2>&1
fetched_zeta=$(jq -r '.entries[0].name' "$PUB_FETCH"/by-repo/wxyc-round-trip/*/type-catalog.json)
assert_eq "Zeta" "$fetched_zeta" "fetched catalog round-trips through publish"
rm -rf "$PUB_BUCKET" "$PUB_CAT" "$PUB_FETCH"

echo "=== publish-catalog.sh: refuses bare-array catalog ==="
PUB_BUCKET=$(mk_scratch)
PUB_CAT=$(mk_scratch)
printf '[{"name":"x","kind":"interface"}]\n' > "$PUB_CAT/type-catalog.json"
out=$(bash "$PIPELINE/publish-catalog.sh" \
  --repo wxyc/bad --sha aaaaaaaaaaaa --catalogs-dir "$PUB_CAT" \
  --bucket-fs "$PUB_BUCKET" --skip-refresh 2>&1)
rc=$?
assert_nonzero_exit "$rc" "bare-array publish exits nonzero"
assert_contains "$out" "REFUSED" "refusal message emitted"
rm -rf "$PUB_BUCKET" "$PUB_CAT"

echo "=== publish-catalog.sh: --skip-refresh leaves index alone ==="
PUB_BUCKET=$(mk_scratch)
PUB_CAT=$(mk_scratch)
cat > "$PUB_CAT/type-catalog.json" <<'JSON'
{"schema_version":"1.1","extractor":{"language":"typescript","name":"type-catalog","version":"0.5.0"},"entries":[]}
JSON
bash "$PIPELINE/publish-catalog.sh" \
  --repo wxyc/skip-refresh --sha 1234567 --catalogs-dir "$PUB_CAT" \
  --bucket-fs "$PUB_BUCKET" --skip-refresh >/dev/null 2>&1
if [ -f "$PUB_BUCKET/index.json" ]; then
  FAIL=$((FAIL + 1))
  echo "  ✗ --skip-refresh wrote index.json anyway"
else
  PASS=$((PASS + 1))
  echo "  ✓ --skip-refresh skipped index rewrite"
fi
# The catalog and pointer should still be present.
assert_file_exists "$PUB_BUCKET/by-repo/wxyc-skip-refresh/latest.json" \
  "latest.json still written under --skip-refresh"
rm -rf "$PUB_BUCKET" "$PUB_CAT"

# ====================================================================
# Summary
# ====================================================================

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
