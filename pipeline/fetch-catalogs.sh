#!/usr/bin/env bash
# fetch-catalogs.sh — pull every per-repo catalog from the cross-repo substrate
# into a local cache, suitable for `jq` merge.
#
# Read-side counterpart to publish-catalog.sh. Honors:
#   AUDIT_BUCKET_URL  required. http(s)://host/prefix OR file:///abs/path
#                     pointing at the bucket root that contains index.json.
#   AUDIT_LOCAL_CACHE optional. Defaults to /tmp/wxyc-audit/catalogs.
#
# CLI flags override the env:
#   --bucket-url URL   AUDIT_BUCKET_URL override
#   --cache-dir DIR    AUDIT_LOCAL_CACHE override
#   --repos a,b,c      restrict to a subset of repos (matches index.json's
#                      "repo" field). Default: every status=="ok" repo.
#   --quiet            suppress per-repo progress lines (summary only)
#   -h, --help         print usage
#
# Algorithm (see docs/substrate.md):
#   1. GET index.json
#   2. For each ok repo (optionally filtered): for each catalog under
#      latest.catalogs[], compare the index's sha256 against the on-disk
#      sha256. Skip if equal (warm cache); fetch + sha-verify otherwise.
#   3. Atomic rename (.tmp -> final) so partial writes don't pollute the
#      cache for a concurrent fetcher.
#   4. Summary on stderr; exit 0 iff at least one repo is now present in
#      the cache (warm or freshly fetched).
#
# Exit codes:
#   0  at least one repo's catalogs are present in the cache after the run
#   1  zero repos available, OR a fatal error (missing url, malformed index,
#      sha mismatch that didn't recover)

set -eu

usage() {
  cat >&2 <<'EOF'
usage: fetch-catalogs.sh [--bucket-url URL] [--cache-dir DIR] [--repos a,b,c] [--quiet]

Env (when flags omitted):
  AUDIT_BUCKET_URL   required. http(s)://host/prefix or file:///abs/path
  AUDIT_LOCAL_CACHE  defaults to /tmp/wxyc-audit/catalogs
EOF
}

bucket_url="${AUDIT_BUCKET_URL:-}"
cache_dir="${AUDIT_LOCAL_CACHE:-/tmp/wxyc-audit/catalogs}"
repos_filter=""
quiet=0

while [ $# -gt 0 ]; do
  case "$1" in
    --bucket-url) bucket_url="$2"; shift 2 ;;
    --cache-dir)  cache_dir="$2";  shift 2 ;;
    --repos)      repos_filter="$2"; shift 2 ;;
    --quiet)      quiet=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "fetch-catalogs.sh: unknown flag: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$bucket_url" ]; then
  echo "fetch-catalogs.sh: AUDIT_BUCKET_URL is required (set via env or --bucket-url)" >&2
  exit 1
fi

# Trim a trailing slash so we can splice "/key" without doubling up.
bucket_url="${bucket_url%/}"

log() {
  if [ "$quiet" -eq 0 ]; then echo "$@" >&2; fi
}

# `get_object SRC DEST` — fetch SRC into DEST atomically. Supports http(s)
# via curl (-fsSL: fail-fast, silent, follow-redirects, location-aware) and
# file:// via cp. Atomic rename via .tmp suffix.
get_object() {
  src="$1"; dest="$2"
  mkdir -p "$(dirname "$dest")"
  tmp="${dest}.tmp.$$"
  case "$src" in
    file://*)
      cp "${src#file://}" "$tmp"
      ;;
    http://*|https://*)
      curl -fsSL --max-time 30 -o "$tmp" "$src"
      ;;
    *)
      echo "fetch-catalogs.sh: unsupported url scheme: $src" >&2
      return 1
      ;;
  esac
  mv "$tmp" "$dest"
}

# `sha256_of FILE` — print the hex sha256 of FILE. Falls back across
# shasum (macOS, BSD) and sha256sum (Linux).
sha256_of() {
  f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo "fetch-catalogs.sh: need shasum or sha256sum on PATH" >&2
    return 1
  fi
}

