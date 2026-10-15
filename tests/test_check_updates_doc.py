"""The curriculum-update procedure lives in docs/OPERATING.md, not in a tool's skill folder."""
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ANCHOR = "docs/OPERATING.md#checking-curriculum-updates"


class CheckUpdatesDocTests(unittest.TestCase):
    def test_the_section_carries_the_procedure(self):
        text = (REPO / "docs" / "OPERATING.md").read_text(encoding="utf-8")
        self.assertIn("\n## Checking curriculum updates\n", text)
        section = text.split("\n## Checking curriculum updates\n", 1)[1].split("\n## ", 1)[0]
        # models.yaml is checked by `make check-models`, a separate target (review of #8).
        self.assertIn("make check-models", section)
        self.assertIn("`make check-updates` does not run it", section)
        for must in ("tracker sync", "check_versions.py", "models.yaml", "Exam versions",
                     "Outdated", "not measured", "Never re-snapshot without the owner's decision",
                     "catalog.yaml", "STATUS.md"):
            with self.subTest(must=must):
                self.assertIn(must, section)

    def test_the_makefile_agrees(self):
        makefile = (REPO / "Makefile").read_text(encoding="utf-8")
        recipe = makefile.split("\ncheck-updates:", 1)[1].split("\n\n", 1)[0]
        self.assertIn("check_versions.py", recipe)
        self.assertNotIn("check_models", recipe)
        self.assertIn("\ncheck-models:", makefile)

    def test_agents_and_people_find_it(self):
        for doc in ("CLAUDE.md", "AGENTS_SYNC.md"):
            with self.subTest(doc=doc):
                self.assertIn(ANCHOR, (REPO / doc).read_text(encoding="utf-8"))

    def test_the_skill_is_gone(self):
        self.assertFalse((REPO / ".claude" / "skills" / "check-updates").exists())


if __name__ == "__main__":
    unittest.main()
