from __future__ import annotations

import builtins
import importlib
import unittest

import oracle


class PureOracleSurfaceCase(unittest.TestCase):
    def test_oracle_imports_only_standard_library_and_no_effect_modules(self):
        loaded = set()
        real_import = builtins.__import__

        def tracking_import(name, globals=None, locals=None, fromlist=(), level=0):
            if (globals or {}).get("__name__") == "oracle" and name:
                loaded.add(name.split(".")[0])
            return real_import(name, globals, locals, fromlist, level)

        builtins.__import__ = tracking_import
        try:
            importlib.reload(oracle)
        finally:
            builtins.__import__ = real_import
        self.assertTrue(loaded <= {"__future__", "dataclasses", "datetime", "enum", "json", "math", "re", "typing"})
        self.assertTrue(loaded.isdisjoint({"os", "pathlib", "socket", "subprocess", "urllib", "http", "fcntl"}))

    def test_step_has_exact_explicit_authority_parameters(self):
        parameters = tuple(__import__("inspect").signature(oracle.step).parameters)
        self.assertEqual(
            parameters,
            ("state", "observation", "now", "sender_result_if_attempted"),
        )


if __name__ == "__main__":
    unittest.main()
