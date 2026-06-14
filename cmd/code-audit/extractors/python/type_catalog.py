#!/usr/bin/env python3
"""type_catalog.py — Python AST extractor for the cross-cutting catalog.

Walks every .py source file under --root (and optionally --shared) and emits
one JSON record per declared class / TypedDict / Pydantic model / dataclass /
NamedTuple / Protocol / Enum / type alias.

Each record carries a deterministic `shape_sig` so downstream cluster queries
can group duplicates with `jq`.

See ../../docs/pipeline-contract.md for the emitted schema.
"""

from __future__ import annotations

import argparse
import ast
import datetime
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _lib import (  # noqa: E402
    EXTRACTOR_VERSION,
    FINGERPRINT_V,
    LANGUAGE,
    SCHEMA_VERSION,
    annotation_text,
    compute_source_sha,
    is_generated,
    is_test_path,
    make_extractor_block,
    shape_sig,
    walk_python_files,
    write_catalog,
)

# --- Built-in / utility type denylist (mirrors the TS BUILTIN_TYPE_DENYLIST) ---
# Names excluded from `references` so they don't dominate the graph.
BUILTIN_TYPE_DENYLIST = frozenset({
    # PEP 585 / typing builtins
    "Optional", "Union", "List", "Dict", "Set", "Tuple", "FrozenSet",
    "Sequence", "Iterable", "Iterator", "Mapping", "MutableMapping",
    "MutableSequence", "Callable", "Awaitable", "Coroutine", "Generator",
    "AsyncIterator", "AsyncIterable", "AsyncGenerator",
    "Any", "None", "NoReturn", "Never", "TypeVar", "ParamSpec",
    "ClassVar", "Final", "Literal", "Annotated", "TypeAlias",
    "Type", "type", "object",
    # builtins
    "int", "str", "bytes", "bytearray", "float", "bool", "complex",
    "list", "dict", "set", "frozenset", "tuple", "range",
    "memoryview", "slice",
    # SQLAlchemy / FastAPI / Pydantic helpers commonly seen in field annotations
    "Mapped", "Column", "Field",
})

# Kind-marker base classes — present in the `bases` list to signal *what kind*
# of declaration this is (Protocol, Pydantic model, dataclass-like, ORM table,
# Enum) rather than to declare structural inheritance. They drive `_classify_class`
# but should NOT appear in the emitted `extends` list — a downstream graph view
# would otherwise show every Protocol-using class inheriting from `Protocol`,
# every Pydantic model inheriting from `BaseModel`, etc., flooding the supertype
# axis with marker noise.
MARKER_BASES = frozenset({
    "Protocol", "Generic",
    "TypedDict", "NamedTuple",
    "BaseModel",
    "Enum", "IntEnum", "StrEnum", "Flag", "IntFlag", "ReprEnum",
    "Base", "DeclarativeBase",
})

def _is_simple_name(node: ast.AST) -> str | None:
    """Return the source spelling of node if it's a Name or attribute-of-Name; else None."""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        # `typing.Protocol` etc. — use the rightmost segment for base-class matching
        return node.attr
    return None


def _decorator_names(decorators: list[ast.expr]) -> list[str]:
    out: list[str] = []
    for d in decorators:
        if isinstance(d, ast.Call):
            d = d.func
        if isinstance(d, ast.Name):
            out.append(d.id)
        elif isinstance(d, ast.Attribute):
            out.append(d.attr)
    return out


def _base_names(bases: list[ast.expr]) -> list[str]:
    """Return the rightmost identifier of each base. Generic[X] → 'Generic',
    typing.Protocol → 'Protocol'."""
    out: list[str] = []
    for b in bases:
        if isinstance(b, ast.Subscript):
            b = b.value
        n = _is_simple_name(b)
        if n:
            out.append(n)
    return out


