"""Tests for scripts/check_citations.py and .github/workflows/citations.yml (#208)."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import check_citations as cc  # noqa: E402


class DomainAndPinTests(unittest.TestCase):
    def test_is_official_checks_catalogued_and_neutral_domains(self):
        owner, neutral, _ = cc.source_domains()
        self.assertTrue(cc.is_official("https://kubernetes.io/docs/concepts/workloads/", owner, neutral))
        self.assertTrue(cc.is_official("https://github.com/cncf/curriculum", owner, neutral))
        self.assertFalse(cc.is_official("https://random-blog.example.com/k8s-post", owner, neutral))

    def test_is_pinned_versioned_git_and_meta_sha(self):
        _, _, versioned = cc.source_domains()
        sha = "a" * 64
        self.assertTrue(cc.is_pinned("https://man7.org/linux/man-pages/man1/ls.1.html", versioned))
        self.assertTrue(cc.is_pinned("https://kubernetes.io/docs/v1.35/tasks/", versioned))
        self.assertFalse(cc.is_pinned("https://kubernetes.io/docs/concepts/workloads/", versioned))
        self.assertTrue(cc.is_pinned("https://kubernetes.io/docs/concepts/workloads/", versioned,
                                     {"https://kubernetes.io/docs/concepts/workloads/": {"sha256": sha}}))
        self.assertFalse(cc.is_pinned("https://raw.githubusercontent.com/org/repo/main/README.md", versioned))
        self.assertTrue(cc.is_pinned("https://github.com/org/repo/raw/0123456789abcdef/file.pdf", versioned))

    def test_floating_aliases_are_not_pins(self):
        floating = {"docs.cilium.io", "argo-cd.readthedocs.io"}
        for url in ("https://docs.cilium.io/en/stable/network/", "https://argo-cd.readthedocs.io/en/stable/",
                    "https://docs.cilium.io/en/lts/network/", "https://docs.cilium.io/en/latest/network/"):
            self.assertFalse(cc.is_pinned(url, floating), url)
        self.assertTrue(cc.is_pinned("https://docs.cilium.io/en/v1.16/network/", floating))

    def test_write_meta_pins_is_idempotent_and_preserves_quality(self):
        with tempfile.TemporaryDirectory() as tmp:
            meta = Path(tmp) / "meta.yaml"
            meta.write_text("backend: claude\nmodel: claude-opus-5\nquality:\n  score: 80\n", encoding="utf-8")
            pins = {"https://kubernetes.io/docs/concepts/": {"sha256": "b" * 64, "date": "2026-11-16"}}
            self.assertTrue(cc.write_meta_pins(meta, pins))
            first = meta.read_text(encoding="utf-8")
            self.assertIn("citation_pins:", first)
            self.assertIn("quality:\n  score: 80", first)
            self.assertFalse(cc.write_meta_pins(meta, pins))


class AuditAndWorkflowTests(unittest.TestCase):
    def _tree(self, root: Path, content: str, meta_extra: str = "") -> None:
        d = root / "certs" / "cka" / "1.1" / "en"
        d.mkdir(parents=True, exist_ok=True)
        (d / "content.md").write_text(f"# Title\n\n## References\n\n{content}\n", encoding="utf-8")
        (d / "meta.yaml").write_text(f"backend: claude\nmodel: claude-opus-5\n{meta_extra}", encoding="utf-8")

    def test_offline_audit_and_mode_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._tree(root, "- https://random-blog.example.com/post\n- https://raw.githubusercontent.com/a/b/main/f.md")
            rep = cc.audit(["certs"], offline=True, root=root)
            self.assertEqual(rep["checked_urls"], 0)
            self.assertEqual(len(rep["unofficial"]), 1)
            self.assertEqual(len(rep["unpinned"]), 1)
            self.assertEqual(cc.main([str(root / "certs"), "--offline", "--mode", "warn"]), 0)
            self.assertEqual(cc.main([str(root / "certs"), "--offline", "--mode", "block"]), 1)

    def test_mocked_reachability_write_pins_and_single_rot_issue_body(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            good = "https://kubernetes.io/docs/concepts/pods/"
            dead = "https://kubernetes.io/docs/does-not-exist"
            self._tree(root, f"- {good}\n- {dead}\n- https://gnu.org/manual/")
            responses = {good: (200, "c" * 64), dead: (404, None), "https://gnu.org/manual/": (403, None)}
            with mock.patch.object(cc, "fetch_sha256", side_effect=lambda u, timeout=10: responses[u]):
                rep = cc.audit(["certs"], write_pins=True, date_str="2026-11-16", cache_path=None, root=root)
            self.assertEqual([b["url"] for b in rep["broken"]], [dead])
            self.assertEqual(rep["pins_written"], 1)
            body = cc.render_issue_body(rep)
            self.assertTrue(body.startswith(cc.ISSUE_MARKER))
            self.assertIn(dead, body)
            rep_after = cc.audit(["certs"], offline=True, root=root)
            self.assertNotIn(good, [x["url"] for x in rep_after["unpinned"]])

    def test_citations_workflow_schedules_single_rot_issue(self):
        wf = yaml.safe_load((REPO / ".github" / "workflows" / "citations.yml").read_text(encoding="utf-8"))
        self.assertIn("citation-rot", wf["jobs"])
        self.assertEqual(wf["permissions"]["issues"], "write")
        run_text = "\n".join(s.get("run", "") for s in wf["jobs"]["citation-rot"]["steps"])
        self.assertIn("<!-- citation-rot -->", run_text)
        self.assertIn("gh issue edit", run_text)
        self.assertIn("gh issue create", run_text)


if __name__ == "__main__":
    unittest.main()
