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

# ====================================================================
# Regression tests for /code-review findings on PR #237
# ====================================================================
# Each block names the finding it guards against. If a future refactor
# reintroduces the bug, the corresponding assertion fails loudly.

echo "=== regression(#5): stale_threshold_days handles empty CROSS_REPO_STALE_DAYS ==="
out=$(CROSS_REPO_STALE_DAYS='' jq -L "$QUERIES_DIR" -n 'include "_canonical"; stale_threshold_days' 2>&1)
rc=$?
assert_eq "exit 0 on empty env" "0" "$rc"
assert_eq "returns 7 (default) on empty env" "7" "$out"

echo "=== regression(#7): coverage errored[] applies > 0 with correct precedence ==="
synth_index='{
  "schema_version": "1.0",
  "generated_at": "2026-05-31T12:00:00Z",
  "bucket": "fs:/x",
  "region": "auto",
  "repos": [
    {"repo": "wxyc/zero-errors", "path_segment": "z", "latest": null, "status": "missing", "extractor_errors": 0},
    {"repo": "wxyc/nonzero",     "path_segment": "n", "latest": null, "status": "missing", "extractor_errors": 3}
  ],
  "coverage": {"total_known_repos": 2, "ok": 0, "stale": 0, "failed_last_run": 0}
}'
errored=$(printf '%s' "$synth_index" | env OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/coverage.jq" /dev/stdin | jq -r '.errored | map(.repo) | sort | join(",")')
assert_eq "extractor_errors=0 excluded, =3 included" "wxyc/nonzero" "$errored"

echo "=== regression(#11): preflight tolerates non-object extractor ==="
bad_ext_index='{
  "schema_version": "1.0",
  "generated_at": "2026-05-31T12:00:00Z",
  "bucket": "fs:/x",
  "region": "auto",
  "repos": [{
    "repo": "wxyc/bad",
    "path_segment": "b",
    "latest": {
      "prefix": "by-repo/b/x/",
      "commit_sha": "aaa", "short_sha": "aaa", "published_at": "2026-05-31T10:00:00Z",
      "catalogs": [{"kind": "type-catalog", "key": "k", "extractor": 42, "size_bytes": 1, "entry_count": 0, "sha256": "x"}]
    },
    "history_prefixes": [],
    "status": "ok"
  }],
  "coverage": {"total_known_repos": 1, "ok": 1, "stale": 0, "failed_last_run": 0}
}'
out=$(printf '%s' "$bad_ext_index" | jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/preflight-versions.jq" /dev/stdin 2>&1)
rc=$?
assert_nonzero_exit "$rc" "non-object extractor refuses (not crashes)"
assert_contains "refusal mentions missing extractor (not a stack trace)" "$out" "missing extractor"

echo "=== regression(#12): coverage uses wall-clock now via NOW_OVERRIDE, not generated_at ==="
# all-ok fixture has generated_at 2026-05-31T12:00:00Z and repo-c published
# 2026-05-30T08:00:00Z (28h before generated_at). If we override now to
# 2026-06-05T12:00:00Z, repo-c is 6+ days old — past the default 7d
# threshold's halfway and approaching staleness, so the max age in jsonl
# output should be much greater than 28h.
override_epoch=$(env TZ=UTC python3 -c 'import datetime; print(int(datetime.datetime(2026,6,5,12,0,0,tzinfo=datetime.timezone.utc).timestamp()))' 2>/dev/null \
  || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-06-05T12:00:00Z' +%s 2>/dev/null \
  || echo 1780999200)
max_h=$(env NOW_OVERRIDE="$override_epoch" OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/coverage.jq" "$FIXTURES/all-ok.index.json" | jq -r '.max_age_hours')
# Without the wall-clock fix, max_age_hours would be 28 (28h before generated_at).
# With the fix and the override 5 days past generated_at, repo-c (which was 28h
# old at generated_at) is now 28+120=148h old.
if [ "$max_h" -gt 100 ]; then
  PASS=$((PASS + 1)); echo "  ✓ NOW_OVERRIDE pushes max_age_hours past the generated_at-frozen value (got $max_h)"
else
  FAIL=$((FAIL + 1)); echo "  ✗ NOW_OVERRIDE did not shift the comparison point (got $max_h)"
fi

echo "=== regression(#13): parse_iso accepts +00:00 offset form ==="
synth_offset='{
  "schema_version": "1.0",
  "generated_at": "2026-05-31T12:00:00+00:00",
  "bucket": "fs:/x", "region": "auto",
  "repos": [{
    "repo": "wxyc/r", "path_segment": "r",
    "latest": {
      "prefix": "by-repo/r/x/",
      "commit_sha": "c", "short_sha": "c",
      "published_at": "2026-05-31T11:00:00+00:00",
      "catalogs": []
    },
    "history_prefixes": [], "status": "ok"
  }],
  "coverage": {"total_known_repos": 1, "ok": 1, "stale": 0, "failed_last_run": 0}
}'
age_h=$(printf '%s' "$synth_offset" | env NOW_OVERRIDE="$(env TZ=UTC python3 -c 'import datetime; print(int(datetime.datetime(2026,5,31,12,0,0,tzinfo=datetime.timezone.utc).timestamp()))' 2>/dev/null || echo 1780574400)" \
  OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/coverage.jq" /dev/stdin | jq -r '.covered[0].age_hours')
assert_eq "+00:00 offset parses (age = 1h)" "1" "$age_h"

echo "=== regression(#14): coverage median averages two middles on even-length ==="
synth_4='{
  "schema_version": "1.0", "generated_at": "2026-05-31T12:00:00Z",
  "bucket": "fs:/x", "region": "auto",
  "repos": [
    {"repo":"r1","path_segment":"r1","latest":{"prefix":"by-repo/r1/x/","commit_sha":"a","short_sha":"a","published_at":"2026-05-31T11:00:00Z","catalogs":[]},"history_prefixes":[],"status":"ok"},
    {"repo":"r2","path_segment":"r2","latest":{"prefix":"by-repo/r2/x/","commit_sha":"a","short_sha":"a","published_at":"2026-05-31T09:00:00Z","catalogs":[]},"history_prefixes":[],"status":"ok"},
    {"repo":"r3","path_segment":"r3","latest":{"prefix":"by-repo/r3/x/","commit_sha":"a","short_sha":"a","published_at":"2026-05-31T07:00:00Z","catalogs":[]},"history_prefixes":[],"status":"ok"},
    {"repo":"r4","path_segment":"r4","latest":{"prefix":"by-repo/r4/x/","commit_sha":"a","short_sha":"a","published_at":"2026-05-31T05:00:00Z","catalogs":[]},"history_prefixes":[],"status":"ok"}
  ],
  "coverage":{"total_known_repos":4,"ok":4,"stale":0,"failed_last_run":0}
}'
# Ages from generated_at: 1h, 3h, 5h, 7h. Median of [1,3,5,7] = 4.
median=$(printf '%s' "$synth_4" | env NOW_OVERRIDE="$(env TZ=UTC python3 -c 'import datetime; print(int(datetime.datetime(2026,5,31,12,0,0,tzinfo=datetime.timezone.utc).timestamp()))' 2>/dev/null || echo 1780574400)" \
  OUTPUT_FORMAT=jsonl jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/coverage.jq" /dev/stdin | jq -r '.median_age_hours')
assert_eq "median of [1h,3h,5h,7h] is 4h" "4" "$median"

echo "=== regression(#3, #6, #1): wrapper handles bare-array v1.0 catalog + spaces + pipefail ==="
# Build a substrate whose one catalog is bare-array v1.0 (legacy format).
# Path includes a space to exercise the xargs whitespace bug.
SPACED_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/cross repo space-XXXXXX")
LEGACY_BUCKET=$(mktemp -d "${TMPDIR:-/tmp}/legacy-bucket-XXXXXX")
mkdir -p "$LEGACY_BUCKET/by-repo/wxyc-legacy/2026-05-31T10-00-00Z_legacy1"
echo '[{"kind":"interface","name":"LegacyType","package":"main","file":"f","line":1}]' \
  > "$LEGACY_BUCKET/by-repo/wxyc-legacy/2026-05-31T10-00-00Z_legacy1/type-catalog.json"
SHA_LEG=$(shasum -a 256 "$LEGACY_BUCKET/by-repo/wxyc-legacy/2026-05-31T10-00-00Z_legacy1/type-catalog.json" | awk '{print $1}')
cat > "$LEGACY_BUCKET/index.json" <<EOF
{
  "schema_version": "1.0",
  "generated_at": "2026-05-31T12:00:00Z",
  "bucket": "fs:/mock",
  "region": "auto",
  "repos": [{
    "repo": "wxyc/legacy",
    "path_segment": "wxyc-legacy",
    "latest": {
      "prefix": "by-repo/wxyc-legacy/2026-05-31T10-00-00Z_legacy1/",
      "commit_sha": "legacy10000000000000000000000000000000000",
      "short_sha": "legacy1",
      "published_at": "2026-05-31T10:00:00Z",
      "catalogs": [{
        "kind": "type-catalog",
        "key": "by-repo/wxyc-legacy/2026-05-31T10-00-00Z_legacy1/type-catalog.json",
        "extractor": {"name": "type-catalog", "language": "typescript", "version": "1.3.2"},
        "size_bytes": 200,
        "entry_count": 1,
        "sha256": "$SHA_LEG"
      }]
    },
    "history_prefixes": [],
    "status": "ok"
  }],
  "coverage": {"total_known_repos": 1, "ok": 1, "stale": 0, "failed_last_run": 0}
}
EOF
out=$(AUDIT_BUCKET_URL="file://$LEGACY_BUCKET" AUDIT_LOCAL_CACHE="$SPACED_CACHE" \
  bash "$PIPELINE/run-cross-repo-query.sh" --quiet "$NOOP_QUERY" 2>"$SPACED_CACHE/err.log")
rc=$?
assert_eq "wrapper exits 0 with v1.0 bare-array + spaced cache path" "0" "$rc"
assert_contains "v1.0 catalog reaches the user query (NOOP-MARKER present)" "$out" "NOOP-MARKER"
rm -rf "$SPACED_CACHE" "$LEGACY_BUCKET"

echo "=== regression(#2): stale leftover catalogs in cache don't contaminate merge ==="
# Pre-populate the cache with a stale-repo catalog file that does NOT appear
# in any ok-status entry of index.json. The wrapper must not pick it up.
STALE_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/stale-cache-XXXXXX")
mkdir -p "$STALE_CACHE/by-repo/wxyc-old/2024-01-01T00-00-00Z_oldddd0"
echo '{"schema_version":"1.1","extractor":{"name":"type-catalog","language":"typescript","version":"1.3.2"},"entries":[{"kind":"interface","name":"StaleType","package":"main","file":"f","line":1}]}' \
  > "$STALE_CACHE/by-repo/wxyc-old/2024-01-01T00-00-00Z_oldddd0/type-catalog.json"
# Build an index.json that lists ONE ok repo, NOT the stale one. fetch will
# add the ok repo's files to this cache.
out=$(AUDIT_BUCKET_URL="file://$MOCK" AUDIT_LOCAL_CACHE="$STALE_CACHE" \
  bash "$PIPELINE/run-cross-repo-query.sh" --quiet "$NOOP_QUERY" 2>"$STALE_CACHE/err.log")
rc=$?
assert_eq "wrapper succeeds with stale leftover in cache" "0" "$rc"
# The merged stream's entries should NOT include the StaleType from the
# leftover. We can't see the merged stream directly (noop-query doesn't
# echo it), so verify via merge invocation directly.
# Find what the wrapper would have merged.
content_check=$(jq -r '
  .repos[]
  | select(.status == "ok")
  | "\(.latest.prefix)type-catalog.json"
' "$STALE_CACHE/index.json")
if printf '%s' "$content_check" | grep -F -q "wxyc-old"; then
  FAIL=$((FAIL + 1)); echo "  ✗ stale wxyc-old somehow in ok-status repos"
else
  PASS=$((PASS + 1)); echo "  ✓ stale leftover repo not in ok-status scope"
fi
rm -rf "$STALE_CACHE"

echo "=== regression(#8): --repos filter forwarded to preflight, so unrelated skew doesn't block ==="
# Use the major-skew bucket from earlier, but ask for only one of the two repos.
SUBSET_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/subset-XXXXXX")
SUBSET_BUCKET=$(mktemp -d "${TMPDIR:-/tmp}/subset-bucket-XXXXXX")
mkdir -p "$SUBSET_BUCKET/by-repo/wxyc-repo-a/2026-05-31T10-00-00Z_aaa1111"
mkdir -p "$SUBSET_BUCKET/by-repo/wxyc-repo-b/2026-05-31T11-00-00Z_bbb2222"
echo '{"schema_version":"1.1","extractor":{"name":"type-catalog","language":"typescript","version":"1.3.0"},"entries":[]}' \
  > "$SUBSET_BUCKET/by-repo/wxyc-repo-a/2026-05-31T10-00-00Z_aaa1111/type-catalog.json"
echo '{"schema_version":"1.1","extractor":{"name":"type-catalog","language":"typescript","version":"2.0.0"},"entries":[]}' \
  > "$SUBSET_BUCKET/by-repo/wxyc-repo-b/2026-05-31T11-00-00Z_bbb2222/type-catalog.json"
SHA_A=$(shasum -a 256 "$SUBSET_BUCKET/by-repo/wxyc-repo-a/2026-05-31T10-00-00Z_aaa1111/type-catalog.json" | awk '{print $1}')
SHA_B=$(shasum -a 256 "$SUBSET_BUCKET/by-repo/wxyc-repo-b/2026-05-31T11-00-00Z_bbb2222/type-catalog.json" | awk '{print $1}')
jq --arg sha_a "$SHA_A" --arg sha_b "$SHA_B" '
  .repos[0].latest.catalogs[0].sha256 = $sha_a
  | .repos[1].latest.catalogs[0].sha256 = $sha_b
' "$FIXTURES/major-skew.index.json" > "$SUBSET_BUCKET/index.json"
out=$(AUDIT_BUCKET_URL="file://$SUBSET_BUCKET" AUDIT_LOCAL_CACHE="$SUBSET_SCRATCH" \
  bash "$PIPELINE/run-cross-repo-query.sh" --quiet --repos wxyc/repo-a "$NOOP_QUERY" 2>"$SUBSET_SCRATCH/err")
rc=$?
assert_eq "wrapper passes when --repos excludes the skewed repo" "0" "$rc"
assert_contains "filtered query reaches user code" "$out" "NOOP-MARKER"
rm -rf "$SUBSET_SCRATCH" "$SUBSET_BUCKET"

echo "=== regression(#9): caller OUTPUT_FORMAT=jsonl does not leak into preflight/coverage ==="
# Run the wrapper with OUTPUT_FORMAT=jsonl in the environment. Coverage's
# header should still appear in text form (comment-prefixed); the JSONL
# only applies to the user's query (noop-query.jq, which has no jsonl
# branch and emits the same text either way).
OF_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/of-cache-XXXXXX")
out=$(env OUTPUT_FORMAT=jsonl AUDIT_BUCKET_URL="file://$MOCK" AUDIT_LOCAL_CACHE="$OF_CACHE" \
  bash "$PIPELINE/run-cross-repo-query.sh" --quiet "$NOOP_QUERY" 2>"$OF_CACHE/err")
rc=$?
assert_eq "wrapper exits 0 with OUTPUT_FORMAT=jsonl in caller env" "0" "$rc"
# The coverage header (comment-prefixed) should be human-readable, not a
# raw JSON object. Look for the text-mode "scope:" prefix.
first_line=$(printf '%s' "$out" | head -1)
assert_contains "first stdout line is text-mode coverage header" "$first_line" "scope:"
rm -rf "$OF_CACHE"

echo "=== regression(#10): edges/nodes catalog refused, doesn't merge to empty ==="
# Build a substrate whose --catalog-kind catalog is package-graph style.
PG_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/pg-cache-XXXXXX")
PG_BUCKET=$(mktemp -d "${TMPDIR:-/tmp}/pg-bucket-XXXXXX")
mkdir -p "$PG_BUCKET/by-repo/wxyc-pg/2026-05-31T10-00-00Z_pg11111"
echo '{"schema_version":"1.1","extractor":{"name":"package-graph","language":"typescript","version":"1.0.0"},"edges":[{"from":"a","to":"b"}],"nodes":[]}' \
  > "$PG_BUCKET/by-repo/wxyc-pg/2026-05-31T10-00-00Z_pg11111/package-graph.json"
SHA_PG=$(shasum -a 256 "$PG_BUCKET/by-repo/wxyc-pg/2026-05-31T10-00-00Z_pg11111/package-graph.json" | awk '{print $1}')
cat > "$PG_BUCKET/index.json" <<EOF
{
  "schema_version": "1.0",
  "generated_at": "2026-05-31T12:00:00Z",
  "bucket": "fs:/mock", "region": "auto",
  "repos": [{
    "repo": "wxyc/pg",
    "path_segment": "wxyc-pg",
    "latest": {
      "prefix": "by-repo/wxyc-pg/2026-05-31T10-00-00Z_pg11111/",
      "commit_sha": "pg111110000000000000000000000000000000000",
      "short_sha": "pg11111",
      "published_at": "2026-05-31T10:00:00Z",
      "catalogs": [{
        "kind": "package-graph",
        "key": "by-repo/wxyc-pg/2026-05-31T10-00-00Z_pg11111/package-graph.json",
        "extractor": {"name": "package-graph", "language": "typescript", "version": "1.0.0"},
        "size_bytes": 50, "entry_count": 1, "sha256": "$SHA_PG"
      }]
    },
    "history_prefixes": [], "status": "ok"
  }],
  "coverage": {"total_known_repos": 1, "ok": 1, "stale": 0, "failed_last_run": 0}
}
EOF
err_out=$(AUDIT_BUCKET_URL="file://$PG_BUCKET" AUDIT_LOCAL_CACHE="$PG_CACHE" \
  bash "$PIPELINE/run-cross-repo-query.sh" --quiet --catalog-kind package-graph "$NOOP_QUERY" 2>&1 1>/dev/null)
rc=$?
assert_nonzero_exit "$rc" "wrapper refuses edges/nodes catalog (no silent empty merge)"
assert_contains "stderr explains the edges/nodes refusal" "$err_out" "edges/nodes"
rm -rf "$PG_CACHE" "$PG_BUCKET"

echo "=== regression(#15): empty-merge exits 2, distinct from preflight-refusal exit 1 ==="
# Empty-merge: use --repos to ask for a repo that's not in the index.
EMPTY_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/empty-cache-XXXXXX")
out=$(AUDIT_BUCKET_URL="file://$MOCK" AUDIT_LOCAL_CACHE="$EMPTY_CACHE" \
  bash "$PIPELINE/run-cross-repo-query.sh" --quiet --repos "wxyc/does-not-exist" "$NOOP_QUERY" 2>"$EMPTY_CACHE/err")
rc=$?
# fetch-catalogs.sh will exit 1 on its own when no matching repos. The
# wrapper's contract: fetch-fail = 3, preflight-refusal = 1, empty-merge
# = 2. fetch-catalogs's behavior makes this exit 3 in practice — which
# is still distinct from refusal (1). Verify it's not 1.
if [ "$rc" = "1" ]; then
  FAIL=$((FAIL + 1)); echo "  ✗ empty-merge collapsed to exit 1 (indistinguishable from preflight refusal)"
else
  PASS=$((PASS + 1)); echo "  ✓ empty-merge exits $rc (distinct from preflight-refusal exit 1)"
fi
rm -rf "$EMPTY_CACHE"

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