def _collect_name_refs(node: ast.AST, exclude: frozenset[str] = frozenset()) -> list[dict]:
    """Walk a type annotation (or any subtree) and yield deduplicated type-ref dicts.

    Only `ast.Name` identifiers are emitted. For qualified names (`module.Foo`),
    ast.walk reaches the inner Name(`module`) directly — so emitting only Name
    nodes naturally satisfies the pipeline-contract rule:
        "for TypeReferenceNode whose typeName is a QualifiedName, the LEFTMOST
         identifier is emitted as the reference."
    Emitting `attr` from `Attribute` nodes too would double-count (e.g.
    `module.Foo` would emit both `module` AND `Foo`).
    """
    found: dict[str, None] = {}
    for child in ast.walk(node):
        if isinstance(child, ast.Name):
            n = child.id
            if n in BUILTIN_TYPE_DENYLIST or n in exclude:
                continue
            found[n] = None
    return [{"name": k, "kind": "type-ref"} for k in sorted(found.keys())]


def _is_classvar_annotation(ann: ast.AST | None) -> bool:
    """True for ClassVar[T] / typing.ClassVar[T] — AST-based so qualified
    spellings classify identically to the unqualified form."""
    if isinstance(ann, ast.Subscript):
        head = _is_simple_name(ann.value)
        return head == "ClassVar"
    return False


def _extract_class_fields(
    cls: ast.ClassDef, exclude_refs: frozenset[str] = frozenset(),
) -> tuple[list[str], list[dict], list[dict]]:
    """Return (fields, fields_structured, references) for a class body.

    Looks at AnnAssign statements (PEP 526 `x: int = 1`) — the only structural
    field form. Skips Assign without annotation; skips method defs.

    `exclude_refs` carries in-scope type-parameter names so generic bindings
    don't leak into `references` (pipeline-contract §references semantics)."""
    fields: list[str] = []
    fields_structured: list[dict] = []
    ref_acc: dict[str, None] = {}

    for stmt in cls.body:
        if isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name):
            fname = stmt.target.id
            ftype = annotation_text(stmt.annotation)
            is_optional = _is_optional_annotation(stmt.annotation)
            is_classvar = _is_classvar_annotation(stmt.annotation)
            fields.append(f"{fname}:{ftype}")
            fields_structured.append({
                "name": fname,
                "type": ftype,
                "is_optional": is_optional,
                "is_static": is_classvar,
            })
            for r in _collect_name_refs(stmt.annotation, exclude=exclude_refs):
                ref_acc[r["name"]] = None

    # Sort fields lexicographically (per contract) — keep fields_structured in lockstep.
    paired = sorted(zip(fields, fields_structured), key=lambda p: p[0])
    fields = [p[0] for p in paired]
    fields_structured = [p[1] for p in paired]
    references = [{"name": k, "kind": "type-ref"} for k in sorted(ref_acc.keys())]
    return fields, fields_structured, references


def _is_optional_annotation(ann: ast.AST | None) -> bool:
    """Structural optional-flag — true for Optional[T], T | None, Union[T, None]."""
    if ann is None:
        return False
    # PEP 604: T | None
    if isinstance(ann, ast.BinOp) and isinstance(ann.op, ast.BitOr):
        return _annotation_mentions_none(ann.left) or _annotation_mentions_none(ann.right)
    # Optional[T]
    if isinstance(ann, ast.Subscript):
        head = _is_simple_name(ann.value)
        if head == "Optional":
            return True
        if head == "Union":
            # Union[..., None]
            slice_node = ann.slice
            if isinstance(slice_node, ast.Tuple):
                for elt in slice_node.elts:
                    if _annotation_mentions_none(elt):
                        return True
    return False


def _annotation_mentions_none(node: ast.AST) -> bool:
    if isinstance(node, ast.Constant) and node.value is None:
        return True
    if isinstance(node, ast.Name) and node.id == "None":
        return True
    return False


def _extract_enum_fields(cls: ast.ClassDef) -> tuple[list[str], list[dict]]:
    """Enum cases — one field per `NAME = value` assignment."""
    fields: list[str] = []
    fields_structured: list[dict] = []
    for stmt in cls.body:
        if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 and isinstance(stmt.targets[0], ast.Name):
            name = stmt.targets[0].id
            if name.startswith("_"):
                continue
            try:
                rendered = ast.unparse(stmt.value)
                ftype = f"={rendered}"
            except Exception:
                ftype = ""
            fields.append(f"{name}:{ftype}")
            fields_structured.append({
                "name": name, "type": ftype, "is_optional": False, "is_static": False,
            })
    paired = sorted(zip(fields, fields_structured), key=lambda p: p[0])
    return [p[0] for p in paired], [p[1] for p in paired]


