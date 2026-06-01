#!/usr/bin/env bash
# run-cross-repo-query.sh — the standard wrapper for invoking a cross-repo
# query against the substrate. Enforces the three guardrails from #155:
#
#   1. Fetch — pulls index.json + per-repo catalogs into the local cache via
#      fetch-catalogs.sh. Skipped with --skip-fetch (caller is responsible
#      for keeping the cache fresh).
#   2. Preflight — runs preflight-versions.jq against index.json. Refuses
#      on major-version skew or missing/malformed extractor blocks.
#   3. Coverage — runs coverage.jq against index.json. Captures stdout and
#      prepends it to the query output so the consumer can always see the
#      scope the report ran over.
#   4. Query — merges every catalog of $CROSS_REPO_CATALOG_KIND across the
#      cache and pipes through the user's query.
#
# The wrapper exists because the brief's safety net is *enforced*: a query
# author cannot forget to call preflight or coverage. Every cross-repo
# query goes through this script.
#
# Usage:
#   pipeline/run-cross-repo-query.sh [flags] <query.jq> [-- jq-args...]
#
# Flags:
#   --bucket-url URL    Overrides AUDIT_BUCKET_URL.
#   --cache-dir DIR     Overrides AUDIT_LOCAL_CACHE.
#   --repos a,b,c       Pass through to fetch-catalogs.sh.
#   --catalog-kind K    Catalog kind to merge for the query (default
#                       $CROSS_REPO_CATALOG_KIND or `type-catalog`).
#                       Per-query override.
#   --skip-fetch        Trust the existing cache; don't re-fetch.
#   --quiet             Suppress per-step progress lines on stderr.
#   -h, --help          Show this help.
#
# Env (when flags omitted):
#   AUDIT_BUCKET_URL          required unless --skip-fetch and cache populated.
#   AUDIT_LOCAL_CACHE         defaults to /tmp/wxyc-audit/catalogs.
#   CROSS_REPO_CATALOG_KIND   defaults to type-catalog.
#   CROSS_REPO_STALE_DAYS     stale threshold; default 7. Read by
#                             coverage.jq and preflight-versions.jq.
#
# Exit:
#   0 — preflight passed (clean or minor-skew), query ran successfully.
#   1 — preflight refused, no available repos, or other fatal error.
#   2 — argument error.
#   Any other code propagates from the user's query.

set -eu

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

bucket_url="${AUDIT_BUCKET_URL:-}"
cache_dir="${AUDIT_LOCAL_CACHE:-/tmp/wxyc-audit/catalogs}"
repos_filter=""
catalog_kind="${CROSS_REPO_CATALOG_KIND:-type-catalog}"
skip_fetch=0
quiet=0
query=""
jq_extra_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --bucket-url)    bucket_url="$2"; shift 2 ;;
    --cache-dir)     cache_dir="$2"; shift 2 ;;
    --repos)         repos_filter="$2"; shift 2 ;;
    --catalog-kind)  catalog_kind="$2"; shift 2 ;;
    --skip-fetch)    skip_fetch=1; shift ;;
    --quiet)         quiet=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; jq_extra_args=("$@"); break ;;
    -*)
      echo "run-cross-repo-query.sh: unknown flag: $1" >&2; usage; exit 2 ;;
    *)
      if [ -z "$query" ]; then query="$1"; shift
      else
        echo "run-cross-repo-query.sh: extra positional after query: $1 (use -- to pass jq args)" >&2
        exit 2
      fi ;;
  esac
done

if [ -z "$query" ]; then
  echo "run-cross-repo-query.sh: missing <query.jq> argument" >&2
  usage
  exit 2
fi
if [ ! -f "$query" ]; then
  echo "run-cross-repo-query.sh: query not found: $query" >&2
  exit 2
fi

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
QUERIES_DIR="$THIS_DIR/queries"

log() { if [ "$quiet" -eq 0 ]; then echo "$@" >&2; fi }

# ---- 1) Fetch (unless --skip-fetch) -----------------------------------------

