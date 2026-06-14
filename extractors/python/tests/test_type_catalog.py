"""Tests for the Python type-catalog extractor.

Runs `type_catalog.py` as a subprocess against `fixtures/` and asserts each
emitted catalog entry matches the spec in `docs/pipeline-contract.md`.

Run with:
    python3 -m unittest discover -s extractors/python -t extractors/python
"""

import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

EXTRACTOR_DIR = Path(__file__).resolve().parent.parent
FIXTURES_ROOT = EXTRACTOR_DIR / "fixtures"
TYPE_CATALOG = EXTRACTOR_DIR / "type_catalog.py"


def run_extractor(*extra_args, root=FIXTURES_ROOT):
    """Subprocess the extractor and return (returncode, parsed_json | stdout, stderr)."""
    result = subprocess.run(
        [sys.executable, str(TYPE_CATALOG), "--root", str(root), *extra_args],
        capture_output=True, text=True, timeout=30,
    )
    parsed = None
    if result.stdout:
        try:
            parsed = json.loads(result.stdout)
        except json.JSONDecodeError:
            parsed = None
    return result.returncode, parsed, result.stderr


# Cached across the suite — the fixture tree is constant; one subprocess
# call covers ~30 tests. Tests that need a fresh subprocess (return-code
# checks, alternate --root) call run_extractor() directly.
_CACHE: dict = {}


def cached_catalog():
    if "catalog" not in _CACHE:
        rc, catalog, stderr = run_extractor()
        if rc != 0 or catalog is None:
            raise RuntimeError(f"extractor failed (rc={rc}): {stderr}")
        _CACHE["catalog"] = catalog
    return _CACHE["catalog"]


def find_entry(catalog, name, file_suffix=None):
    """Find an entry by name; optionally restrict by file suffix to disambiguate
    same-name records across fixture files (e.g., GenericProtocol appears in
    both 01_protocols.py and 11_generics.py)."""
    matches = [e for e in catalog["entries"] if e["name"] == name]
    if file_suffix:
        matches = [e for e in matches if e["file"].endswith(file_suffix)]
    return matches[0] if matches else None


def find_entries(catalog, name):
    return [e for e in catalog["entries"] if e["name"] == name]


class CatalogShapeTests(unittest.TestCase):
    """Wrapper-level invariants from docs/pipeline-contract.md."""

    def test_extractor_exits_zero(self):
        rc, _, stderr = run_extractor()
        self.assertEqual(rc, 0, f"stderr: {stderr}")

    def test_wrapper_fields(self):
        cat = cached_catalog()
        self.assertEqual(cat["schema_version"], "2.0")
        self.assertEqual(cat["extractor"]["language"], "python")
        self.assertEqual(cat["extractor"]["name"], "type-catalog")
        self.assertRegex(cat["extractor"]["version"], r"^\d+\.\d+\.\d+")
        # source_sha is either a 40-char git sha or "unknown".
        sha = cat["extractor"]["source_sha"]
        self.assertTrue(
            sha == "unknown" or re.fullmatch(r"[0-9a-f]{40}", sha),
            f"source_sha: {sha}",
        )
        self.assertEqual(cat["fingerprint_v"], "shape_sig:1")
        self.assertRegex(
            cat["generated_at"],
            r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$",
        )
        self.assertIsInstance(cat["entries"], list)
        self.assertGreater(len(cat["entries"]), 0)

    def test_every_entry_carries_per_entry_language(self):
        # V2 core-projection requirement — every row must stamp `language`.
        cat = cached_catalog()
        for e in cat["entries"]:
            self.assertEqual(
                e["language"], "python",
                f"entry {e['kind']}/{e['name']} missing per-entry language",
            )

    def test_every_entry_carries_symbol_id(self):
        cat = cached_catalog()
        for e in cat["entries"]:
            self.assertRegex(
                e["symbol_id"], r"^[0-9a-f]{40}$",
                f"symbol_id for {e['kind']}/{e['name']}: {e['symbol_id']}",
            )

    def test_every_entry_has_required_fields(self):
        cat = cached_catalog()
        required = {"name", "kind", "package", "file", "line",
                    "is_test", "extends", "references", "references_count"}
        for e in cat["entries"]:
            missing = required - e.keys()
            self.assertEqual(
                missing, set(),
                f"entry {e['name']} missing required fields: {missing}",
            )

    def test_references_count_matches_references_length(self):
        cat = cached_catalog()
        for e in cat["entries"]:
            self.assertEqual(
                e["references_count"], len(e["references"]),
                f"entry {e['name']}: count {e['references_count']} != len {len(e['references'])}",
            )

    def test_entries_are_sorted(self):
        cat = cached_catalog()
        keys = [(e["package"], e["file"], e["line"], e["name"]) for e in cat["entries"]]
        self.assertEqual(keys, sorted(keys), "entries not sorted by (package, file, line, name)")

    def test_runs_byte_deterministic(self):
        """Two runs over the same input produce byte-identical JSON entries
        (timestamps and source_sha drift would change the wrapper, but the
        entries array must be stable)."""
        rc1, c1, _ = run_extractor()
        rc2, c2, _ = run_extractor()
        self.assertEqual(rc1, 0)
        self.assertEqual(rc2, 0)
        self.assertEqual(c1["entries"], c2["entries"])


