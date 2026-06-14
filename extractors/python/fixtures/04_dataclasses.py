"""Fixtures for @dataclass — should map to `kind: "type-alias-object"`."""

from dataclasses import dataclass


@dataclass
class Point:
    x: float
    y: float


@dataclass(frozen=True)
class FrozenPoint:
    """frozen=True should still classify as type-alias-object."""

    x: float
    y: float


@dataclass
class HasOptional:
    """is_optional structural flag covers both Optional[T] and T | None."""

    a: int
    b: str | None = None
    c: int = 0  # not optional — the default isn't None
