# Python extractor

Python AST extractor for the code-audit pipeline. Walks `.py` source files under `--root` (and optionally `--shared`) and emits a `type-catalog.json` matching the JSON shape in [`docs/pipeline-contract.md`](../../docs/pipeline-contract.md). The sibling `function-catalog.json` lands in a follow-up (#277).

Stdlib-only (`ast`, `hashlib`, `json`, `pathlib`) — no `pip install` step, no bootstrap. Requires Python 3.9+ for `ast.unparse`.

## Usage

```bash
# Type catalog
python3 type_catalog.py --root /path/to/repo --output type-catalog.json

# Cross-package shadow detection (main vs shared)
python3 type_catalog.py --root /path/to/svc --shared /path/to/shared --output type-catalog.json
```

The extractor:
- Skips dotdirs (`.git`, `.venv`, `.claude`, etc.) and `node_modules`, `dist`, `build`, `coverage`, `__pycache__`, `.tox`, `.eggs`.
- Tags every record with `is_test: bool` derived from path patterns (`test_*.py`, `*_test.py`, `conftest.py`, plus the universal `tests/`, `__tests__/`, `spec/`, `fixtures/`, `e2e/` dir segments).
- Tags every record with `generated: true` for files under `generated/`, `.egg-info/`, or named `*_pb2.py` / `*_pb2_grpc.py`.

## Kind mapping

How Python source constructs map to the catalog `kind` field:

| Python construct | Catalog `kind` |
|---|---|
| `class X(Protocol):` | `interface` |
| `class X(TypedDict):` or `X = TypedDict("X", {...})` | `type-alias-object` |
| `class X(NamedTuple):` or `X = NamedTuple("X", [("a", int), ("b", str)])` | `type-alias-object` |
| `class X(BaseModel):` (Pydantic) | `zod-object` |
| `@dataclass class X:` | `type-alias-object` |
| `class X(Base):` with `Mapped[…]` columns (SQLAlchemy) | `drizzle-table` |
| `class X(Enum):` / `IntEnum` / `StrEnum` / `Flag` / `IntFlag` | `type-alias-union` |
| plain `class X:` with AnnAssign fields | `type-alias-object` |
| `X: TypeAlias = …` or `type X = …` (PEP 695) | `type-alias-union` (when value is `\|` / `Union` / `Literal` / `Optional`) or `type-alias-other` |
| `X = NewType("X", Y)` | `type-alias-other` |

Marker bases are recognized in both their bare (`TypedDict`, `Mapped`, `ClassVar`, …) and qualified (`typing.TypedDict`, `sqlalchemy.orm.Mapped`, `typing.ClassVar`, …) spellings — the classifier walks the AST rather than string-matching the unparsed annotation.

`def f():` / `async def f():` / methods inside a `ClassDef` belong to the function-catalog half of this extractor and will be emitted under the follow-up tracked by #277.

The Pydantic → `zod-object` mapping intentionally collapses Zod and Pydantic into one kind because cluster queries treat them symmetrically — both are runtime-validated record schemas with the same shape semantics.

## Built-in / utility denylist

These names are filtered out of every `references[]` array (so they don't dominate the graph): `Optional`, `Union`, `List`, `Dict`, `Set`, `Tuple`, `Sequence`, `Iterable`, `Mapping`, `Callable`, `Awaitable`, `Any`, `None`, `NoReturn`, `Never`, `TypeVar`, `ParamSpec`, `ClassVar`, `Final`, `Literal`, `Annotated`, `TypeAlias`, `Type`, `Mapped`, `Column`, `Field`, plus the lowercase primitives (`int`, `str`, `bytes`, `bool`, `float`, `list`, `dict`, `set`, `tuple`, `range`, …).

To extend (e.g., a new typing-stub introduces `Required` / `NotRequired`), add the name to `BUILTIN_TYPE_DENYLIST` in `type_catalog.py`.

## Known limitations (v0.1.0)

- **No body-level type resolution.** A class body that references its own name (`self: "X"`) only sees the literal-string ref, not the resolved class. For shape-clustering queries this is fine; for inverted-reference queries it under-reports.
- **SQLAlchemy `Base` heuristic.** A class is tagged `drizzle-table` only when its base class is literally named `Base` or `DeclarativeBase` AND it has at least one `Mapped[…]` annotation. Custom base-class names (`MyBase`, `MyDeclarative`) need explicit support; file a query if you hit this.

## Sibling artifacts

This extractor does not (yet) emit `files.json` or `references.json`. The TypeScript extractor's [`--emit-files`](../typescript/README.md) and [`--emit-references-graph`](../typescript/README.md) are tracked separately; mirror them here when the cross-package-backward-imports query becomes load-bearing for a Python service.
