"""run_batch skips topics already in an open PR or a local topic_pr worktree (#339)."""
from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import run_batch  # noqa: E402


def done(stdout: str = "", returncode: int = 0, stderr: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class InFlight(unittest.TestCase):
    def test_topics_in_an_open_pr_are_read_from_its_files(self):
        files = ["certs/nca-aiio/1.6/en/content.md", "certs/nca-aiio/1.6/en/meta.yaml",
                 "certs/nca-aiio/1.7/es/content.md", "certs/cks/1.6/en/content.md", "docs/STATUS.md"]
        self.assertEqual(run_batch.topics_in_files(files, "nca-aiio", "en"), {"1.6"})
        self.assertEqual(run_batch.topics_in_files(files, "nca-aiio", "es"), {"1.7"})

    def test_a_topic_pr_worktree_holds_its_topic_until_pushed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main, held, empty = root / "main", root / "wt-1.7", root / "wt-1.8"
            (held / "certs/nca-aiio/1.7/en").mkdir(parents=True)
            (held / "certs/nca-aiio/1.7/en/content.md").write_text("# x\n", encoding="utf-8")
            empty.mkdir()
            (root / "other/certs/nca-aiio/1.9/en").mkdir(parents=True)
            (root / "other/certs/nca-aiio/1.9/en/content.md").write_text("# x\n", encoding="utf-8")
            (main / "certs/nca-aiio/2.6/en").mkdir(parents=True)
            (main / "certs/nca-aiio/2.6/en/content.md").write_text("# x\n", encoding="utf-8")
            porcelain = "\n".join([
                f"worktree {main}", "HEAD a", "branch refs/heads/feat/284-nca-aiio-2.6", "",
                f"worktree {held}", "HEAD b", "branch refs/heads/feat/284-nca-aiio-1.7", "",
                f"worktree {empty}", "HEAD c", "branch refs/heads/feat/nca-aiio-1.8", "",
                f"worktree {root / 'other'}", "HEAD d", "branch refs/heads/feat/284-nca-aiio-extra-1.9", ""])
            # the checkout itself never counts; a worktree without the file holds nothing; another cert's prefix
            # (nca-aiio-extra) does not match nca-aiio
            self.assertEqual(run_batch.topics_in_worktrees(porcelain, "nca-aiio", "en", main), {"1.7"})
            self.assertEqual(run_batch.topics_in_worktrees(porcelain, "nca-aiio", "es", main), set())
            # pushed: its PR counts from now on, and a worktree left behind after the PR closed holds nothing
            self.assertEqual(run_batch.topics_in_worktrees(porcelain, "nca-aiio", "en", main,
                                                           frozenset({"refs/heads/feat/284-nca-aiio-1.7"})), set())

    def test_in_flight_joins_both_and_survives_gh_failing(self):
        prs = json.dumps([{"files": [{"path": "certs/nca-aiio/1.6/en/content.md"}]}, {"files": []}])

        def fake(cmd, **kw):
            return done(prs) if cmd[0] == "gh" else done("")
        with mock.patch.object(run_batch.subprocess, "run", side_effect=fake):
            self.assertEqual(run_batch.in_flight("nca-aiio", "en"), {"1.6"})

    def test_in_flight_reads_upstreams_so_a_pushed_worktree_does_not_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            wt = Path(tmp) / "wt"
            (wt / "certs/nca-aiio/1.7/en").mkdir(parents=True)
            (wt / "certs/nca-aiio/1.7/en/content.md").write_text("# x\n", encoding="utf-8")
            porcelain = f"worktree {wt}\nHEAD b\nbranch refs/heads/feat/284-nca-aiio-1.7\n"
            for upstream, want in (("", {"1.7"}), ("refs/remotes/origin/feat/284-nca-aiio-1.7", set())):
                def fake(cmd, **kw):
                    if cmd[0] == "gh":
                        return done("[]")
                    if cmd[1] == "worktree":
                        return done(porcelain)
                    return done(f"refs/heads/feat/284-nca-aiio-1.7 {upstream}".rstrip() + "\n")
                with self.subTest(upstream=upstream or "none"), \
                        mock.patch.object(run_batch.subprocess, "run", side_effect=fake):
                    self.assertEqual(run_batch.in_flight("nca-aiio", "en"), want)

        def offline(cmd, **kw):
            return done(returncode=1, stderr="gh: not logged in") if cmd[0] == "gh" else done("")
        err = io.StringIO()
        with mock.patch.object(run_batch.subprocess, "run", side_effect=offline), redirect_stderr(err):
            self.assertEqual(run_batch.in_flight("nca-aiio", "en"), set())
        self.assertIn("may be authored again", err.getvalue())

    def test_a_pr_with_more_files_than_the_list_returns_is_read_in_full(self):
        listed = [{"path": f"certs/nca-aiio/1.{i}/en/meta.yaml"} for i in range(100)]
        prs = json.dumps([{"number": 357, "changedFiles": 305, "files": listed},
                          {"number": 9, "changedFiles": 1, "files": [{"path": "certs/nca-aiio/2.1/en/content.md"}]}])
        calls = []

        def fake(cmd, **kw):
            calls.append(cmd)
            if cmd[:3] == ["gh", "pr", "list"]:
                return done(prs)
            if cmd[:2] == ["gh", "api"]:
                return done("certs/nca-aiio/3.4/en/content.md\ncerts/nca-aiio/3.4/en/meta.yaml\n")
            return done("")
        with mock.patch.object(run_batch.subprocess, "run", side_effect=fake):
            self.assertEqual(run_batch.in_flight("nca-aiio", "en"), {"2.1", "3.4"})
        self.assertEqual([c for c in calls if c[:2] == ["gh", "api"]],
                         [["gh", "api", "--paginate", "repos/{owner}/{repo}/pulls/357/files", "--jq", ".[].filename"]])

        def no_api(cmd, **kw):
            return done(prs) if cmd[:3] == ["gh", "pr", "list"] else done(returncode=1) if cmd[0] == "gh" else done("")
        err = io.StringIO()
        with mock.patch.object(run_batch.subprocess, "run", side_effect=no_api), redirect_stderr(err):
            self.assertEqual(run_batch.in_flight("nca-aiio", "en"), {"2.1"})   # the other PRs still count
        self.assertIn("PR #357 lists 100 of its 305 files", err.getvalue())

    def test_no_gh_a_hung_gh_or_bad_json_warn_instead_of_crashing_the_batch(self):
        for broken in (FileNotFoundError("gh"), subprocess.TimeoutExpired("gh", 60), done("not json")):
            def fake(cmd, **kw):
                if cmd[0] != "gh":
                    return done("")
                if isinstance(broken, BaseException):
                    raise broken
                return broken
            err = io.StringIO()
            with self.subTest(broken=type(broken).__name__), \
                    mock.patch.object(run_batch.subprocess, "run", side_effect=fake), redirect_stderr(err):
                self.assertEqual(run_batch.in_flight("nca-aiio", "en"), set())
            self.assertIn("may be authored again", err.getvalue())

    def test_the_batch_authors_the_next_topic_not_the_ones_in_flight(self):
        authored = []
        argv = ["run_batch.py", "nca-aiio", "--lang", "en", "--topics", "1"]
        with mock.patch.object(sys, "argv", argv), \
                mock.patch.object(run_batch, "pending", return_value=["1.6", "1.7", "2.6"]), \
                mock.patch.object(run_batch, "in_flight", return_value={"1.6", "1.7"}), \
                mock.patch.object(run_batch.pipeline, "mine", return_value=True), \
                mock.patch.object(run_batch.claims, "is_claimed", return_value=False), \
                mock.patch.object(run_batch.subprocess, "run", return_value=done()), \
                mock.patch.object(run_batch, "generate_with_retries",
                                  side_effect=lambda topic, *a: authored.append(topic) or "done"), \
                redirect_stdout(io.StringIO()) as out:
            self.assertEqual(run_batch.main(), 0)
        self.assertEqual(authored, ["2.6"])
        self.assertIn("2 topics already in an open PR or a topic_pr worktree (1.6, 1.7)", out.getvalue())


if __name__ == "__main__":
    unittest.main()
