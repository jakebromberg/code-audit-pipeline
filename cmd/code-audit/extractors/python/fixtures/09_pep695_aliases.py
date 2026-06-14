"""Fixtures for PEP 695 `type X = ...` syntax (Python 3.12+).

If running on < 3.12, this file will fail to parse and the extractor should
skip it with a stderr warning — not crash. The CI matrix should run 3.12+
to actually exercise this kind.
"""

type Pep695Union = int | str
type Pep695Single = int


# Generic PEP 695 alias — the declared type-parameter `T` must NOT appear
# in references (pipeline-contract §references semantics) and the `generics`
# field on the emitted row should record T.
type Pep695Generic[T] = list[T]
