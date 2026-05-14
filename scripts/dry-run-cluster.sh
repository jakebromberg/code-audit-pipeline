#!/usr/bin/env bash
# §5.3 single-cluster end-to-end dry run.
#
# Renders the agent prompt against one normalized cluster row and sends it
# through the pinned Sonnet model via the Anthropic Messages API. Captures
# the response, validates JSON-schema match, and reports usage tokens.
#
# Expects ANTHROPIC_API_KEY in env. Does not log or persist the key.
#
# Args (all optional):
#   --query <name>        default: pat-candidates (richest substrate signal)
#   --row <int>           default: 0
#   --model <id>          default: claude-sonnet-4-6 (bare id; API returns the
#                                 date-pinned version in response.model)
#   --max-tokens <int>    default: 4096
#   --temperature <float> default: 0.0
#   --output <path>       default: experiments/v7-refactor-recommendation/preflight/dry-run-response.json

set -euo pipefail

QUERY=pat-candidates
ROW=0
MODEL=claude-sonnet-4-6
MAX_TOKENS=4096
TEMPERATURE=0.0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_PATH="$REPO_ROOT/experiments/v7-refactor-recommendation/preflight/dry-run-response.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query) QUERY="$2"; shift 2;;
    --row) ROW="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --max-tokens) MAX_TOKENS="$2"; shift 2;;
    --temperature) TEMPERATURE="$2"; shift 2;;
    --output) OUT_PATH="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY must be set in env" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_PATH")"

# Render the user-message body.
PROMPT_BODY=$("$SCRIPT_DIR/render-prompt.py" --query "$QUERY" --row "$ROW")

# Build the API request payload via python3 to handle JSON escaping robustly.
# Body is piped in via stdin; model/limits via env.
export MODEL MAX_TOKENS TEMPERATURE
PAYLOAD=$(printf '%s' "$PROMPT_BODY" | python3 -c '
import json, os, sys
body = sys.stdin.read()
payload = {
  "model": os.environ["MODEL"],
  "max_tokens": int(os.environ["MAX_TOKENS"]),
  "temperature": float(os.environ["TEMPERATURE"]),
  "messages": [{"role": "user", "content": body}],
}
print(json.dumps(payload))
')

echo "  payload bytes: $(wc -c <<< "$PAYLOAD")" >&2
echo "  model:         $MODEL" >&2
echo "  max_tokens:    $MAX_TOKENS" >&2
echo "  temperature:   $TEMPERATURE" >&2
echo "  query:         $QUERY (row $ROW)" >&2
echo "  output:        $OUT_PATH" >&2

START_NS=$(python3 -c 'import time; print(time.monotonic_ns())')
HTTP_STATUS=$(curl -sS -o "$OUT_PATH" -w "%{http_code}" \
  -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$PAYLOAD")
END_NS=$(python3 -c 'import time; print(time.monotonic_ns())')

LATENCY_MS=$(( (END_NS - START_NS) / 1000000 ))

echo "  http status:   $HTTP_STATUS" >&2
echo "  latency:       ${LATENCY_MS} ms" >&2

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "ERROR: API returned non-200" >&2
  cat "$OUT_PATH" >&2
  exit 1
fi

python3 - "$OUT_PATH" <<'EOF'
import json, sys, re
resp = json.load(open(sys.argv[1]))

model_returned = resp.get("model", "?")
input_tokens = resp.get("usage", {}).get("input_tokens", 0)
output_tokens = resp.get("usage", {}).get("output_tokens", 0)
stop_reason = resp.get("stop_reason", "?")
content_blocks = resp.get("content", [])

cost = input_tokens / 1_000_000 * 3.00 + output_tokens / 1_000_000 * 15.00

print(f"  model returned:     {model_returned}", file=sys.stderr)
print(f"  input_tokens:       {input_tokens}", file=sys.stderr)
print(f"  output_tokens:      {output_tokens}", file=sys.stderr)
print(f"  stop_reason:        {stop_reason}", file=sys.stderr)
print(f"  estimated cost:     ${cost:.6f}", file=sys.stderr)

text = "".join(b.get("text", "") for b in content_blocks if b.get("type") == "text")
print("=== response body (first 400 chars) ===", file=sys.stderr)
print(text[:400], file=sys.stderr)
if len(text) > 400:
    print("...", file=sys.stderr)

# JSON-schema match check. The prompt asks for an array of recommendation
# objects per §1 (one per cluster row). Since we sent a single row, expect
# an array of length 1.
m = re.search(r"\[.*\]", text, re.DOTALL)
if not m:
    print("FAIL: response does not contain a JSON array", file=sys.stderr)
    sys.exit(1)
try:
    arr = json.loads(m.group(0))
except json.JSONDecodeError as e:
    print(f"FAIL: response array is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
if not isinstance(arr, list) or len(arr) != 1:
    print(f"FAIL: expected 1-element array, got {type(arr).__name__} of len {len(arr) if isinstance(arr, list) else '?'}", file=sys.stderr)
    sys.exit(1)

rec = arr[0]
required = {"cluster_id", "category", "specifics", "rationale", "evidence_quote", "confidence"}
missing = required - set(rec.keys())
if missing:
    print(f"FAIL: recommendation missing required fields: {sorted(missing)}", file=sys.stderr)
    sys.exit(1)

valid_categories = {
    "extract-to-common", "protocol-inheritance", "default-implementation",
    "pat-introduction", "generic-parameterization", "subclass-lift",
    "macro-synthesis", "composition", "extension-consolidation",
    "no-action", "other",
}
if rec["category"] not in valid_categories:
    print(f"FAIL: category not in allowed set: {rec['category']}", file=sys.stderr)
    sys.exit(1)

print(f"  recommendation category: {rec['category']}", file=sys.stderr)
print(f"  confidence:              {rec.get('confidence')}", file=sys.stderr)
print(f"  JSON-schema match:       OK", file=sys.stderr)
EOF
