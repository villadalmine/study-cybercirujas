"""scripts/milestone_sync.py: which milestone a merged PR, a closed issue or a release lands on (offline)."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import milestone_sync as ms  # noqa: E402

MILESTONES = [
    {"number": 8, "title": "CKA & CKAD v1.37 upgrade", "state": "open", "due_on": None},
    {"number": 11, "title": "v0.5.0", "state": "open", "due_on": "2027-01-07T00:00:00Z"},
    {"number": 10, "title": "v0.4.0", "state": "open", "due_on": "2026-12-10T00:00:00Z"},
    {"number": 9, "title": "v0.3.0", "state": "closed", "due_on": "2026-11-12T00:00:00Z"},
    {"number": 12, "title": "v0.6.0", "state": "open", "due_on": None},
]


def pr(**kw):
    base = {"number": 5, "merged": True, "base": {"ref": "main"}, "head": {"ref": "fix/x"},
            "labels": [], "milestone": None, "body": "Closes #12"}
    base.update(kw)
    return base


class PlanTests(unittest.TestCase):
    def test_earliest_due_open_release_milestone_undated_last(self):
        self.assertEqual(ms.pick_milestone(MILESTONES)["title"], "v0.4.0")
        self.assertEqual([m["title"] for m in ms.release_milestones(MILESTONES)], ["v0.4.0", "v0.5.0", "v0.6.0"])
        self.assertEqual(ms.pick_milestone(MILESTONES, exclude="v0.4.0")["title"], "v0.5.0")
        self.assertIsNone(ms.pick_milestone([MILESTONES[0], MILESTONES[3]]))

    def test_sets_the_current_release_and_warns_only_without_an_issue_link(self):
        plan = ms.plan_pr_merged(pr(), MILESTONES)
        self.assertEqual((plan["milestone"], plan["warn"]), (10, None))
        plan = ms.plan_pr_merged(pr(body="Small fix. <!-- Closes #1 -->"), MILESTONES)
        self.assertEqual(plan["milestone"], 10)
        self.assertIn("links no issue", plan["warn"])

    def test_left_alone_existing_milestone_release_pr_unmerged_or_other_base(self):
        for p in (pr(milestone={"title": "CKA & CKAD v1.37 upgrade"}), pr(merged=False), pr(base={"ref": "dev"}),
                  pr(head={"ref": "release-please--branches--main--components--study-cybercirujas"}),
                  pr(labels=[{"name": "autorelease: pending"}])):
            self.assertIsNone(ms.plan_pr_merged(p, MILESTONES)["milestone"], p)

    def test_issue_link_forms(self):
        for body in ("Closes #3", "fixes #3", "Fixed: #3", "Part of #123", "Resolves owner/repo#7",
                     "Closes https://github.com/o/r/issues/9"):
            self.assertTrue(ms.links_an_issue(body), body)
        for body in ("", None, "see #3", "issue 3"):
            self.assertFalse(ms.links_an_issue(body), body)

    def test_only_completed_issues_without_milestone(self):
        self.assertEqual(ms.plan_issue_closed({"state_reason": "completed", "milestone": None}, MILESTONES)["milestone"], 10)
        self.assertIsNone(ms.plan_issue_closed({"state_reason": "not_planned", "milestone": None}, MILESTONES)["milestone"])
        self.assertIsNone(ms.plan_issue_closed({"state_reason": "completed", "milestone": {"title": "v0.5.0"}}, MILESTONES)["milestone"])

    def test_release_moves_open_items_to_the_next_and_closes(self):
        plan = ms.plan_release("v0.4.0", MILESTONES, [{"number": 1}, {"number": 2}])
        self.assertEqual((plan["released"], plan["next"]["title"], plan["move"], plan["close"]), (10, "v0.5.0", [1, 2], True))
        self.assertEqual(ms.plan_release("v0.4.0", MILESTONES, [])["close"], True)
        plan = ms.plan_release("v0.4.0", [MILESTONES[2]], [{"number": 1}])
        self.assertEqual((plan["move"], plan["close"]), ([], False))
        self.assertEqual(ms.plan_release("v0.4.1", MILESTONES, [])["released"], None)   # patch without its milestone


class MainTests(unittest.TestCase):
    def run_main(self, event, command, open_items=(), dry_run=False, live=None):
        calls = []

        def call(_self, method, path, body=None):
            if method == "GET":
                return {"milestone": live}
            calls.append((method, path, body))
            return None

        def paged(_self, path):
            return list(MILESTONES) if path.startswith("/milestones") else list(open_items)

        with tempfile.TemporaryDirectory() as tmp:
            ev = Path(tmp) / "event.json"
            ev.write_text(json.dumps(event))
            env = {"GITHUB_EVENT_PATH": str(ev), "GITHUB_REPOSITORY": "o/r", "GITHUB_TOKEN": "t",
                   "GITHUB_STEP_SUMMARY": str(Path(tmp) / "summary.md")}
            with mock.patch.dict(os.environ, env), mock.patch.object(ms.GitHub, "call", call), \
                 mock.patch.object(ms.GitHub, "paged", paged), mock.patch("builtins.print"):
                ms.main([command] + (["--dry-run"] if dry_run else []))
                summary = Path(env["GITHUB_STEP_SUMMARY"]).read_text()
        return calls, summary

    def test_pr_merged_patches_the_milestone_and_writes_the_warning(self):
        calls, summary = self.run_main({"pull_request": pr(body="no link")}, "pr-merged")
        self.assertEqual(calls, [("PATCH", "/issues/5", {"milestone": 10})])
        self.assertIn("links no issue", summary)

    def test_a_milestone_set_since_the_event_is_kept(self):
        for event, command in (({"pull_request": pr()}, "pr-merged"),
                               ({"issue": {"number": 3, "state_reason": "completed", "milestone": None}}, "issue-closed")):
            self.assertEqual(self.run_main(event, command, live={"title": "v0.5.0"})[0], [])

    def test_release_moves_comments_then_closes(self):
        calls, _ = self.run_main({"release": {"tag_name": "v0.4.0"}}, "release", open_items=[{"number": 7}])
        self.assertEqual([c[:2] for c in calls],
                         [("PATCH", "/issues/7"), ("POST", "/issues/7/comments"), ("PATCH", "/milestones/10")])
        self.assertEqual(calls[0][2], {"milestone": 11})
        self.assertEqual(calls[2][2], {"state": "closed"})


if __name__ == "__main__":
    unittest.main()