def _classify_class(cls: ast.ClassDef) -> tuple[str, list[str]]:
    """Return (kind, extends_names) for a class declaration.

    Detection order is intentional — Pydantic BaseModel wins over TypedDict if
    both somehow appear (Pydantic isn't a TypedDict in practice; this is a
    safety net), and Enum wins over plain class because Enum members are union
    cases, not structural fields.
    """
    bases = _base_names(cls.bases)
    decorators = _decorator_names(cls.decorator_list)
    extends = sorted({
        b for b in bases
        if b not in BUILTIN_TYPE_DENYLIST and b not in MARKER_BASES
    })

    if any(b in {"Enum", "IntEnum", "StrEnum", "Flag", "IntFlag", "ReprEnum"} for b in bases):
        return "type-alias-union", extends
    if "Protocol" in bases:
        return "interface", extends
    if "TypedDict" in bases:
        return "type-alias-object", extends
    if "NamedTuple" in bases:
        return "type-alias-object", extends
    if "BaseModel" in bases:
        return "zod-object", extends
    if "dataclass" in decorators or "dataclass_transform" in decorators:
        return "type-alias-object", extends
    # SQLAlchemy declarative classes — `class Foo(Base):` where Base is
    # `declarative_base()` or `DeclarativeBase`. Heuristic: a class whose
    # body uses `Mapped[…]` or `Column(…)` annotations.
    if any(b in {"Base", "DeclarativeBase"} for b in bases) and _has_mapped_columns(cls):
        return "drizzle-table", extends
    # Fallback: any class with at least one AnnAssign is shape-bearing.
    if any(isinstance(s, ast.AnnAssign) for s in cls.body):
        return "type-alias-object", extends
    return "interface", extends


def _has_mapped_columns(cls: ast.ClassDef) -> bool:
    """True if any AnnAssign in the body uses `Mapped[T]` (either bare or
    qualified). AST-based — text-prefix matches against annotation_text
    silently miss `sqlalchemy.orm.Mapped[T]`."""
    for stmt in cls.body:
        if isinstance(stmt, ast.AnnAssign) and isinstance(stmt.annotation, ast.Subscript):
            head = _is_simple_name(stmt.annotation.value)
            if head == "Mapped":
                return True
    return False


def _extract_typed_dict_call(node: ast.Assign) -> tuple[str, list[str], list[dict], list[dict]] | None:
    """`X = TypedDict("X", {...})` functional form (bare or qualified call).

    Accepts both `TypedDict(...)` and `typing.TypedDict(...)` via the rightmost
    -identifier match on the call's `.func`.
    """
    if not isinstance(node.value, ast.Call):
        return None
    if _is_simple_name(node.value.func) != "TypedDict":
        return None
    if len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
        return None
    name = node.targets[0].id
    # Need both a name-positional and the fields-dict — anything else is
    # malformed and would emit a spurious empty-shape record that shape_sig
    # would cluster against every other empty record. Drop it.
    if len(node.value.args) < 2:
        return None
    dict_arg = node.value.args[1]
    if not isinstance(dict_arg, ast.Dict):
        return None
    fields: list[str] = []
    fields_structured: list[dict] = []
    refs: dict[str, None] = {}
    for k, v in zip(dict_arg.keys, dict_arg.values):
        if not isinstance(k, ast.Constant) or not isinstance(k.value, str):
            continue
        ftype = annotation_text(v)
        fields.append(f"{k.value}:{ftype}")
        fields_structured.append({
            "name": k.value, "type": ftype,
            "is_optional": _is_optional_annotation(v), "is_static": False,
        })
        for r in _collect_name_refs(v):
            refs[r["name"]] = None
    paired = sorted(zip(fields, fields_structured), key=lambda p: p[0])
    fields = [p[0] for p in paired]
    fields_structured = [p[1] for p in paired]
    references = [{"name": k, "kind": "type-ref"} for k in sorted(refs.keys())]
    return name, fields, fields_structured, references


