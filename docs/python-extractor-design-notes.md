# Python extractor: design notes from library-metadata-lookup

> A feasibility study. Before writing the Python extractor, walk real Python services and see what an AST-based extractor can faithfully capture, where the [deterministic-extraction principle](../CLAUDE.md) bends, and where it breaks. The conclusions are evidence for a future iteration of [`pipeline-contract.md`](pipeline-contract.md); they do not prescribe one. Sibling study to [`swift-extractor-design-notes.md`](swift-extractor-design-notes.md).

## Context

The pipeline's [TypeScript extractor](../extractors/typescript/type-catalog.mjs) is the lighthouse implementation. It produces the JSON shape documented in [`pipeline-contract.md`](pipeline-contract.md). The [case study](case-study.md) tells that origin story. [`swift-extractor-design-notes.md`](swift-extractor-design-notes.md) is the second study, walking real Swift 6.2 code in [`wxyc-ios-64`](https://github.com/WXYC/wxyc-ios-64) to ground a discussion of source AST vs expanded AST. This study is the third — Python.

Python has its own structural pressures. Heavy use of decorators that mutate behavior at import time. Metaclass-injected accessors via [Pydantic](https://docs.pydantic.dev/latest/) (whose `BaseModel` is the most common Python data class in WXYC's stack). Route registration via [FastAPI](https://fastapi.tiangolo.com/) decorators whose final path is a join across two or three files. Dynamic SQL composed at runtime through f-strings. Type hints with [PEP 563](https://peps.python.org/pep-0563/) string-form annotations. Versioned [Alembic](https://alembic.sqlalchemy.org/) migrations whose DDL is sometimes in the AST and sometimes in external SQL files. And — most stressful for the deterministic-extraction principle — [PyO3](https://pyo3.rs/) bindings that put the implementation across a language boundary into Rust.

The study addresses three questions, the same three the Swift study asked:

1. What does an AST-only extractor capture faithfully?
2. Where does it lose fidelity, and is the loss admissible?
3. What does the catalog need to grow to cover Python adequately?

The relevant project roadmap entries are [`future-directions.md`](future-directions.md) §2 (the catalog as a universal structural index) and §5 (the polemic and case-study library). The findings here feed both: §2 because Python exposes kinds the current schema does not model (routes, dependencies, migrations, SQL queries), and §5 because a Python audit grounded in a real codebase is the kind of artifact the polemic accumulates.

## The codebase

The anchor for this study is [`library-metadata-lookup`](https://github.com/WXYC/library-metadata-lookup) — a FastAPI service that proxies and enriches WXYC's library catalog with Discogs metadata, identity resolution, and streaming-availability checks. It is the largest Python service in the WXYC stack: roughly 50K non-test lines across 487 `.py` files. It sits in front of an [aiosqlite](https://aiosqlite.omnilib.dev/) FTS5 database for the library catalog and an [asyncpg](https://magicstack.github.io/asyncpg/current/) connection pool to a [PostgreSQL](https://www.postgresql.org/) cache populated by [`discogs-etl`](https://github.com/WXYC/discogs-etl) — itself the second anchor for this study, contributing the [Alembic migration](https://alembic.sqlalchemy.org/en/latest/tutorial.html#create-a-migration-script) walk. A third anchor, [`semantic-index`](https://github.com/WXYC/semantic-index), supplies the PyO3 hybrid case because it imports from [`wxyc-etl`](https://github.com/WXYC/wxyc-etl), a Rust crate exposed to Python via the `wxyc_etl` extension module.

Across surveyed files, the WXYC Python stack exercises:

- [FastAPI](https://fastapi.tiangolo.com/) decorator-based routing, [`Depends`](https://fastapi.tiangolo.com/tutorial/dependencies/) dependency injection in default-argument expressions, and [`APIRouter` mounting via `include_router`](https://fastapi.tiangolo.com/tutorial/bigger-applications/) — including the same router imported twice from one module and mounted at two different paths with different auth postures.
- [Pydantic v2](https://docs.pydantic.dev/latest/) `BaseModel` declarations, [`Field`](https://docs.pydantic.dev/latest/concepts/fields/) defaults with constraints, [`SerializeAsAny`](https://docs.pydantic.dev/latest/concepts/serialization/#serializing-with-duck-typing) annotations, constrained types via [`conint` / `confloat`](https://docs.pydantic.dev/latest/api/types/), and `from __future__ import annotations` ([PEP 563](https://peps.python.org/pep-0563/)) flipping every annotation in the file to string form.
- Codegen via [`datamodel-code-generator`](https://github.com/koxudaxi/datamodel-code-generator/) producing Pydantic models from the [`wxyc-shared`](https://github.com/WXYC/wxyc-shared) OpenAPI `api.yaml`, with downstream packages subclassing the codegen models to add fields that have not yet landed in `api.yaml`.
- Module-level singleton lifecycle: a `_global: Cls | None = None` plus an async `get_*()` constructor plus a `close_*()` companion, wired into FastAPI's `lifespan` context manager.
- Async / await throughout (FastAPI handlers, asyncpg pool, aiosqlite connections, httpx clients).
- `StrEnum`, `IntEnum`, and `Literal[...]` types as closed-set value vocabularies.
- Multiple inheritance for shape composition (`class FlowsheetBreakpointEntry(FlowsheetMessageEntry, DateTimeEntry)`).
- Strategy patterns with `@dataclass` registries dispatched on `StrEnum` tags.
- Three structurally distinct forms of dynamic SQL: static module-level constants, f-string composition with runtime conditionals, and external `.sql` file contents read via `Path.read_text()` and applied through `psycopg`'s autocommit cursor.
- PyO3 imports (`from wxyc_etl.text import to_match_form`) where the implementation lives in Rust source and reaches Python via the `wxyc_etl._native` extension.
- Alembic migrations whose `revision` / `down_revision` form a DAG and whose `upgrade()` / `downgrade()` functions may use `op.add_column(...)` (in the AST) or apply external SQL files (not in the AST).

The TS-flavored kinds in the current contract — `interface`, `type-alias-*`, `zod-object`, `drizzle-table` — model some of this. `pydantic-model` maps onto `zod-object` cleanly enough that it can probably be added as an alias rather than a new kind. But routes, dependencies, migrations, SQL queries, and strategy-pattern dispatch tables have no existing kind. As with the Swift study, a Python extractor needs the catalog to grow.

## Seven files, seven records

This section walks seven real files. Each shows the source, the catalog records an extractor might emit, and what the records do and do not preserve. The records are illustrative — they extend the current contract in ways that would need to be ratified before they could ship — and are written to make the fidelity boundaries legible.

### File 1: a route surface composed across three places

[`library-metadata-lookup/lookup/router.py`](https://github.com/WXYC/library-metadata-lookup/blob/main/lookup/router.py) declares the route:

```python
router = APIRouter(tags=["lookup"])

@router.post(
    "/lookup",
    response_model=LookupResponse,
    summary="Look up a song/artist/album in the library catalog",
    responses={
        200: {"description": "Lookup completed successfully"},
        400: {"description": "Invalid request"},
        500: {"description": "Internal server error"},
    },
)
async def handle_lookup(
    request: LookupRequest,
    db: LibraryDB = Depends(get_library_db),
    discogs_service: DiscogsService | None = Depends(get_discogs_service),
    discogs_cache: DiscogsCacheService | None = Depends(get_discogs_cache_service),
    mb_pg: PgSource | None = Depends(get_musicbrainz_pg),
    entity_store: EntityStore | None = Depends(get_entity_store),
    posthog_client: Posthog | None = Depends(get_posthog_client),
    http_client: httpx.AsyncClient = Depends(get_apple_music_http_client),
    skip_cache: bool = False,
):
```

But the actual route is `POST /api/v1/lookup`, not `POST /lookup`. The full path appears in [`main.py`](https://github.com/WXYC/library-metadata-lookup/blob/main/main.py):

```python
_lml_protected = [Depends(require_lml_key)]
app.include_router(lookup_router, prefix="/api/v1", tags=["lookup"], dependencies=_lml_protected)
```

So the route is a join across:

- The `APIRouter(tags=["lookup"])` instantiation (router prefix, if any)
- The `@router.post(...)` decorator (HTTP method, path-suffix, response model, OpenAPI metadata)
- The handler signature (request body type — first non-`Depends` parameter; query params from primitive-typed defaults; DI edges from every `Depends(...)` default)
- The `app.include_router(..., prefix=..., dependencies=...)` call (additional prefix, auth dependencies wired at the composition site, not at the decorator)

An honest extractor emits:

```jsonc
{
  "kind": "fastapi-route",
  "name": "handle_lookup",
  "package": "library-metadata-lookup",
  "file": "lookup/router.py",
  "line": 87,
  "language": "python",
  "language_data": {
    "python": {
      "method": "POST",
      "path": "/api/v1/lookup",
      "router_name": "router",
      "router_decl_file": "lookup/router.py",
      "router_decl_line": 32,
      "mount_file": "main.py",
      "mount_line": 108,
      "mount_prefix": "/api/v1",
      "router_prefix": null,
      "decorator_path": "/lookup",
      "request_model": "lookup.models.LookupRequest",
      "response_model": "lookup.models.LookupResponse",
      "dependencies": [
        "core.dependencies.get_library_db",
        "core.dependencies.get_discogs_service",
        "core.dependencies.get_discogs_cache_service",
        "core.dependencies.get_musicbrainz_pg",
        "identity.dependencies.get_entity_store",
        "core.dependencies.get_posthog_client",
        "core.dependencies.get_apple_music_http_client"
      ],
      "mount_dependencies": ["core.auth.require_lml_key"],
      "query_params": [{"name": "skip_cache", "type": "bool", "default": false}],
      "tags": ["lookup"]
    }
  }
}
```

The composition is captured as a structural fact rather than rebuilt from a runtime introspection of `app.routes`. That keeps the extractor byte-reproducible against source files — preserving the property [`future-directions.md`](future-directions.md) §1 (time as a first-class dimension) depends on.

What this *does not* capture: that the decorator-time `responses` dict declares OpenAPI metadata that won't change handler behavior; that the handler's `return response` path may also raise `HTTPException(status_code=500)` from its except clause; that the response is shaped by Pydantic serialization rules including `SerializeAsAny` on `LookupResultItem.artwork` (file 2 below). The route record names the model; the *shape* of the model lives in the model record.

The same module imports a router twice under different names in `main.py`:

```python
from identity.router import api_v1_router as identity_api_v1_router
from identity.router import router as identity_router

app.include_router(identity_router, prefix="/identity", tags=["identity"])
app.include_router(
    identity_api_v1_router, prefix="/api/v1", tags=["lookup"], dependencies=_lml_protected
)
```

One Python module → two distinct route subgraphs with different mount prefixes and different auth postures. A naive "one record per `@router.post`" extractor produces wrong paths and silently loses the auth contract. The route record above resolves this correctly because it carries `mount_*` fields, not just `decorator_*` fields.

### File 2: a Pydantic model tower with codegen, override, and re-export

The lookup endpoint's request and response types live in three layered modules. The base shape is generated from OpenAPI. [`generated/api_models.py`](https://github.com/WXYC/library-metadata-lookup/blob/main/generated/api_models.py) (excerpted):

```python
from __future__ import annotations
from pydantic import AwareDatetime, BaseModel, Field, RootModel, confloat, conint


class Genre(StrEnum):
    Blues = "Blues"
    Rock = "Rock"
    Electronic = "Electronic"
    ...

class PaginationParams(BaseModel):
    page: conint(ge=1) | None = None
    limit: conint(ge=1, le=100) | None = None

class FlowsheetBreakpointEntry(FlowsheetMessageEntry, DateTimeEntry):
    pass
```

[`lookup/models.py`](https://github.com/WXYC/library-metadata-lookup/blob/main/lookup/models.py) subclasses and overrides:

```python
from generated.api_models import LookupRequest as _GeneratedLookupRequest
from generated.api_models import LookupResponse as _GeneratedLookupResponse
from generated.api_models import LookupResultItem as _GeneratedLookupResultItem

class LookupRequest(_GeneratedLookupRequest):
    """Override to add the Phase 1.5 ``include_external_caches`` opt-in."""

    include_external_caches: bool = Field(
        False,
        description=(
            "When True and the library returns no results, fall back to "
            "fuzzy artist-name search against discogs-cache and then "
            "musicbrainz-cache."
        ),
    )


class LookupResultItem(_GeneratedLookupResultItem):
    """Override to serialize artwork subclasses with all fields."""

    artwork: SerializeAsAny[DiscogsMatchResult] | None = None


class LookupResponse(_GeneratedLookupResponse):
    """Override so results use our LookupResultItem with SerializeAsAny."""

    results: list[LookupResultItem] | None = None  # type: ignore[assignment]
    external_source: Literal["library", "discogs", "musicbrainz"] | None = Field(
        None, description="Provenance for the returned results..."
    )
```

Two records, one per declared class. The catalog stores each class as a `pydantic-model`:

```jsonc
{
  "kind": "pydantic-model",
  "name": "LookupRequest",
  "package": "library-metadata-lookup",
  "file": "lookup/models.py",
  "line": 38,
  "language": "python",
  "fields": ["include_external_caches:bool"],
  "shape_sig_declared": "include_external_caches:bool",
  "language_data": {
    "python": {
      "bases": ["generated.api_models.LookupRequest"],
      "base_alias": "_GeneratedLookupRequest",
      "future_annotations": false,
      "field_metadata": {
        "include_external_caches": {
          "default": false,
          "description": "When True and the library returns no results..."
        }
      }
    }
  },
  "core_projection_complete": false,
  "omitted_features": ["inherited_fields"]
}
```

And the codegen base in the same package:

```jsonc
{
  "kind": "pydantic-model",
  "name": "LookupRequest",
  "package": "library-metadata-lookup",
  "file": "generated/api_models.py",
  "line": 423,
  "language": "python",
  "fields": ["album?:str | null", "artist?:str | null", "raw_message?:str | null", "song?:str | null"],
  "shape_sig_declared": "album?:str | null|artist?:str | null|raw_message?:str | null|song?:str | null",
  "generated": true,
  "language_data": {
    "python": {
      "bases": ["BaseModel"],
      "future_annotations": true
    }
  }
}
```

The same name `LookupRequest` exists in two modules with two different declared shapes. The catalog records both honestly — this is the *intended pattern*; it should not produce a name-collision finding in the duplication cluster query. The `package` field alone isn't enough to disambiguate; the cluster query needs to be made module-aware. The TS extractor faces the same question for re-export chains and resolves it by treating the file path as part of the dedup key. The same approach works here.

What the records *do not* capture:

- The full shape of `LookupRequest`. The declared fields are the additions only; the base-class fields live in the codegen record. Computing the "real" shape for similarity comparison requires walking the inheritance edge across modules. The catalog stores the edge; the *cluster query* walks it.
- The `conint(ge=1, le=100)` constraint. The AST sees `conint` as a function call inside a type annotation. The extractor can either record the call expression verbatim in `language_data.python.field_metadata`, or normalize it into a `{type: "int", min: 1, max: 100}` shape. The latter is more useful for queries but requires a Pydantic-aware AST walker. The illustrative records above record the constraint as opaque metadata; a richer extractor would normalize it.
- The `SerializeAsAny[DiscogsMatchResult]` annotation. The AST sees a `Subscript` node; the semantic meaning ("serialize using the runtime type, not the declared type") only matters for [Pydantic's duck-typed serialization](https://docs.pydantic.dev/latest/concepts/serialization/#serializing-with-duck-typing). This is a fidelity loss the catalog admits via `omitted_features`.
- The `from __future__ import annotations` switch at the top of [`generated/api_models.py`](https://github.com/WXYC/library-metadata-lookup/blob/main/generated/api_models.py) changes every annotation to string form per [PEP 563](https://peps.python.org/pep-0563/). The AST still parses them as expressions, but resolution requires forward-reference tracking. The catalog records `future_annotations: true` so downstream tooling can choose its resolution strategy.

The honest representation pairs each declared class with its inheritance edges. The cluster query walks edges to compute resolved shapes for comparison. This is more work than the TS extractor needs because TS's `extends` clauses are universally same-file or same-package; in Python, `extends` regularly spans the codegen boundary.

### File 3: SQL appears in three structurally different forms

**Form A — static module-level constant.** [`semantic-index/semantic_index/pg_source.py`](https://github.com/WXYC/semantic-index/blob/main/semantic_index/pg_source.py):

```python
_FLOWSHEET_SQL = """\
SELECT id, artist_name, track_title, album_title, record_label,
       show_id, play_order, album_id, request_flag,
       EXTRACT(EPOCH FROM add_time)::bigint AS add_time_epoch,
       legacy_entry_id
FROM wxyc_schema.flowsheet
WHERE entry_type = 'track'
ORDER BY show_id, play_order
"""

def load_flowsheet_entries(conn: Any) -> list[FlowsheetEntry]:
    rows = conn.execute(_FLOWSHEET_SQL).fetchall()
    ...
```

The SQL is a string literal in the AST. A SQL parser ([`sqlglot`](https://github.com/tobymao/sqlglot) or [`pglast`](https://github.com/lelit/pglast)) fed this string recovers everything: table set (`wxyc_schema.flowsheet`), column projection (eleven columns including a computed `EXTRACT(EPOCH ...)::bigint`), the literal predicate (`entry_type = 'track'`), the ordering, and (in this case) zero placeholders.

```jsonc
{
  "kind": "sql-query",
  "name": "_FLOWSHEET_SQL",
  "package": "semantic-index",
  "file": "semantic_index/pg_source.py",
  "line": 57,
  "language": "python",
  "language_data": {
    "python": {
      "composition": "static-literal",
      "execute_sites": [
        {"file": "semantic_index/pg_source.py", "line": 165, "function": "load_flowsheet_entries"}
      ]
    },
    "sql": {
      "dialect": "postgresql",
      "tables_read": ["wxyc_schema.flowsheet"],
      "tables_written": [],
      "columns_selected": ["id", "artist_name", "track_title", "album_title", "record_label", "show_id", "play_order", "album_id", "request_flag", "add_time_epoch", "legacy_entry_id"],
      "where_predicates": [{"left": "entry_type", "op": "=", "right": "'track'"}],
      "order_by": ["show_id", "play_order"],
      "placeholder_count": 0,
      "placeholder_style": null
    }
  }
}
```

The two-tier schema earns its keep here. `language_data.sql.*` is the natural home for SQL-aware fields; `language_data.python.*` records how the SQL got into the program (a module-level constant referenced by name from one or more execute sites).

**Form B — f-string composition with runtime conditionals.** [`library-metadata-lookup/library/db.py`](https://github.com/WXYC/library-metadata-lookup/blob/main/library/db.py):

```python
async def _search_uncached(
    self, query, artist, title, limit, fallback_to_like, fallback_to_fuzzy
) -> list[LibraryItem]:
    ...
    elif artist or title:
        conditions: list[str] = []
        params: list[str | int] = []
        if artist:
            if self._has_alternate_artist and self._has_album_artist:
                conditions.append(
                    "(artist LIKE ? OR alternate_artist_name LIKE ? OR album_artist LIKE ?)"
                )
                params.extend([f"%{artist}%", f"%{artist}%", f"%{artist}%"])
            elif self._has_alternate_artist:
                conditions.append("(artist LIKE ? OR alternate_artist_name LIKE ?)")
                ...

        cols = self._select_columns()
        sql = f"""
            SELECT {cols}
            FROM library
            WHERE {" AND ".join(conditions)}
            LIMIT ?
        """
```

The query is assembled at call time. The branch chosen depends on instance flags (`_has_alternate_artist`, `_has_album_artist`, `_has_label`) set by a `PRAGMA table_info` introspection at connect time. The AST recovers the *skeleton* and the *fragment alternatives*, but cannot tell you which fragment fires for any given call.

```jsonc
{
  "kind": "sql-query",
  "name": "<library.db._search_uncached:filtered-branch>",
  "package": "library-metadata-lookup",
  "file": "library/db.py",
  "line": 307,
  "language": "python",
  "language_data": {
    "python": {
      "composition": "fstring",
      "static_prefix": "SELECT <cols> FROM library WHERE <conditions> LIMIT ?",
      "fragment_alternatives": [
        "(artist LIKE ? OR alternate_artist_name LIKE ? OR album_artist LIKE ?)",
        "(artist LIKE ? OR alternate_artist_name LIKE ?)",
        "(artist LIKE ? OR album_artist LIKE ?)",
        "artist LIKE ?",
        "title LIKE ?"
      ]
    },
    "sql": {
      "dialect": "sqlite",
      "tables_read": ["library"],
      "placeholder_style": "qmark"
    }
  },
  "core_projection_complete": false,
  "omitted_features": ["runtime_branch_choice", "dynamic_column_list"]
}
```

The recoverable structure (table = `library`, primary predicate column set, LIMIT placeholder) is still worth storing. A query like "which queries touch the `library` table?" produces a useful, slightly-overcounting answer. A query like "which queries filter on `album_artist`?" requires the fragment-alternative list. The `core_projection_complete: false` marker is the catalog's honest signal that *this row, specifically, may have lost fidelity*.

**Form C — SQL files referenced from Python.** [`discogs-etl/alembic/versions/0001_initial.py`](https://github.com/WXYC/discogs-etl/blob/main/alembic/versions/0001_initial.py):

```python
_SCHEMA_DIR = Path(__file__).resolve().parents[2] / "schema"

_SCHEMA_FILES: tuple[str, ...] = (
    "create_functions.sql",
    "create_database.sql",
    "create_indexes.sql",
    "create_track_indexes.sql",
)

def upgrade() -> None:
    ...
    with psycopg.connect(db_url, autocommit=True) as conn, conn.cursor() as cur:
        ...
        for name in _SCHEMA_FILES:
            sql = (_SCHEMA_DIR / name).read_text().replace(" CONCURRENTLY", "")
            cur.execute(sql)
```

The DDL is in [`schema/create_database.sql`](https://github.com/WXYC/discogs-etl/blob/main/schema/create_database.sql) and three siblings, not in the Python AST. The Python extractor sees `.read_text()` and `cur.execute(...)`; to catalog the actual schema it has to follow the path expression to the filesystem and feed the file contents to the SQL extractor. The migration record below carries the external file references; the SQL records get produced by a separate per-file pass.

```jsonc
{
  "kind": "sql-external-reference",
  "file": "alembic/versions/0001_initial.py",
  "line": 110,
  "language": "python",
  "language_data": {
    "python": {
      "loaded_from": [
        "schema/create_functions.sql",
        "schema/create_database.sql",
        "schema/create_indexes.sql",
        "schema/create_track_indexes.sql"
      ],
      "transformations": [{"kind": "string_replace", "from": " CONCURRENTLY", "to": ""}],
      "execute_via": "psycopg.connect(..., autocommit=True).cursor().execute"
    }
  }
}
```

The Python catalog references SQL files by path; a SQL extractor processes them separately. This is the structural analogue of `pipeline-contract.md`'s `--shared` flag for the TS extractor — the catalog spans multiple roots whose languages differ.

### File 4: dependency injection encoded as default-arg expressions

[`library-metadata-lookup/core/dependencies.py`](https://github.com/WXYC/library-metadata-lookup/blob/main/core/dependencies.py) follows a consistent pattern across every service provider:

```python
_library_db: LibraryDB | None = None

async def get_library_db(settings: Settings = Depends(get_settings)) -> LibraryDB:
    global _library_db

    if _library_db is None:
        try:
            db_path = settings.resolved_library_db_path
            _library_db = LibraryDB(db_path=db_path)
            await _library_db.connect()
            logger.info(f"Library database connected: {db_path}")
        except FileNotFoundError:
            logger.warning(...)
        except Exception as e:
            logger.error(f"Failed to initialize library database: {e}")
            raise ServiceInitializationError(...) from e

    assert _library_db is not None
    return _library_db

async def close_library_db() -> None:
    global _library_db
    if _library_db:
        await _library_db.close()
        _library_db = None
```

The `Depends(get_settings)` in the parameter default is a dependency-graph edge: `get_library_db → get_settings`. The module-level `_library_db: LibraryDB | None = None` plus `if _library_db is None: ... = LibraryDB(...)` is a recognizable singleton idiom. The `close_library_db` companion (and its presence in [`main.py`](https://github.com/WXYC/library-metadata-lookup/blob/main/main.py)'s lifespan shutdown) closes the lifecycle:

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    ...
    yield
    ...
    await close_library_db()
    await close_discogs_service()
    ...
```

The record:

```jsonc
{
  "kind": "fastapi-dependency",
  "name": "get_library_db",
  "package": "library-metadata-lookup",
  "file": "core/dependencies.py",
  "line": 31,
  "language": "python",
  "language_data": {
    "python": {
      "returns": "LibraryDB",
      "depends_on": ["core.dependencies.get_settings"],
      "is_async": true,
      "singleton": true,
      "singleton_state_name": "_library_db",
      "lifecycle_close": "core.dependencies.close_library_db",
      "errors_raised": ["ServiceInitializationError"]
    }
  }
}
```

`singleton` and `lifecycle_close` are heuristics (the singleton heuristic: a module-level `_name: T | None = None` mutated only inside the provider; the lifecycle-close heuristic: a sibling function named `close_<name>` that resets the same state). Heuristics are admissible at the catalog layer because they are disprovable from the source — any reader can verify the heuristic against the file at the recorded line.

The DI graph becomes a query: every route handler (file 1) plus every dependency provider (file 4) compose into a directed graph rooted at the FastAPI app. "Find every route that transitively depends on `get_discogs_service`" is a graph traversal. "Find dependencies declared but never wired into a route" is an anti-join. These are the kinds of cross-cutting structural questions [`future-directions.md`](future-directions.md) §2 (the catalog as a universal structural index) anticipates becoming joins rather than audits.

### File 5: strategy registry with tag dispatch

[`library-metadata-lookup/core/search.py`](https://github.com/WXYC/library-metadata-lookup/blob/main/core/search.py) declares a closed set of strategy tags, a dataclass holding two callables, a builder function, and a dispatcher that pattern-matches on the tag:

```python
class SearchStrategyType(StrEnum):
    ARTIST_PLUS_ALBUM = "artist_plus_album"
    SWAPPED_INTERPRETATION = "swapped_interpretation"
    TRACK_ON_COMPILATION = "track_on_compilation"
    SONG_AS_ARTIST = "song_as_artist"
    ...

@dataclass
class SearchStrategy:
    name: SearchStrategyType
    condition: ConditionFunc
    execute: ExecuteFunc
    updates_song_not_found: bool = False
    updates_discogs_titles: bool = False

def build_strategies(
    search_library_func: ExecuteFunc,
    search_alternative_func: ExecuteFunc,
    search_compilations_func: ExecuteFunc,
    search_song_as_artist_func: ExecuteFunc | None = None,
) -> list[SearchStrategy]:
    strategies = [
        SearchStrategy(name=SearchStrategyType.ARTIST_PLUS_ALBUM, ...),
        SearchStrategy(name=SearchStrategyType.SWAPPED_INTERPRETATION, ...),
        SearchStrategy(name=SearchStrategyType.TRACK_ON_COMPILATION, ...),
    ]
    if search_song_as_artist_func is not None:
        strategies.append(SearchStrategy(name=SearchStrategyType.SONG_AS_ARTIST, ...))
    return strategies

async def execute_search_pipeline(...) -> SearchState:
    ...
    for strategy in strategies:
        ...
        if strategy.name == SearchStrategyType.ARTIST_PLUS_ALBUM:
            results, fallback_used = await strategy.execute(...)
            ...
        elif strategy.name == SearchStrategyType.TRACK_ON_COMPILATION:
            results, discogs_titles = await strategy.execute(...)
            ...
```

Three records cover the structural surface: the enum, the dataclass, and the builder function. The dispatcher is implementation detail — its branches mirror the enum cases, and any future case added without being dispatched is caught by `mypy`'s exhaustiveness checking, not by the structural extractor.

```jsonc
{
  "kind": "enum",
  "name": "SearchStrategyType",
  "package": "library-metadata-lookup",
  "file": "core/search.py",
  "line": 60,
  "language": "python",
  "language_data": {
    "python": {
      "base": "StrEnum",
      "members": [
        {"name": "ARTIST_PLUS_ALBUM", "value": "artist_plus_album"},
        {"name": "ARTIST_ONLY", "value": "artist_only"},
        {"name": "SWAPPED_INTERPRETATION", "value": "swapped_interpretation"},
        {"name": "TRACK_ON_COMPILATION", "value": "track_on_compilation"},
        {"name": "SONG_AS_ARTIST", "value": "song_as_artist"},
        {"name": "KEYWORD_MATCH", "value": "keyword_match"}
      ]
    }
  }
}
```

```jsonc
{
  "kind": "dataclass",
  "name": "SearchStrategy",
  "package": "library-metadata-lookup",
  "file": "core/search.py",
  "line": 142,
  "language": "python",
  "fields": [
    "condition:ConditionFunc",
    "execute:ExecuteFunc",
    "name:SearchStrategyType",
    "updates_discogs_titles:bool",
    "updates_song_not_found:bool"
  ],
  "shape_sig": "condition:conditionfunc|execute:executefunc|name:searchstrategytype|updates_discogs_titles:bool|updates_song_not_found:bool",
  "language_data": {
    "python": {
      "decorator": "@dataclass",
      "field_defaults": {"updates_song_not_found": false, "updates_discogs_titles": false}
    }
  }
}
```

The closed-set property of `StrEnum` is the catalog's anchor for exhaustiveness queries. The dataclass record gives the strategy's contract. Together they describe everything the runtime registry will hold; the runtime registry itself (the list returned by `build_strategies`) is constructed at call time and doesn't need to be cataloged separately — `build_strategies` shows up as a function whose return type is `list[SearchStrategy]`, and that's enough to answer "where are SearchStrategy registries built?"

This is structurally the Python analogue of the Swift `MainActorNotificationMessage` PAT walked in [`swift-extractor-design-notes.md`](swift-extractor-design-notes.md) File 3 — declarative contract with runtime polymorphism, captured fully at the structural level. The principle holds without qualification on this file.

### File 6: PyO3 puts the implementation across a language boundary

[`library-metadata-lookup/library/db.py`](https://github.com/WXYC/library-metadata-lookup/blob/main/library/db.py) imports from a compiled extension:

```python
from wxyc_etl.schema import library_columns
from wxyc_etl.text import to_match_form as normalize_for_comparison
```

The package's [`__init__.py`](https://github.com/WXYC/wxyc-etl/blob/main/wxyc-etl-python/python/wxyc_etl/__init__.py) is a passthrough:

```python
from . import _native
from ._native import (
    fuzzy,
    import_utils,
    parser,
    schema,
    state,
    text,
)

__all__ = ["fuzzy", "import_utils", "logger", "parser", "schema", "state", "text"]
```

The actual implementations live in [Rust](https://github.com/WXYC/wxyc-etl/blob/main/wxyc-etl-python/src/lib.rs):

```rust
#[pymodule]
fn _native(py: Python, m: &Bound<'_, PyModule>) -> PyResult<()> {
    register_submodule(py, m, "text", text::register)?;
    register_submodule(py, m, "parser", parser::register)?;
    ...
}
```

And [`text.rs`](https://github.com/WXYC/wxyc-etl/blob/main/wxyc-etl-python/src/text.rs):

```rust
pub fn register(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(to_match_form, m)?)?;
    m.add_function(wrap_pyfunction!(strip_diacritics, m)?)?;
    ...
}

#[pyfunction]
fn to_match_form(s: &str) -> PyResult<String> { ... }
```

The Python AST sees, exhaustively:

- An `ImportFrom` node referencing `wxyc_etl.text.to_match_form`
- A `Call` node `to_match_form(query)` at every use site

That's it. There is no `.py` file containing `to_match_form`'s signature. The `__init__.py` is genuinely empty of structural content — it re-exports a binary module. From the Python catalog's vantage, `wxyc_etl.text.*` is an opaque vocabulary of names.

Three paths, mirroring the Swift macro decision in [`swift-extractor-design-notes.md`](swift-extractor-design-notes.md):

**Path 1 — parse Python only.** Record the import edge and the call sites; treat `wxyc_etl.text.*` as opaque vocabulary. The catalog answers "which Python files use the wxyc-etl text functions?" but cannot answer "what is the signature of `to_match_form`?"

```jsonc
{
  "kind": "external-import",
  "module": "wxyc_etl.text",
  "name": "to_match_form",
  "import_kind": "native-extension",
  "file": "library/db.py",
  "line": 9,
  "language": "python",
  "language_data": {
    "python": {
      "imported_as": "normalize_for_comparison",
      "implementation_language": "rust",
      "implementation_package": "wxyc-etl",
      "resolution": "opaque"
    }
  }
}
```

**Path 2 — parse Python + parse Rust.** Write a sibling Rust extractor that walks `#[pyfunction]` attributes (Rust's [`syn`](https://github.com/dtolnay/syn) parses these into structured AST nodes whose `fn` signatures are statically available) and emits records under the Python-visible qualified name (`wxyc_etl.text.to_match_form`). The Python record references the Rust record by name; cross-language join becomes a `JOIN ON name` query.

```jsonc
{
  "kind": "pyo3-function",
  "name": "to_match_form",
  "python_module": "wxyc_etl.text",
  "package": "wxyc-etl",
  "file": "wxyc-etl-python/src/text.rs",
  "line": 144,
  "language": "rust",
  "language_data": {
    "rust": {
      "fn_signature": "fn to_match_form(s: &str) -> PyResult<String>",
      "pyo3_attribute": "#[pyfunction]",
      "registered_in": "register@wxyc-etl-python/src/text.rs"
    },
    "python": {
      "qualified_name": "wxyc_etl.text.to_match_form"
    }
  }
}
```

**Path 3 — parse Python + parse `.pyi` type stubs.** If a `wxyc_etl/__init__.pyi` or `wxyc_etl/text.pyi` existed with declared signatures, parse it with the Python extractor (same AST, same code). None exists today; this path is hypothetical for this codebase. It's the lightest-weight path *if and only if* there's a convention to maintain stubs in sync with the Rust source, which adds documentation overhead without runtime enforcement.

Path 1 is the right v1. It captures the import edges; downstream queries that need PyO3 signatures can adopt Path 2 incrementally without disturbing what's already shipped. Path 2 is the right answer if and when WXYC has multiple PyO3 libraries and wants cross-boundary structural queries; until then it's premature infrastructure of exactly the kind a prior adversarial review of this project's roadmap warned against (the live-or-die instinct to build platform infrastructure before there's evidence of a second consumer).

This is the strongest stress test of the deterministic-extraction principle in the Python stack — stronger than any single Swift macro because the implementation is *in another language's source tree entirely*, not in another AST pass within the same language. The principle survives via Path 2, conditional on the cross-language join being worth its weight; absent that condition, the catalog admits the limit and the AST-only Python extractor moves on.

### File 7: an Alembic migration as versioned Python AST

[`discogs-etl/alembic/versions/0001_initial.py`](https://github.com/WXYC/discogs-etl/blob/main/alembic/versions/0001_initial.py):

```python
revision: str = "0001_initial"
down_revision: str | Sequence[str] | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

def upgrade() -> None:
    if context.is_offline_mode():
        raise RuntimeError(...)
    db_url = os.environ.get("DATABASE_URL_DISCOGS") or os.environ.get("DATABASE_URL")
    ...
    with psycopg.connect(db_url, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT to_regclass('public.release') IS NOT NULL "
            "AND to_regclass('public.cache_metadata') IS NOT NULL"
        )
        if cur.fetchone()[0]:
            logging.getLogger("alembic.runtime.migration").warning(...)
            return

        for name in _SCHEMA_FILES:
            sql = (_SCHEMA_DIR / name).read_text().replace(" CONCURRENTLY", "")
            cur.execute(sql)


def downgrade() -> None:
    raise NotImplementedError("0001_initial is the baseline migration; downgrade is not supported.")
```

Alembic's shape is fixed: four module-level identifiers (`revision`, `down_revision`, `branch_labels`, `depends_on`) plus two functions (`upgrade`, `downgrade`). The four identifiers describe the migration DAG; the two functions describe forward and reverse DDL operations. Together they constitute a complete record of what schema change this revision applies and how it composes with siblings.

This particular migration is unusual — it applies external SQL files via a side-channel `psycopg.connect(..., autocommit=True)` rather than the conventional `op.add_column(...)` / `op.execute(...)` calls. So its `upgrade_ops` list points to external SQL files (File 3 Form C above) rather than to AST-resident DDL calls. Most Alembic migrations use the `op` API:

```python
def upgrade() -> None:
    op.add_column("artists", sa.Column("normalized_name", sa.Text, nullable=True))
    op.create_index("ix_artists_normalized_name", "artists", ["normalized_name"])
```

For those, the DDL operations are fully in the AST; the migration record carries them as structured ops.

```jsonc
{
  "kind": "migration",
  "name": "0001_initial",
  "package": "discogs-etl",
  "file": "alembic/versions/0001_initial.py",
  "line": 29,
  "language": "python",
  "language_data": {
    "python": {
      "migration_framework": "alembic",
      "revision": "0001_initial",
      "down_revision": null,
      "branch_labels": null,
      "depends_on": null,
      "upgrade_ops": [
        {"op": "external-sql-file", "path": "schema/create_functions.sql", "transformations": [{"kind": "string_replace", "from": " CONCURRENTLY", "to": ""}]},
        {"op": "external-sql-file", "path": "schema/create_database.sql"},
        {"op": "external-sql-file", "path": "schema/create_indexes.sql"},
        {"op": "external-sql-file", "path": "schema/create_track_indexes.sql"}
      ],
      "downgrade_ops": [{"op": "raise", "exception": "NotImplementedError"}],
      "guards": [
        {"kind": "offline-mode-check", "behavior": "refuse"},
        {"kind": "schema-presence-check", "tables": ["public.release", "public.cache_metadata"], "behavior": "skip-with-warning"}
      ]
    }
  }
}
```

Alembic migrations and Drizzle migrations encode the same conceptual record in different DSLs. A shared `migration` kind across languages — with `language_data.<lang>.*` carrying the host-specific bits (Alembic's `op.add_column` shape vs Drizzle's table-builder shape) — is the natural application of the two-tier schema sketched in [`pipeline-contract.md`](pipeline-contract.md). A cluster query like "find every migration that adds a column without a default, then find every migration reachable in the same revision DAG that backfills it" works across both DSLs if the records share the kind name and the upgrade-op shape is normalized.

## Source AST vs runtime structure

The deterministic-extraction principle survives in Python in a specific form, mirroring the source-AST vs expanded-AST distinction drawn in [`swift-extractor-design-notes.md`](swift-extractor-design-notes.md) but with a different center of gravity.

In Swift, the AST is a static thing the parser produces from bytes on disk; macros synthesize *additional* nodes only after a plugin process runs. The three paths there are parse-only, parse + macro-contract-join, or parse + actually expand.

In Python, the AST stays static — Python's [`ast`](https://docs.python.org/3/library/ast.html) module is in the stdlib and `ast.parse(source)` returns the full tree of what's written. What Python adds is a *different* gap: the parser sees decorator application sites, class declarations, function calls, and imports, but everything that *runs at import time* is invisible until the module is actually imported. The metaclass behind `BaseModel` synthesizes `__init__`, `__fields__`, validators, and JSON schema at class creation. The `@router.post(...)` decorator pushes a route object onto the router's internal list and the route is finalized only after `include_router` fires. The `@dataclass` decorator synthesizes `__init__`, `__repr__`, `__eq__`. The `@asynccontextmanager` decorator wraps a generator function as a context-manager factory.

The three paths reappear in Python, with names adapted to the substrate:

1. **Parse only.** Treat decorators as opaque metadata: record their names and arguments, walk on. Adequate for most catalog questions about declared shape; will miss "what runtime structure does this decorator produce?" entirely.

2. **Parse + recognize known decorators.** Enumerate the well-known decorators in the WXYC stack — `@router.<verb>` (FastAPI), `@app.middleware` (FastAPI), `@app.exception_handler` (FastAPI), `@dataclass` (stdlib), `BaseModel` subclass (Pydantic), `@asynccontextmanager` (stdlib) — and apply their known semantics during extraction. Pydantic models become `pydantic-model` records; FastAPI routes become `fastapi-route` records; dataclasses become `dataclass` records. This is the recommended middle ground, structurally analogous to Path 2 in the Swift study.

3. **Import the module and inspect.** Actually run the import to materialize `app.routes`, `<PydanticModel>.__fields__`, etc. Same risk as the Swift Path 3: side effects, env-var dependence, slow, lights up the module's transitive import graph (which for a FastAPI service is the entire application). Useful for diagnostics, wrong for extraction.

Path 2 is what this study recommends. It buys most of the structural-query value without crossing into "run the application" territory. It preserves the byte-reproducible-from-source-files property the catalog depends on. And it bounds the implementation surface: the recognized-decorator list is short (maybe ten entries to cover the WXYC stack comprehensively), stable (FastAPI and Pydantic don't reinvent their conventions often), and self-documenting (the catalog is honest about which decorators it recognized and which it left opaque).

Two Python-specific complications worth naming:

- **`from __future__ import annotations`** changes every annotation in a file to string form per [PEP 563](https://peps.python.org/pep-0563/). The AST still parses annotations as expressions, but resolution to actual types requires either name-table walking or runtime [`typing.get_type_hints`](https://docs.python.org/3/library/typing.html#typing.get_type_hints). The catalog records the `future_annotations: true` flag per file so downstream tooling chooses its resolution strategy.
- **PyO3 boundaries** are a fourth case Swift didn't have. The Python module is a passthrough to a compiled extension; the implementation lives in Rust source. None of Paths 1, 2, or 3 (within Python) recovers what those functions do. The honest options are accept-as-opaque (Path 1 above) or cross-language join (Path 2, in a different sense: parse Rust separately and join on qualified name).

The principle [deterministic extraction, agentic synthesis](../CLAUDE.md) holds in Python in two specific senses: structurally-rich features that look dynamic (Pydantic models, FastAPI routes, dataclasses) are *deterministically extractable* once the recognized-decorator vocabulary is in place; features that are genuinely dynamic at runtime (importlib dispatch, `__getattr__` modules, dynamic SQL composition past a static prefix) are admitted in `omitted_features` rather than papered over. The hard limit — PyO3 — is admitted in the same way, by recording the import edge and stopping there.

## Where the principle holds, bends, breaks

Across the seven files surveyed:

**Holds cleanly.** Function signatures (including async/await, parameter types, return types, generic parameters, default values). Plain Pydantic models and dataclass declarations with their declared fields. StrEnum / IntEnum members and `Literal[...]` closed sets. Module-level constants assigned simple expressions. Import edges. The strategy-and-tag-dispatch pattern (File 5). The Alembic migration DAG metadata (File 7 module-level identifiers). Static SQL constants (File 3 Form A). The DI graph encoded in `Depends(...)` default values (File 4). Type-alias declarations (`Foo = Bar | None`) and `TypeAlias` annotations. All of this lives in the source AST and the extractor captures it deterministically. The principle holds without qualification.

**Bends — survives via `language_data.python.*` extensions or via new kinds, with `core_projection_complete: false` markers where appropriate.** FastAPI routes (File 1) require composition across three places to compute the actual path and auth posture; an extractor that walks only one place gets the route wrong. Pydantic inheritance (File 2) crosses the codegen boundary, and shape-similarity comparison requires walking the inheritance edge; the catalog stores the edge but the cluster query walks it. F-string SQL (File 3 Form B) loses the runtime branch choice; static prefix and fragment alternatives are still recoverable. External SQL files (File 3 Form C) require a follow-the-path side trip; the Python catalog references the files but a separate SQL extractor processes them. Recognized decorators are captured structurally; unrecognized decorators are recorded by name and argument list but their semantics are admitted as opaque.

**Breaks — requires honest fidelity-loss markers, sibling cross-language extractors, or path-3 import-time inspection.** PyO3 boundaries (File 6): the implementation lives in Rust source; Python sees the import edge and nothing more. The pragmatic responses are accept-as-opaque or write a sibling Rust extractor. Dynamic imports via [`importlib.import_module(...)`](https://docs.python.org/3/library/importlib.html) with string-valued module names: the AST sees a function call; the dispatched module is unknown until runtime. Metaclass injection beyond well-known patterns (Pydantic, dataclass): an arbitrary metaclass can do anything; the catalog can only record `metaclass=<name>` and stop. [`__getattr__` modules](https://peps.python.org/pep-0562/) that synthesize names at attribute access. Dynamic SQL composition past a static prefix (the f-string case is partial; pure string concatenation through a builder pattern is worse). And, in principle, runtime monkey-patching of any of the above — none observed in the surveyed files, but the principle's reach ends at runtime mutation regardless.

That third bucket is the honest limit. The extractor marks these in `omitted_features` and accepts that some questions are undercounted, or grows a sibling tool, or imports the code at the cost of breaking byte-reproducibility.

## Comparison to Swift

The shape of the analysis is remarkably similar across the two languages — which is itself a finding, and one that should inform the eventual schema decisions.

| Concern | Swift | Python |
|---|---|---|
| Application-site visible, synthesis invisible | Macros | Decorators, metaclasses |
| Recommended middle path | Parse + read macro contracts + join | Parse + recognize known decorators |
| Cross-language boundary | None in `wxyc-ios-64` (Obj-C interop possible in principle) | PyO3 in `semantic-index`, `library-metadata-lookup`, others |
| Inheritance for shape comparison | Protocols + conformances | Class hierarchy + Pydantic codegen |
| AST-as-strings cases | Existential `any P`, opaque `some P` | `from __future__ import annotations`, forward refs |
| Runtime polymorphism with declarative contract | PATs | Strategy dataclass + StrEnum dispatch |
| Substrate library for extractor | [`swift-syntax`](https://github.com/swiftlang/swift-syntax) | [`ast`](https://docs.python.org/3/library/ast.html) (stdlib) |

Two places Python is structurally *harder* than Swift:

1. **PyO3 strictly breaks the principle.** Swift macros can be expanded in-language if you invoke the plugin process; Rust source cannot be parsed by a Python tool without writing a sibling extractor in Rust. This is the only structural feature in the surveyed code that is unreachable from the Python AST regardless of effort.
2. **The route-composition join is genuinely worse.** Swift's `View.body` doesn't have an `include_router`-style remount; Python's three-place join (decorator + `APIRouter` + `include_router`) means a naive extractor produces wrong route paths and silently loses the auth contract. The Swift study's File 3 (PATs) was the structurally richest single record; Python's File 1 (routes) is the structurally most *brittle* single record — easy to extract incorrectly.

Two places Python is structurally *easier*:

1. **The AST is in stdlib.** No `swift-syntax` dependency tree, no plugin protocol, no platform-specific build. `import ast; ast.parse(source)` and walk. Per-file parse time is on the order of 1 ms for small files, 10–20 ms for large ones; the entire `library-metadata-lookup` codebase parses in well under a second. This makes the per-commit time-series direction in [`future-directions.md`](future-directions.md) §1 cheaper for Python than for Swift by roughly an order of magnitude.
2. **Pydantic and FastAPI are closed conventions.** Their decorators have predictable semantics. The Path-2 recognized-decorator list is short and stable. Swift's macro ecosystem is more open-ended — anyone can write a macro plugin; recognizing every plugin's contract requires reading every macro declaration. Python's relevant decorators are mostly first-party to a handful of well-known libraries.

One important place where the Python and Swift findings *converge*, and which deserves to be ratified rather than re-discovered: both studies recommend Path 2 (parse + recognize contracts) as the structurally honest middle ground. The Swift study labeled this "parse + read macro contracts + join"; the Python study labels it "parse + recognize known decorators". They are the same approach, applied to different language features. The catalog should treat them as instances of a common pattern — *declarative contracts statically extractable from the source, joined against application sites* — rather than as language-specific solutions to language-specific problems.

## Implications for the extractor design

A few conclusions crystallize once the analysis is grounded in real code rather than abstract taxonomy.

**The catalog needs new kinds again, and some of them straddle languages.** Python's new kinds: `pydantic-model`, `fastapi-route`, `fastapi-dependency`, `enum` (StrEnum / IntEnum), `dataclass`, `sql-query`, `sql-external-reference`, `migration` (Alembic flavor), `external-import` (for PyO3 and unresolved imports). Of these, `migration` and `sql-query` straddle languages — Drizzle migrations and Alembic migrations are different DSLs encoding the same conceptual record; static SQL in `psycopg.execute` and static SQL in TypeScript's `db.raw(...)` are different host languages embedding the same SQL dialect. Encoding these cross-language commonalities as shared kinds (with `language_data.<lang>.*` carrying the host-specific bits) is the natural application of the two-tier schema [`pipeline-contract.md`](pipeline-contract.md) sketches.

**The two-tier schema earns more of its keep in Python than in Swift.** The Swift study concluded that PATs, isolation, retroactive flags, and where clauses are language-specific and have no cross-language analog. The Python study finds the opposite for SQL and migrations: these are *natural* cross-language joins. A query like "find every migration that adds a column" should work the same whether the source is `op.add_column(...)` in an Alembic file or `pgTable("...").addColumn(...)` in a Drizzle one. The two-tier schema's central premise — `language_data.*` extension namespaces with a thin shared core — finds its strongest justification here, not in Swift.

**The recognized-decorator list is the contract.** Path 2 says "parse the AST, then apply known semantics to recognized decorator names." The catalog should document the recognized list as a first-class artifact — what decorators map to what kinds — and treat additions to the list as schema events. This is the Python analogue of the Swift `macro_definition` registry, except Python's recognized list is hardcoded in the extractor rather than discovered from the source. Same idea, different ingestion mechanism.

**FastAPI route composition needs an explicit graph walk in the extractor.** A naive per-file pass over `@router.post(...)` decorators produces wrong paths and missing auth. The extractor needs to (a) walk every `APIRouter(...)` instantiation to a per-router prefix table, (b) walk every `@<router>.<verb>(...)` decorator to a per-route record carrying decorator metadata and handler-signature DI edges, (c) walk every `app.include_router(<router>, prefix=..., dependencies=...)` call to bind routers into the app's path space. The final route record carries the composition resolved. Without this, the route catalog is a footgun.

**SQL deserves its own extractor pass, called as a sibling to the Python pass.** The Python pass finds SQL literals, f-strings, and external file references. The SQL pass (using e.g. [`sqlglot`](https://github.com/tobymao/sqlglot) or [`pglast`](https://github.com/lelit/pglast)) parses each SQL string into a structured shape. The Python catalog references SQL records by an internal ID; the SQL catalog is a separate artifact with its own queries. This is the Python analogue of `--shared` in the TS extractor's CLI — multiple roots with multiple languages, joined by reference. Cross-language pipelines become the norm, not the exception.

**PyO3 should be treated as opaque in v1.** The cross-language join is structurally sensible (File 6 Path 2) but premature for a one-extractor pipeline. The catalog records the import edges; if and when a second PyO3 library shows up or a query genuinely depends on knowing PyO3 signatures, the Rust extractor gets written. Until then, recording the boundary as a boundary is sufficient.

**Worktree exclusion is load-bearing for Python too.** WXYC's Python repos use `.worktrees/` and `.venv/` directories at the top level, plus `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`, and `__pycache__/` directories scattered throughout. Running the extractor without exclusion produces order-of-magnitude inflation from `.venv/lib/python3.12/site-packages/`. The dotdir-skipping convention in [`pipeline-contract.md`](pipeline-contract.md#what-to-skip) plus exclusion of `__pycache__/`, `*.egg-info/`, and `node_modules/` covers what's needed.

## Recommended order of operations

The Swift study's recommended order applies, adapted to the Python substrate:

1. **Write the Python extractor as a single file**, in the same shape as the TS one. Use [`ast`](https://docs.python.org/3/library/ast.html) from stdlib. Emit records to stdout. Cover `pydantic-model`, `fastapi-route` (with composition resolved), `fastapi-dependency`, `dataclass`, `enum`, `function` (signatures), `sql-query` (static only at first), `sql-external-reference`, `migration` (Alembic), `external-import`. Lose fidelity in the obvious places and record what was lost as informal `omitted_features` strings — do not formalize the schema extension yet.
2. **Run it against [`library-metadata-lookup`](https://github.com/WXYC/library-metadata-lookup)**. See what the catalog looks like. Check whether the existing [jq queries](../pipeline/queries/) (exact duplicates, name collisions, near-duplicates) produce useful output. They probably will not without modification — Python's duplication patterns differ from TS — but the route and dependency catalogs will already enable new queries (route-without-auth, dependency-without-route, route-pair-with-overlapping-paths).
3. **Then run it against [`request-o-matic`](https://github.com/WXYC/request-o-matic)**. The shapes should match library-metadata-lookup's closely (it's the same FastAPI + Pydantic + asyncpg pattern), which is a useful sanity check on the Path-2 recognized-decorator list.
4. **Then run it against [`semantic-index`](https://github.com/WXYC/semantic-index)** to see what the PyO3 boundary actually does to the catalog in practice. The hypothesis: import edges show up cleanly, `wxyc_etl.*` calls become opaque, and that's fine for the questions you actually want to ask. If the hypothesis fails — if PyO3-signature questions turn out to be load-bearing — that's the trigger to write the Rust sibling extractor for Path 2 in earnest.
5. **Write two or three new queries specific to what surfaces.** Plausible candidates: "routes mounted without an auth dependency" (from File 1 records), "Pydantic models in `lookup.models` whose declared fields collide with the codegen base" (from File 2 records), "migrations that add a column without a default in revision DAGs where no later migration backfills it" (from File 7 records). Run them. Look at output.
6. **With three languages — TS, Swift, Python — and a handful of real queries, look for what the core projection should actually be.** Do not guess. The shape will be obvious by then. The likely answer, anticipated in [`swift-extractor-design-notes.md`](swift-extractor-design-notes.md): `kind`, `name`, `file`, `line`, `language`, `package`, `shape_sig`, `relations[]`, with everything else in `language_data.<lang>.*`. The Python study agrees but adds: `migration` and `sql-query` are *structurally* shared kinds whose `language_data.<lang>.*` carries thin host-specific bits — the schema should accommodate that.

This sequence treats the catalog schema as something to *derive from evidence*, not *impose ahead of evidence*. The previous instinct — write the JSON Schema, build the conformance suite, set up CI gates first — was the wrong order; it would have baked in a TS-shaped core and the wrong abstractions before the Python and Swift extractors existed to disprove them.

## One prediction

The Python extractor will produce its highest-leverage cross-cutting catalog row in *routes*, not in types. Type duplication in Python is real but the codegen pattern (`@wxyc/shared` → Pydantic in two languages → consumed by services) already attacks it at the source; cluster queries on Python types will mostly surface what the codegen already prevents. Routes, by contrast, are *not* codegen-protected. Each FastAPI service declares its own routes idiomatically; the `@router.post` decorator and the `include_router` wiring are written by hand; the auth dependency is added at the wiring site, not generated. A catalog of routes across all three of [`library-metadata-lookup`](https://github.com/WXYC/library-metadata-lookup), [`request-o-matic`](https://github.com/WXYC/request-o-matic), and [`semantic-index`](https://github.com/WXYC/semantic-index) will surface inconsistencies in auth posture, path conventions, response-model usage, and OpenAPI metadata that no single-service review catches. The TS analogue of this — Express route catalogs — is one of the candidates in [`future-directions.md`](future-directions.md) §2; the Python extractor lands it for FastAPI services as a side effect of File 1's machinery.

That single observation is the most actionable take-away from this study. It is also the easiest to falsify by writing the extractor and seeing what queries are actually useful.

## See also

- [`CLAUDE.md`](../CLAUDE.md) — the principle, the layout, the extractor-adding instructions, the jq gotchas
- [`docs/pipeline-contract.md`](pipeline-contract.md) — the current schema, which this study implicitly proposes evolving
- [`docs/case-study.md`](case-study.md) — the TS origin story
- [`docs/swift-extractor-design-notes.md`](swift-extractor-design-notes.md) — the sibling study; shares the source-AST-vs-runtime-structure framing and the Path-2 recommendation
- [`docs/future-directions.md`](future-directions.md) — particularly §1 (time as a first-class dimension), §2 (broader catalog kinds), §3 (substrate evolution), and §5 (the case-study library)
- [`extractors/typescript/type-catalog.mjs`](../extractors/typescript/type-catalog.mjs) — the TS reference implementation

External references for the Python constructs surveyed:

- [The Python `ast` module](https://docs.python.org/3/library/ast.html) — stdlib parser and AST; the substrate for the Python extractor
- [FastAPI](https://fastapi.tiangolo.com/) — particularly [Dependencies](https://fastapi.tiangolo.com/tutorial/dependencies/), [Bigger Applications](https://fastapi.tiangolo.com/tutorial/bigger-applications/) (`include_router`), and [Path Operation Configuration](https://fastapi.tiangolo.com/tutorial/path-operation-configuration/) (decorator metadata)
- [Pydantic v2](https://docs.pydantic.dev/latest/) — particularly [Models](https://docs.pydantic.dev/latest/concepts/models/), [Fields](https://docs.pydantic.dev/latest/concepts/fields/), [Serialization](https://docs.pydantic.dev/latest/concepts/serialization/) (covers `SerializeAsAny`), and [Types](https://docs.pydantic.dev/latest/api/types/) (covers `conint` / `confloat`)
- [`datamodel-code-generator`](https://github.com/koxudaxi/datamodel-code-generator/) — the OpenAPI → Pydantic codegen used to produce `generated/api_models.py`
- [PEP 484 Type Hints](https://peps.python.org/pep-0484/), [PEP 526 Variable Annotations](https://peps.python.org/pep-0526/), [PEP 563 Postponed Evaluation of Annotations](https://peps.python.org/pep-0563/) — the type-annotation evolution
- [PEP 562 Module `__getattr__` and `__dir__`](https://peps.python.org/pep-0562/) — the runtime-name-synthesis case referenced in "where the principle breaks"
- [Alembic](https://alembic.sqlalchemy.org/) — particularly [Operations](https://alembic.sqlalchemy.org/en/latest/ops.html) (the `op` API) and the [tutorial on migration scripts](https://alembic.sqlalchemy.org/en/latest/tutorial.html#create-a-migration-script)
- [PyO3](https://pyo3.rs/) and [`maturin`](https://www.maturin.rs/) — the Rust ↔ Python interop story
- [`syn`](https://github.com/dtolnay/syn) — the Rust parser whose `#[pyfunction]` attribute extraction would back the Path-2 sibling Rust extractor
- [asyncpg](https://magicstack.github.io/asyncpg/current/) and [psycopg](https://www.psycopg.org/psycopg3/docs/) — the PostgreSQL async drivers used in `library-metadata-lookup` and `discogs-etl` respectively
- [aiosqlite](https://aiosqlite.omnilib.dev/) — the async SQLite driver underneath `library/db.py`
- [SQLite FTS5](https://www.sqlite.org/fts5.html) — the full-text search engine `library/db.py` queries via `MATCH ?`
- [PostgreSQL pg_trgm](https://www.postgresql.org/docs/current/pgtrgm.html) — the trigram-similarity extension `discogs/cache_service.py` uses via the `%` operator
- [`sqlglot`](https://github.com/tobymao/sqlglot) and [`pglast`](https://github.com/lelit/pglast) — candidate SQL parsers for the sibling SQL extractor

WXYC repository references:

- [`library-metadata-lookup`](https://github.com/WXYC/library-metadata-lookup) — primary anchor for this study
- [`request-o-matic`](https://github.com/WXYC/request-o-matic) — secondary FastAPI service for cross-service validation
- [`semantic-index`](https://github.com/WXYC/semantic-index) — the PyO3 hybrid case
- [`discogs-etl`](https://github.com/WXYC/discogs-etl) — the Alembic migration anchor
- [`wxyc-etl`](https://github.com/WXYC/wxyc-etl) — the Rust crate exposing `wxyc_etl` to Python via PyO3
- [`wxyc-shared`](https://github.com/WXYC/wxyc-shared) — the OpenAPI source for the Pydantic codegen
