"""`.env` may configure translation and nothing else.

It exists for one purpose — translating without spending the Claude
subscription. `TEACH_BACKEND=litellm` in that file would silently move AUTHORING
to a cheap model, which is the one substitution this project does not make and
would be invisible afterwards except in the meta.yaml of every topic written
while it was set. The restriction is enforced here rather than documented.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from teach.core import TRANSLATION_ONLY, load_env  # noqa: E402


class EnvScopeTests(unittest.TestCase):
    def _write(self, text: str) -> Path:
        tmp = Path(tempfile.mkdtemp()) / ".env"
        tmp.write_text(text)
        return tmp

    def tearDown(self):
        for key in ("LITELLM_MODEL", "TEACH_BACKEND", "TEACH_TRANSLATE_BACKEND"):
            os.environ.pop(key, None)

    def test_loads_translation_variables(self):
        loaded = load_env(self._write("LITELLM_MODEL=gemini-free\n"))
        self.assertEqual(loaded, 1)
        self.assertEqual(os.environ["LITELLM_MODEL"], "gemini-free")

    def test_refuses_to_change_the_authoring_backend(self):
        load_env(self._write("TEACH_BACKEND=litellm\n"))
        self.assertNotIn("TEACH_BACKEND", os.environ)

    def test_authoring_backend_is_not_in_the_allowed_set(self):
        self.assertNotIn("TEACH_BACKEND", TRANSLATION_ONLY)
        self.assertNotIn("TEACH_CLAUDE_MODEL", TRANSLATION_ONLY)
        self.assertIn("TEACH_TRANSLATE_BACKEND", TRANSLATION_ONLY)

    def test_the_real_environment_wins(self):
        os.environ["LITELLM_MODEL"] = "chosen-explicitly"
        load_env(self._write("LITELLM_MODEL=from-the-file\n"))
        self.assertEqual(os.environ["LITELLM_MODEL"], "chosen-explicitly")

    def test_a_missing_file_is_not_an_error(self):
        self.assertEqual(load_env(Path("/nonexistent/.env")), 0)


if __name__ == "__main__":
    unittest.main()
