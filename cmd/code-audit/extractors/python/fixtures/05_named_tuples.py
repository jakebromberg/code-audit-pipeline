"""Fixtures for NamedTuple — should map to `kind: "type-alias-object"`."""

from typing import NamedTuple


class ClassNamedTuple(NamedTuple):
    name: str
    score: int
