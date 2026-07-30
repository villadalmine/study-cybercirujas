"""Quality floor: the same standard for every backend.

Tested because a floor is only useful if it is stable. If the thresholds drift
by accident, material that passes today stops passing (or the reverse), and the
STATUS matrix starts lying in the opposite direction.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import unittest

from teach.core import pipeline, quality

CONTENT_OK = "# 1.1 Topic\n\n" + ("Explanation with concrete examples. " * 200) + (
    "\n\n## Referencias\n\n- Kubernetes — https://kubernetes.io/docs/\n"
)
EXERCISES_OK = "# 1.1 Exercises\n\n" + ("Numbered step with its verification. " * 80) + (
    "\n\n<details><summary>Answers</summary>\n\nA1.\n\n</details>\n"
)


class QualityFloorTest(unittest.TestCase):
    def test_complete_material_passes(self) -> None:
        self.assertEqual(quality.check("content", CONTENT_OK), [])
        self.assertEqual(quality.check("exercises", EXERCISES_OK), [])

    def test_short_material_is_rejected(self) -> None:
        problems = quality.check("content", "# Topic\n\nTwo sentences, nothing else.\n")
        self.assertTrue(any("below the" in p for p in problems))

    def test_content_without_references_is_rejected(self) -> None:
        """The references section is explicitly requested by the prompt, and it
        is what backs the original-content-with-attribution policy."""
        without = CONTENT_OK.replace("## Referencias", "## Something else")
        problems = quality.check("content", without)
        self.assertTrue(any("references" in p.lower() for p in problems))

    def test_exercises_without_details_are_rejected(self) -> None:
        """The real case: CNPE produced 18 of 18 exercises with no collapsible
        answers section, in files that could have passed on size alone."""
        without = EXERCISES_OK.replace("<details>", "<div>").replace("</details>", "</div>")
        problems = quality.check("exercises", without)
        self.assertTrue(any("details" in p for p in problems))

    def test_references_heading_in_other_languages(self) -> None:
        """Material is generated in seven languages; the heading changes and the
        floor cannot depend on Spanish."""
        for heading in ("References", "Références", "Referenzen", "Referências", "参考文献"):
            with self.subTest(heading=heading):
                text = CONTENT_OK.replace("## Referencias", f"## {heading}")
                self.assertEqual(quality.check("content", text), [])

    def test_missing_leading_heading(self) -> None:
        problems = quality.check("content", CONTENT_OK.replace("# 1.1 Topic", "1.1 Topic"))
        self.assertTrue(any("does not start with" in p for p in problems))

    def test_unknown_kind_invents_no_rules(self) -> None:
        self.assertEqual(quality.check("does-not-exist", "x"), [])


class QualityThresholdsTest(unittest.TestCase):
    """The thresholds live in pipeline.yaml and are calibrated against material
    already verified as good; keeping them below the observed minimum is what
    stops the floor from rejecting known-good content."""

    def test_thresholds_are_declared(self) -> None:
        self.assertEqual(quality.rules("content").get("min_bytes"), 4000)
        self.assertEqual(quality.rules("exercises").get("min_bytes"), 1700)

    def test_floor_sits_below_the_observed_minimum(self) -> None:
        # Across cks/cka/ckad/lpi: content.md observed minimum 4577, exercises 1778.
        self.assertLess(quality.rules("content")["min_bytes"], 4577)
        self.assertLess(quality.rules("exercises")["min_bytes"], 1778)

    def test_without_a_quality_block_everything_passes(self) -> None:
        """The floor is optional: a repo with no `quality` in the YAML must not
        break. `pipeline.load` is cached, so the returned dict is mutated and
        restored on the way out."""
        config = pipeline.load()
        original = config.pop("quality", None)
        try:
            self.assertEqual(quality.check("content", "short"), [])
        finally:
            if original is not None:
                config["quality"] = original
        self.assertNotEqual(quality.check("content", "short"), [])


if __name__ == "__main__":
    unittest.main()
