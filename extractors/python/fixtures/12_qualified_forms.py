"""Fixtures for qualified-name (`typing.X`, `sqlalchemy.orm.Mapped`) forms.

Real codebases that `import typing` rather than `from typing import …` write
their kind-markers in qualified form. The extractor must classify these
identically to their unqualified counterparts — string-prefix checks against
`annotation_text` silently miss the qualified spelling.

Each declaration here mirrors a record in 02 / 07 / 08 / 10 but with the
marker spelled qualified.
"""

import sqlalchemy.orm  # type: ignore[import-not-found]
import typing  # noqa: F401  # type: ignore[import-not-found]


# Qualified ClassVar — is_static must be True for the static_field row.
class QualifiedClassVar:
    instance_field: int
    static_field: typing.ClassVar[str] = "default"


# Qualified TypedDict functional form — class kind must be type-alias-object.
QualifiedFunctionalTypedDict = typing.TypedDict(
    "QualifiedFunctionalTypedDict", {"a": int, "b": str}
)


# Qualified TypeAlias annotation — must be extracted as a type alias.
QualifiedTypeAliasUnion: typing.TypeAlias = int | str


# Qualified SQLAlchemy Mapped — class kind must be drizzle-table.
# Subclasses DeclarativeBase directly to hit the existing heuristic; the
# load-bearing check is that `sqlalchemy.orm.Mapped[int]` (qualified) trips
# the column detector even though the annotation_text starts with the module
# prefix, not the literal "Mapped".
class QualifiedOrmModel(sqlalchemy.orm.DeclarativeBase):
    __tablename__ = "qualified_orm_model"
    id: sqlalchemy.orm.Mapped[int]
    name: sqlalchemy.orm.Mapped[str]
