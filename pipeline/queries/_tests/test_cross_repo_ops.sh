#!/usr/bin/env bash
# Tests for the operational-safety substrate guardrails (issue #155).
# Covers:
#   - pipeline/queries/preflight-versions.jq  (extractor version skew refusal)
#   - pipeline/queries/coverage.jq            (scope / missing / stale header)
#   - pipeline/run-cross-repo-query.sh        (wrapper: fetch → preflight → coverage → query)
#
# Run:  bash pipeline/queries/_tests/test_cross_repo_ops.sh
# Exits 0 on success; non-zero on any assertion failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$QUERIES_DIR/../.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/cross-repo-ops"
PIPELINE="$REPO_ROOT/pipeline"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s\n      expected: %s\n      actual:   %s\n" "$desc" "$expected" "$actual"
  fi
}

assert_contains() {
  local desc="$1"; local haystack="$2"; local needle="$3"
  if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
    PASS=$((PASS + 1)); printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s (substring not found)\n      looking for: %s\n      in:          %s\n" "$desc" "$needle" "$haystack"
  fi
}

assert_nonzero_exit() {
  if [ "$1" -ne 0 ]; then
    PASS=$((PASS + 1)); printf "  ✓ %s (exit %d)\n" "$2" "$1"
  else
    FAIL=$((FAIL + 1)); printf "  ✗ %s (exit 0, expected nonzero)\n" "$2"
  fi
}