def _extract_named_tuple_call(node: ast.Assign) -> tuple[str, list[str], list[dict], list[dict]] | None:
    """`X = NamedTuple("X", [("a", int), ("b", str)])` functional form.

    Parallel to _extract_typed_dict_call; the contract treats the class form
    `class X(NamedTuple)` and this functional form as the same kind
    (`type-alias-object`) so cluster queries match them together.
    """
    if not isinstance(node.value, ast.Call):
        return None
    if _is_simple_name(node.value.func) != "NamedTuple":
        return None
    if len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
        return None
    name = node.targets[0].id
    if len(node.value.args) < 2:
        return None
    fields_arg = node.value.args[1]
    # Accept list / tuple of 2-tuples — `[("a", int), ("b", str)]` or
    # `(("a", int), ("b", str))`. Reject anything else (string-form
    # `"a b"` is not type-bearing).
    if not isinstance(fields_arg, (ast.List, ast.Tuple)):
        return None
    fields: list[str] = []
    fields_structured: list[dict] = []
    refs: dict[str, None] = {}
    for elt in fields_arg.elts:
        if not isinstance(elt, ast.Tuple) or len(elt.elts) != 2:
            continue
        key_node, type_node = elt.elts
        if not (isinstance(key_node, ast.Constant) and isinstance(key_node.value, str)):
            continue
        fname = key_node.value
        ftype = annotation_text(type_node)
        fields.append(f"{fname}:{ftype}")
        fields_structured.append({
            "name": fname, "type": ftype,
            "is_optional": _is_optional_annotation(type_node), "is_static": False,
        })
        for r in _collect_name_refs(type_node):
            refs[r["name"]] = None
    paired = sorted(zip(fields, fields_structured), key=lambda p: p[0])
    fields = [p[0] for p in paired]
    fields_structured = [p[1] for p in paired]
    references = [{"name": k, "kind": "type-ref"} for k in sorted(refs.keys())]
    return name, fields, fields_structured, references


def _classify_type_alias(value: ast.AST) -> str:
    """Pick the kind for a top-level `Foo: TypeAlias = ...` or `Foo = ...` value."""
    # PEP 604 union: X | Y
    if isinstance(value, ast.BinOp) and isinstance(value.op, ast.BitOr):
        return "type-alias-union"
    if isinstance(value, ast.Subscript):
        head = _is_simple_name(value.value)
        if head in {"Union", "Literal"}:
            return "type-alias-union"
        if head == "Optional":
            return "type-alias-union"
    return "type-alias-other"


def _is_type_alias_assignment(node: ast.Assign | ast.AnnAssign) -> bool:
    """True if this assignment is a top-level type alias (`Foo: TypeAlias = X` or
    `Foo = NewType('Foo', X)` or `Foo = Union[...]`).

    AnnAssign matches AST-based via the rightmost identifier so qualified
    spellings (`X: typing.TypeAlias = ...`) classify identically to the bare
    form (`X: TypeAlias = ...`).
    """
    if isinstance(node, ast.AnnAssign):
        return _is_simple_name(node.annotation) == "TypeAlias"
    if isinstance(node, ast.Assign):
        if len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
            return False
        v = node.value
        if isinstance(v, ast.Call) and _is_simple_name(v.func) in {"NewType", "TypeAliasType"}:
            return True
        # Bare alias like `Foo = Union[int, str]` or `Foo = int | str`.
        if isinstance(v, ast.Subscript):
            head = _is_simple_name(v.value)
            if head in {"Union", "Literal", "Optional", "Annotated", "Type", "Tuple", "List", "Dict", "Callable"}:
                return True
        if isinstance(v, ast.BinOp) and isinstance(v.op, ast.BitOr):
            return True
    return False


def _symbol_id(package: str, file: str, name: str, kind: str) -> str:
    h = hashlib.sha1()
    h.update(f"{package}\x00{file}\x00{name}\x00{kind}".encode("utf-8"))
    return h.hexdigest()