if [ "$skip_fetch" -eq 0 ]; then
  if [ -z "$bucket_url" ]; then
    echo "run-cross-repo-query.sh: AUDIT_BUCKET_URL is required (set via env or --bucket-url; or pass --skip-fetch)" >&2
    exit 1
  fi
  log "[1/4] Fetching catalogs..."
  fetch_args=(--bucket-url "$bucket_url" --cache-dir "$cache_dir")
  if [ -n "$repos_filter" ]; then fetch_args+=(--repos "$repos_filter"); fi
  if [ "$quiet" -eq 1 ]; then fetch_args+=(--quiet); fi
  if ! bash "$THIS_DIR/fetch-catalogs.sh" "${fetch_args[@]}" >&2; then
    echo "run-cross-repo-query.sh: fetch-catalogs.sh failed; cannot proceed" >&2
    exit 1
  fi
else
  log "[1/4] Skipping fetch (--skip-fetch)"
fi

index_path="$cache_dir/index.json"
if [ ! -f "$index_path" ]; then
  echo "run-cross-repo-query.sh: no index.json in cache ($index_path); cannot run preflight or coverage" >&2
  exit 1
fi

# ---- 2) Preflight -----------------------------------------------------------

log "[2/4] Running preflight-versions.jq..."
# Run preflight in text mode so its summary is human-readable for the
# operator on stderr; the wrapper inspects its exit code (1 = refused).
preflight_log=$(mktemp "${TMPDIR:-/tmp}/cross-repo-preflight.XXXXXX")
trap 'rm -f "$preflight_log"' EXIT
if ! jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/preflight-versions.jq" "$index_path" > "$preflight_log" 2>&1; then
  cat "$preflight_log" >&2
  echo "run-cross-repo-query.sh: preflight refused; aborting (catalogs at incompatible major versions or missing extractor metadata)" >&2
  exit 1
fi
# On pass, only surface the preflight summary when not quiet.
if [ "$quiet" -eq 0 ]; then
  cat "$preflight_log" >&2
fi

# ---- 3) Coverage ------------------------------------------------------------

log "[3/4] Computing coverage header..."
coverage_header=$(jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/coverage.jq" "$index_path")
coverage_rc=$?
if [ "$coverage_rc" -ne 0 ]; then
  echo "run-cross-repo-query.sh: coverage.jq exited $coverage_rc; aborting" >&2
  exit 1
fi

# ---- 4) Query ---------------------------------------------------------------

log "[4/4] Merging $catalog_kind catalogs and running query..."
# Discover the relevant catalog files in the cache. Layout:
#   $cache_dir/by-repo/<seg>/<ts>_<sha>/<kind>.json
catalog_files=$(find "$cache_dir/by-repo" -mindepth 3 -maxdepth 3 -type f -name "${catalog_kind}.json" 2>/dev/null | sort)

if [ -z "$catalog_files" ]; then
  echo "run-cross-repo-query.sh: no $catalog_kind.json files found in $cache_dir/by-repo (cache empty or wrong --catalog-kind?)" >&2
  exit 1
fi

# Prepend the coverage header so the query's consumer can read scope at a
# glance. Header is comment-prefixed so consumers that ingest the rest as
# JSONL can drop comment lines with a `grep -v '^# '`.
printf '# %s\n' "$coverage_header" | sed 's/$//' | awk 'NR==1{print; next} {print "# " $0}' | sed 's/^# # /# /'
# (the awk pipe re-applies the comment prefix to wrapped lines split by \n
# inside coverage's stdout)

# Merge all catalogs into one stream, then pipe into the query.
# jq -s 'map(.entries // []) | add' yields the flat entries array; the
# user's query then operates on that with the same `entries` helper as
# single-repo invocations.
# shellcheck disable=SC2086
echo "$catalog_files" | xargs jq -s 'map(.entries // []) | add | {schema_version: "1.1", extractor: {name: "merged", language: "cross-repo", version: "1.0.0"}, entries: .}' \
  | jq -L "$QUERIES_DIR" -rf "$query" "${jq_extra_args[@]+"${jq_extra_args[@]}"}"

exit 0