class ProtocolTests(unittest.TestCase):
    def test_simple_protocol_is_interface(self):
        cat = cached_catalog()
        e = find_entry(cat, "SimpleProtocol")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "interface")
        self.assertEqual(e["fields"], ["age:int", "name:str"])
        self.assertEqual(e["shape_sig"], "age:int|name:str")

    def test_extending_protocol_records_extends(self):
        cat = cached_catalog()
        e = find_entry(cat, "ExtendingProtocol")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "interface")
        # SimpleProtocol is in extends (Protocol itself is denylisted from extends).
        self.assertIn("SimpleProtocol", e["extends"])
        self.assertNotIn("Protocol", e["extends"])

    def test_method_only_protocol(self):
        cat = cached_catalog()
        e = find_entry(cat, "ProtocolWithMethods")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "interface")
        self.assertEqual(e["fields"], [])


class TypedDictTests(unittest.TestCase):
    def test_class_form(self):
        cat = cached_catalog()
        e = find_entry(cat, "ClassTypedDict")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "type-alias-object")
        self.assertEqual(e["fields"], ["count:int", "name:str"])

    def test_functional_form(self):
        cat = cached_catalog()
        e = find_entry(cat, "FunctionalTypedDict")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "type-alias-object")
        self.assertEqual(e["fields"], ["a:int", "b:str"])

    def test_total_false_class_form(self):
        cat = cached_catalog()
        e = find_entry(cat, "OptionalKeyDict")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "type-alias-object")


class PydanticTests(unittest.TestCase):
    def test_basemodel_maps_to_zod_object(self):
        cat = cached_catalog()
        e = find_entry(cat, "UserModel")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "zod-object")
        self.assertEqual(e["fields"], ["age:int", "email:str | None", "name:str"])

    def test_nested_model_records_reference(self):
        cat = cached_catalog()
        e = find_entry(cat, "NestedRefModel")
        self.assertIsNotNone(e)
        # UserModel should appear in references — int is denylisted.
        ref_names = {r["name"] for r in e["references"]}
        self.assertIn("UserModel", ref_names)
        self.assertNotIn("int", ref_names)