def extract_from_file(file_path: Path, pkg_name: str, pkg_root: Path, touched: set[str]) -> list[dict]:
    text = file_path.read_text(encoding="utf-8", errors="replace")
    try:
        tree = ast.parse(text, filename=str(file_path))
    except SyntaxError as exc:
        sys.stderr.write(f"  parse error {file_path}: {exc}\n")
        return []
    rel = str(file_path.relative_to(pkg_root))
    row_defaults = {
        "package": pkg_name,
        "file": rel,
        "language": LANGUAGE,
        "touched_in_window": pkg_name == "main" and rel in touched,
        "generated": is_generated(rel),
        "is_test": is_test_path(rel),
    }
    out: list[dict] = []

    def emit_class(cls: ast.ClassDef, qual_prefix: str = ""):
        kind, extends = _classify_class(cls)
        generics = _collect_generics(cls)
        if kind == "type-alias-union":
            fields, fields_structured = _extract_enum_fields(cls)
            references = []
        else:
            # Exclude in-scope generics from references — per the contract,
            # `interface Foo<T> { x: T }` produces references: [], not [{T}].
            fields, fields_structured, references = _extract_class_fields(
                cls, exclude_refs=frozenset(generics),
            )
        full_name = qual_prefix + cls.name
        sig = shape_sig(fields)
        row = {
            **row_defaults,
            "name": full_name,
            "kind": kind,
            "line": cls.lineno,
            "symbol_id": _symbol_id(pkg_name, rel, full_name, kind),
            "exported": not full_name.startswith("_"),
            "fields": fields,
            "fields_structured": fields_structured,
            "shape_sig": sig,
            "extends": extends,
            "references": references,
            "references_count": len(references),
        }
        if generics:
            row["generics"] = ",".join(generics)
        out.append(row)

        # Walk nested ClassDefs (rare but legitimate for shape clustering of
        # nested `Config` / `Meta` shapes — keeps the catalog complete).
        for stmt in cls.body:
            if isinstance(stmt, ast.ClassDef):
                emit_class(stmt, qual_prefix=full_name + ".")

    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            emit_class(node)
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            # Functional TypedDict / NamedTuple — both map to type-alias-object
            # so the catalog matches the class-form spelling.
            if isinstance(node, ast.Assign):
                functional = _extract_typed_dict_call(node) or _extract_named_tuple_call(node)
                if functional is not None:
                    name, fields, fields_structured, references = functional
                    sig = shape_sig(fields)
                    out.append({
                        **row_defaults,
                        "name": name,
                        "kind": "type-alias-object",
                        "line": node.lineno,
                        "symbol_id": _symbol_id(pkg_name, rel, name, "type-alias-object"),
                        "exported": not name.startswith("_"),
                        "fields": fields,
                        "fields_structured": fields_structured,
                        "shape_sig": sig,
                        "extends": [],
                        "references": references,
                        "references_count": len(references),
                    })
                    continue
            # Top-level type alias
            if _is_type_alias_assignment(node):
                name = None
                value = None
                if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
                    name = node.target.id
                    value = node.value
                elif isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
                    name = node.targets[0].id
                    value = node.value
                if name and value is not None:
                    kind = _classify_type_alias(value)
                    type_text = annotation_text(value)
                    references = _collect_name_refs(value)
                    out.append({
                        **row_defaults,
                        "name": name,
                        "kind": kind,
                        "line": node.lineno,
                        "symbol_id": _symbol_id(pkg_name, rel, name, kind),
                        "exported": not name.startswith("_"),
                        "fields": None,
                        "shape_sig": None,
                        "type_text": type_text,
                        "type_sig": type_text.lower(),
                        "extends": [],
                        "references": references,
                        "references_count": len(references),
                    })
        elif isinstance(node, getattr(ast, "TypeAlias", type(None))):
            # PEP 695 `type Foo[T] = X` (Python 3.12+). Excludes the alias's
            # declared type-parameters from references — same contract rule
            # as PEP 695 generic classes (`class Foo[T]:`).
            name = node.name.id if isinstance(node.name, ast.Name) else None
            if name:
                value = node.value
                kind = _classify_type_alias(value)
                type_text = annotation_text(value)
                alias_generics = frozenset(_pep695_type_param_names(node))
                references = _collect_name_refs(value, exclude=alias_generics)
                row = {
                    **row_defaults,
                    "name": name,
                    "kind": kind,
                    "line": node.lineno,
                    "symbol_id": _symbol_id(pkg_name, rel, name, kind),
                    "exported": not name.startswith("_"),
                    "fields": None,
                    "shape_sig": None,
                    "type_text": type_text,
                    "type_sig": type_text.lower(),
                    "extends": [],
                    "references": references,
                    "references_count": len(references),
                }
                if alias_generics:
                    row["generics"] = ",".join(_pep695_type_param_names(node))
                out.append(row)

    return out


