#!/usr/bin/env bash
# run-cross-repo-query.sh — the standard wrapper for invoking a cross-repo
# query against the substrate. Enforces the three guardrails from #155:
#
#   1. Fetch — pulls index.json + per-repo catalogs into the local cache via
#      fetch-catalogs.sh. Skipped with --skip-fetch (caller is responsible
#      for keeping the cache fresh).
#   2. Preflight — runs preflight-versions.jq against index.json (filtered
#      by --repos, if set). Refuses on major-version skew or
#      missing/malformed extractor blocks.
#   3. Coverage — runs coverage.jq against the same filtered index.json.
#      Captures stdout and prepends it (comment-prefixed) to the query
#      output so the consumer can always see the scope the report ran over.
#   4. Query — merges every ok-status catalog of $CROSS_REPO_CATALOG_KIND
#      and pipes through the user's query.
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
#   --repos a,b,c       Restrict to a subset of repos (matches index.json's
#                       "repo" field). Forwarded to fetch-catalogs and used
#                       to filter the index for preflight + coverage.
#   --catalog-kind K    Catalog kind to merge for the query (default
#                       $CROSS_REPO_CATALOG_KIND or `type-catalog`).
#   --skip-fetch        Trust the existing cache; don't re-fetch.
#   --quiet             Suppress per-step progress lines on stderr.
#   -h, --help          Show this help.
#
# Env (when flags omitted):
#   AUDIT_BUCKET_URL          required unless --skip-fetch and cache populated.
#   AUDIT_LOCAL_CACHE         defaults to /tmp/wxyc-audit/catalogs.
#   CROSS_REPO_CATALOG_KIND   defaults to type-catalog. Currently the
#                             wrapper merges only entries-shaped catalogs;
#                             package-graph (edges/nodes) is refused.
#   CROSS_REPO_STALE_DAYS     stale threshold; default 7. Read by
#                             coverage.jq and preflight-versions.jq.
#
# Exit:
#   0 — preflight passed (clean or minor-skew), query ran successfully.
#   1 — preflight refused; merge unsafe at any cost.
#   2 — argument error, or empty merge set (no ok-status repos in scope).
#   3 — fetch failed, no index.json available, or another fatal substrate
#       error before the query can run.
#   Other codes propagate from the user's query (anything > 3).

# -E so trap inherits into command substitutions; pipefail so an upstream
# merge crash doesn't get masked by a no-op downstream query. -u so
# unset-variable bugs surface during dev.
set -Eeuo pipefail

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

# Force preflight + coverage into text mode regardless of caller env: the
# wrapper's text-formatting pipeline assumes multi-line text, not the
# JSONL envelope a `OUTPUT_FORMAT=jsonl` caller would otherwise inherit.
INTERNAL_JQ_ENV=(env OUTPUT_FORMAT=text)

log() { if [ "$quiet" -eq 0 ]; then echo "$@" >&2; fi }

# Scratch dir for filtered index + tempfiles, cleaned on EXIT.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cross-repo.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

# ---- 1) Fetch (unless --skip-fetch) -----------------------------------------

if [ "$skip_fetch" -eq 0 ]; then
  if [ -z "$bucket_url" ]; then
    echo "run-cross-repo-query.sh: AUDIT_BUCKET_URL is required (set via env or --bucket-url; or pass --skip-fetch)" >&2
    exit 3
  fi
  log "[1/4] Fetching catalogs..."
  fetch_args=(--bucket-url "$bucket_url" --cache-dir "$cache_dir")
  if [ -n "$repos_filter" ]; then fetch_args+=(--repos "$repos_filter"); fi
  if [ "$quiet" -eq 1 ]; then fetch_args+=(--quiet); fi
  if ! bash "$THIS_DIR/fetch-catalogs.sh" "${fetch_args[@]}" >&2; then
    echo "run-cross-repo-query.sh: fetch-catalogs.sh failed; cannot proceed" >&2
    exit 3
  fi
else
  log "[1/4] Skipping fetch (--skip-fetch)"
fi

index_path_raw="$cache_dir/index.json"
if [ ! -f "$index_path_raw" ]; then
  echo "run-cross-repo-query.sh: no index.json in cache ($index_path_raw); cannot run preflight or coverage" >&2
  exit 3
fi

