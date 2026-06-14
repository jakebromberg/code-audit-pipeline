"""Fixtures for SQLAlchemy declarative — should map to `kind: "drizzle-table"`.

The heuristic requires:
  - base class named Base or DeclarativeBase, AND
  - at least one Mapped[…] annotation in the body.
"""

# Type-stubs imports; not required at runtime — ast only inspects names.
from sqlalchemy.orm import DeclarativeBase, Mapped  # type: ignore[import-not-found]


class Base(DeclarativeBase):
    """Stand-in declarative base."""


class User(Base):
    """Real SQLAlchemy model — should be drizzle-table."""

    __tablename__ = "user"
    id: Mapped[int]
    name: Mapped[str]
    email: Mapped[str | None]


class NotAnOrmModel(Base):
    """Inherits from Base but has no Mapped[…] columns — falls back to
    type-alias-object via the regular class-with-AnnAssign rule."""

    plain_field: str
