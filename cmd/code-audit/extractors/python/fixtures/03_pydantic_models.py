"""Fixtures for Pydantic BaseModel — should map to `kind: "zod-object"`.

The mapping treats Zod and Pydantic symmetrically; both are runtime-validated
record schemas with the same shape semantics for clustering purposes.
"""

# Pydantic isn't installed in CI; the parser only looks at the AST,
# so the base-class name is what matters, not the import existence.
from pydantic import BaseModel  # noqa: E402,F401  # type: ignore[import-not-found]


class UserModel(BaseModel):
    name: str
    age: int
    email: str | None = None


class NestedRefModel(BaseModel):
    """References another Pydantic model — exercise the `references` list."""

    user: UserModel
    timestamp: int