# Produce a `--repos`-filtered view of index.json so preflight/coverage
# see only the repos the caller asked for. Without this, version skew in
# unrelated repos (or stale unrelated repos) would block a subset query.
index_path="$SCRATCH/filtered-index.json"
if [ -n "$repos_filter" ]; then
  filter_json=$(printf '%s' "$repos_filter" | jq -Rsc 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
  jq --argjson keep "$filter_json" '
    .repos = (.repos | map(select(.repo as $r | $keep | index($r))))
  ' "$index_path_raw" > "$index_path"
else
  cp "$index_path_raw" "$index_path"
fi

# ---- 2) Preflight -----------------------------------------------------------

log "[2/4] Running preflight-versions.jq..."
preflight_log="$SCRATCH/preflight.log"
# Capture preflight's stdout+stderr; inspect exit code without `set -e`
# aborting the script before we get to the diagnostic.
if "${INTERNAL_JQ_ENV[@]}" jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/preflight-versions.jq" "$index_path" > "$preflight_log" 2>&1; then
  preflight_rc=0
else
  preflight_rc=$?
fi
if [ "$preflight_rc" -ne 0 ]; then
  cat "$preflight_log" >&2
  echo "run-cross-repo-query.sh: preflight refused (rc=$preflight_rc); aborting — catalogs at incompatible major versions or missing extractor metadata" >&2
  exit 1
fi
# On pass, only surface the preflight summary when not quiet.
if [ "$quiet" -eq 0 ]; then
  cat "$preflight_log" >&2
fi

# ---- 3) Coverage ------------------------------------------------------------

log "[3/4] Computing coverage header..."
# Pass wall-clock UTC as the staleness reference so the report reflects
# real time, not the index's `generated_at` (which can lag arbitrarily).
now_epoch=$(date -u +%s)
coverage_header_file="$SCRATCH/coverage.txt"
if "${INTERNAL_JQ_ENV[@]}" NOW_OVERRIDE="$now_epoch" jq -L "$QUERIES_DIR" -rf "$QUERIES_DIR/coverage.jq" "$index_path" > "$coverage_header_file" 2> "$SCRATCH/coverage.err"; then
  coverage_rc=0
else
  coverage_rc=$?
fi
if [ "$coverage_rc" -ne 0 ]; then
  cat "$SCRATCH/coverage.err" >&2
  echo "run-cross-repo-query.sh: coverage.jq exited $coverage_rc; aborting" >&2
  exit 3
fi

# ---- 4) Query ---------------------------------------------------------------

log "[4/4] Merging $catalog_kind catalogs and running query..."

# Determine the set of ok-status repo prefixes from the *filtered* index.
# We do NOT trust the cache layout blindly: stale leftover files from
# earlier fetches must not contaminate the merge. The index is the
# source of truth for what's in scope.
catalog_files_list="$SCRATCH/catalog-files.txt"
jq -r --arg kind "$catalog_kind" '
  .repos[]
  | select(.status == "ok" and .latest != null and (.latest.prefix // null) != null)
  | "\(.latest.prefix)\($kind).json"
' "$index_path" > "$catalog_files_list"

# Materialize each prefix into an absolute path inside the cache;
# tolerate missing files by skipping them with a stderr warning.
catalog_paths=()
missing_after_fetch=()
while IFS= read -r rel; do
  if [ -z "$rel" ]; then continue; fi
  abs="$cache_dir/$rel"
  if [ -f "$abs" ]; then
    catalog_paths+=("$abs")
  else
    missing_after_fetch+=("$rel")
  fi
done < "$catalog_files_list"

if [ "${#missing_after_fetch[@]}" -gt 0 ]; then
  echo "run-cross-repo-query.sh: WARNING ${#missing_after_fetch[@]} catalog(s) referenced by index.json are not in the cache (skipped):" >&2
  for m in "${missing_after_fetch[@]}"; do echo "  $m" >&2; done
fi

if [ "${#catalog_paths[@]}" -eq 0 ]; then
  echo "run-cross-repo-query.sh: no ok-status $catalog_kind.json files in scope (cache empty, filter excluded all, or wrong --catalog-kind?)" >&2
  exit 2
fi

# Reject catalog kinds the merge logic can't faithfully represent. Today
# the wrapper merges only `.entries`-shaped catalogs; an edges/nodes
# catalog (e.g. package-graph) would silently merge to an empty stream.
# Sniff the first catalog's top-level shape and refuse before any query
# author writes against bogus output.
first_catalog="${catalog_paths[0]}"
shape=$(jq -r '
  if type == "array" then "array-v1.0"
  elif has("entries") then "entries"
  elif has("edges") or has("nodes") then "edges-nodes"
  else "unknown"
  end
' "$first_catalog")
if [ "$shape" = "edges-nodes" ]; then
  echo "run-cross-repo-query.sh: $catalog_kind catalogs have edges/nodes shape, which the cross-repo merge does not yet support. Refusing rather than silently producing empty results. (First sample: $first_catalog)" >&2
  exit 2
fi

# Prepend the coverage header as comment-prefixed lines so consumers can
# strip them with `grep -v '^#'`. We do this *after* the empty-merge
# check so an empty scope exits cleanly with no spurious banner.
while IFS= read -r line; do
  echo "# $line"
done < "$coverage_header_file"

# Merge polymorphically: bare-array v1.0 catalogs unwrap into `.entries`;
# wrapped v1.1 catalogs project `.entries`. Any other shape contributes
# an empty array (kept defensively even though the pre-check above
# refuses edges/nodes — a future mixed-shape merge can extend the rule).
# The merged synthetic catalog mirrors the v1.1 wrapper so downstream
# queries' `entries` helper works unchanged.
#
# Building the jq command with an array preserves quoting through paths
# with spaces; `xargs` cannot do that without -0 plus find -print0,
# which complicates the index-driven file list above.
merge_filter='
  map(if type == "array" then . else (.entries // []) end)
  | add
  | { schema_version: "1.1",
      extractor: { name: "merged", language: "cross-repo", version: "1.0.0" },
      entries: . }
'
jq -s "$merge_filter" "${catalog_paths[@]}" \
  | jq -L "$QUERIES_DIR" -rf "$query" "${jq_extra_args[@]+"${jq_extra_args[@]}"}"

exit 0
