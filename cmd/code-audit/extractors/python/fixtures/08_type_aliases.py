"""Fixtures for top-level type aliases — kind depends on the RHS shape.

- `Foo: TypeAlias = X | Y` (PEP 604) -> type-alias-union
- `Foo: TypeAlias = Union[X, Y]`     -> type-alias-union
- `Foo: TypeAlias = Literal["a"]`    -> type-alias-union
- `Foo: TypeAlias = list[int]`       -> type-alias-other (bare subscript)
- `Foo = NewType("Foo", int)`        -> type-alias-other
- bare `Foo = Union[...]` / `Foo = int | str` (no TypeAlias annotation)
                                      -> classified as type alias if RHS is Union-like
"""

from typing import Literal, NewType, TypeAlias, Union


IntOrStr: TypeAlias = int | str
UnionAlias: TypeAlias = Union[int, str, None]
LiteralAlias: TypeAlias = Literal["a", "b", "c"]
ListAlias: TypeAlias = list[int]
NewTypeAlias = NewType("NewTypeAlias", int)
BareUnion = int | str
