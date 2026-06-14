"""Fixtures for Enum families — should map to `kind: "type-alias-union"`.

Each enum case becomes a field. Cases with raw values render the value as
`=<unparsed>`; cases without values render as empty type.
"""

from enum import Enum, IntEnum


class Color(Enum):
    """No raw values — type for each field should be empty string."""

    RED = "red"
    GREEN = "green"
    BLUE = "blue"


class Priority(IntEnum):
    LOW = 1
    MEDIUM = 5
    HIGH = 10


class CaseWithoutValue(Enum):
    """Auto-numbered cases; we still record them."""

    A = 1
    B = 2
