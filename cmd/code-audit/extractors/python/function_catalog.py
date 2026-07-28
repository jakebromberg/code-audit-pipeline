#!/usr/bin/env python3
"""function_catalog.py — Python AST extractor for function-level catalog data.

Walks every .py source file under --root (and optionally --shared) and emits
one JSON record per function / async function / method declaration. Each record
carries body_hash + body_lines for duplication clustering and a signature
projection (params, return_ref, references) for cross-catalog joins.

See ../../docs/pipeline-contract.md for the emitted schema.
"""

from __future__ import annotations

import argparse
import ast
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _lib import (  # noqa: E402
    EXTRACTOR_VERSION,
    FINGERPRINT_V,
    LANGUAGE,
    SCHEMA_VERSION,
    compute_source_sha,
    is_generated,
    is_test_path,
    make_extractor_block,
    sha256_hex,
    walk_python_files,
    write_catalog,
)
from type_catalog import (  # noqa: E402
    BUILTIN_TYPE_DENYLIST,
    _collect_name_refs,
    _decorator_names,
)

DEFAULT_MIN_BODY_LINES = 3


def _symbol_id(package: str, file: str, name: str, kind: str, signature_index: int) -> str:
    """sha1 over (package, file, name, kind, signature_index) joined by NUL
    bytes. `signature_index` is included so `@typing.overload` heads (each a
    separate FunctionDef sharing one name + kind) get distinct ids."""
    h = hashlib.sha1()
    h.update(
        f"{package}\x00{file}\x00{name}\x00{kind}\x00{signature_index}".encode("utf-8")
    )
    return h.hexdigest()


def _normalize_body_lines(stmts: list[ast.stmt]) -> list[str]:
    """Render body statements as a deduplicated, sorted, whitespace-normalized
    list of source lines.

    Comments are stripped naturally because ast doesn't keep them. Docstrings
    (first-statement string Expr) are dropped because they're documentation,
    not behavior."""
    if not stmts:
        return []
    # Drop docstring if first statement is a string Expr.
    if (isinstance(stmts[0], ast.Expr)
            and isinstance(stmts[0].value, ast.Constant)
            and isinstance(stmts[0].value.value, str)):
        stmts = stmts[1:]
    rendered: list[str] = []
    for s in stmts:
        try:
            src = ast.unparse(s)
        except Exception:
            continue
        for raw_line in src.split("\n"):
            line = re.sub(r"\s+", " ", raw_line).strip()
            if line:
                rendered.append(line)
    # Dedupe + sort for Jaccard input (matches the TS extractor's convention).
    return sorted(set(rendered))


def _single_type_ref(ann: ast.AST | None) -> str | None:
    """Return the single-identifier form of a type annotation; None for
    primitives, unions, anonymous shapes."""
    if ann is None:
        return None
    if isinstance(ann, ast.Name):
        n = ann.id
        if n in BUILTIN_TYPE_DENYLIST:
            return None
        return n
    if isinstance(ann, ast.Attribute):
        n = ann.attr
        if n in BUILTIN_TYPE_DENYLIST:
            return None
        return n
    return None


# --- field_copy_map — hand-written field-copy mapper detection -----------------
# A callable whose body is essentially a run of *identity* field copies between
# two catalogued types. Computed from the constructor-call / assignment AST
# BEFORE body normalization, so short single-return mappers keep the signal even
# when their body_hash is nulled by --min-body-lines. See the contract:
# docs/pipeline-contract.md § "Optional: field_copy_map".


def _callee_name(func: ast.AST) -> str | None:
    """Rightmost identifier of a call target: Name -> id, Attribute -> attr."""
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return None


def _bare_attr(node: ast.AST) -> tuple[str, str] | None:
    """If `node` is `<Name>.<attr>`, return (name_id, attr); else None. This is
    the shape of an identity copy's value / target — a bare attribute access off
    a single operand, no call or computation wrapping it."""
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
        return node.value.id, node.attr
    return None


