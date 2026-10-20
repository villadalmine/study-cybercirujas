"""Every third-party action in .github/ is pinned to a full commit SHA with a `# vX.Y.Z` comment.

A tag such as `@v4` can be moved by whoever controls the action repository; a commit SHA cannot.
The comment keeps the pin readable and tells a reviewer which release the SHA is. Local actions
(`./...`) are part of this repository and are exempt. Found by an external security review.
"""
import re
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
USES = re.compile(r"^\s*-?\s*uses:\s*(\S+)(.*)$")
PINNED = re.compile(r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$")
COMMENT = re.compile(r"^\s+# v\d+\.\d+\.\d+$")


def unpinned(root: Path) -> list[str]:
    bad = []
    files = sorted(root.glob(".github/workflows/*.y*ml")) + sorted(root.glob(".github/actions/*/action.y*ml"))
    for f in files:
        in_description = False
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            # The composite action documents its own usage inside `description: >`: text, not a step.
            if line.startswith("description:"):
                in_description = True
                continue
            if in_description and re.match(r"^\S", line):
                in_description = False
            if in_description:
                continue
            m = USES.match(line)
            if not m:
                continue
            ref, rest = m.groups()
            if ref.startswith("./"):
                continue
            if not (PINNED.match(ref) and COMMENT.match(rest)):
                bad.append(f"{f.relative_to(root)}:{n}: {line.strip()}")
    return bad


class ActionsPinnedTests(unittest.TestCase):
    def test_every_action_is_pinned_by_sha_with_version_comment(self):
        self.assertEqual(unpinned(REPO), [])

    def test_a_tag_or_a_missing_comment_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            wf = Path(tmp) / ".github/workflows/x.yml"
            wf.parent.mkdir(parents=True)
            sha = "0" * 40
            wf.write_text(
                "steps:\n"
                "  - uses: actions/checkout@v4\n"
                "  - uses: ./local\n"
                f"  - uses: a/b@{sha}  # v1.2.3\n"
                f"  - uses: a/c@{sha}\n"
            )
            self.assertEqual(len(unpinned(Path(tmp))), 2)


if __name__ == "__main__":
    unittest.main()
