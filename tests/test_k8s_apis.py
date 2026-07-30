"""Detection of removed Kubernetes APIs.

What is tested is the judgement, not the table: the hard part is not knowing
that `batch/v1beta1` was removed, it is not reporting the topic that teaches
exactly that. A check that flags correct material gets ignored, and then it
stops working for the incorrect material too.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import check_k8s_apis as checker  # noqa: E402

STALE = """\
# Example Ingress

```yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: web
```
"""

TEACHING = """\
# API deprecation

Before 1.25, `CronJob` was created like this:

```yaml
apiVersion: batch/v1beta1
kind: CronJob
```

That version was **removed** in 1.25; the API server answers
`no matches for kind "CronJob" in version "batch/v1beta1"`.
"""

FAR_AWAY = """\
# Container security

Capabilities should be removed from the container by default.

""" + ("\ncontext filler.\n" * 40) + """
```yaml
apiVersion: extensions/v1beta1
kind: Ingress
```
"""


class RemovedApiTest(unittest.TestCase):
    def _write(self, text: str) -> Path:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
        tmp.write(text)
        tmp.close()
        return Path(tmp.name)

    def test_detects_a_removed_api(self) -> None:
        found = checker.findings(self._write(STALE))
        self.assertEqual(len(found), 1)
        _, api, _, _, deliberate = found[0]
        self.assertEqual(api, "extensions/v1beta1")
        self.assertFalse(deliberate)

    def test_does_not_report_the_topic_teaching_deprecation(self) -> None:
        found = checker.findings(self._write(TEACHING))
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0][4], "should be marked as a deliberate usage")

    def test_context_is_measured_by_proximity(self) -> None:
        """Mentioning 'removed' in another paragraph cannot give a free pass to
        a stale manifest forty lines below."""
        found = checker.findings(self._write(FAR_AWAY))
        self.assertEqual(len(found), 1)
        self.assertFalse(found[0][4])

    def test_ignores_third_party_crds(self) -> None:
        """Istio and Tekton version independently: their v1beta1 may be current."""
        text = "```yaml\napiVersion: security.istio.io/v1beta1\nkind: PeerAuthentication\n```\n"
        self.assertEqual(checker.findings(self._write(text)), [])

    def test_current_apis_are_not_reported(self) -> None:
        for api in ("apps/v1", "batch/v1", "networking.k8s.io/v1", "policy/v1"):
            with self.subTest(api=api):
                text = f"```yaml\napiVersion: {api}\nkind: X\n```\n"
                self.assertEqual(checker.findings(self._write(text)), [])


if __name__ == "__main__":
    unittest.main()
