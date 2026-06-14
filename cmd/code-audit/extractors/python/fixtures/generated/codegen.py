"""Fixture for the generated-flag detection.

This file lives under fixtures/generated/, so every record emitted from it
should carry `generated: true`.
"""

from pydantic import BaseModel  # type: ignore[import-not-found]


class GeneratedShape(BaseModel):
    field_a: str
    field_b: int
