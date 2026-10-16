"""scripts/check_graph.py --regenerate: compare the committed graph with a rebuild (no graphify needed here)."""
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import check_graph  # noqa: E402

GRAPH = {"directed": False, "nodes": [{"id": "a"}], "links": [], "built_at_commit": "aaaa"}


class IncrementalContractTests(unittest.TestCase):
    """The rebuild runs on top of the committed graphify-out/, like `make graph` (review of #9)."""

    def test_the_copy_includes_the_committed_graph(self):
        seen = {}
        real_run = check_graph.subprocess.run

        def fake_run(cmd, *args, **kwargs):
            if cmd[0] == "graphify":
                out = Path(kwargs["cwd"]) / "graphify-out"
                seen["graph"] = (out / "graph.json").exists()
                seen["labels"] = (out / ".graphify_labels.json").exists()
                seen["certs"] = (Path(kwargs["cwd"]) / "certs").exists()
                return check_graph.subprocess.CompletedProcess(cmd, 0, "", "")
            return real_run(cmd, *args, **kwargs)

        with mock.patch.object(check_graph.subprocess, "run", fake_run):
            graph = check_graph.rebuild_in_copy("graphify")
        self.assertEqual(seen, {"graph": True, "labels": True, "certs": False})
        self.assertIn("nodes", graph)


class RegenerateTests(unittest.TestCase):
    def run_regenerate(self, rebuilt, touched, strict=False):
        with tempfile.TemporaryDirectory() as tmp:
            committed = Path(tmp) / "graph.json"
            committed.write_text(json.dumps(GRAPH), encoding="utf-8")
            out = io.StringIO()
            with mock.patch.object(check_graph, "GRAPH", committed), \
                 mock.patch.object(check_graph, "graphify_bin", lambda: "graphify"), \
                 mock.patch.object(check_graph, "rebuild_in_copy", lambda g: rebuilt), \
                 mock.patch.object(check_graph, "touches_graph_sources", lambda base: touched), \
                 redirect_stdout(out):
                code = check_graph.regenerate("origin/main", strict)
        return code, out.getvalue()

    def test_same_graph_from_another_commit_is_fresh(self):
        code, out = self.run_regenerate(dict(GRAPH, built_at_commit="bbbb"), ["scripts/x.py"])
        self.assertEqual(code, 0)
        self.assertIn("graph: OK", out)

    def test_stale_graph_fails_when_the_change_touches_the_code(self):
        code, out = self.run_regenerate(dict(GRAPH, nodes=[{"id": "a"}, {"id": "b"}]), ["teach/api.py"])
        self.assertEqual(code, 1)
        self.assertIn("make graph", out)

    def test_stale_graph_only_warns_for_other_changes(self):
        code, out = self.run_regenerate(dict(GRAPH, nodes=[]), [])
        self.assertEqual(code, 0)
        self.assertIn("Warning only", out)

    def test_strict_makes_any_difference_a_failure_even_with_no_base_change(self):
        # graph.yml opens the refresh PR on this exit code
        code, out = self.run_regenerate(dict(GRAPH, nodes=[]), [], strict=True)
        self.assertEqual(code, 1)
        self.assertIn("--strict", out)
        code, _ = self.run_regenerate(dict(GRAPH, built_at_commit="bbbb"), [], strict=True)
        self.assertEqual(code, 0)

    def test_without_graphify_it_says_how_to_get_it(self):
        out = io.StringIO()
        with mock.patch.object(check_graph, "graphify_bin", lambda: None), redirect_stdout(out):
            self.assertEqual(check_graph.regenerate(None), 1)
        self.assertIn("make graph-setup", out.getvalue())


if __name__ == "__main__":
    unittest.main()
