"""Fixtures for plain classes.

- Class with AnnAssign fields           -> type-alias-object (fallback)
- Class with no annotations             -> interface (fallback)
- Exception subclass with no body       -> interface
- Class with ClassVar / static-like     -> is_static flag set
"""

from typing import ClassVar


class PlainShape:
    """Plain class with annotated attrs — fallback maps to type-alias-object."""

    name: str
    count: int


class EmptyClass:
    """No annotations, no body — empty fields, kind=interface."""

    pass


class CustomError(Exception):
    """Exception subclass — empty AnnAssign list, kind=interface."""

    pass


class HasClassVar:
    """ClassVar should flip is_static=True for that field."""

    instance_field: int
    static_field: ClassVar[str] = "default"