def _strip_docstring(body: list[ast.stmt]) -> list[ast.stmt]:
    if (body
            and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        return body[1:]
    return body


def _operand_type_map(
    fn: ast.FunctionDef | ast.AsyncFunctionDef, class_name: str | None,
) -> dict[str, str]:
    """operand-name -> single-identifier declared type, for every parameter.

    `self` / `cls` resolve to the enclosing class so the attr-assign and
    model_validate forms can name a dest/source that is the method's own type."""
    args = fn.args
    all_args: list[ast.arg] = []
    all_args.extend(args.posonlyargs)
    all_args.extend(args.args)
    if args.vararg:
        all_args.append(args.vararg)
    all_args.extend(args.kwonlyargs)
    if args.kwarg:
        all_args.append(args.kwarg)
    out: dict[str, str] = {}
    for a in all_args:
        t = _single_type_ref(a.annotation)
        if t is not None:
            out[a.arg] = t
    if class_name is not None:
        out.setdefault("self", class_name)
        out.setdefault("cls", class_name)
    return out


def _detect_model_validate(
    body: list[ast.stmt], operand_type: dict[str, str], class_name: str | None,
) -> dict | None:
    """The already-fixed `Dest.model_validate(src, from_attributes=True)` form.

    Recognized so the consuming query can DEMOTE it — a site that already adopted
    the field-agnostic projection is the fix, not the smell."""
    if len(body) != 1 or not isinstance(body[0], ast.Return):
        return None
    call = body[0].value
    if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Attribute):
        return None
    if call.func.attr != "model_validate":
        return None
    # `from_attributes=True` is the load-bearing marker of the field-agnostic form.
    if not any(k.arg == "from_attributes"
               and isinstance(k.value, ast.Constant) and k.value.value is True
               for k in call.keywords):
        return None
    src = call.args[0] if call.args else None
    source_ref = operand_type.get(src.id) if isinstance(src, ast.Name) else None
    recv = call.func.value
    if isinstance(recv, ast.Name):
        dest_ref = class_name if recv.id in ("cls", "self") else recv.id
    elif isinstance(recv, ast.Attribute):
        dest_ref = recv.attr
    else:
        dest_ref = None
    return {
        "source_type_ref": source_ref,
        "dest_type_ref": dest_ref,
        "copied_fields": [],
        "form": "model_validate",
    }


def _constructor_call(body: list[ast.stmt]) -> ast.Call | None:
    """The single constructor Call in a projection body, or None. Recognizes
    `return Dest(...)`, a lone `x = Dest(...)`, and `x = Dest(...); return x`."""
    if len(body) == 1:
        s = body[0]
        if isinstance(s, ast.Return) and isinstance(s.value, ast.Call):
            return s.value
        if isinstance(s, (ast.Assign, ast.AnnAssign)) and isinstance(s.value, ast.Call):
            return s.value
    if len(body) == 2:
        a, b = body
        if (isinstance(a, ast.Assign) and isinstance(a.value, ast.Call)
                and len(a.targets) == 1 and isinstance(a.targets[0], ast.Name)
                and isinstance(b, ast.Return) and isinstance(b.value, ast.Name)
                and b.value.id == a.targets[0].id):
            return a.value
    return None


def _detect_constructor(body: list[ast.stmt], operand_type: dict[str, str]) -> dict | None:
    """Constructor form — `return Dest(kw=src.attr, …)` where the keywords are
    predominantly identity copies (`kw == attr`) off a single source operand."""
    call = _constructor_call(body)
    if call is None:
        return None
    dest_ref = _callee_name(call.func)
    if dest_ref is None:
        return None
    # A `**spread` (arg is None) is the field-agnostic form, not a hand-enumerated
    # mapper; positional args aren't name-keyed copies. Bail on either.
    if any(k.arg is None for k in call.keywords) or call.args:
        return None
    named = [k for k in call.keywords if k.arg is not None]
    if not named:
        return None
    copied: set[str] = set()
    operands: set[str] = set()
    for k in named:
        pair = _bare_attr(k.value)
        if pair is not None and pair[1] == k.arg:
            copied.add(k.arg)
            operands.add(pair[0])
    # Predominantly identity copies from exactly ONE source operand.
    if not copied or len(operands) != 1 or len(copied) * 2 < len(named):
        return None
    return {
        "source_type_ref": operand_type.get(next(iter(operands))),
        "dest_type_ref": dest_ref,
        "copied_fields": sorted(copied),
        "form": "constructor",
    }


