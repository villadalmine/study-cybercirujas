"""scripts/release_notes.py: the release-notes block, the Thanks and the NEXT.md reset (offline)."""
import base64
import sys
import unittest
import urllib.error
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import release_notes as rn  # noqa: E402

NEXT = "<!-- hint -->\n## Highlights\n\n- **Labs:** nine labs now fail.\n\n## Upgrade notes\n\n<!-- h -->\n\n## Thanks\n\n- @reviewer for the report (#9)\n"
EMPTY = "<!-- hint\n## Highlights\n- not a line\n-->\n## Highlights\n\n<!-- h -->\n\n## Upgrade notes\n\n## Thanks\n"


def pr(n, login, merged=True, kind="User"):
    return {"number": n, "user": {"login": login, "type": kind}, "merged_at": "2026-10-20T00:00:00Z" if merged else None}


class PureTests(unittest.TestCase):
    def test_only_lines_outside_comments_count_and_the_shipped_template_is_empty(self):
        self.assertEqual(rn.parse_sections(EMPTY), {})
        self.assertEqual(list(rn.parse_sections(NEXT)), ["Highlights", "Thanks"])
        self.assertEqual(rn.parse_sections((REPO / rn.NEXT_PATH).read_text(encoding="utf-8")), {})

    def test_thanks_leave_out_maintainers_bots_unmerged_and_hand_thanked(self):
        prs = [pr(1, "villadalmine"), pr(2, "dependabot[bot]", kind="Bot"), pr(3, "Alice"), pr(4, "bob", merged=False),
               pr(5, "alice"), pr(6, "carol"), pr(8, "reviewer")]
        self.assertEqual(rn.thanks_lines(prs, {"villadalmine"}, {"reviewer"}), ["- @Alice (#3, #5)", "- @carol (#6)"])

    def test_codeowners_logins_not_teams_or_comments(self):
        text = "# @commented\n*  @Villadalmine\n/a/ @org/team @second-owner  # @trailing\n"
        self.assertEqual(rn.maintainers(text), {"villadalmine", "second-owner"})

    def test_pr_numbers_and_previous_tag(self):
        self.assertEqual(rn.pr_numbers(["feat(x): a (#12)\n\nbody (#99)", "fix: b (#7)", "chore: none", "feat: c (#12)"]), [12, 7])
        tags = ["v0.3.0", "v0.4.0", "v0.10.0", "v0.9.1", "site-2026-10-01", "v0.4.0-rc1"]
        self.assertEqual(rn.previous_tag(tags, "v0.10.0"), "v0.9.1")
        self.assertIsNone(rn.previous_tag(tags, "v0.3.0"))
        self.assertIsNone(rn.previous_tag(tags, "site-2026-10-01"))
        self.assertEqual(rn.MENTION.findall("a@b.com @x-y, (@z)"), ["x-y", "z"])

    def test_compose_puts_generated_thanks_after_hand_written_ones_and_drops_empty_sections(self):
        block = rn.compose(NEXT, ["- @alice (#3)"])
        self.assertTrue(block.startswith(rn.MARKER) and "Upgrade notes" not in block)
        self.assertTrue(block.rstrip().endswith("- @reviewer for the report (#9)\n- @alice (#3)"))
        self.assertEqual(rn.compose(EMPTY, []), "")

    def test_the_changelog_stays_below_a_rule_and_a_second_run_changes_nothing(self):
        changelog = "## [0.5.0](https://x) (2026-11-01)\n"
        block = rn.compose(NEXT, [])
        once = rn.merge_body(block, changelog)
        self.assertEqual(once, f"{block}\n---\n\n{changelog}")
        self.assertEqual(rn.merge_body(block, once), once)
        self.assertEqual(rn.merge_body("", changelog), changelog)

    def test_reset_removes_published_lines_keeps_new_ones_and_comments(self):
        current = NEXT.replace("## Upgrade notes", "- **New:** added after the tag.\n\n## Upgrade notes")
        got = rn.remove_published(current, NEXT)
        self.assertTrue("nine labs" not in got and "@reviewer" not in got)
        self.assertIn("- **New:** added after the tag.", got)
        self.assertIn("<!-- hint -->", got)
        self.assertEqual(rn.remove_published(got, NEXT), got)


class FakeGitHub:
    def __init__(self, body="## [0.5.0]\n", branch_exists=False, main_next=NEXT):
        self.writes, self.body, self.branch_exists = [], body, branch_exists
        self.files = {("v0.5.0", rn.NEXT_PATH): NEXT, ("v0.5.0", rn.CODEOWNERS_PATH): "* @villadalmine\n",
                      ("main", rn.NEXT_PATH): main_next}

    def paged(self, path):
        return [{"tag_name": t} for t in ("v0.5.0", "v0.4.0", "v0.3.0")]

    def call(self, method, path, body=None):
        if method != "GET":
            self.writes.append((method, path, body))
        not_found = urllib.error.HTTPError(path, 404, "nf", {}, None)
        if path == "/releases/tags/v0.5.0":
            return {"id": 77, "body": self.body}
        if path.startswith("/compare/v0.4.0...v0.5.0"):
            return {"commits": [{"commit": {"message": f"x (#{n})"}} for n in (10, 11, 12, 13)]}
        if path.startswith("/pulls/") and method == "GET":
            return {10: pr(10, "villadalmine"), 11: pr(11, "dana"), 12: pr(12, "app[bot]", kind="Bot"),
                    13: pr(13, "releases[bot]", kind="Bot")}[int(path.rsplit("/", 1)[1])]
        if path.startswith("/contents/") and method == "GET":
            file, ref = path[len("/contents/"):].split("?ref=")
            if (ref, file) not in self.files:
                raise not_found
            return {"content": base64.b64encode(self.files[(ref, file)].encode()).decode(), "sha": "blob1"}
        if path.startswith("/git/ref/heads/release-notes-reset"):
            if not self.branch_exists:
                raise not_found
        if path == "/git/ref/heads/main":
            return {"object": {"sha": "abc"}}
        return {"number": 200} if (method, path) == ("POST", "/pulls") else {}


class PublishTests(unittest.TestCase):
    def test_publish_edits_the_release_and_opens_one_reset_pr(self):
        gh = FakeGitHub()
        rn.publish(gh, "v0.5.0")
        patch = [w for w in gh.writes if w[0] == "PATCH"]
        self.assertEqual([w[1] for w in patch], ["/releases/77"])
        text = patch[0][2]["body"]
        self.assertIn("- @dana (#11)", text)
        self.assertNotIn("villadalmine (#", text + "app[bot]")
        self.assertTrue(text.endswith("\n---\n\n## [0.5.0]\n"))
        self.assertEqual([w[0] for w in gh.writes if w[0] != "PATCH"], ["POST", "PUT", "POST"])
        put = next(w for w in gh.writes if w[0] == "PUT")[2]
        self.assertEqual(put["branch"], "release-notes-reset--v0.5.0")
        self.assertEqual(rn.parse_sections(base64.b64decode(put["content"]).decode()), {})

    def test_a_rerun_after_the_reset_merged_writes_nothing(self):
        first = FakeGitHub()
        rn.publish(first, "v0.5.0")
        body = next(w for w in first.writes if w[0] == "PATCH")[2]["body"]
        for branch_exists, main_next in ((True, NEXT), (False, EMPTY)):   # reset PR open; reset merged
            done = FakeGitHub(body=body, branch_exists=branch_exists, main_next=main_next)
            rn.publish(done, "v0.5.0")
            self.assertEqual(done.writes, [])


if __name__ == "__main__":
    unittest.main()
