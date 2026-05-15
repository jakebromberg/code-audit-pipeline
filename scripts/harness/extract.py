"""Fence-aware JSON-array extraction from a model response.

Sonnet 4.6 was observed in §5.3 to wrap its single-element array in a
```json ... ``` fence even when the prompt asks for a bare array. Phase D
sends one cluster row per request, so the expected payload is always an
array of length 1. The extractor accepts either fenced or bare-array
responses and returns the parsed list.

Raises `ExtractError` (a `ValueError`) with a categorized error class so the
caller can record `error_class` in telemetry without re-parsing the message.
"""

from __future__ import annotations

import json
import re


class ExtractError(ValueError):
    def __init__(self, error_class: str, message: str):
        super().__init__(message)
        self.error_class = error_class


_FENCED_RE = re.compile(r"```(?:json)?\s*(\[.*?\])\s*```", re.DOTALL)
_BARE_RE = re.compile(r"\[.*\]", re.DOTALL)


def extract_recommendation_array(text: str) -> list:
    """Parse and return the JSON array of recommendations.

    Tries a ```json fenced block first (Sonnet 4.6's observed default),
    then falls back to a greedy first-`[`-through-last-`]` match. Raises
    ExtractError with one of: "no-array", "json-parse-error", "not-a-list".
    """
    fenced = _FENCED_RE.search(text)
    if fenced:
        array_text = fenced.group(1)
    else:
        m = _BARE_RE.search(text)
        if not m:
            raise ExtractError("no-array", "response does not contain a JSON array")
        array_text = m.group(0)
    try:
        arr = json.loads(array_text)
    except json.JSONDecodeError as e:
        raise ExtractError("json-parse-error", f"response array is not valid JSON: {e}")
    if not isinstance(arr, list):
        raise ExtractError("not-a-list", f"expected list, got {type(arr).__name__}")
    return arr
