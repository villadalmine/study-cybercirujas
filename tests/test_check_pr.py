"""scripts/check_pr.py: the PR format as a check, offline (fixtures in tests/fixtures/pr/)."""
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import check_pr  # noqa: E402

FIXTURES = REPO / "tests" / "fixtures" / "pr"
TOUCHED = ["certs/cka/1.1/en/content.md", "README.md"]


class CheckPrTests(unittest.TestCase):
    def body(self, name):
        return (FIXTURES / name).read_text(encoding="utf-8")

    def test_a_complete_pr_passes(self):
        self.assertEqual(check_pr.check("fix(cka): reclaim policy", self.body("good.md"), TOUCHED), [])

    def test_the_bad_fixture_fails_on_both_counts(self):
        problems = "\n".join(check_pr.check("fix(cka): reclaim policy", self.body("bad.md"), TOUCHED))
        self.assertIn("empty section: ## Risk and rollback", problems)
        self.assertIn("meta.yaml says 'claude'", problems)

    def test_deleted_material_is_not_missing_provenance(self):
        gone = ["certs/cka/9.9/xx/content.md", "certs/cka/9.9/xx/meta.yaml"]
        self.assertEqual(check_pr.check("fix(cka): x", self.body("good.md"), TOUCHED + gone), [])

    def test_existing_material_without_meta_still_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            topic = Path(tmp) / "certs" / "cka" / "1.1" / "en"
            topic.mkdir(parents=True)
            (topic / "content.md").write_text("x")
            problems = check_pr.check("fix(cka): x", self.body("good.md"),
                                      ["certs/cka/1.1/en/content.md"], root=Path(tmp))
            self.assertTrue(any("no meta.yaml" in p for p in problems))

    def test_title_must_be_a_conventional_commit(self):
        problems = check_pr.check("Fixed stuff", self.body("good.md"), [])
        self.assertTrue(any("Conventional Commit" in p for p in problems))

    def test_missing_section(self):
        body = self.body("good.md").replace("## Depends on", "## Something else")
        self.assertIn("missing section: ## Depends on", check_pr.check("docs: x", body, []))

    def test_human_edit_needs_a_human_edits_record(self):
        body = self.body("good.md").replace("- Author: ai", "- Author: human")
        problems = check_pr.check("fix(cka): x", body, TOUCHED)
        self.assertTrue(any("human_edits" in p for p in problems))

    def test_no_material_touched_skips_provenance_matching(self):
        body = (self.body("good.md").replace("- Model: claude", "- Model: anything")
                .replace("Site: image-rebuild", "Site: none"))
        self.assertEqual(check_pr.check("docs: x", body, ["README.md"]), [])

    def test_site_impact_is_computed_from_docker_yml_paths(self):
        self.assertIn("certs/**", check_pr.image_paths())
        self.assertEqual(check_pr.site_impact(["README.md", "docs/x.md", "tests/t.py",
                                               "Makefile", ".github/workflows/verify.yml"]), "none")
        for touched in (["teach/api.py"], ["models.yaml"], ["certs/cka/1.1/en/content.md"],
                        ["scripts/check_pr.py"], ["deploy/Dockerfile"]):
            with self.subTest(touched=touched):
                self.assertEqual(check_pr.site_impact(touched), "image-rebuild")
        self.assertEqual(check_pr.site_impact(["deploy/helm/values.yaml"]), "none")
        self.assertEqual(check_pr.site_impact(["docs/sub/x.yaml"]), "none")  # *.yaml is root only

    def test_declared_site_must_match(self):
        body = self.body("good.md").replace("Site: image-rebuild", "Site: none")
        problems = check_pr.check("fix(cka): x", body, TOUCHED)
        self.assertTrue(any("Site: none" in p and "image-rebuild" in p for p in problems))

    def test_site_line_is_required(self):
        body = self.body("good.md").replace("- Site: image-rebuild\n", "")
        self.assertTrue(any("add a 'Site:" in p for p in check_pr.check("docs: x", body, [])))

    def test_the_templates_carry_every_required_section(self):
        for template in list((REPO / ".github" / "PULL_REQUEST_TEMPLATE").glob("*.md")) + [
                REPO / ".github" / "pull_request_template.md"]:
            found = check_pr.sections(template.read_text(encoding="utf-8"))
            with self.subTest(template=template.name):
                self.assertEqual([s for s in check_pr.SECTIONS if s not in found], [])
                self.assertIn("### Where it ran", found["Evidence"] + template.read_text(encoding="utf-8"))
                self.assertIn("### Known gaps", template.read_text(encoding="utf-8"))


class WhereItRanTests(unittest.TestCase):
    def test_runs_are_read_from_the_subsection(self):
        body = (FIXTURES / "good.md").read_text(encoding="utf-8")
        self.assertEqual(check_pr.cited_runs(body), [("villadalmine/study-cybercirujas", "123")])

    def test_evidence_without_a_run_fails(self):
        body = (FIXTURES / "good.md").read_text(encoding="utf-8").replace("/actions/runs/123", "")
        self.assertTrue(any("Where it ran" in p for p in check_pr.check("docs: x", body, [])))


class ScopeTests(unittest.TestCase):
    def test_one_topic_language_per_content_pr(self):
        files = ["certs/cka/1.1/es/content.md", "certs/cka/1.2/es/content.md"]
        self.assertTrue(any("2 topic/language" in p for p in check_pr.scope(files)))
        self.assertEqual(check_pr.scope(files[:1]), [])

    def test_one_lab_per_pr(self):
        files = ["certs/cka/1.1/lab/lab.yaml", "certs/cka/1.2/lab/lab.yaml"]
        self.assertTrue(any("2 labs" in p for p in check_pr.scope(files)))

    def test_material_and_code_do_not_mix(self):
        files = ["certs/cka/1.1/en/content.md", "teach/api.py"]
        self.assertTrue(any("material and code" in p for p in check_pr.scope(files)))
        self.assertEqual(check_pr.scope(files, labels={"scope-exception"}), [])

    def test_generated_files_are_not_edited_by_hand(self):
        self.assertTrue(any("generated file" in p for p in check_pr.scope(["STATUS.md"])))
        self.assertEqual(check_pr.scope(["STATUS.md", "certs/cka/1.1/en/content.md"]), [])

    def test_size_limit_and_exception(self):
        self.assertTrue(any("size:" in p for p in check_pr.scope(["teach/api.py"], code_lines=401)))
        self.assertEqual(check_pr.scope(["teach/api.py"], code_lines=401, labels={"size-exception"}), [])
        self.assertEqual(check_pr.scope(["teach/api.py"], code_lines=400), [])

    def test_docs_and_fixtures_are_not_code(self):
        k = check_pr.kinds(["README.md", "docs/x.md", "tests/fixtures/pr/good.md", "tests/test_x.py"])
        self.assertEqual(k["code"], {"tests/test_x.py"})


if __name__ == "__main__":
    unittest.main()
