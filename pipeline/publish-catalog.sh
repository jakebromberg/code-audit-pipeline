#!/usr/bin/env bash
# publish-catalog.sh — CI-side write path for the cross-repo substrate.
#
# Given a local directory of catalog files for one (repo, commit_sha) pair,
# uploads each catalog under
#   by-repo/<flattened-repo>/<iso-utc>_<short-sha>/<filename>
# writes the per-repo `latest.json` pointer, and triggers index.json refresh
# via refresh-index.mjs.
#
# Required inputs:
#   --repo NAME            canonical "owner/name" (e.g. wxyc/dj-site)
#   --sha SHA              full git commit sha (>= 7 chars)
#   --catalogs-dir DIR     directory of *.json catalog files to publish
#   --bucket-name NAME     S3-API bucket name (or AUDIT_BUCKET env)
#   --bucket-endpoint URL  S3-API endpoint (or AUDIT_ENDPOINT env);
#                          for R2: https://<account>.r2.cloudflarestorage.com
#
# Optional:
#   --bucket-fs DIR        Local filesystem mode (tests / dev). When set,
#                          --bucket-name / --bucket-endpoint are ignored and
#                          the script writes into DIR via cp.
#   --skip-refresh         Don't invoke refresh-index.mjs after publish
#                          (useful in tests; production callers should let it run).
#
# Validation: each catalog file must match the v1.1 wrapper shape
# (`{schema_version, extractor, entries|edges|nodes}`). Bare-array catalogs
# are refused.
#
# Exit:
#   0  every catalog uploaded + latest.json written + index refreshed
#   1  validation failure or upload error

set -eu

# Sweep our pid-scoped tempfiles on any exit (success, validation failure,
# upload error, signal). Without this an `set -eu` early-exit inside any of
# the later stages would leak `/tmp/publish-catalog-*.$$.*` files.
trap 'rm -f /tmp/publish-catalog-*.$$.* /tmp/publish-catalog-*.$$' EXIT

usage() {
  cat >&2 <<'EOF'
usage: publish-catalog.sh --repo NAME --sha SHA --catalogs-dir DIR
                          (--bucket-fs DIR | --bucket-name NAME --bucket-endpoint URL)
                          [--skip-refresh]
EOF
}

repo=""
sha=""
catalogs_dir=""
bucket_name="${AUDIT_BUCKET:-}"
bucket_endpoint="${AUDIT_ENDPOINT:-}"
bucket_fs=""
skip_refresh=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)            repo="$2"; shift 2 ;;
    --sha)             sha="$2"; shift 2 ;;
    --catalogs-dir)    catalogs_dir="$2"; shift 2 ;;
    --bucket-name)     bucket_name="$2"; shift 2 ;;
    --bucket-endpoint) bucket_endpoint="$2"; shift 2 ;;
    --bucket-fs)       bucket_fs="$2"; shift 2 ;;
    --skip-refresh)    skip_refresh=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "publish-catalog.sh: unknown flag: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$repo" ] || [ -z "$sha" ] || [ -z "$catalogs_dir" ]; then
  echo "publish-catalog.sh: --repo, --sha, --catalogs-dir all required" >&2
  usage; exit 1
fi
if [ -z "$bucket_fs" ] && { [ -z "$bucket_name" ] || [ -z "$bucket_endpoint" ]; }; then
  echo "publish-catalog.sh: need --bucket-fs DIR OR (--bucket-name + --bucket-endpoint)" >&2
  exit 1
fi
if [ ! -d "$catalogs_dir" ]; then
  echo "publish-catalog.sh: catalogs-dir not a directory: $catalogs_dir" >&2
  exit 1
fi
if [ "${#sha}" -lt 7 ]; then
  echo "publish-catalog.sh: --sha must be >= 7 chars: $sha" >&2
  exit 1
fi

short_sha="${sha:0:7}"
path_segment=$(printf '%s' "$repo" | tr '/' '-')
timestamp=$(date -u +'%Y-%m-%dT%H-%M-%SZ')
prefix="by-repo/${path_segment}/${timestamp}_${short_sha}"

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"

# sha256 helper (same fallback chain as fetch-catalogs.sh).
sha256_of() {
  f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo "publish-catalog.sh: need shasum or sha256sum on PATH" >&2; return 1
  fi
}

