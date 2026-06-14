"""Fixtures for the function-catalog extractor.

Coverage:
- sync / async functions
- methods (self / cls should be skipped from param_count)
- short body (< min-body-lines) -> body_hash null
- long body  (>= min-body-lines) -> body_hash populated
- docstring should NOT contribute to body lines
- nested function (qualified name)
- return-type ref / param-type ref filtered by builtin denylist
"""


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
