"""scripts/check_pr.py: the PR format as a check, offline (fixtures in tests/fixtures/pr/)."""
import io
import json
import sys
import tempfile
from contextlib import redirect_stdout
from unittest import mock
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
                .replace("AI: content-agent · claude", "AI: content-agent · anything")  # Authorship agrees
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
                # Inside Evidence: cited_runs() reads only that section.
                self.assertIn("### Where it ran", found["Evidence"])
                self.assertIn("### Known gaps", found["Evidence"])
                self.assertEqual(check_pr.cited_runs(template.read_text(encoding="utf-8").replace(
                    "- CI: ", "- CI: https://github.com/o/r/actions/runs/1 ")), [("o/r", "1")])

    def test_where_it_ran_outside_evidence_is_not_evidence(self):
        # The case the old assertion could not catch (review of #3).
        moved = self.body("good.md").replace("### Where it ran", "## Lab cycle\n\n### Where it ran")
        self.assertNotIn("### Where it ran", check_pr.sections(moved)["Evidence"])


class AuthorshipTests(unittest.TestCase):
    """## Authorship: who wrote it agrees with Provenance; who found and fixed what."""

    def body(self):
        return (FIXTURES / "good.md").read_text(encoding="utf-8")

    def problems(self, body):
        return [p for p in check_pr.check("docs: x", body, []) if "Authorship" in p or "ledger" in p
                or "## Authorship" in p]

    def test_the_fixture_passes(self):
        self.assertEqual(self.problems(self.body()), [])

    def test_the_section_is_required(self):
        body = self.body().replace("## Authorship", "## Credits")
        self.assertIn("missing section: ## Authorship", check_pr.check("docs: x", body, []))

    def test_the_author_must_agree_with_provenance(self):
        body = self.body().replace("| Author | AI: content-agent · claude |", "| Author | Human: @someone |")
        self.assertTrue(any("Author row says Human" in p for p in self.problems(body)))
        body = self.body().replace("- Author: ai", "- Author: human")
        self.assertTrue(any("Provenance says Author: human" in p for p in self.problems(body)))

    def test_an_ai_author_names_the_declared_model(self):
        body = self.body().replace("| Author | AI: content-agent · claude |", "| Author | AI: content-agent |")
        self.assertTrue(any("must name the model" in p for p in self.problems(body)))

    def test_an_author_row_is_required(self):
        body = self.body().replace("| Author | AI: content-agent · claude |", "| Writer | someone |")
        self.assertTrue(any("add an Author row" in p for p in self.problems(body)))

    def test_the_findings_ledger_is_required_and_well_formed(self):
        self.assertTrue(any("Findings ledger" in p for p in
                            self.problems(self.body().replace("### Findings ledger", "### Notes"))))
        row = "| 1 | Copilot r1 | `aaaaaaa` | low | typo | content-agent / claude | `bbbbbbb` | pending | fixed |"
        for bad, why in ((row.replace("| fixed |", "| done |"), "status must be"),
                         (row.replace("| fixed |", "| rejected |"), "status must be"),
                         (row.replace("| Copilot r1 |", "|  |"), "'Found by' is empty"),
                         (row.replace("| `bbbbbbb` |", "|  |"), "'Fix' is empty"),
                         (row.replace("| low |", "|"), "8 columns")):
            with self.subTest(why=why):
                self.assertTrue(any(why in p for p in self.problems(self.body().replace(row, bad))))
        rejected = row.replace("| fixed |", "| rejected — the API already caps it |")
        self.assertEqual(self.problems(self.body().replace(row, rejected)), [])

    def test_the_templates_carry_an_empty_ledger_and_pass_the_author_rule(self):
        for template in list((REPO / ".github" / "PULL_REQUEST_TEMPLATE").glob("*.md")) + [
                REPO / ".github" / "pull_request_template.md"]:
            found = check_pr.sections(template.read_text(encoding="utf-8"))
            with self.subTest(template=template.name):
                self.assertEqual(check_pr.ledger_rows(found["Authorship"]), [])
                self.assertIn("| Author | Human:", found["Authorship"])


class WhereItRanTests(unittest.TestCase):
    def test_runs_are_read_from_the_subsection(self):
        body = (FIXTURES / "good.md").read_text(encoding="utf-8")
        self.assertEqual(check_pr.cited_runs(body), [("villadalmine/study-cybercirujas", "123")])

    def test_evidence_without_a_run_fails(self):
        body = (FIXTURES / "good.md").read_text(encoding="utf-8").replace("/actions/runs/123", "")
        self.assertTrue(any("Where it ran" in p for p in check_pr.check("docs: x", body, [])))


HEAD = "a" * 40
REPO_NAME = "villadalmine/study-cybercirujas"
GOOD_RUN = {"head_sha": HEAD, "path": ".github/workflows/verify.yml", "event": "pull_request"}
GOOD_JOBS = {"jobs": [{"name": "verify", "conclusion": "success"}, {"name": "e2e", "conclusion": "success"},
                      {"name": "pr-format", "conclusion": "failure"}]}


