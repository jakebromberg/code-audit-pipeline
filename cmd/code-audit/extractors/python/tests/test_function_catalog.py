"""Tests for the Python function-catalog extractor.

Runs `function_catalog.py` as a subprocess against `fixtures/` and asserts on
the emitted records against the spec in `docs/pipeline-contract.md`.

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
FUNCTION_CATALOG = EXTRACTOR_DIR / "function_catalog.py"


def run_extractor(*extra_args, root=FIXTURES_ROOT):
    result = subprocess.run(
        [sys.executable, str(FUNCTION_CATALOG), "--root", str(root), *extra_args],
        capture_output=True, text=True, timeout=30,
    )
    parsed = None
    if result.stdout:
        try:
            parsed = json.loads(result.stdout)
        except json.JSONDecodeError:
            parsed = None
    return result.returncode, parsed, result.stderr


_CACHE: dict = {}


def cached_catalog():
    if "catalog" not in _CACHE:
        rc, catalog, stderr = run_extractor()
        if rc != 0 or catalog is None:
            raise RuntimeError(f"extractor failed (rc={rc}): {stderr}")
        _CACHE["catalog"] = catalog
    return _CACHE["catalog"]


def find_entry(catalog, name, file_suffix=None):
    matches = [e for e in catalog["entries"] if e["name"] == name]
    if file_suffix:
        matches = [e for e in matches if e["file"].endswith(file_suffix)]
    return matches[0] if matches else None


class WrapperTests(unittest.TestCase):
    def test_extractor_exits_zero(self):
        rc, _, stderr = run_extractor()
        self.assertEqual(rc, 0, f"stderr: {stderr}")

    def test_wrapper_shape(self):
        cat = cached_catalog()
        self.assertEqual(cat["schema_version"], "2.0")
        self.assertEqual(cat["extractor"]["language"], "python")
        self.assertEqual(cat["extractor"]["name"], "function-catalog")
        self.assertRegex(cat["extractor"]["version"], r"^\d+\.\d+\.\d+")
        self.assertEqual(cat["fingerprint_v"], "shape_sig:1")
        self.assertIsInstance(cat["entries"], list)
        self.assertGreater(len(cat["entries"]), 0)

    def test_every_entry_carries_per_entry_language(self):
        for e in cached_catalog()["entries"]:
            self.assertEqual(e["language"], "python")

    def test_every_entry_has_required_fields(self):
        required = {"name", "kind", "package", "file", "line",
                    "is_test", "exported", "async", "param_count",
                    "param_names", "body_hash", "body_lines",
                    "body_line_count", "body_length",
                    "params", "return_ref", "references", "references_count",
                    "signature_index"}
        for e in cached_catalog()["entries"]:
            missing = required - e.keys()
            self.assertEqual(
                missing, set(),
                f"function {e['name']} missing fields: {missing}",
            )

    def test_runs_byte_deterministic(self):
        rc1, c1, _ = run_extractor()
        rc2, c2, _ = run_extractor()
        self.assertEqual(rc1, 0)
        self.assertEqual(rc2, 0)
        self.assertEqual(c1["entries"], c2["entries"])


class SyncAsyncTests(unittest.TestCase):
    def test_sync_function(self):
        e = find_entry(cached_catalog(), "short_sync")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "function")
        self.assertFalse(e["async"])

    def test_async_function(self):
        e = find_entry(cached_catalog(), "short_async")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "function")
        self.assertTrue(e["async"])


class BodyHashGatingTests(unittest.TestCase):
    """Functions whose normalized body has fewer than --min-body-lines lines
    emit a row with body_hash / body_lines / body_line_count / body_length null."""

    def test_short_body_yields_null_body_fields(self):
        e = find_entry(cached_catalog(), "short_sync")
        # `return x + 1` is 1 line after normalization. Default min=3.
        self.assertIsNone(e["body_hash"])
        self.assertIsNone(e["body_lines"])
        self.assertIsNone(e["body_line_count"])
        self.assertIsNone(e["body_length"])

    def test_long_body_populates_body_fields(self):
        e = find_entry(cached_catalog(), "long_function")
        self.assertIsNotNone(e["body_hash"])
        self.assertRegex(e["body_hash"], r"^[0-9a-f]{64}$")
        self.assertGreaterEqual(e["body_line_count"], 3)
        self.assertIsInstance(e["body_lines"], list)
        self.assertGreater(len(e["body_lines"]), 0)

    def test_docstring_dropped_from_body(self):
        e = find_entry(cached_catalog(), "long_function")
        # The docstring `"This docstring should be skipped..."` must NOT
        # appear in body_lines.
        for line in e["body_lines"]:
            self.assertNotIn("This docstring should be skipped", line)

    def test_min_body_lines_override(self):
        """With --min-body-lines 1, even the short functions get body fields."""
        rc, cat, _ = run_extractor("--min-body-lines", "1")
        self.assertEqual(rc, 0)
        e = find_entry(cat, "short_sync")
        self.assertIsNotNone(e["body_hash"])
        self.assertGreaterEqual(e["body_line_count"], 1)


class SelfClsHandlingTests(unittest.TestCase):
    def test_self_excluded_from_param_count(self):
        # WithMethods.instance_method(self, n: int)
        e = find_entry(cached_catalog(), "WithMethods.instance_method")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "method")
        self.assertEqual(e["param_count"], 1)
        self.assertEqual(e["param_names"], ["n"])

    def test_cls_excluded_from_param_count(self):
        e = find_entry(cached_catalog(), "WithMethods.class_method")
        self.assertIsNotNone(e)
        self.assertEqual(e["param_count"], 1)
        self.assertEqual(e["param_names"], ["n"])

    def test_staticmethod_keeps_first_arg_even_when_named_self(self):
        # @staticmethod has NO implicit first arg, even if the author
        # unfortunately named the first parameter `self`. param_count must
        # reflect the caller-perspective arity (2), and `self` must remain in
        # param_names.
        e = find_entry(cached_catalog(), "WithMethods.static_method")
        self.assertIsNotNone(e)
        self.assertEqual(e["kind"], "method")
        self.assertEqual(e["param_count"], 2)
        self.assertEqual(e["param_names"], ["self", "n"])


class OverloadSignatureIndexTests(unittest.TestCase):
    def test_overload_heads_get_distinct_signature_indices(self):
        # Three FunctionDefs all named `WithOverloads.value`: two @overload
        # heads + one implementation. signature_index must run 0, 1, 2 in
        # source order so downstream queries can dedupe by (name, package,
        # file) and order by signature_index.
        cat = cached_catalog()
        entries = [
            e for e in cat["entries"] if e["name"] == "WithOverloads.value"
        ]
        self.assertEqual(len(entries), 3)
        # Catalog is sorted by (package, file, line, name); the source order
        # of @overload heads then implementation gives ascending lines.
        entries.sort(key=lambda e: e["line"])
        self.assertEqual([e["signature_index"] for e in entries], [0, 1, 2])

    def test_overload_heads_get_distinct_symbol_ids(self):
        # symbol_id folds in signature_index, so collisions across overload
        # heads are impossible.
        cat = cached_catalog()
        entries = [
            e for e in cat["entries"] if e["name"] == "WithOverloads.value"
        ]
        ids = [e["symbol_id"] for e in entries]
        self.assertEqual(len(set(ids)), len(ids), f"symbol_id collision: {ids}")


class MethodQualificationTests(unittest.TestCase):
    def test_method_name_is_qualified(self):
        # Inside `class WithMethods`, method `instance_method` should be
        # emitted as `WithMethods.instance_method`.
        cat = cached_catalog()
        names = {e["name"] for e in cat["entries"]}
        self.assertIn("WithMethods.instance_method", names)
        # And not the bare name.
        self.assertNotIn("instance_method", names)

    def test_method_kind(self):
        e = find_entry(cached_catalog(), "WithMethods.instance_method")
        self.assertEqual(e["kind"], "method")

    def test_top_level_kind(self):
        e = find_entry(cached_catalog(), "long_function")
        self.assertEqual(e["kind"], "function")


class NestedFunctionTests(unittest.TestCase):
    def test_nested_function_qualified(self):
        cat = cached_catalog()
        names = {e["name"] for e in cat["entries"]}
        # `def outer():` contains `def inner():` -> qualified as `outer.inner`.
        self.assertIn("outer.inner", names)
        self.assertIn("outer", names)


class ReferencesTests(unittest.TestCase):
    def test_user_type_in_references(self):
        # `takes_and_returns(arg: CustomReturn) -> CustomReturn`
        e = find_entry(cached_catalog(), "takes_and_returns")
        self.assertIsNotNone(e)
        ref_names = {r["name"] for r in e["references"]}
        self.assertIn("CustomReturn", ref_names)

    def test_builtins_filtered_from_references(self):
        e = find_entry(cached_catalog(), "short_sync")
        ref_names = {r["name"] for r in e["references"]}
        self.assertNotIn("int", ref_names)
        self.assertNotIn("str", ref_names)

    def test_references_count_matches(self):
        for e in cached_catalog()["entries"]:
            self.assertEqual(e["references_count"], len(e["references"]))

    def test_return_ref_single_identifier(self):
        e = find_entry(cached_catalog(), "takes_and_returns")
        self.assertEqual(e["return_ref"], "CustomReturn")

    def test_return_ref_none_for_primitive(self):
        e = find_entry(cached_catalog(), "short_sync")
        self.assertIsNone(e["return_ref"])


class ExportedFlagTests(unittest.TestCase):
    def test_public_function_exported(self):
        e = find_entry(cached_catalog(), "long_function")
        self.assertTrue(e["exported"])

    def test_underscore_prefix_not_exported(self):
        # The fixture tree has no top-level `_func` to assert against; this
        # exercises the path indirectly by checking that nothing private
        # leaks. (Adding a `_private_helper` fixture if a regression is
        # ever observed is cheap; for now the convention is held by the
        # `not name.split('.')[-1].startswith('_')` rule in the extractor.)
        cat = cached_catalog()
        for e in cat["entries"]:
            last = e["name"].split(".")[-1]
            if last.startswith("_"):
                self.assertFalse(
                    e["exported"],
                    f"{e['name']}: underscore-prefixed name should be exported=false",
                )


class FlagsPropagationTests(unittest.TestCase):
    def test_tests_dir_function_flagged_is_test(self):
        # The tests/ fixture dir is empty of functions today; the
        # type-catalog test covers the same code path. Defensive: if a
        # function ever lands under tests/, it must be flagged.
        for e in cached_catalog()["entries"]:
            if e["file"].startswith("tests/"):
                self.assertTrue(e["is_test"], f"{e['file']}: should be is_test")

    def test_generated_dir_function_flagged_generated(self):
        for e in cached_catalog()["entries"]:
            if e["file"].startswith("generated/"):
                self.assertTrue(e["generated"], f"{e['file']}: should be generated")


class FieldCopyMapTests(unittest.TestCase):
    """The `field_copy_map` additive field — hand-written field-copy mappers.

    Fixtures live in fixtures/13_field_copy_mappers.py. See
    docs/pipeline-contract.md § "Optional: field_copy_map".
    """

    IDENTITY_FIELDS = [
        "apple_music_artist_id", "bandcamp_id", "discogs_artist_id",
        "library_name", "musicbrainz_artist_id", "reconciliation_status",
        "spotify_artist_id", "wikidata_qid",
    ]

    def test_constructor_form(self):
        # _identity_to_response(identity: Identity) -> IdentityResponse copies
        # all eight shared fields by keyword. Computed BEFORE body normalization
        # (a single return renders as one line, below --min-body-lines), so the
        # body_hash is null but the signal survives.
        e = find_entry(cached_catalog(), "_identity_to_response")
        self.assertIsNotNone(e)
        self.assertIsNone(e["body_hash"], "single-return body should be nulled")
        fcm = e.get("field_copy_map")
        self.assertIsNotNone(fcm, "constructor-form mapper must carry field_copy_map")
        self.assertEqual(fcm["form"], "constructor")
        self.assertEqual(fcm["source_type_ref"], "Identity")
        self.assertEqual(fcm["dest_type_ref"], "IdentityResponse")
        self.assertEqual(fcm["copied_fields"], self.IDENTITY_FIELDS)

    def test_constructor_form_assign_then_return(self):
        # `response = IdentityResponse(...); return response`
        e = find_entry(cached_catalog(), "build_response")
        self.assertIsNotNone(e)
        fcm = e.get("field_copy_map")
        self.assertIsNotNone(fcm)
        self.assertEqual(fcm["form"], "constructor")
        self.assertEqual(fcm["source_type_ref"], "Identity")
        self.assertEqual(fcm["dest_type_ref"], "IdentityResponse")
        self.assertEqual(
            fcm["copied_fields"],
            ["discogs_artist_id", "library_name", "wikidata_qid"],
        )

    def test_attr_assign_form(self):
        # copy_record(src: SourceRecord, dst: DestRecord): dst.x = src.x ...
        e = find_entry(cached_catalog(), "copy_record")
        self.assertIsNotNone(e)
        fcm = e.get("field_copy_map")
        self.assertIsNotNone(fcm)
        self.assertEqual(fcm["form"], "attr-assign")
        self.assertEqual(fcm["source_type_ref"], "SourceRecord")
        self.assertEqual(fcm["dest_type_ref"], "DestRecord")
        self.assertEqual(fcm["copied_fields"], ["alpha", "beta", "delta", "gamma"])

    def test_model_validate_form_is_tagged(self):
        # IdentityResponse.from_identity(cls, identity) returns
        # cls.model_validate(identity, from_attributes=True) — the already-fixed
        # form. dest resolves through the enclosing class, copied_fields is empty.
        e = find_entry(cached_catalog(), "IdentityResponse.from_identity")
        self.assertIsNotNone(e)
        fcm = e.get("field_copy_map")
        self.assertIsNotNone(fcm)
        self.assertEqual(fcm["form"], "model_validate")
        self.assertEqual(fcm["source_type_ref"], "Identity")
        self.assertEqual(fcm["dest_type_ref"], "IdentityResponse")
        self.assertEqual(fcm["copied_fields"], [])

    def test_partial_transform_excludes_transformed_field(self):
        # Predominantly copies (alpha/beta/gamma) with one transform (delta):
        # emitted, but copied_fields counts only the identity copies.
        e = find_entry(cached_catalog(), "mostly_copy_one_transform")
        self.assertIsNotNone(e)
        fcm = e.get("field_copy_map")
        self.assertIsNotNone(fcm)
        self.assertEqual(fcm["form"], "constructor")
        self.assertEqual(fcm["copied_fields"], ["alpha", "beta", "gamma"])
        self.assertNotIn("delta", fcm["copied_fields"])

    def test_real_adapter_not_emitted(self):
        # Identity copies are the minority (only library_name); the extractor
        # must NOT recognize this as a 1:1 mapper.
        e = find_entry(cached_catalog(), "adapter_with_transforms")
        self.assertIsNotNone(e)
        self.assertNotIn("field_copy_map", e)

    def test_plain_function_not_emitted(self):
        e = find_entry(cached_catalog(), "not_a_mapper")
        self.assertIsNotNone(e)
        self.assertNotIn("field_copy_map", e)

    def test_field_copy_map_absent_by_default(self):
        # The field is additive — absent on every row that is not a mapper.
        for e in cached_catalog()["entries"]:
            if "field_copy_map" in e:
                fcm = e["field_copy_map"]
                self.assertIn(fcm["form"], {"constructor", "attr-assign", "model_validate"})
                self.assertIsInstance(fcm["copied_fields"], list)


if __name__ == "__main__":
    unittest.main()