# Fetch + parse the index.
mkdir -p "$cache_dir"
index_dest="$cache_dir/index.json"
log "[1/3] Fetching index.json from $bucket_url"
get_object "$bucket_url/index.json" "$index_dest" \
  || { echo "fetch-catalogs.sh: failed to fetch index.json from $bucket_url" >&2; exit 1; }

if ! jq -e . "$index_dest" >/dev/null 2>&1; then
  echo "fetch-catalogs.sh: malformed index.json at $index_dest" >&2
  exit 1
fi
if ! jq -e '.schema_version == "1.0" and (.repos | type == "array")' "$index_dest" >/dev/null 2>&1; then
  echo "fetch-catalogs.sh: index.json missing required schema_version=\"1.0\" / repos[] fields" >&2
  exit 1
fi

# Build the work list: one line per (repo, key, sha256), filtered by
# --repos when set. Stale repos (status != "ok") are skipped silently.
work_list=$(
  if [ -n "$repos_filter" ]; then
    # Comma-separated → jq array.
    repos_json=$(printf '%s' "$repos_filter" | jq -Rsc 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
    jq -r --argjson keep "$repos_json" '
      .repos[]
      | select(.status == "ok" and (.repo as $r | $keep | index($r)))
      | .repo as $repo
      | .latest.catalogs[]
      | [$repo, .key, .sha256] | @tsv
    ' "$index_dest"
  else
    jq -r '
      .repos[]
      | select(.status == "ok")
      | .repo as $repo
      | .latest.catalogs[]
      | [$repo, .key, .sha256] | @tsv
    ' "$index_dest"
  fi
)

if [ -z "$work_list" ]; then
  echo "fetch-catalogs.sh: no ok repos to fetch (filter or empty index)" >&2
  exit 1
fi

# Iterate the work list. Per-line: repo<TAB>key<TAB>sha256.
new_count=0
cached_count=0
fail_count=0
# Only repos with at least one cached-or-fetched catalog count as "present
# in cache." A repo whose every catalog fails to fetch does NOT count —
# otherwise the script would exit 0 with an empty cache and downstream
# `jq -s 'map(.entries) | add' */latest.json` would silently produce zero
# results.
present_repos_file="$cache_dir/.fetch-present-repos.tmp"
: > "$present_repos_file"

log "[2/3] Fetching catalog objects from $bucket_url"

while IFS=$'\t' read -r repo key expected_sha; do
  dest="$cache_dir/$key"
  if [ -f "$dest" ]; then
    actual_sha=$(sha256_of "$dest")
    if [ "$actual_sha" = "$expected_sha" ]; then
      log "  cached  $repo  $(basename "$key")"
      cached_count=$((cached_count + 1))
      echo "$repo" >> "$present_repos_file"
      continue
    fi
  fi
  if get_object "$bucket_url/$key" "$dest" 2>/dev/null; then
    actual_sha=$(sha256_of "$dest")
    if [ "$actual_sha" = "$expected_sha" ]; then
      log "  fetched $repo  $(basename "$key")"
      new_count=$((new_count + 1))
      echo "$repo" >> "$present_repos_file"
    else
      echo "  SHA MISMATCH $repo  $(basename "$key"): index=$expected_sha actual=$actual_sha" >&2
      rm -f "$dest"
      fail_count=$((fail_count + 1))
    fi
  else
    echo "  FAIL    $repo  $(basename "$key")" >&2
    fail_count=$((fail_count + 1))
  fi
done <<EOF
$work_list
EOF

present_repos=$(sort -u "$present_repos_file" | wc -l | tr -d ' ')
rm -f "$present_repos_file"

log "[3/3] Summary: $present_repos repos present / $new_count fetched / $cached_count cached / $fail_count failed"
log "Cache: $cache_dir"

if [ "$present_repos" -eq 0 ]; then
  exit 1
fi
exit 0
