"""Fixtures for generic declarations — the `generics` field should be set."""

from typing import Generic, Protocol, TypeVar


T = TypeVar("T")
U = TypeVar("U")


class GenericProtocol(Protocol[T]):
    """Protocol[T] form — generics: T."""

    value: T


class GenericClass(Generic[T, U]):
    """Generic[T, U] form — generics: T,U."""

    first: T
    second: U
