"""Fixtures for the function-catalog extractor.

Coverage:
- sync / async functions
- methods (self / cls should be skipped from param_count)
- @staticmethod (NO implicit first arg; even a param literally named `self`
  must be preserved)
- @typing.overload heads + implementation (signature_index 0, 1, 2 in source order)
- short body (< min-body-lines) -> body_hash null
- long body  (>= min-body-lines) -> body_hash populated
- docstring should NOT contribute to body lines
- nested function (qualified name)
- return-type ref / param-type ref filtered by builtin denylist
"""

from typing import overload


def short_sync(x: int) -> int:
    return x + 1


async def short_async(x: int) -> int:
    return x + 1


def long_function(a: int, b: int, c: int) -> int:
    """This docstring should be skipped from body normalization."""
    total = a + b
    doubled = total * 2
    adjusted = doubled - c
    return adjusted


class WithMethods:
    def instance_method(self, n: int) -> str:
        result = str(n)
        upper = result.upper()
        return upper

    @classmethod
    def class_method(cls, n: int) -> str:
        result = str(n)
        upper = result.upper()
        return upper

    @staticmethod
    def static_method(self, n: int) -> str:
        # `self` here is a regular positional parameter; @staticmethod has no
        # implicit first arg, so param_count must be 2 and `self` must appear
        # in param_names.
        first = self
        second = n
        return str(first + second)


class WithOverloads:
    @overload
    def value(self, x: int) -> int: ...
    @overload
    def value(self, x: str) -> str: ...
    def value(self, x):
        first = x
        second = x
        return first or second


def outer(x: int) -> int:
    def inner(y: int) -> int:
        return y * 2

    return inner(x)


# Return / param annotations referencing a user-defined type — should land
# in `references`, while `int` / `str` are filtered out.
class CustomReturn:
    pass


def takes_and_returns(arg: CustomReturn) -> CustomReturn:
    placeholder_a = arg
    placeholder_b = placeholder_a
    return placeholder_b