def _detect_attr_assign(body: list[ast.stmt], operand_type: dict[str, str]) -> dict | None:
    """Attr-assign form — a run of `dst.x = src.x` statements against a single
    stable dst and src, predominantly identity copies. A leading `dst = Dest(...)`
    construction resolves the dest type when dst is not a parameter."""
    field_targets = 0
    copied: set[str] = set()
    dst_names: set[str] = set()
    src_names: set[str] = set()
    local_types: dict[str, str] = {}
    for s in body:
        # Local construction `name = Dest(...)` — track for dest/source resolution.
        if (isinstance(s, ast.Assign) and len(s.targets) == 1
                and isinstance(s.targets[0], ast.Name) and isinstance(s.value, ast.Call)):
            callee = _callee_name(s.value.func)
            if callee is not None:
                local_types[s.targets[0].id] = callee
            continue
        if isinstance(s, ast.Assign) and len(s.targets) == 1:
            tgt = _bare_attr(s.targets[0])
            if tgt is None:
                continue
            field_targets += 1
            dst_names.add(tgt[0])
            val = _bare_attr(s.value)
            if val is not None and val[1] == tgt[1]:
                copied.add(tgt[1])
                src_names.add(val[0])
    if (not copied or field_targets == 0
            or len(dst_names) != 1 or len(src_names) != 1
            or len(copied) * 2 < field_targets):
        return None
    dst = next(iter(dst_names))
    src = next(iter(src_names))
    if dst == src:
        return None
    return {
        "source_type_ref": operand_type.get(src) or local_types.get(src),
        "dest_type_ref": operand_type.get(dst) or local_types.get(dst),
        "copied_fields": sorted(copied),
        "form": "attr-assign",
    }


def _field_copy_map(
    fn: ast.FunctionDef | ast.AsyncFunctionDef, class_name: str | None,
) -> dict | None:
    """Detect a hand-written field-copy mapper. Returns the additive
    `field_copy_map` object, or None when the body is not a 1:1 projection."""
    body = _strip_docstring(fn.body)
    if not body:
        return None
    operand_type = _operand_type_map(fn, class_name)
    return (
        _detect_model_validate(body, operand_type, class_name)
        or _detect_constructor(body, operand_type)
        or _detect_attr_assign(body, operand_type)
    )


def _has_implicit_self(fn: ast.FunctionDef | ast.AsyncFunctionDef, inside_class: bool) -> bool:
    """True if the function's first positional arg is implicit (`self` / `cls`)
    in Python's calling convention. False for `@staticmethod` and for any
    function declared outside a class. `@classmethod` keeps the implicit first
    arg (it's `cls`)."""
    if not inside_class:
        return False
    return "staticmethod" not in _decorator_names(fn.decorator_list)


def _extract_params(
    fn: ast.FunctionDef | ast.AsyncFunctionDef,
    has_implicit_self: bool,
) -> tuple[list[dict], list[str]]:
    """Return (params_payload, param_names).

    When `has_implicit_self` is True, the FIRST positional arg (`self` / `cls`
    by convention) is dropped from both the payload and the names list so
    `param_count` matches the TS arity convention (caller-perspective)."""
    args = fn.args
    out: list[dict] = []
    names: list[str] = []

    # The full ordered arg list, in spec order: posonly, args, vararg, kwonly, kwarg.
    all_args: list[ast.arg] = []
    all_args.extend(args.posonlyargs)
    all_args.extend(args.args)
    if args.vararg:
        all_args.append(args.vararg)
    all_args.extend(args.kwonlyargs)
    if args.kwarg:
        all_args.append(args.kwarg)

    for i, a in enumerate(all_args):
        # Strip the implicit first arg (whatever the author named it) on
        # methods that have one; never strip on functions, staticmethods,
        # or after the first positional.
        if i == 0 and has_implicit_self:
            continue
        names.append(a.arg)
        type_ref = _single_type_ref(a.annotation)
        type_refs = _collect_name_refs(a.annotation) if a.annotation is not None else []
        out.append({
            "name": a.arg,
            "type_ref": type_ref,
            "type_refs": type_refs,
        })
    return out, names


def _walk_functions(tree: ast.Module):
    """Yield (qual_name, FunctionDef|AsyncFunctionDef, kind, inside_class,
    class_name) for every function declaration in the module. Class methods are
    qualified as Class.method. `inside_class` tells the caller whether the
    function's first positional arg is implicit-self by Python's calling
    convention (modulo `@staticmethod`); `class_name` names the immediately
    enclosing class (None for free / nested functions) so field-copy detection
    can resolve `self` / `cls` operands to that type."""
    def walk(node: ast.AST, qual_prefix: str = "", inside_class: bool = False,
             class_name: str | None = None):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.ClassDef):
                inner_prefix = qual_prefix + child.name + "."
                yield from walk(child, qual_prefix=inner_prefix, inside_class=True,
                                class_name=child.name)
            elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                qual = qual_prefix + child.name
                kind = "method" if inside_class else "function"
                yield qual, child, kind, inside_class, class_name
                # Walk into nested defs for closures; the prefix follows the dotted
                # form. A nested def is no longer directly inside a class body.
                yield from walk(child, qual_prefix=qual + ".", inside_class=False,
                                class_name=None)
    yield from walk(tree)


