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

    def test_missing_milestone_is_created_and_shipped_work_moves_into_it(self):
        shipped = [{"number": 221, "milestone": {"title": "v0.6.0"}}, {"number": 230, "milestone": None},
                   {"number": 231, "milestone": {"title": "CKA & CKAD v1.37 upgrade"}},
                   {"number": 232, "milestone": {"title": "v0.5.1"}}]
        plan = ms.plan_release("v0.5.1", MILESTONES, [], shipped, "2026-10-20T10:00:00Z")
        self.assertEqual((plan["create"], plan["released"], plan["due_on"]), (True, None, "2026-10-20T10:00:00Z"))
        self.assertEqual(plan["retag"], [221, 230])          # exam milestone and already-there items untouched
        self.assertEqual((plan["move"], plan["close"]), ([], True))

    def test_minor_release_with_its_planned_milestone(self):
        shipped = [{"number": 1, "milestone": {"title": "v0.4.0"}}, {"number": 2, "milestone": {"title": "v0.5.0"}}]
        plan = ms.plan_release("v0.4.0", MILESTONES, [{"number": 9}], shipped)
        self.assertEqual((plan["create"], plan["released"], plan["retag"], plan["move"], plan["close"]),
                         (False, 10, [2], [9], True))
        self.assertEqual(plan["next"]["title"], "v0.5.0")

    def test_new_milestone_never_moves_open_items_even_if_passed(self):
        plan = ms.plan_release("v0.5.1", MILESTONES, [{"number": 4}], [], "x")
        self.assertEqual(plan["move"], [])

    def test_rerun_on_a_closed_milestone_changes_nothing(self):
        closed = MILESTONES + [{"number": 13, "title": "v0.5.1", "state": "closed", "due_on": "2026-10-20T00:00:00Z"}]
        plan = ms.plan_release("v0.5.1", closed, [], [{"number": 221, "milestone": {"title": "v0.5.1"}}])
        self.assertEqual((plan["create"], plan["retag"], plan["move"], plan["close"]), (False, [], [], False))

    def test_git_and_description_parsing(self):
        tags = ["v0.5.1", "v0.5.0", "v0.4.0", "v0.10.0", "latest", "v0.9.0-rc1"]
        self.assertEqual(ms.previous_tag("v0.5.1", tags), "v0.5.0")
        self.assertEqual(ms.previous_tag("v0.10.0", tags), "v0.5.1")
        self.assertIsNone(ms.previous_tag("v0.4.0", ["v0.4.0"]))
        self.assertEqual(ms.pr_numbers(["fix(x): y (#221)", "Merge pull request #230 from a/b", "chore: no pr",
                                        "feat: z (#221)", "fix: mentions (#5) midline"]), [221, 230])
        body = "Fixes #12\nCloses https://github.com/o/r/issues/13 and part of #14 <!-- Closes #15 -->"
        self.assertEqual(ms.closing_issue_numbers(body, "o/r"), [12, 13])


SHIPPED_PRS = {
    221: {"number": 221, "merged_at": "t", "head": {"ref": "fix/a"}, "labels": [], "body": "Fixes #300"},
    230: {"number": 230, "merged_at": "t", "head": {"ref": "fix/b"}, "labels": [], "body": "Part of #301"},
    231: {"number": 231, "merged_at": "t", "head": {"ref": "fix/c"}, "labels": [], "body": ""},
    240: {"number": 240, "merged_at": "t", "head": {"ref": "release-please--branches--main"}, "labels": [], "body": ""},
}
ISSUES = {
    221: {"number": 221, "milestone": {"title": "v0.6.0"}},
    230: {"number": 230, "milestone": None},
    231: {"number": 231, "milestone": {"title": "CKA & CKAD v1.37 upgrade"}},
    300: {"number": 300, "state": "closed", "state_reason": "completed", "milestone": {"title": "v0.6.0"}},
}


