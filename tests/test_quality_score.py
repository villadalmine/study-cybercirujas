"""The quality score: the formula, the levels, determinism, and that blocks are never hand-kept."""
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "scripts"))
import quality_score  # noqa: E402
from teach.core import certs, scoring  # noqa: E402

W = scoring.load_weights()


def check(name, result):
    return {"name": name, "version": "1", "result": result, "weight": W["checks"][name]["weight"],
            "ran_at": None, "evidence": "x"}


ALL = list(W["checks"])


class FormulaTests(unittest.TestCase):
    """Table tests: (results) -> (score, level)."""

    CASES = [
        # everything passes -> 100, but Verified needs lab + independent review, which pass here
        ({n: "pass" for n in ALL}, 100.0, "verified"),
        # nothing ran -> half of every weight (not_run_penalty 0.5) -> 50, Draft
        ({n: "not_run" for n in ALL}, 50.0, "draft"),
        # everything failed -> 0, Draft
        ({n: "fail" for n in ALL}, 0.0, "draft"),
        # all automatic checks pass, no lab and no review -> high, but not Verified
        ({**{n: "pass" for n in ALL}, "lab": "not_run", "independent_review": "not_run"}, 90.0, "ai-beta"),
        # floor fails -> cannot be AI beta whatever the score
        ({**{n: "pass" for n in ALL}, "quality_floor": "fail", "independent_review": "not_run"}, 80.0, "draft"),
    ]

    def test_table(self):
        for results, want_score, want_level in self.CASES:
            checks = [check(n, r) for n, r in results.items()]
            with self.subTest(results=results):
                value = scoring.score(checks, W)
                self.assertEqual(value, want_score)
                self.assertEqual(scoring.level_for(value, checks, W)["id"], want_level)

    def test_fail_costs_more_than_not_run(self):
        base = [check(n, "pass") for n in ALL]
        not_run = [dict(c, result="not_run") if c["name"] == "lab" else c for c in base]
        failed = [dict(c, result="fail") if c["name"] == "lab" else c for c in base]
        self.assertGreater(scoring.score(base, W), scoring.score(not_run, W))
        self.assertGreater(scoring.score(not_run, W), scoring.score(failed, W))

    def test_checks_that_do_not_apply_are_left_out_of_both_sides(self):
        some = [check(n, "pass") for n in ("quality_floor", "provenance")]
        self.assertEqual(scoring.score(some, W), 100.0)

    def test_weights_file_is_complete(self):
        self.assertEqual(sum(c["weight"] for c in W["checks"].values()), 100)
        self.assertIn("groundedness", W["checks"])
        self.assertEqual([lv["id"] for lv in W["levels"]], ["verified", "ai-beta", "draft"])


class BlockTests(unittest.TestCase):
    def test_a_real_topic_block_is_deterministic(self):
        ctx = quality_score.Context()
        topic = REPO / "certs" / "cka" / "3.3" / "en"
        a, b = quality_score.block_for(topic, ctx), quality_score.block_for(topic, ctx)
        self.assertEqual(a, b)
        text = (topic / "meta.yaml").read_text(encoding="utf-8")
        self.assertEqual(quality_score.render(text, a), quality_score.render(quality_score.render(text, a), a))
        names = [c["name"] for c in a["checks"]]
        self.assertIn("groundedness", names)
        self.assertEqual(next(c for c in a["checks"] if c["name"] == "groundedness")["result"], "not_run")
        self.assertEqual(next(c for c in a["checks"] if c["name"] == "lab")["result"], "pass")   # runner-verified

    def test_render_keeps_the_rest_of_meta_yaml_byte_for_byte(self):
        text = "generated_at: '2026-07-16'\nlang: en\nsources:\n- https://x\nquality:\n  score: 1\n  checks: []\n"
        out = quality_score.render(text, {"score": 2})
        self.assertTrue(out.startswith("generated_at: '2026-07-16'\nlang: en\nsources:\n- https://x\n"))
        self.assertEqual(yaml.safe_load(out)["quality"], {"score": 2})

    def test_check_mode_catches_a_hand_edited_block(self):
        # A committed block that differs from what the files give (a hand edit
        # promoting a topic to verified, say) must fail --check, and --check
        # must not write anything.
        topic = REPO / "certs" / "cka" / "3.3" / "en"
        before = (topic / "meta.yaml").read_bytes()
        real = quality_score.block_for
        with mock.patch.object(quality_score, "topic_dirs", lambda paths: [topic]), \
             mock.patch.object(quality_score, "block_for",
                               lambda d, ctx: dict(real(d, ctx), level="verified", score=99.0)):
            self.assertEqual(quality_score.main(["--check"]), 1)
        self.assertEqual((topic / "meta.yaml").read_bytes(), before)
        with mock.patch.object(quality_score, "topic_dirs", lambda paths: [topic]):
            self.assertEqual(quality_score.main(["--check"]), 0)

    def test_every_committed_block_is_what_the_tree_gives(self):
        self.assertEqual(quality_score.main(["--check"]), 0)


