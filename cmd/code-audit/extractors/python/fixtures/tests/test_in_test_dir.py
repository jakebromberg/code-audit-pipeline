"""Fixture: a file under a test directory.

Per the universal test-path patterns (`tests/`, `__tests__/`, etc.), every
record here should carry `is_test: true`. The directory name `tests-dir`
itself does NOT match, but the immediate parent (`tests`) does — exercised
indirectly via `test_pattern.py` and similar.
"""


class ShapeInsideTestsDir:
    field_z: str