def _pep695_type_param_names(node: ast.AST) -> list[str]:
    """Names of the PEP 695 type-parameters on a ClassDef / TypeAlias.

    Each `type_params` entry is one of `ast.TypeVar` / `ast.TypeVarTuple`
    / `ast.ParamSpec` whose `.name` is a `str` (per CPython 3.12 ast docs).
    Returns the empty list if the node has no `type_params` or runs on
    pre-3.12 Python (where the attribute doesn't exist)."""
    out: list[str] = []
    for tp in getattr(node, "type_params", None) or []:
        name = getattr(tp, "name", None)
        if isinstance(name, str):
            out.append(name)
    return out


def _collect_generics(cls: ast.ClassDef) -> list[str]:
    """Extract type-parameter names from `Generic[T]` / `Protocol[T]` bases, plus
    PEP 695 `class Foo[T]:` form. Returns names in declaration order."""
    names: list[str] = list(_pep695_type_param_names(cls))
    # Generic[T] / Protocol[T] bases
    for b in cls.bases:
        if isinstance(b, ast.Subscript):
            head = _is_simple_name(b.value)
            if head not in {"Generic", "Protocol"}:
                continue
            sl = b.slice
            if isinstance(sl, ast.Tuple):
                items = sl.elts
            else:
                items = [sl]
            for it in items:
                if isinstance(it, ast.Name):
                    names.append(it.id)
    # Dedupe preserving order
    seen: dict[str, None] = {}
    for n in names:
        seen.setdefault(n, None)
    return list(seen.keys())


def main() -> int:
    ap = argparse.ArgumentParser(description="Python AST type-catalog extractor.")
    ap.add_argument("--root", required=True, help="Root of the codebase to scan.")
    ap.add_argument("--shared", help="Secondary package root tagged as package='shared'.")
    ap.add_argument("--touched", help="Path to a JSON array of touched-in-window files.")
    ap.add_argument("--output", help="Write JSON to this path. Default: stdout.")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    shared = Path(args.shared).resolve() if args.shared else None
    touched: set[str] = set()
    if args.touched:
        with open(args.touched, encoding="utf-8") as fh:
            touched = set(json.load(fh))

    extractor_dir = Path(__file__).resolve().parent
    source_sha = compute_source_sha(extractor_dir)
    generated_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    main_files = list(walk_python_files(root))
    sys.stderr.write(f"main: {len(main_files)} files\n")
    entries: list[dict] = []
    errors = 0
    for f in main_files:
        try:
            entries.extend(extract_from_file(f, "main", root, touched))
        except Exception as exc:
            errors += 1
            sys.stderr.write(f"  ERR {f}: {exc}\n")

    if shared:
        shared_files = list(walk_python_files(shared))
        sys.stderr.write(f"shared: {len(shared_files)} files\n")
        for f in shared_files:
            try:
                entries.extend(extract_from_file(f, "shared", shared, set()))
            except Exception as exc:
                errors += 1
                sys.stderr.write(f"  ERR {f}: {exc}\n")

    # Stable sort: package, file, line, name. Output is byte-deterministic.
    entries.sort(key=lambda r: (r["package"], r["file"], r["line"], r["name"]))

    payload = {
        "schema_version": SCHEMA_VERSION,
        "extractor": make_extractor_block("type-catalog", source_sha),
        "fingerprint_v": FINGERPRINT_V,
        "generated_at": generated_at,
        "entries": entries,
    }

    sys.stderr.write(f"\nTotal entries: {len(entries)} (errors: {errors})\n")
    write_catalog(args.output, payload)
    return 0 if len(main_files) > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