class CitedRunTests(unittest.TestCase):
    """The run under 'Where it ran' must be verify.yml's, on this head (review of #3)."""

    def fetch(self, run=GOOD_RUN, jobs=GOOD_JOBS):
        return lambda path: jobs if path.endswith("/jobs") else run

    def test_a_green_verify_run_on_the_head_proves_it(self):
        self.assertIsNone(check_pr.judge_run(GOOD_RUN, GOOD_JOBS, HEAD))
        self.assertTrue(check_pr.verify_runs([(REPO_NAME, "1")], REPO_NAME, HEAD, self.fetch()))

    def test_jobs_named_verify_and_e2e_in_another_workflow_do_not(self):
        run = dict(GOOD_RUN, path=".github/workflows/anything.yml")
        self.assertIn("anything.yml", check_pr.judge_run(run, GOOD_JOBS, HEAD))
        self.assertFalse(check_pr.verify_runs([(REPO_NAME, "1")], REPO_NAME, HEAD, self.fetch(run)))

    def test_a_dispatched_run_does_not(self):
        self.assertIn("workflow_dispatch", check_pr.judge_run(dict(GOOD_RUN, event="workflow_dispatch"),
                                                              GOOD_JOBS, HEAD))

    def test_another_head_or_a_red_job_does_not(self):
        self.assertIn("not the PR head", check_pr.judge_run(dict(GOOD_RUN, head_sha="b" * 40), GOOD_JOBS, HEAD))
        red = {"jobs": [{"name": "verify", "conclusion": "success"}, {"name": "e2e", "conclusion": "failure"}]}
        self.assertIn("e2e=failure", check_pr.judge_run(GOOD_RUN, red, HEAD))

    def test_the_repository_name_is_compared_without_case(self):
        pasted = "Villadalmine/Study-Cybercirujas"
        self.assertTrue(check_pr.verify_runs([(pasted, "1")], REPO_NAME, HEAD, self.fetch()))

    def test_an_api_error_is_reported_not_swallowed(self):
        def fail(path):
            raise RuntimeError("HTTP 403: Resource not accessible by integration")
        with redirect_stdout(io.StringIO()) as out:
            self.assertFalse(check_pr.verify_runs([(REPO_NAME, "1")], REPO_NAME, HEAD, fail))
        self.assertIn("HTTP 403", out.getvalue())


def verify_workflow() -> dict:
    import yaml
    wf = yaml.safe_load((REPO / ".github" / "workflows" / "verify.yml").read_text(encoding="utf-8"))
    wf["on"] = wf.get("on", wf.get(True))  # YAML 1.1 reads `on:` as True
    return wf


class VerifyWorkflowTests(unittest.TestCase):
    def test_pr_format_can_read_the_cited_run(self):
        # GET actions/runs/{id} and /jobs need actions: read on a private repository.
        self.assertEqual(verify_workflow()["jobs"]["pr-format"]["permissions"].get("actions"), "read")

    def test_a_waiver_label_re_runs_pr_format_and_nothing_else(self):
        # Adding scope-exception/size-exception fires `labeled`; before, the
        # waiver took effect only after an unrelated edit or push (review of #3).
        wf = verify_workflow()
        self.assertTrue({"labeled", "unlabeled"} <= set(wf["on"]["pull_request"]["types"]))
        for job in ("verify", "e2e", "where-it-ran"):
            with self.subTest(job=job):
                self.assertIn('!contains(fromJSON(\'["edited","labeled","unlabeled"]\')', wf["jobs"][job]["if"])
        self.assertIn('"labeled"', wf["concurrency"]["group"])

    def test_labels_are_read_live_not_from_the_replayed_payload(self):
        step = next(s for s in verify_workflow()["jobs"]["pr-format"]["steps"]
                    if s.get("name") == "Check the PR description")
        self.assertIn("/labels", step["run"])
        self.assertIn("--labels-file labels.txt", step["run"])
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "labels.txt"
            f.write_text("site:none\nsize-exception\n\n", encoding="utf-8")
            labels = check_pr.read_labels(f)
        self.assertEqual(labels, {"site:none", "size-exception"})
        self.assertEqual(check_pr.scope(["teach/api.py"], code_lines=401, labels=labels), [])


class MainTests(unittest.TestCase):
    """check_pr.main() as CI and a contributor call it (review round 2 of #3: an `if`
    inserted before the `else` of `if args.event` blanked the event's title and body)."""

    TITLE = "fix(cka): reclaim policy"

    def run_main(self, *argv):
        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["check_pr.py", *argv, "--files", *TOUCHED]), redirect_stdout(out):
            code = check_pr.main()
        return code, out.getvalue()

    def event(self, tmp, labels=()):
        ev = Path(tmp) / "event.json"
        ev.write_text(json.dumps({"pull_request": {
            "title": self.TITLE, "body": (FIXTURES / "good.md").read_text(encoding="utf-8"),
            "labels": [{"name": n} for n in labels]}}), encoding="utf-8")
        return str(ev)

    def test_event_alone_reads_title_and_body_from_the_event(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, out = self.run_main("--event", self.event(tmp))
        self.assertEqual(code, 0, out)
        self.assertIn("PR description OK", out)

    def test_a_missing_labels_file_keeps_the_event(self):
        # The workflow's fallback when `gh api .../labels` fails: `rm -f labels.txt`.
        with tempfile.TemporaryDirectory() as tmp:
            code, out = self.run_main("--event", self.event(tmp), "--labels-file", str(Path(tmp) / "nope.txt"))
        self.assertEqual(code, 0, out)
        self.assertNotIn("missing section", out)

    def test_title_and_body_file_with_a_labels_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            labels = Path(tmp) / "labels.txt"
            labels.write_text("size-exception\n", encoding="utf-8")
            code, out = self.run_main("--title", self.TITLE, "--body-file", str(FIXTURES / "good.md"),
                                      "--labels-file", str(labels))
        self.assertEqual(code, 0, out)

    def test_live_labels_replace_the_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            labels = Path(tmp) / "labels.txt"
            labels.write_text("scope-exception\n", encoding="utf-8")
            with mock.patch.object(check_pr, "scope", wraps=check_pr.scope) as scope:
                self.run_main("--event", self.event(tmp, labels=["stale"]), "--labels-file", str(labels))
        self.assertEqual(scope.call_args.args[2], {"scope-exception"})


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
