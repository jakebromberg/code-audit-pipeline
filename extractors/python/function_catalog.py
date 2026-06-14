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
    annotation_text,
    compute_source_sha,
    is_generated,
    is_test_path,
    make_extractor_block,
    sha256_hex,
    walk_python_files,
    write_catalog,
)
from type_catalog import BUILTIN_TYPE_DENYLIST, _collect_name_refs  # noqa: E402

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


def _decorator_simple_names(decorators: list[ast.expr]) -> set[str]:
    """Return the rightmost-identifier set of a function's decorator list. Matches
    the convention used by type_catalog._decorator_names but returns a set for
    membership checks; handles `@dec` and `@dec(arg)` and `@mod.dec` forms."""
    out: set[str] = set()
    for d in decorators:
        if isinstance(d, ast.Call):
            d = d.func
        if isinstance(d, ast.Name):
            out.add(d.id)
        elif isinstance(d, ast.Attribute):
            out.add(d.attr)
    return out


def _has_implicit_self(fn: ast.FunctionDef | ast.AsyncFunctionDef, inside_class: bool) -> bool:
    """True if the function's first positional arg is implicit (`self` / `cls`)
    in Python's calling convention. False for `@staticmethod` and for any
    function declared outside a class. `@classmethod` keeps the implicit first
    arg (it's `cls`)."""
    if not inside_class:
        return False
    decs = _decorator_simple_names(fn.decorator_list)
    return "staticmethod" not in decs


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
    """Yield (qual_name, FunctionDef|AsyncFunctionDef, kind, inside_class) for
    every function declaration in the module. Class methods are qualified as
    Class.method. `inside_class` tells the caller whether the function's first
    positional arg is implicit-self by Python's calling convention (modulo
    `@staticmethod`)."""
    def walk(node: ast.AST, qual_prefix: str = "", inside_class: bool = False):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.ClassDef):
                inner_prefix = qual_prefix + child.name + "."
                yield from walk(child, qual_prefix=inner_prefix, inside_class=True)
            elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                qual = qual_prefix + child.name
                kind = "method" if inside_class else "function"
                yield qual, child, kind, inside_class
                # Walk into nested defs for closures; the prefix follows the dotted form.
                yield from walk(child, qual_prefix=qual + ".", inside_class=False)
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
    for qual, fn, kind, inside_class in _walk_functions(tree):
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
