"""Unit tests for the pure helpers in _lib.py.

Pure functions that don't need subprocess execution — fast feedback loop.
Run with:  python3 -m unittest discover -s extractors/python -t extractors/python
"""

import os
import sys
import unittest
from pathlib import Path

EXTRACTOR_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(EXTRACTOR_DIR))

from _lib import (  # noqa: E402
    SCHEMA_VERSION,
    FINGERPRINT_V,
    LANGUAGE,
    SKIP_DIRS,
    TEST_DIR_SEGMENTS,
    annotation_text,
    is_generated,
    is_test_path,
    make_extractor_block,
    sha256_hex,
    shape_sig,
    walk_python_files,
)


class ConstantsTests(unittest.TestCase):
    def test_schema_version(self):
        self.assertEqual(SCHEMA_VERSION, "2.0")

    def test_fingerprint_v(self):
        self.assertEqual(FINGERPRINT_V, "shape_sig:1")

    def test_language(self):
        self.assertEqual(LANGUAGE, "python")

    def test_skip_dirs_contains_pyspecific(self):
        # Python-specific entries the contract requires (mirrors the substrate
        # convention; `__pycache__` and `.venv` are the two most common
        # sources of catalog inflation if missing).
        self.assertIn("__pycache__", SKIP_DIRS)
        self.assertIn(".venv", SKIP_DIRS)

    def test_test_dir_segments_match_contract(self):
        # The universal dir-pattern set from docs/pipeline-contract.md
        # §"Test path patterns". Other-language extractors must implement
        # the same set; this guards a silent drift.
        required = {"tests", "test", "__tests__", "__test__",
                    "spec", "__mocks__", "__fixtures__", "fixtures", "e2e"}
        self.assertEqual(TEST_DIR_SEGMENTS & required, required)


class IsTestPathTests(unittest.TestCase):
    """Test path detection — universal + Python-specific patterns."""

    def test_test_underscore_prefix(self):
        self.assertTrue(is_test_path("test_foo.py"))
        self.assertTrue(is_test_path(f"core{os.sep}test_helpers.py"))

    def test_underscore_test_suffix(self):
        self.assertTrue(is_test_path("foo_test.py"))

    def test_conftest(self):
        self.assertTrue(is_test_path("conftest.py"))
        self.assertTrue(is_test_path(f"tests{os.sep}conftest.py"))

    def test_universal_dir_segments(self):
        for seg in ["tests", "test", "__tests__", "spec", "fixtures", "e2e"]:
            with self.subTest(seg=seg):
                self.assertTrue(is_test_path(f"{seg}{os.sep}foo.py"))

    def test_fixture_suffix(self):
        self.assertTrue(is_test_path("user.fixture.py"))
        self.assertTrue(is_test_path("user.fixtures.py"))
        self.assertTrue(is_test_path("user.mock.py"))

    def test_non_test_paths(self):
        self.assertFalse(is_test_path("foo.py"))
        self.assertFalse(is_test_path("src/main.py"))
        self.assertFalse(is_test_path("testing.py"))  # NOT a test marker

    def test_test_keyword_in_middle_of_filename_not_match(self):
        # "test" in the middle of a filename without `_test.py` / `test_*`
        # shouldn't trigger — `latest.py`, `my_protest_form.py`, etc.
        self.assertFalse(is_test_path("latest.py"))


class IsGeneratedTests(unittest.TestCase):
    def test_generated_segment(self):
        self.assertTrue(is_generated("generated/foo.py"))
        self.assertTrue(is_generated(f"src{os.sep}generated{os.sep}foo.py"))

    def test_egg_info(self):
        self.assertTrue(is_generated("pkg.egg-info/PKG-INFO"))

    def test_protobuf_pb2(self):
        self.assertTrue(is_generated("foo_pb2.py"))
        self.assertTrue(is_generated("foo_pb2_grpc.py"))

    def test_not_generated(self):
        self.assertFalse(is_generated("src/main.py"))
        self.assertFalse(is_generated("tests/test_foo.py"))


class ShapeSigTests(unittest.TestCase):
    def test_lowercase_and_join(self):
        # shape_sig = sorted(fields).join("|").lower(), per contract.
        self.assertEqual(shape_sig(["B:int", "A:str"]), "a:str|b:int")

    def test_empty(self):
        self.assertEqual(shape_sig([]), "")

    def test_order_independent(self):
        # Same fields in any order should produce the same signature.
        a = shape_sig(["x:int", "y:str", "z:bool"])
        b = shape_sig(["z:bool", "x:int", "y:str"])
        self.assertEqual(a, b)


class AnnotationTextTests(unittest.TestCase):
    def test_none_annotation(self):
        self.assertEqual(annotation_text(None), "Any")

    def test_simple_name(self):
        import ast as _ast
        self.assertEqual(annotation_text(_ast.parse("int", mode="eval").body), "int")

    def test_collapses_whitespace(self):
        import ast as _ast
        # `Union[int,\n    str]` — ast.unparse re-renders without internal newlines, but
        # we still normalize defensively.
        node = _ast.parse("Union[int,\n    str]", mode="eval").body
        self.assertNotIn("\n", annotation_text(node))


class WalkPythonFilesTests(unittest.TestCase):
    def setUp(self):
        self.fixtures = EXTRACTOR_DIR / "fixtures"

    def test_walk_finds_all_fixture_files(self):
        files = list(walk_python_files(self.fixtures))
        names = {f.name for f in files}
        # Spot-check: each major fixture is present.
        self.assertIn("01_protocols.py", names)
        self.assertIn("06_enums.py", names)
        self.assertIn("conftest.py", names)
        self.assertIn("codegen.py", names)

    def test_walk_skips_dotdirs(self, tmpdir=None):
        # The fixture tree has no dotdirs today, but the skip-list also
        # excludes `.venv` etc. — synthesize a dotdir under the fixture
        # tree just for this test and verify it gets pruned.
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "src").mkdir()
            (root / "src" / "real.py").write_text("x = 1\n")
            (root / ".hidden").mkdir()
            (root / ".hidden" / "secret.py").write_text("x = 1\n")
            (root / "__pycache__").mkdir()
            (root / "__pycache__" / "compiled.py").write_text("x = 1\n")
            files = list(walk_python_files(root))
            names = {f.name for f in files}
            self.assertEqual(names, {"real.py"})


class MakeExtractorBlockTests(unittest.TestCase):
    def test_shape(self):
        block = make_extractor_block("type-catalog", "abc123")
        self.assertEqual(block["language"], "python")
        self.assertEqual(block["name"], "type-catalog")
        self.assertEqual(block["source_sha"], "abc123")
        # version is the package-level constant — just assert it's there.
        self.assertIn("version", block)


class Sha256HexTests(unittest.TestCase):
    def test_known_value(self):
        # `sha256("hello") = 2cf24dba…b9824`. Lock the alg + hex digest format.
        self.assertEqual(
            sha256_hex("hello"),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        )


if __name__ == "__main__":
    unittest.main()
