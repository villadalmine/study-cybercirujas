"""docs/ISSUE-TO-RELEASE.md lists every label of .github/labels.yml, and only those, so it cannot drift."""
import re
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent


class LabelTableTests(unittest.TestCase):
    def test_the_doc_table_is_the_label_file(self):
        names = {l["name"] for l in yaml.safe_load((REPO / ".github" / "labels.yml").read_text(encoding="utf-8"))}
        text = (REPO / "docs" / "ISSUE-TO-RELEASE.md").read_text(encoding="utf-8")
        table = text.split("## Every label, who sets it", 1)[1]
        documented = set(re.findall(r"^\| `([^`]+)` \|", table, re.M))
        self.assertEqual(documented, names, "labels missing from the doc: %s; not in labels.yml: %s"
                         % (sorted(names - documented), sorted(documented - names)))


if __name__ == "__main__":
    unittest.main()