class ReviewTests(unittest.TestCase):
    """The latest review decides (docs/REVIEWS.md; review of the quality-score PR)."""

    CASES = [
        ([], "not_run"),
        ([{"date": "2026-10-01", "result": "pass"}], "pass"),
        ([{"date": "2026-10-01", "result": "pass"}, {"date": "2026-10-15", "result": "fail"}], "fail"),
        ([{"date": "2026-10-15", "result": "fail"}, {"date": "2026-10-01", "result": "pass"}], "fail"),
        ([{"date": "2026-10-01", "result": "fail"}, {"date": "2026-10-15", "result": "pass"}], "pass"),
        ([{"date": "2026-10-15", "result": "pass"}, {"date": "2026-10-15", "result": "fail"}], "fail"),
        # an undated review is the oldest, not the latest (None used to sort after any ISO date)
        ([{"result": "fail"}, {"date": "2026-10-01", "result": "pass"}], "pass"),
        ([{"date": "2026-10-01", "result": "pass"}, {"result": "fail"}], "pass"),
        ([{"date": None, "result": "fail"}, {"date": "2026-10-01", "result": "pass"}], "pass"),
    ]

    def test_table(self):
        for reviews, want in self.CASES:
            with self.subTest(reviews=reviews):
                got = quality_score.review_check({"reviews": [dict(r, by="fable", link="x") for r in reviews]}, W)
                self.assertEqual(got["result"], want)


class GroundednessTests(unittest.TestCase):
    """A groundedness entry recorded by the classifier lab survives a rescore (PR #13)."""

    def test_no_entry_defaults_to_not_run(self):
        self.assertEqual(quality_score.groundedness_check({}, W)["result"], "not_run")

    def test_a_recorded_entry_is_kept_not_overwritten(self):
        recorded = {"name": "groundedness", "version": "1", "result": "pass", "weight": W["checks"]["groundedness"]["weight"],
                    "ran_at": "2026-10-16", "evidence": "classifier: 0.97 of claims supported"}
        meta = {"quality": {"checks": [check("lab", "pass"), recorded]}}
        self.assertEqual(quality_score.groundedness_check(meta, W), recorded)

    def test_rescoring_a_topic_with_a_recorded_entry_keeps_it_and_is_stable(self):
        lang_dir = REPO / "certs" / "cka" / "3.3" / "en"
        text = (lang_dir / "meta.yaml").read_text(encoding="utf-8")
        recorded = {"name": "groundedness", "version": "1", "result": "pass", "weight": W["checks"]["groundedness"]["weight"],
                    "ran_at": "2026-10-16", "evidence": "recorded"}
        meta = yaml.safe_load(text)
        meta["quality"]["checks"] = [c for c in meta["quality"]["checks"] if c["name"] != "groundedness"] + [recorded]
        with tempfile.TemporaryDirectory() as tmp:
            topic = Path(tmp) / "certs" / "cka" / "3.3"
            shutil.copytree(lang_dir.parent, topic)
            target = topic / "en"
            (target / "meta.yaml").write_text(yaml.safe_dump(meta, sort_keys=False, allow_unicode=True), encoding="utf-8")
            ctx = quality_score.Context()
            with mock.patch.object(quality_score, "rel", side_effect=lambda p: str(p)):
                block = quality_score.block_for(target, ctx)
        kept = [c for c in block["checks"] if c["name"] == "groundedness"]
        self.assertEqual(kept, [recorded])
        self.assertEqual(block["checks"][-1], recorded)


class RecordedGroundednessIsNotTrustedVerbatim(unittest.TestCase):
    """A recorded entry keeps its result, evidence and date; the weight and version are the project's (#120)."""

    def recorded(self, **over):
        return {"name": "groundedness", "version": "1", "result": "pass", "weight": 5, "ran_at": "2026-10-16",
                "evidence": "0 of 3 claims unsupported", **over}

    def test_its_own_weight_and_version_are_replaced(self):
        got = quality_score.groundedness_check({"quality": {"checks": [self.recorded(weight=500, version="9")]}}, W)
        self.assertEqual((got["weight"], got["version"]), (W["checks"]["groundedness"]["weight"], quality_score.CHECK_VERSION))
        self.assertEqual((got["result"], got["ran_at"], got["evidence"]), ("pass", "2026-10-16", "0 of 3 claims unsupported"))

    def test_a_result_other_than_pass_or_fail_is_not_run(self):
        for bad in ("PASS", "ok", None, True):
            with self.subTest(result=bad):
                got = quality_score.groundedness_check({"quality": {"checks": [self.recorded(result=bad)]}}, W)
                self.assertEqual(got["result"], "not_run")

    def test_the_entry_keeps_the_keys_and_order_of_every_other_check(self):
        got = quality_score.groundedness_check({"quality": {"checks": [self.recorded(extra="x")]}}, W)
        self.assertEqual(list(got), ["name", "version", "result", "weight", "ran_at", "evidence"])


class VisibleTests(unittest.TestCase):
    def test_the_api_serves_the_summary(self):
        topic = certs.topic_content("cka", "3.3", lang="en")
        self.assertEqual(topic["quality"]["level"], "ai-beta")
        self.assertEqual(topic["quality"]["level_label"], "AI beta")
        self.assertTrue(any(c["name"] == "lab" for c in topic["quality"]["checks"]))

    def test_status_md_has_the_quality_table(self):
        self.assertIn("\n## Quality\n", (REPO / "docs/STATUS.md").read_text(encoding="utf-8"))

    def test_the_site_shows_a_badge_in_every_language(self):
        html = (REPO / "teach" / "web" / "index.html").read_text(encoding="utf-8")
        self.assertIn("data.quality.level", html)
        self.assertEqual(html.count("qLabel:"), html.count("    aiGen: '"))


if __name__ == "__main__":
    unittest.main()