def extract_from_file(
    file_path: Path,
    pkg_name: str,
    pkg_root: Path,
    touched: set[str],
    min_body_lines: int,
) -> list[dict]:
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
        "synthetic": False,
    }
    out: list[dict] = []
    # Per-(file, name) counter so two FunctionDefs sharing a name in the same
    # file -- @typing.overload heads above an implementation, or nested
    # same-name defs -- get signature_index 0, 1, 2, ... in source order.
    # Mirrors the TS function-catalog convention so (name, package, file)
    # dedupe + signature_index ordering both work uniformly.
    sig_index: dict[str, int] = {}
    for qual, fn, kind, inside_class, class_name in _walk_functions(tree):
        params, param_names = _extract_params(fn, _has_implicit_self(fn, inside_class))

        body_lines = _normalize_body_lines(fn.body)
        if len(body_lines) >= min_body_lines:
            body_text = "\n".join(body_lines)
            body_hash = sha256_hex(body_text)
            body_line_count = len(body_lines)
            body_length = len(body_text)
        else:
            body_hash = None
            body_lines = None  # type: ignore[assignment]
            body_line_count = None
            body_length = None

        return_ref = _single_type_ref(fn.returns)
        return_refs = _collect_name_refs(fn.returns) if fn.returns is not None else []

        # Function-level references: deduplicated union of all param type_refs +
        # the return-side ref set, minus generic names (Python has no easy way
        # to scope TypeVars, so we just rely on the denylist filtering).
        all_refs: dict[str, None] = {}
        for p in params:
            for r in p["type_refs"]:
                all_refs[r["name"]] = None
        for r in return_refs:
            all_refs[r["name"]] = None
        references = [{"name": k, "kind": "type-ref"} for k in sorted(all_refs.keys())]

        async_flag = isinstance(fn, ast.AsyncFunctionDef)
        exported = not qual.split(".")[-1].startswith("_")

        idx = sig_index.get(qual, 0)
        sig_index[qual] = idx + 1

        row = {
            **row_defaults,
            "name": qual,
            "kind": kind,
            "line": fn.lineno,
            "symbol_id": _symbol_id(pkg_name, rel, qual, kind, idx),
            "exported": exported,
            "async": async_flag,
            "param_count": len(params),
            "param_names": param_names,
            "body_hash": body_hash,
            "body_line_count": body_line_count,
            "body_length": body_length,
            "body_lines": body_lines,
            "generics": "",
            "params": params,
            "return_ref": return_ref,
            "references": references,
            "references_count": len(references),
            "signature_index": idx,
        }
        # Additive: only present when the body is a hand-written field-copy
        # mapper. Computed from the raw AST above, independent of body gating.
        field_copy_map = _field_copy_map(fn, class_name)
        if field_copy_map is not None:
            row["field_copy_map"] = field_copy_map
        out.append(row)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Python AST function-catalog extractor.")
    ap.add_argument("--root", required=True, help="Root of the codebase to scan.")
    ap.add_argument("--shared", help="Secondary package root tagged as package='shared'.")
    ap.add_argument("--touched", help="Path to a JSON array of touched-in-window files.")
    ap.add_argument("--output", help="Write JSON to this path. Default: stdout.")
    ap.add_argument(
        "--min-body-lines", type=int, default=DEFAULT_MIN_BODY_LINES,
        help=(
            "Functions whose normalized body has fewer than this many lines emit "
            "body_hash / body_lines / body_line_count / body_length as null. "
            "Default: 3."
        ),
    )
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
            entries.extend(extract_from_file(f, "main", root, touched, args.min_body_lines))
        except Exception as exc:
            errors += 1
            sys.stderr.write(f"  ERR {f}: {exc}\n")

    if shared:
        shared_files = list(walk_python_files(shared))
        sys.stderr.write(f"shared: {len(shared_files)} files\n")
        for f in shared_files:
            try:
                entries.extend(extract_from_file(f, "shared", shared, set(), args.min_body_lines))
            except Exception as exc:
                errors += 1
                sys.stderr.write(f"  ERR {f}: {exc}\n")

    entries.sort(key=lambda r: (r["package"], r["file"], r["line"], r["name"]))

    payload = {
        "schema_version": SCHEMA_VERSION,
        "extractor": make_extractor_block("function-catalog", source_sha),
        "fingerprint_v": FINGERPRINT_V,
        "generated_at": generated_at,
        "entries": entries,
    }

    sys.stderr.write(f"\nTotal entries: {len(entries)} (errors: {errors})\n")
    write_catalog(args.output, payload)
    return 0 if len(main_files) > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