class DataclassTests(unittest.TestCase):
    def test_dataclass_maps_to_type_alias_object(self):
        cat = cached_catalog()
        e = find_entry(cat, "Point")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "type-alias-object")
        self.assertEqual(e["fields"], ["x:float", "y:float"])

    def test_frozen_dataclass_still_object(self):
        cat = cached_catalog()
        e = find_entry(cat, "FrozenPoint")
        self.assertEqual(e["kind"], "type-alias-object")

    def test_is_optional_flag_set(self):
        cat = cached_catalog()
        e = find_entry(cat, "HasOptional")
        # Find the structured entry for `b: str | None`.
        b_entry = next(fs for fs in e["fields_structured"] if fs["name"] == "b")
        self.assertTrue(b_entry["is_optional"])
        # And NOT for `a: int` or `c: int = 0`.
        a_entry = next(fs for fs in e["fields_structured"] if fs["name"] == "a")
        self.assertFalse(a_entry["is_optional"])
        c_entry = next(fs for fs in e["fields_structured"] if fs["name"] == "c")
        self.assertFalse(c_entry["is_optional"])


class NamedTupleTests(unittest.TestCase):
    def test_class_form(self):
        cat = cached_catalog()
        e = find_entry(cat, "ClassNamedTuple")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "type-alias-object")
        self.assertEqual(e["fields"], ["name:str", "score:int"])


class EnumTests(unittest.TestCase):
    def test_enum_maps_to_type_alias_union(self):
        cat = cached_catalog()
        e = find_entry(cat, "Color")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "type-alias-union")

    def test_enum_cases_with_raw_values_carry_eq_prefix(self):
        cat = cached_catalog()
        e = find_entry(cat, "Color")
        # Each case rendered as `NAME:=<unparsed-value>`.
        self.assertIn("RED:='red'", e["fields"])
        self.assertIn("GREEN:='green'", e["fields"])

    def test_intenum(self):
        cat = cached_catalog()
        e = find_entry(cat, "Priority")
        self.assertEqual(e["kind"], "type-alias-union")
        self.assertIn("LOW:=1", e["fields"])
        self.assertIn("HIGH:=10", e["fields"])


class SQLAlchemyTests(unittest.TestCase):
    def test_declarative_with_mapped_columns_is_drizzle_table(self):
        cat = cached_catalog()
        e = find_entry(cat, "User", file_suffix="07_sqlalchemy.py")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "drizzle-table")

    def test_declarative_base_without_mapped_columns_falls_back(self):
        cat = cached_catalog()
        e = find_entry(cat, "NotAnOrmModel")
        self.assertIsNotNone(e)
        # No Mapped[...] in the body, so the heuristic falls through to the
        # AnnAssign-based rule: type-alias-object.
        self.assertEqual(e["kind"], "type-alias-object")


class TypeAliasTests(unittest.TestCase):
    def test_pep604_union_alias(self):
        cat = cached_catalog()
        e = find_entry(cat, "IntOrStr")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "type-alias-union")
        self.assertIn("type_text", e)

    def test_union_subscript(self):
        cat = cached_catalog()
        e = find_entry(cat, "UnionAlias")
        self.assertEqual(e["kind"], "type-alias-union")

    def test_literal_alias_is_union(self):
        cat = cached_catalog()
        e = find_entry(cat, "LiteralAlias")
        self.assertEqual(e["kind"], "type-alias-union")

    def test_newtype_is_other(self):
        cat = cached_catalog()
        e = find_entry(cat, "NewTypeAlias")
        self.assertEqual(e["kind"], "type-alias-other")

    def test_list_alias_is_other(self):
        cat = cached_catalog()
        e = find_entry(cat, "ListAlias")
        self.assertEqual(e["kind"], "type-alias-other")

    def test_bare_union_without_typealias_annotation(self):
        cat = cached_catalog()
        e = find_entry(cat, "BareUnion")
        self.assertEqual(e["kind"], "type-alias-union")


@unittest.skipIf(sys.version_info < (3, 12), "PEP 695 requires Python 3.12+")
class Pep695Tests(unittest.TestCase):
    def test_pep695_union(self):
        cat = cached_catalog()
        e = find_entry(cat, "Pep695Union")
        self.assertIsNotNone(e, "PEP 695 alias should be extracted on 3.12+")
        self.assertEqual(e["kind"], "type-alias-union")

    def test_pep695_single(self):
        cat = cached_catalog()
        e = find_entry(cat, "Pep695Single")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "type-alias-other")