# Run preflight-versions.jq in the requested mode, capturing stdout, stderr, exit.
# Args: <mode: text|jsonl> <fixture-path>
run_preflight() {
  local mode="$1"; local fixture="$2"
  local out; local err; local rc
  out=$(env OUTPUT_FORMAT="$mode" jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/preflight-versions.jq" "$fixture" 2>/tmp/preflight.$$.err)
  rc=$?
  err=$(cat /tmp/preflight.$$.err); rm -f /tmp/preflight.$$.err
  printf '%s\n--SEP--\n%s\n--SEP--\n%d' "$out" "$err" "$rc"
}

# Helpers to slice the run_preflight tri-record. Currently we only need
# stdout and exit code; pf_stderr is omitted until a test reads stderr.
pf_stdout() { printf '%s' "$1" | awk '/^--SEP--$/{exit} {print}'; }
pf_exit()   { printf '%s' "$1" | awk 'p==2{print; exit} /^--SEP--$/{p+=1}'; }

run_coverage() {
  local mode="$1"; local fixture="$2"
  local out; local err; local rc
  out=$(env OUTPUT_FORMAT="$mode" jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/coverage.jq" "$fixture" 2>/tmp/coverage.$$.err)
  rc=$?
  err=$(cat /tmp/coverage.$$.err); rm -f /tmp/coverage.$$.err
  printf '%s\n--SEP--\n%s\n--SEP--\n%d' "$out" "$err" "$rc"
}

# ====================================================================
# preflight-versions.jq
# ====================================================================

echo "=== preflight-versions.jq: clean fixture passes ==="
res=$(run_preflight text "$FIXTURES/clean.index.json")
assert_eq "exit 0 on all-matching versions" "0" "$(pf_exit "$res")"
assert_contains "stdout reports ok status" "$(pf_stdout "$res")" "ok"
assert_contains "stdout names the typescript/type-catalog extractor" "$(pf_stdout "$res")" "typescript/type-catalog"

echo "=== preflight-versions.jq: minor skew warns but passes ==="
res=$(run_preflight text "$FIXTURES/minor-skew.index.json")
assert_eq "exit 0 on minor skew (warn-only)" "0" "$(pf_exit "$res")"
assert_contains "stdout reports minor-skew status" "$(pf_stdout "$res")" "minor-skew"
assert_contains "stdout names version 1.2" "$(pf_stdout "$res")" "1.2"
assert_contains "stdout names version 1.3" "$(pf_stdout "$res")" "1.3"

echo "=== preflight-versions.jq: major skew refuses ==="
res=$(run_preflight text "$FIXTURES/major-skew.index.json")
assert_nonzero_exit "$(pf_exit "$res")" "major skew refuses"
assert_contains "stdout reports refused status" "$(pf_stdout "$res")" "refused"
assert_contains "stdout names major version 1" "$(pf_stdout "$res")" "1.3"
assert_contains "stdout names major version 2" "$(pf_stdout "$res")" "2.0"
assert_contains "stdout names repo-a as offending" "$(pf_stdout "$res")" "wxyc/repo-a"
assert_contains "stdout names repo-b as offending" "$(pf_stdout "$res")" "wxyc/repo-b"

echo "=== preflight-versions.jq: multi-language passes ==="
res=$(run_preflight text "$FIXTURES/multi-lang.index.json")
assert_eq "exit 0 on multi-language merge" "0" "$(pf_exit "$res")"
assert_contains "stdout lists typescript group" "$(pf_stdout "$res")" "typescript/type-catalog"
assert_contains "stdout lists python group" "$(pf_stdout "$res")" "python/type-catalog"
assert_contains "stdout lists swift group" "$(pf_stdout "$res")" "swift/type-catalog"

echo "=== preflight-versions.jq: missing extractor block refuses ==="
res=$(run_preflight text "$FIXTURES/missing-extractor.index.json")
assert_nonzero_exit "$(pf_exit "$res")" "missing extractor refuses"
assert_contains "stdout reports refused" "$(pf_stdout "$res")" "refused"
assert_contains "stdout mentions missing extractor" "$(pf_stdout "$res")" "missing"
assert_contains "stdout names repo-broken" "$(pf_stdout "$res")" "wxyc/repo-broken"

echo "=== preflight-versions.jq: malformed extractor refuses ==="
res=$(run_preflight text "$FIXTURES/malformed-extractor.index.json")
assert_nonzero_exit "$(pf_exit "$res")" "malformed extractor refuses"
assert_contains "stdout reports refused" "$(pf_stdout "$res")" "refused"
assert_contains "stdout mentions malformed" "$(pf_stdout "$res")" "malformed"

echo "=== preflight-versions.jq: jsonl mode emits structured object ==="
res=$(run_preflight jsonl "$FIXTURES/clean.index.json")
assert_eq "exit 0 on clean" "0" "$(pf_exit "$res")"
status=$(pf_stdout "$res" | jq -r '.status')
assert_eq "jsonl reports status=ok" "ok" "$status"

res=$(run_preflight jsonl "$FIXTURES/major-skew.index.json")
assert_nonzero_exit "$(pf_exit "$res")" "jsonl refuses on major skew"
status=$(pf_stdout "$res" | jq -r '.status')
assert_eq "jsonl reports status=refused on major skew" "refused" "$status"

res=$(run_preflight jsonl "$FIXTURES/missing-extractor.index.json")
status=$(pf_stdout "$res" | jq -r '.status')
assert_eq "jsonl reports status=refused on missing extractor" "refused" "$status"
reason=$(pf_stdout "$res" | jq -r '.reason')
assert_contains "jsonl .reason mentions extractor" "$reason" "extractor"

# ====================================================================
# coverage.jq
# ====================================================================

echo "=== coverage.jq: all-ok fixture reports full scope ==="
res=$(run_coverage text "$FIXTURES/all-ok.index.json")
assert_eq "exit 0 on coverage (always informational)" "0" "$(pf_exit "$res")"
assert_contains "header reports 3/3 covered" "$(pf_stdout "$res")" "3/3"
assert_contains "header mentions no missing" "$(pf_stdout "$res")" "0 missing"
assert_contains "header mentions no stale" "$(pf_stdout "$res")" "0 stale"

echo "=== coverage.jq: mixed fixture surfaces missing+stale repos ==="
res=$(run_coverage text "$FIXTURES/mixed.index.json")
assert_eq "exit 0" "0" "$(pf_exit "$res")"
assert_contains "header reports 1/3 covered" "$(pf_stdout "$res")" "1/3"
assert_contains "header mentions 1 missing" "$(pf_stdout "$res")" "1 missing"
assert_contains "header mentions 1 stale" "$(pf_stdout "$res")" "1 stale"
assert_contains "names missing repo" "$(pf_stdout "$res")" "wxyc/repo-missing"
assert_contains "names stale repo" "$(pf_stdout "$res")" "wxyc/repo-stale"

echo "=== coverage.jq: jsonl mode emits structured object ==="
res=$(run_coverage jsonl "$FIXTURES/mixed.index.json")
assert_eq "exit 0" "0" "$(pf_exit "$res")"
covered=$(pf_stdout "$res" | jq -r '.scope.covered')
expected=$(pf_stdout "$res" | jq -r '.scope.expected')
assert_eq "scope.covered = 1" "1" "$covered"
assert_eq "scope.expected = 3" "3" "$expected"
missing_count=$(pf_stdout "$res" | jq -r '.missing | length')
stale_count=$(pf_stdout "$res" | jq -r '.stale | length')
errored_count=$(pf_stdout "$res" | jq -r '.errored | length')
assert_eq "missing[] has 1 entry" "1" "$missing_count"
assert_eq "stale[] has 1 entry" "1" "$stale_count"
assert_eq "errored[] is empty (substrate doesn't emit yet)" "0" "$errored_count"
missing_repo=$(pf_stdout "$res" | jq -r '.missing[0].repo')
assert_eq "missing[0].repo = wxyc/repo-missing" "wxyc/repo-missing" "$missing_repo"

echo "=== coverage.jq: stale threshold env-overridable via CROSS_REPO_STALE_DAYS ==="
# The mixed fixture's stale repo published 2026-05-15 (15+ days before
# the substrate's `generated_at` of 2026-05-31). Coverage uses index.json's
# `status` field (already computed at publish-time with the env value
# *then*), but also re-derives age vs. the env value *now* for divergence
# detection. With CROSS_REPO_STALE_DAYS=30 (and the index already saying
# status=stale), .stale[] still surfaces it from .status — and an explicit
# .threshold_days field records the now-value for the consumer.
res=$(env CROSS_REPO_STALE_DAYS=30 jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/coverage.jq" "$FIXTURES/mixed.index.json" 2>/dev/null)
threshold=$(printf '%s' "$res" | jq -r '.threshold_days' 2>/dev/null \
  || env CROSS_REPO_STALE_DAYS=30 OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/coverage.jq" "$FIXTURES/mixed.index.json" 2>/dev/null | jq -r '.threshold_days')
assert_eq "structured output exposes threshold_days=30 from env" "30" "$threshold"

# ====================================================================
# run-cross-repo-query.sh (wrapper)
# ====================================================================
# Built against the mock-substrate fixture in pipeline/_tests/fixtures/.

MOCK="$REPO_ROOT/pipeline/_tests/fixtures/mock-substrate"
NOOP_QUERY="$SCRIPT_DIR/fixtures/cross-repo-ops/noop-query.jq"

echo "=== run-cross-repo-query.sh: golden path prepends coverage header ==="
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrap-test-XXXXXX")
out=$(AUDIT_BUCKET_URL="file://$MOCK" AUDIT_LOCAL_CACHE="$SCRATCH" \
  bash "$PIPELINE/run-cross-repo-query.sh" --quiet "$NOOP_QUERY" 2>"$SCRATCH/err")
rc=$?
assert_eq "wrapper exits 0 on golden path" "0" "$rc"
assert_contains "stdout begins with coverage header" "$out" "covered"
assert_contains "stdout contains the no-op query marker" "$out" "NOOP-MARKER"
rm -rf "$SCRATCH"

echo "=== run-cross-repo-query.sh: missing AUDIT_BUCKET_URL refuses ==="
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrap-test-XXXXXX")
out=$(AUDIT_LOCAL_CACHE="$SCRATCH" bash "$PIPELINE/run-cross-repo-query.sh" --quiet "$NOOP_QUERY" 2>&1)
rc=$?
assert_nonzero_exit "$rc" "wrapper refuses without AUDIT_BUCKET_URL"
assert_contains "stderr mentions AUDIT_BUCKET_URL" "$out" "AUDIT_BUCKET_URL"
rm -rf "$SCRATCH"

echo "=== run-cross-repo-query.sh: preflight refusal blocks query ==="
# Stand up a substrate whose index.json carries a major version skew.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wrap-test-XXXXXX")
BAD_BUCKET=$(mktemp -d "${TMPDIR:-/tmp}/bad-bucket-XXXXXX")
mkdir -p "$BAD_BUCKET/by-repo/wxyc-repo-a/2026-05-31T10-00-00Z_aaa1111"
mkdir -p "$BAD_BUCKET/by-repo/wxyc-repo-b/2026-05-31T11-00-00Z_bbb2222"
# Place empty placeholder catalogs so fetch-catalogs doesn't fail on missing files.
echo '{"schema_version":"1.1","extractor":{"name":"type-catalog","language":"typescript","version":"1.3.0"},"entries":[]}' \
  > "$BAD_BUCKET/by-repo/wxyc-repo-a/2026-05-31T10-00-00Z_aaa1111/type-catalog.json"
echo '{"schema_version":"1.1","extractor":{"name":"type-catalog","language":"typescript","version":"2.0.0"},"entries":[]}' \
  > "$BAD_BUCKET/by-repo/wxyc-repo-b/2026-05-31T11-00-00Z_bbb2222/type-catalog.json"
# Compute sha256s for the index.
SHA_A=$(shasum -a 256 "$BAD_BUCKET/by-repo/wxyc-repo-a/2026-05-31T10-00-00Z_aaa1111/type-catalog.json" | awk '{print $1}')
SHA_B=$(shasum -a 256 "$BAD_BUCKET/by-repo/wxyc-repo-b/2026-05-31T11-00-00Z_bbb2222/type-catalog.json" | awk '{print $1}')
# Inject sha256s into a copy of major-skew.index.json
jq --arg sha_a "$SHA_A" --arg sha_b "$SHA_B" '
  .repos[0].latest.catalogs[0].sha256 = $sha_a
  | .repos[1].latest.catalogs[0].sha256 = $sha_b
' "$FIXTURES/major-skew.index.json" > "$BAD_BUCKET/index.json"

out=$(AUDIT_BUCKET_URL="file://$BAD_BUCKET" AUDIT_LOCAL_CACHE="$SCRATCH" \
  bash "$PIPELINE/run-cross-repo-query.sh" --quiet "$NOOP_QUERY" 2>"$SCRATCH/err")
rc=$?
assert_nonzero_exit "$rc" "wrapper refuses on major version skew"
err=$(cat "$SCRATCH/err")
assert_contains "stderr mentions refused" "$err" "refused"
# Confirm query never ran: NOOP-MARKER should not appear in stdout.
if printf '%s' "$out" | grep -F -q "NOOP-MARKER"; then
  FAIL=$((FAIL + 1))
  echo "  ✗ query ran despite preflight refusal (NOOP-MARKER in stdout)"
else
  PASS=$((PASS + 1))
  echo "  ✓ query did not run after preflight refusal"
fi
rm -rf "$SCRATCH" "$BAD_BUCKET"

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