# Upload one file. Backend-aware.
upload() {
  src="$1"; key="$2"
  if [ -n "$bucket_fs" ]; then
    dest="$bucket_fs/$key"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
  else
    aws --endpoint-url "$bucket_endpoint" s3 cp "$src" "s3://${bucket_name}/${key}" \
      --content-type application/json >/dev/null
  fi
}

# Use POSIX glob via find rather than bash's nullglob extension for
# portability across bash 3.x (macOS default).
catalog_files=$(find "$catalogs_dir" -maxdepth 1 -type f -name '*.json' | sort)

if [ -z "$catalog_files" ]; then
  echo "publish-catalog.sh: no *.json files under $catalogs_dir" >&2
  exit 1
fi

echo "[1/4] Validating every catalog before any upload..." >&2

# Validate all files first — only after every catalog passes do we touch
# the bucket. Prevents the orphan-upload case where file A validates+uploads
# then file B fails validation, leaving A stranded under the SHA prefix
# with no latest.json. The subshell `exit 1` inside the pipe-then-read loop
# wouldn't terminate the script, so we record failure to a tempfile and
# check it after the loop.
val_status="/tmp/publish-catalog-val.$$.status"
: > "$val_status"
echo "$catalog_files" | while IFS= read -r path; do
  filename=$(basename "$path")
  if ! jq -e '
        type == "object"
        and (.schema_version | type == "string")
        and (.extractor | type == "object")
        and ((.entries | type == "array")
             or (.edges | type == "array")
             or (.nodes | type == "array"))
      ' "$path" >/dev/null 2>&1; then
    echo "  REFUSED: $filename is not a v1.1 wrapper-shaped catalog" >&2
    echo "fail" >> "$val_status"
  fi
done
if [ -s "$val_status" ]; then
  rm -f "$val_status"
  echo "publish-catalog.sh: validation failed; nothing uploaded" >&2
  exit 1
fi
rm -f "$val_status"

echo "[2/4] Uploading catalogs..." >&2
echo "$catalog_files" | while IFS= read -r path; do
  filename=$(basename "$path")
  upload "$path" "${prefix}/${filename}"
  echo "  uploaded ${prefix}/${filename}" >&2
done

# We re-derive metadata in a separate pass because the `while ... | read`
# loop above runs in a subshell, so any vars set in there don't survive.
echo "[3/4] Building latest.json pointer..." >&2
echo "$catalog_files" | while IFS= read -r path; do
  filename=$(basename "$path")
  kind="${filename%.json}"
  sha_val=$(sha256_of "$path")
  printf '%s\n' "$kind|$filename|$sha_val"
done > /tmp/publish-catalog-meta.$$.txt

# Build the latest.json JSON.
latest_json=$(
  catalogs_array=$(awk -F'|' '
    BEGIN { sep = "" }
    { printf "%s{\"kind\":\"%s\",\"file\":\"%s\",\"sha256\":\"%s\"}", sep, $1, $2, $3; sep = "," }
  ' /tmp/publish-catalog-meta.$$.txt)
  jq -n \
    --arg repo "$repo" \
    --arg prefix "${prefix}/" \
    --arg commit_sha "$sha" \
    --arg published_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson catalogs "[$catalogs_array]" \
    '{kind: "latest-pointer", schema_version: "1.0", repo: $repo, prefix: $prefix, commit_sha: $commit_sha, published_at: $published_at, catalogs: $catalogs}'
)

latest_tmp="/tmp/publish-catalog-latest.$$.json"
printf '%s\n' "$latest_json" > "$latest_tmp"
upload "$latest_tmp" "by-repo/${path_segment}/latest.json"
echo "  wrote by-repo/${path_segment}/latest.json" >&2
rm -f "$latest_tmp" "/tmp/publish-catalog-meta.$$.txt"

echo "[4/4] Refreshing index.json..." >&2
if [ "$skip_refresh" -eq 1 ]; then
  echo "  skipped (--skip-refresh)" >&2
else
  if [ -n "$bucket_fs" ]; then
    node "$THIS_DIR/refresh-index.mjs" --bucket-fs "$bucket_fs" >&2
  else
    node "$THIS_DIR/refresh-index.mjs" --bucket-name "$bucket_name" --bucket-endpoint "$bucket_endpoint" >&2
  fi
fi

echo "Published $repo @ ${short_sha} to ${prefix}/" >&2
exit 0