class RegularClassTests(unittest.TestCase):
    def test_plain_with_annassign_is_object(self):
        cat = cached_catalog()
        e = find_entry(cat, "PlainShape")
        self.assertEqual(e["kind"], "type-alias-object")
        self.assertEqual(e["fields"], ["count:int", "name:str"])

    def test_empty_class_is_interface(self):
        cat = cached_catalog()
        e = find_entry(cat, "EmptyClass")
        self.assertEqual(e["kind"], "interface")
        self.assertEqual(e["fields"], [])

    def test_exception_subclass_is_interface(self):
        cat = cached_catalog()
        e = find_entry(cat, "CustomError")
        self.assertEqual(e["kind"], "interface")
        self.assertIn("Exception", e["extends"])

    def test_classvar_sets_is_static(self):
        cat = cached_catalog()
        e = find_entry(cat, "HasClassVar")
        static_field = next(fs for fs in e["fields_structured"] if fs["name"] == "static_field")
        self.assertTrue(static_field["is_static"])
        instance_field = next(fs for fs in e["fields_structured"] if fs["name"] == "instance_field")
        self.assertFalse(instance_field["is_static"])


class GenericsTests(unittest.TestCase):
    def test_protocol_with_type_param(self):
        cat = cached_catalog()
        e = find_entry(cat, "GenericProtocol", file_suffix="11_generics.py")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "interface")
        self.assertEqual(e.get("generics"), "T")

    def test_generic_class_with_two_params(self):
        cat = cached_catalog()
        e = find_entry(cat, "GenericClass")
        self.assertIsNotNone(e)
        # Generic isn't itself a "shape-bearing" base, but the class has
        # AnnAssign fields so it falls to type-alias-object.
        self.assertEqual(e["kind"], "type-alias-object")
        self.assertEqual(e.get("generics"), "T,U")


class FlagsTests(unittest.TestCase):
    """File-path-derived is_test / generated flags."""

    def test_generated_subdir_flags_records(self):
        cat = cached_catalog()
        e = find_entry(cat, "GeneratedShape")
        self.assertTrue(e["generated"])

    def test_pb2_suffix_flags_generated(self):
        cat = cached_catalog()
        e = find_entry(cat, "ProtobufShape")
        self.assertTrue(e["generated"])

    def test_tests_dir_flags_is_test(self):
        cat = cached_catalog()
        e = find_entry(cat, "ShapeInsideTestsDir")
        self.assertTrue(e["is_test"])

    def test_test_prefix_filename_flags_is_test(self):
        cat = cached_catalog()
        e = find_entry(cat, "TestPatternShape")
        self.assertTrue(e["is_test"])

    def test_test_suffix_filename_flags_is_test(self):
        cat = cached_catalog()
        e = find_entry(cat, "PatternFileTestShape")
        self.assertTrue(e["is_test"])

    def test_conftest_flags_is_test(self):
        cat = cached_catalog()
        e = find_entry(cat, "ConftestShape")
        self.assertTrue(e["is_test"])

    def test_normal_file_not_flagged(self):
        cat = cached_catalog()
        e = find_entry(cat, "Point")
        self.assertFalse(e["is_test"])
        self.assertFalse(e["generated"])


class ShapeSigDeterminismTests(unittest.TestCase):
    """Cross-fixture invariants on shape_sig."""

    def test_shape_sig_is_lowercase(self):
        cat = cached_catalog()
        for e in cat["entries"]:
            sig = e.get("shape_sig")
            if sig:
                self.assertEqual(sig, sig.lower(), f"shape_sig not lowercased: {sig}")

    def test_shape_sig_separator(self):
        cat = cached_catalog()
        for e in cat["entries"]:
            sig = e.get("shape_sig")
            if sig and len(e.get("fields") or []) >= 2:
                self.assertIn("|", sig, f"multi-field shape_sig missing separator: {sig}")


if __name__ == "__main__":
    unittest.main()
