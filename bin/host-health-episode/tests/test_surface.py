from __future__ import annotations

import ast
from pathlib import Path
import unittest

import oracle


class PureOracleSurfaceCase(unittest.TestCase):
    def test_oracle_imports_only_standard_library_and_no_effect_modules(self):
        path = Path(oracle.__file__).resolve()
        tree = ast.parse(path.read_text(encoding="utf-8"))
        imports = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imports.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imports.add(node.module.split(".")[0])
        self.assertTrue(imports <= {"__future__", "dataclasses", "datetime", "enum", "json", "math", "re", "typing"})
        self.assertTrue(imports.isdisjoint({"os", "pathlib", "socket", "subprocess", "urllib", "http", "fcntl"}))

    def test_step_has_exact_explicit_authority_parameters(self):
        parameters = tuple(__import__("inspect").signature(oracle.step).parameters)
        self.assertEqual(
            parameters,
            ("state", "observation", "now", "sender_result_if_attempted"),
        )


if __name__ == "__main__":
    unittest.main()
