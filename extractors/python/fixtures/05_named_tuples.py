"""Fixtures for NamedTuple — should map to `kind: "type-alias-object"`.

Covers both the class form (`class X(NamedTuple)`) and the functional form
(`X = NamedTuple("X", [...])`) — both forms must produce the same kind so
cluster queries treat them symmetrically.
"""

from typing import NamedTuple


class ClassNamedTuple(NamedTuple):
    name: str
    score: int


# Functional form — list-of-tuples spelling. Should classify as
# type-alias-object with fields parallel to the class form.
FunctionalNamedTuple = NamedTuple("FunctionalNamedTuple", [("a", int), ("b", str)])