class MainTests(unittest.TestCase):
    def run_main(self, event, command, open_items=(), dry_run=False, live=None, milestones=None,
                 subjects=(), tags=()):
        calls = []
        milestones = MILESTONES if milestones is None else milestones

        def call(_self, method, path, body=None):
            if method == "GET":
                if path.startswith("/pulls/"):
                    return SHIPPED_PRS.get(int(path.rsplit("/", 1)[1]))
                if path.startswith("/releases/tags/"):
                    return {"published_at": "2026-10-20T10:00:00Z"}
                return {"milestone": live}
            calls.append((method, path, body))
            return {"number": 99} if (method, path) == ("POST", "/milestones") else None

        def paged(_self, path):
            return list(milestones) if path.startswith("/milestones") else list(open_items)

        def issue(_self, number):
            return ISSUES.get(number, {"number": number, "milestone": live})

        def git(*args):
            return list(subjects) if args[0] == "log" else (list(tags) if args[0] == "tag" else [])

        with tempfile.TemporaryDirectory() as tmp:
            ev = Path(tmp) / "event.json"
            ev.write_text(json.dumps(event))
            env = {"GITHUB_EVENT_PATH": str(ev), "GITHUB_REPOSITORY": "o/r", "GITHUB_TOKEN": "t",
                   "GITHUB_STEP_SUMMARY": str(Path(tmp) / "summary.md")}
            with mock.patch.dict(os.environ, env), mock.patch.object(ms.GitHub, "call", call), \
                 mock.patch.object(ms.GitHub, "paged", paged), mock.patch.object(ms.GitHub, "issue", issue), \
                 mock.patch.object(ms, "git_lines", git), mock.patch("builtins.print"):
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
        calls, _ = self.run_main({"release": {"tag_name": "v0.4.0"}}, "release", open_items=[{"number": 7}],
                                 tags=["v0.4.0"])
        self.assertEqual([c[:2] for c in calls],
                         [("PATCH", "/issues/7"), ("POST", "/issues/7/comments"), ("PATCH", "/milestones/10")])
        self.assertEqual(calls[0][2], {"milestone": 11})
        self.assertEqual(calls[2][2], {"state": "closed"})

    def test_patch_release_creates_the_milestone_and_collects_what_shipped(self):
        subjects = ["fix: a (#221)", "fix: b (#230)", "fix: c (#231)", "chore(main): release 0.5.1 (#240)", "docs: no pr"]
        calls, summary = self.run_main({"release": {"tag_name": "v0.5.1"}}, "release", subjects=subjects,
                                       tags=["v0.5.1", "v0.5.0", "v0.4.0"])
        self.assertEqual(calls, [
            ("POST", "/milestones", {"title": "v0.5.1", "due_on": "2026-10-20T10:00:00Z"}),
            ("PATCH", "/issues/221", {"milestone": 99}),     # PR from v0.6.0
            ("PATCH", "/issues/300", {"milestone": 99}),     # the issue it fixes, closed as completed
            ("PATCH", "/issues/230", {"milestone": 99}),     # no milestone
            ("PATCH", "/milestones/99", {"state": "closed"}),  # #231 (exam milestone), #240 (release PR) untouched
        ])
        self.assertIn("create v0.5.1", summary)

    def test_workflow_dispatch_input_and_rerun_is_a_noop(self):
        done = MILESTONES + [{"number": 13, "title": "v0.5.1", "state": "closed", "due_on": "2026-10-20T00:00:00Z"}]
        shipped_in = {221: {"number": 221, "milestone": {"title": "v0.5.1"}}, 230: {"number": 230, "milestone": {"title": "v0.5.1"}},
                      300: {"number": 300, "state": "closed", "state_reason": "completed", "milestone": {"title": "v0.5.1"}}}
        with mock.patch.dict(ISSUES, shipped_in):
            calls, _ = self.run_main({"inputs": {"tag": "v0.5.1"}}, "release", milestones=done,
                                     subjects=["fix: a (#221)", "fix: b (#230)"], tags=["v0.5.1", "v0.5.0"])
        self.assertEqual(calls, [])

    def test_a_bad_tag_input_is_refused(self):
        with mock.patch("sys.stderr"):
            for tag in ("main", "v1; rm -rf /", "", "v0.5"):
                self.assertEqual(self.run_main_status({"inputs": {"tag": tag}}), 1, tag)

    def run_main_status(self, event):
        with tempfile.TemporaryDirectory() as tmp:
            ev = Path(tmp) / "event.json"
            ev.write_text(json.dumps(event))
            env = {"GITHUB_EVENT_PATH": str(ev), "GITHUB_REPOSITORY": "o/r", "GITHUB_TOKEN": "t"}
            with mock.patch.dict(os.environ, env), mock.patch.object(ms.GitHub, "call", return_value=None):
                return ms.main(["release"])


if __name__ == "__main__":
    unittest.main()
