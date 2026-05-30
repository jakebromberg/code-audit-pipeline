#!/usr/bin/env bash
# verify-index.sh — drift detector for the cross-repo substrate's index.json.
#
# Compares index.json's claimed `latest.prefix` set against the prefixes
# actually present in the bucket. Reports orphans (in bucket but not index)
# and dangling references (in index but not bucket). Exits nonzero on any
# drift.
#
# Intended for two callers:
#   - refresh-index.mjs (self-check after every rewrite)
#   - scheduled CI cron (nightly)
#
# Backends mirror refresh-index.mjs:
#   --bucket-fs DIR
#       Local filesystem mode. Walks DIR/by-repo/ and reads DIR/index.json.
#   --bucket-url URL
#       Read-only HTTP mode. Fetches URL/index.json. Requires `aws s3 ls`
#       for the bucket-listing side (the URL is the read CDN; the listing
#       still needs S3-API credentials), in which case pass
#       --bucket-name + --bucket-endpoint alongside.
#
# Exit:
#   0  no drift
#   1  drift detected (orphans or dangling refs reported on stderr)
#   2  argument error or I/O failure

set -eu

usage() {
  cat >&2 <<'EOF'
usage: verify-index.sh --bucket-fs DIR
       verify-index.sh --bucket-name NAME --bucket-endpoint URL [--bucket-url URL]

  --bucket-fs DIR            Local filesystem bucket (tests / dev).
  --bucket-name NAME         S3 bucket name (production); requires aws CLI.
  --bucket-endpoint URL      S3 endpoint URL.
  --bucket-url URL           Optional read URL for index.json (default:
                             read via aws s3 cp).
EOF
}

bucket_fs=""
bucket_name=""
bucket_endpoint=""
bucket_url=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bucket-fs)       bucket_fs="$2"; shift 2 ;;
    --bucket-name)     bucket_name="$2"; shift 2 ;;
    --bucket-endpoint) bucket_endpoint="$2"; shift 2 ;;
    --bucket-url)      bucket_url="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "verify-index.sh: unknown flag: $1" >&2; usage; exit 2 ;;
  esac
done

# Materialize index.json + the prefix list into TMP and compare.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -n "$bucket_fs" ]; then
  if [ ! -f "$bucket_fs/index.json" ]; then
    echo "verify-index.sh: no index.json at $bucket_fs/index.json" >&2
    exit 2
  fi
  cp "$bucket_fs/index.json" "$tmp/index.json"
  # Bucket prefixes: list by-repo/<repo>/<ts>_<sha>/ directories.
  if [ -d "$bucket_fs/by-repo" ]; then
    find "$bucket_fs/by-repo" -mindepth 2 -maxdepth 2 -type d \
      | sed "s|^$bucket_fs/||;s|$|/|" \
      | sort > "$tmp/bucket_prefixes.txt"
  else
    : > "$tmp/bucket_prefixes.txt"
  fi
elif [ -n "$bucket_name" ] && [ -n "$bucket_endpoint" ]; then
  if [ -n "$bucket_url" ]; then
    curl -fsSL "${bucket_url%/}/index.json" -o "$tmp/index.json"
  else
    aws --endpoint-url "$bucket_endpoint" s3 cp "s3://$bucket_name/index.json" "$tmp/index.json" >/dev/null
  fi
  # List the `<ts>_<sha>/` prefixes via aws s3 ls.
  aws --endpoint-url "$bucket_endpoint" s3api list-objects-v2 \
    --bucket "$bucket_name" --prefix 'by-repo/' --delimiter '/' \
    --query 'CommonPrefixes[].Prefix' --output text > "$tmp/repo_dirs.txt" 2>/dev/null || true
  : > "$tmp/bucket_prefixes.txt"
  # For each repo dir, list its timestamp subdirs.
  while IFS=$'\t' read -ra rdirs; do
    for rd in "${rdirs[@]}"; do
      [ -z "$rd" ] && continue
      aws --endpoint-url "$bucket_endpoint" s3api list-objects-v2 \
        --bucket "$bucket_name" --prefix "$rd" --delimiter '/' \
        --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null \
        | tr '\t' '\n' >> "$tmp/bucket_prefixes.txt"
    done
  done < "$tmp/repo_dirs.txt"
  sort -u "$tmp/bucket_prefixes.txt" -o "$tmp/bucket_prefixes.txt"
else
  usage
  exit 2
fi

# Extract claimed `latest.prefix` set from the index.
jq -r '.repos[] | select(.latest != null) | .latest.prefix' "$tmp/index.json" \
  | sort > "$tmp/index_prefixes.txt"

# Drift = symmetric difference. Anything in index but not bucket is dangling;
# anything in bucket but not in index (filtering out history_prefixes) is an
# orphan we surface for human review.
jq -r '.repos[] | (.history_prefixes // [])[]' "$tmp/index.json" \
  | sort > "$tmp/history_prefixes.txt"

comm -23 "$tmp/index_prefixes.txt" "$tmp/bucket_prefixes.txt" > "$tmp/dangling.txt"
comm -23 "$tmp/bucket_prefixes.txt" "$tmp/index_prefixes.txt" \
  | comm -23 - "$tmp/history_prefixes.txt" > "$tmp/orphan.txt"

dangling_count=$(wc -l < "$tmp/dangling.txt" | tr -d ' ')
orphan_count=$(wc -l < "$tmp/orphan.txt" | tr -d ' ')

if [ "$dangling_count" -gt 0 ]; then
  echo "verify-index.sh: $dangling_count dangling references (in index, not in bucket):" >&2
  sed 's/^/  /' "$tmp/dangling.txt" >&2
fi
if [ "$orphan_count" -gt 0 ]; then
  echo "verify-index.sh: $orphan_count orphan prefixes (in bucket, not in index or history):" >&2
  sed 's/^/  /' "$tmp/orphan.txt" >&2
fi

if [ "$dangling_count" -gt 0 ] || [ "$orphan_count" -gt 0 ]; then
  exit 1
fi
echo "verify-index.sh: no drift (index ↔ bucket converged)" >&2
exit 0
