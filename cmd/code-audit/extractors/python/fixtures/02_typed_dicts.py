"""Fixtures for TypedDict — both class and functional forms.

Class-form TypedDict and functional `TypedDict("X", {...})` both serialize as
`kind: "type-alias-object"`.
"""

from typing import TypedDict


class ClassTypedDict(TypedDict):
    name: str
    count: int


# Functional form.
FunctionalTypedDict = TypedDict("FunctionalTypedDict", {"a": int, "b": str})


class OptionalKeyDict(TypedDict, total=False):
    """total=False — every key optional; the `total` argument is ignored for
    shape clustering."""

    flag: bool
    label: str
