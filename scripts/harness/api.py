"""Anthropic `/v1/messages` HTTP wrapper with an injectable transport.

The transport is split out so unit tests can drive the loop without making
real HTTP calls. The default transport uses stdlib `urllib.request` (no
third-party deps to match the rest of the repo).

Pin values come from `experiments/v7-refactor-recommendation/reproducibility.yaml`:
  - model alias: claude-sonnet-4-6 (per §6.1; date-pinned variant is not
    published for this tier)
  - anthropic-version: 2023-06-01
  - temperature: 0.0
  - max_tokens: 4096

The drift-detection mechanism is the per-rec `response.model` field — the
caller captures it in telemetry so a mid-run alias retarget by Anthropic
would surface as a change in the recorded ids.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Callable, Optional

ANTHROPIC_MESSAGES_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
DEFAULT_MODEL = "claude-sonnet-4-6"
DEFAULT_TEMPERATURE = 0.0
DEFAULT_MAX_TOKENS = 4096


@dataclass
class ApiResponse:
    status: int
    body: dict
    latency_ms: int


# Transport contract: takes (url, headers, body_bytes) and returns
# (status_code, response_body_bytes). Implementations must NOT raise on
# non-2xx — they must surface the status code so the caller can decide.
Transport = Callable[[str, dict, bytes], tuple[int, bytes]]


def _urllib_transport(url: str, headers: dict, body: bytes) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.getcode(), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def build_payload(
    user_message: str,
    *,
    model: str = DEFAULT_MODEL,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    temperature: float = DEFAULT_TEMPERATURE,
) -> dict:
    """Build the `/v1/messages` payload for one cluster row."""
    return {
        "model": model,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "messages": [{"role": "user", "content": user_message}],
    }


def call_messages(
    payload: dict,
    api_key: str,
    *,
    transport: Optional[Transport] = None,
    retries: int = 3,
    backoff_base_s: float = 2.0,
) -> ApiResponse:
    """POST to `/v1/messages`, returning ApiResponse with measured latency.

    Retries on HTTP 429 / 5xx and transport-layer exceptions (TimeoutError,
    URLError, OSError) with exponential backoff (2s, 4s, 8s, ...). After
    exhausting retries, returns status=0 with a synthetic error body so a
    single network blip is recorded as `api-status-0` telemetry rather than
    aborting the whole trial. Transport is injectable for tests.
    """
    transport = transport or _urllib_transport
    headers = {
        "x-api-key": api_key,
        "anthropic-version": ANTHROPIC_VERSION,
        "content-type": "application/json",
    }
    body = json.dumps(payload).encode("utf-8")

    last_status = -1
    last_bytes = b""
    last_latency_ms = 0
    for attempt in range(retries + 1):
        start_ns = time.monotonic_ns()
        try:
            status, raw = transport(ANTHROPIC_MESSAGES_URL, headers, body)
        except (TimeoutError, urllib.error.URLError, OSError) as e:
            last_latency_ms = (time.monotonic_ns() - start_ns) // 1_000_000
            last_status = 0
            last_bytes = json.dumps(
                {"error": "transport-error", "exception": repr(e)}
            ).encode("utf-8")
            if attempt == retries:
                break
            time.sleep(backoff_base_s * (2 ** attempt))
            continue
        last_latency_ms = (time.monotonic_ns() - start_ns) // 1_000_000
        last_status = status
        last_bytes = raw
        if status == 200:
            break
        if status not in (429, 500, 502, 503, 504):
            break
        if attempt == retries:
            break
        time.sleep(backoff_base_s * (2 ** attempt))

    try:
        parsed = json.loads(last_bytes.decode("utf-8")) if last_bytes else {}
    except json.JSONDecodeError:
        parsed = {"_raw": last_bytes.decode("utf-8", errors="replace")}
    return ApiResponse(status=last_status, body=parsed, latency_ms=last_latency_ms)


def extract_text(response_body: dict) -> str:
    """Concatenate `content[*].text` from a successful /v1/messages body."""
    blocks = response_body.get("content", []) or []
    return "".join(b.get("text", "") for b in blocks if b.get("type") == "text")
