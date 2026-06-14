"""Fixtures for the Protocol kind.

Each top-level class here should serialize as `kind: "interface"`.
"""

from typing import Protocol


class SimpleProtocol(Protocol):
    name: str
    age: int


class GenericProtocol(Protocol):
    """A generic Protocol — should still classify as interface."""

    items: list[str]


class ExtendingProtocol(SimpleProtocol, Protocol):
    """Heritage — `extends` should contain SimpleProtocol."""

    extra: bool


class ProtocolWithMethods(Protocol):
    """A method-only Protocol — empty fields, but still kind=interface."""

    def do_thing(self, n: int) -> str: ...
