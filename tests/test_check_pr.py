"""scripts/check_pr.py: the PR format as a check, offline (fixtures in tests/fixtures/pr/)."""
import io
import json
import os
import subprocess
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

    def test_the_graph_bot_pr_is_checked_by_title_author_and_files_only(self):
        graph = ["graphify-out/graph.json", "graphify-out/wiki/index.md"]
        title = "chore(graph): regenerate code graph"
        bot = dict(head_ref="bot/graph-refresh", author="github-actions[bot]", same_repo=True)
        self.assertEqual(check_pr.check(title, "", graph, **bot), [])
        # the title is still checked
        self.assertTrue(check_pr.check("regenerate", "", graph, **bot))
        # another branch, or any file outside graphify-out/, gets the full check
        self.assertTrue(check_pr.check(title, "", graph, **{**bot, "head_ref": "bot/other"}))
        self.assertTrue(check_pr.check(title, "", graph + ["scripts/check_pr.py"], **bot))
        self.assertTrue(check_pr.check(title, "", [], **bot))
        # the branch name alone is not an identity (#33): a person, or a fork, with
        # the same branch name gets the full check
        self.assertTrue(check_pr.check(title, "", graph, **{**bot, "author": "villadalmine"}))
        self.assertTrue(check_pr.check(title, "", graph, **{**bot, "author": None}))
        self.assertTrue(check_pr.check(title, "", graph, **{**bot, "same_repo": False}))
        self.assertTrue(check_pr.check(title, "", graph, head_ref="bot/graph-refresh"))

    def test_the_bot_exemption_reads_the_author_and_repo_from_the_event(self):
        """Through main(): the event payload decides, and an exempt PR writes no runs file."""
        def run(login, head_repo):
            event = {"pull_request": {"title": "chore(graph): regenerate code graph", "body": "",
                                      "user": {"login": login},
                                      "head": {"ref": "bot/graph-refresh", "repo": {"full_name": head_repo}},
                                      "base": {"repo": {"full_name": "o/r"}}}}
            with tempfile.TemporaryDirectory() as tmp:
                ev, runs = Path(tmp) / "e.json", Path(tmp) / "runs.txt"
                ev.write_text(json.dumps(event))
                argv = ["check_pr.py", "--event", str(ev), "--files", "graphify-out/a.md",
                        "--runs-file", str(runs)]
                with mock.patch.object(sys, "argv", argv), redirect_stdout(io.StringIO()):
                    return check_pr.main(), runs.exists()
        self.assertEqual(run("github-actions[bot]", "o/r"), (0, False))
        self.assertEqual(run("someone", "o/r")[0], 1)
        self.assertEqual(run("github-actions[bot]", "fork/r")[0], 1)

    def test_git_paths_are_read_unquoted(self):
        """core.quotePath=false: a quoted "graphify-out/... name cost #60 the exemption."""
        with tempfile.TemporaryDirectory() as tmp:
            def sh(*a):
                subprocess.run(["git", "-C", tmp, *a], check=True, capture_output=True)
            sh("init", "-q", "-b", "main")
            sh("config", "user.email", "t@t")
            sh("config", "user.name", "t")
            sh("commit", "-q", "--allow-empty", "-m", "base")
            (Path(tmp) / "graphify-out").mkdir()
            (Path(tmp) / "graphify-out" / "Roadmap — where.md").write_text("x")
            sh("add", ".")
            sh("commit", "-q", "-m", "n")
            with mock.patch.object(check_pr, "REPO", Path(tmp)):
                files = check_pr.changed_files("HEAD~1")
        self.assertEqual(files, ["graphify-out/Roadmap — where.md"])

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

    def test_the_docstring_shows_the_invocations_ci_runs(self):
        # --help prints it; it must match verify.yml (review round 3 of #3).
        wf = (REPO / ".github" / "workflows" / "verify.yml").read_text(encoding="utf-8")
        doc = check_pr.__doc__
        self.assertNotIn("No network, no model:", doc)
        for flag in ("--labels-file", "--label-file", "--runs-file", "--verify-runs", "--repo", "--head"):
            with self.subTest(flag=flag):
                self.assertIn(flag, doc)
                self.assertIn(flag, wf)

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


class QualityOnlyTests(unittest.TestCase):
    """A rescore (make quality) is not an edit of the material (quality-score PR)."""

    META = "generated_at: '2026-07-16'\nlang: en\nbackend: claude\nmodel: claude\n"

    def tree(self, tmp, head_meta, extra=()):
        d = Path(tmp) / "certs" / "cka" / "1.1" / "en"
        d.mkdir(parents=True)
        (d / "meta.yaml").write_text(head_meta, encoding="utf-8")
        files = ["certs/cka/1.1/en/meta.yaml", *extra]
        return files, (lambda paths: {p: self.META for p in paths})

    def test_only_the_quality_block_changed(self):
        with tempfile.TemporaryDirectory() as tmp:
            files, base = self.tree(tmp, self.META + "quality:\n  score: 80.0\n")
            self.assertEqual(check_pr.quality_only(files, base, root=Path(tmp)), {"certs/cka/1.1/en/meta.yaml"})

    def test_recording_a_review_is_not_authorship(self):
        # docs/REVIEWS.md: add a reviews: entry and run make quality (review of the quality PR).
        review = ("reviews:\n- by: fable (revisor-pr)\n  link: https://github.com/o/r/pull/1\n"
                  "  date: '2026-10-15'\n  result: pass\nquality:\n  score: 90.0\n")
        with tempfile.TemporaryDirectory() as tmp:
            files, base = self.tree(tmp, self.META + review)
            self.assertEqual(check_pr.quality_only(files, base, root=Path(tmp)), {"certs/cka/1.1/en/meta.yaml"})

    def test_any_other_change_still_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            files, base = self.tree(tmp, self.META.replace("model: claude", "model: other") + "quality: {}\n")
            self.assertEqual(check_pr.quality_only(files, base, root=Path(tmp)), set())

    def test_content_changed_too_still_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            files, base = self.tree(tmp, self.META + "quality: {}\n", extra=["certs/cka/1.1/en/content.md"])
            self.assertEqual(check_pr.quality_only(files, base, root=Path(tmp)), set())

    def test_status_md_with_only_rescored_metadata_is_not_a_hand_edit(self):
        rescored = ["STATUS.md", "certs/cka/1.1/en/meta.yaml"]
        self.assertEqual(check_pr.scope(["STATUS.md"], all_files=rescored), [])
        self.assertTrue(any("generated file" in p for p in check_pr.scope(["STATUS.md"])))

    def test_base_texts_reads_git(self):
        texts = check_pr.base_texts(["README.md", "no/such/file.md"], "HEAD")
        self.assertIn("study", texts["README.md"].lower())
        self.assertIsNone(texts["no/such/file.md"])


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


class DisclosureTests(unittest.TestCase):
    """The AI disclosure is checked on every PR, not only when certs/ changes (#68)."""

    def test_placeholder_author_fails_on_a_code_pr(self):
        body = (FIXTURES / "good.md").read_text(encoding="utf-8").replace("- Author: ai", "- Author: human | ai")
        problems = check_pr.check("fix(api): x", body, ["scripts/x.py"])
        self.assertTrue(any("'Author:' must be exactly" in p for p in problems), problems)

    def test_ai_must_name_backend_and_model(self):
        self.assertEqual(check_pr.disclosure({"author": "ai", "backend": "claude", "model": "claude-x"}), [])
        for prov in ({"author": "ai", "backend": "none", "model": "claude-x"},
                     {"author": "ai", "backend": "claude", "model": ""},
                     {"author": "ai"}):
            with self.subTest(prov=prov):
                self.assertEqual(len(check_pr.disclosure(prov)), 1)

    def test_human_needs_nothing_else(self):
        self.assertEqual(check_pr.disclosure({"author": "human", "backend": "none", "model": "none"}), [])

    def test_the_certs_check_does_not_repeat_the_message(self):
        body = (FIXTURES / "good.md").read_text(encoding="utf-8").replace("- Author: ai", "- Author: maybe")
        problems = check_pr.check("fix(cka): x", body, TOUCHED)
        self.assertEqual(sum("'Author:'" in p for p in problems), 1, problems)


def commit(sha="a" * 40, email="dev@example.org", trailer="Signed-off-by: Dev <dev@example.org>", subject="fix: x"):
    return {"sha": sha, "email": email, "message": f"{subject}\n\nbody\n\n{trailer}\n" if trailer else f"{subject}\n"}


class DcoTests(unittest.TestCase):
    def test_a_signed_commit_passes(self):
        self.assertEqual(check_pr.dco([commit()]), [])

    def test_an_unsigned_commit_fails_and_says_how_to_fix_it(self):
        problems = check_pr.dco([commit(trailer="")])
        self.assertEqual(len(problems), 1)
        for text in ("aaaaaaa", "git commit --amend -s", "git rebase --signoff", "--force-with-lease"):
            self.assertIn(text, problems[0])

    def test_one_problem_per_unsigned_commit(self):
        commits = [commit(), commit("b" * 40, trailer=""), commit("c" * 40, trailer="")]
        self.assertEqual(len(check_pr.dco(commits)), 2)

    def test_the_sign_off_must_be_the_authors_email(self):
        other = commit(trailer="Signed-off-by: Someone Else <other@example.org>")
        self.assertEqual(len(check_pr.dco([other])), 1)

    def test_email_case_does_not_matter(self):
        self.assertEqual(check_pr.dco([commit(trailer="signed-off-by: Dev <DEV@Example.org>")]), [])

    def test_the_prs_github_noreply_address_counts(self):
        for noreply in ("1070184+octo@users.noreply.github.com", "octo@users.noreply.github.com"):
            with self.subTest(noreply=noreply):
                c = commit(email="octo@laptop.local", trailer=f"Signed-off-by: Octo <{noreply}>")
                self.assertEqual(check_pr.dco([c], pr_author="octo"), [])
        c = commit(email="octo@laptop.local", trailer="Signed-off-by: Octo <1+someoneelse@users.noreply.github.com>")
        self.assertEqual(len(check_pr.dco([c], pr_author="octo")), 1)

    def test_a_sign_off_buried_in_a_line_is_not_a_trailer(self):
        c = commit(trailer="I never wrote Signed-off-by: Dev <dev@example.org>")
        self.assertEqual(len(check_pr.dco([c])), 1)

    def test_no_pr_is_grandfathered_by_its_number(self):
        # #85: dco() has no PR number at all, so a reopened old PR cannot carry new unsigned code
        self.assertFalse(hasattr(check_pr, "DCO_FIRST_PR"))
        with self.assertRaises(TypeError):
            check_pr.dco([commit(trailer="")], number=61)
        self.assertEqual(len(check_pr.dco([commit(trailer="")])), 1)

    def test_a_forged_commit_date_does_not_exempt_a_commit(self):
        # #85: only base..HEAD decides (commits_of); dates and the PR number are never read
        git = lambda *a, **kw: subprocess.run(["git", *a], cwd=tmp, check=True, capture_output=True,  # noqa: E731
                                              text=True, **kw)
        with tempfile.TemporaryDirectory() as tmp:
            git("init", "-q", "-b", "main")
            git("config", "user.name", "Dev")
            git("config", "user.email", "dev@example.org")
            git("commit", "-q", "--allow-empty", "-m", "base")
            git("checkout", "-q", "-b", "old-pr")
            env = {**os.environ, "GIT_AUTHOR_DATE": "2020-01-01T00:00:00", "GIT_COMMITTER_DATE": "2020-01-01T00:00:00"}
            git("commit", "-q", "--allow-empty", "-m", "unsigned, dated before the rule", env=env)
            with mock.patch.object(check_pr, "REPO", Path(tmp)):
                commits = check_pr.commits_of("main")
            self.assertEqual(len(check_pr.dco(commits)), 1)

    BOT = dict(pr_author="github-actions[bot]", same_repo=True)
    GRAPH = ["graphify-out/graph.json"]
    REF = "bot/graph-refresh"

    def test_the_graph_bot_is_exempt_only_on_its_branch_with_its_files_and_its_author(self):
        bot = commit(email="41898282+github-actions[bot]@users.noreply.github.com", trailer="")
        self.assertEqual(check_pr.dco([bot], head_ref=self.REF, files=self.GRAPH, **self.BOT), [])
        self.assertEqual(len(check_pr.dco([bot], head_ref="bot/other", files=self.GRAPH, **self.BOT)), 1)
        self.assertEqual(len(check_pr.dco([bot], head_ref=self.REF, files=self.GRAPH + ["scripts/x.py"],
                                          **self.BOT)), 1)
        self.assertEqual(len(check_pr.dco([bot], head_ref=self.REF, files=[], **self.BOT)), 1)
        # the branch name alone is not an identity (#33): another author, or a fork, is not exempt
        self.assertEqual(len(check_pr.dco([bot], head_ref=self.REF, files=self.GRAPH,
                                          pr_author="someone", same_repo=True)), 1)
        self.assertEqual(len(check_pr.dco([bot], head_ref=self.REF, files=self.GRAPH,
                                          pr_author="github-actions[bot]", same_repo=False)), 1)

    def test_a_forged_bot_email_exempts_nobody(self):
        # #86: mallory forks, names the branch bot/graph-refresh, touches only graphify-out/ and forges
        # the author email on every commit: the PR's login and head repo, not the email, decide
        forged = commit(email="github-actions[bot]@users.noreply.github.com", trailer="")
        problems = check_pr.dco([forged], head_ref=self.REF, files=self.GRAPH, pr_author="mallory", same_repo=False)
        self.assertEqual(len(problems), 1)
        # ... also from a branch of this repo, if the opener is not the bot
        self.assertEqual(len(check_pr.dco([forged], head_ref=self.REF, files=self.GRAPH,
                                          pr_author="mallory", same_repo=True)), 1)

    def test_the_bot_pr_is_exempt_whatever_the_commit_email_says(self):
        # the email is not an input any more: neither required nor trusted
        for email in ("github-actions[bot]@users.noreply.github.com", "whoever@example.org"):
            with self.subTest(email=email):
                c = commit(email=email, trailer="")
                self.assertEqual(check_pr.dco([c], head_ref=self.REF, files=self.GRAPH, **self.BOT), [])

    def test_commits_of_reads_git_without_merges(self):
        git = lambda *a: subprocess.run(["git", *a], cwd=tmp, check=True, capture_output=True, text=True)  # noqa: E731
        with tempfile.TemporaryDirectory() as tmp:
            git("init", "-q", "-b", "main")
            git("config", "user.name", "Dev")
            git("config", "user.email", "dev@example.org")
            git("commit", "-q", "--allow-empty", "-m", "base")
            git("checkout", "-q", "-b", "topic")
            git("commit", "-q", "--allow-empty", "-s", "-m", "signed")
            git("commit", "-q", "--allow-empty", "-m", "unsigned")
            with mock.patch.object(check_pr, "REPO", Path(tmp)):
                commits = check_pr.commits_of("main")
            self.assertEqual(len(commits), 2)
            problems = check_pr.dco(commits)
            self.assertEqual(len(problems), 1)
            self.assertIn("unsigned", problems[0])


class DcoMainTests(unittest.TestCase):
    """main() wires the commits of --base..HEAD, the event's number and author into dco()."""

    def run_main(self, number, commits):
        with tempfile.TemporaryDirectory() as tmp:
            ev = Path(tmp) / "event.json"
            ev.write_text(json.dumps({"pull_request": {
                "number": number, "user": {"login": "dev"}, "title": "fix(cka): reclaim policy",
                "body": (FIXTURES / "good.md").read_text(encoding="utf-8")}}), encoding="utf-8")
            out = io.StringIO()
            argv = ["check_pr.py", "--event", str(ev), "--base", "origin/main", "--files", *TOUCHED]
            with mock.patch.object(sys, "argv", argv), mock.patch.object(check_pr, "commits_of", return_value=commits), \
                    mock.patch.object(check_pr, "code_lines_changed", return_value=0), \
                    mock.patch.object(check_pr, "base_texts", return_value={}), redirect_stdout(out):
                code = check_pr.main()
        return code, out.getvalue()

    def test_an_unsigned_commit_fails_the_pr(self):
        code, out = self.run_main(500, [commit(trailer="")])
        self.assertEqual(code, 1)
        self.assertIn("PR: DCO:", out)

    def test_an_old_pr_number_gets_the_full_check(self):
        code, out = self.run_main(61, [commit(trailer="")])
        self.assertEqual(code, 1, out)
        self.assertIn("PR: DCO:", out)

    def test_signed_commits_pass(self):
        code, out = self.run_main(500, [commit()])
        self.assertEqual(code, 0, out)


class ScopeSectionTests(unittest.TestCase):
    """## Scope: exactly one of the four values."""

    def body(self):
        return (FIXTURES / "good.md").read_text(encoding="utf-8")

    def problems(self, body):
        return [p for p in check_pr.check("fix(cka): x", body, TOUCHED) if "Scope" in p]

    def test_each_scope_passes(self):
        for value in check_pr.SCOPES:
            with self.subTest(value=value):
                self.assertEqual(self.problems(self.body().replace("- Scope: medium", f"- Scope: {value}")), [])

    def test_the_section_is_required(self):
        body = self.body().replace("## Scope", "## Size")
        self.assertIn("missing section: ## Scope", check_pr.check("docs: x", body, []))

    def test_the_unedited_template_line_fails(self):
        body = self.body().replace("- Scope: medium", "- Scope: small | medium | large | exam-version")
        self.assertTrue(self.problems(body))

    def test_an_unknown_scope_fails(self):
        self.assertTrue(self.problems(self.body().replace("- Scope: medium", "- Scope: huge")))

    def test_a_missing_scope_line_fails(self):
        self.assertTrue(self.problems(self.body().replace("- Scope: medium\n", "")))


CATALOG_BASE = """
certs:
  cka:
    tracked_version: '1.35'
    last_checked: '2026-09-03'
    sources:
      objectives: https://example.org/cka-1.35.pdf
  lpic-1:
    tracked_version: '5.0'
    sources:
      objectives: https://example.org/lpic.html
"""


class ExamVersionTests(unittest.TestCase):
    """catalog.yaml: tracked_version or objectives only move in the milestone's final PR."""

    def changes(self, head):
        return check_pr.exam_version_changes(CATALOG_BASE, head)

    def test_an_identical_catalog_has_no_change(self):
        self.assertEqual(self.changes(CATALOG_BASE), [])

    def test_other_fields_are_free(self):
        head = CATALOG_BASE.replace("2026-09-03", "2026-10-16")
        self.assertEqual(self.changes(head), [])

    def test_tracked_version_change_is_detected(self):
        self.assertEqual(self.changes(CATALOG_BASE.replace("'1.35'", "'1.37'")), ["cka"])

    def test_objectives_link_change_is_detected(self):
        # what PR #61 did: a links fix that moved the objectives
        self.assertEqual(self.changes(CATALOG_BASE.replace("cka-1.35.pdf", "cka-1.37.pdf")), ["cka"])

    def test_a_new_or_removed_cert_is_a_change(self):
        added = CATALOG_BASE + "  ckad:\n    tracked_version: '1.35'\n    sources: {objectives: x}\n"
        self.assertEqual(self.changes(added), ["ckad"])
        self.assertEqual(check_pr.exam_version_changes(added, CATALOG_BASE), ["ckad"])
        self.assertEqual(check_pr.exam_version_changes(None, CATALOG_BASE), ["cka", "lpic-1"])

    UPGRADE = "CKA & CKAD v1.37 upgrade"

    def test_without_a_change_nothing_is_required(self):
        self.assertEqual(check_pr.exam_version([], None, None), [])

    def test_a_change_with_nothing_fails_twice(self):
        self.assertEqual(len(check_pr.exam_version(["cka"], None, "medium")), 2)

    def test_the_declared_scope_alone_is_not_enough(self):
        problems = check_pr.exam_version(["cka"], None, "exam-version")
        self.assertEqual(len(problems), 1)
        self.assertIn("milestone", problems[0])

    def test_the_milestone_alone_is_not_enough(self):
        problems = check_pr.exam_version(["cka"], self.UPGRADE, "medium")
        self.assertEqual(len(problems), 1)
        self.assertIn("Scope", problems[0])

    def test_only_an_upgrade_milestone_authorizes(self):
        for milestone in ("F2 labs", "Quality & groundedness", "none", "", "v1.37 upgrade", "CKA v1.37 upgrades", "CKAv1.37 upgrade"):
            with self.subTest(milestone=milestone):
                self.assertTrue(check_pr.exam_version(["cka"], milestone, "exam-version", {"cka": "1.37"}))
        for milestone in (self.UPGRADE, "CKA v1.37 upgrade", "cka v1.37 upgrade"):
            with self.subTest(milestone=milestone):
                self.assertEqual(check_pr.exam_version(["cka"], milestone, "exam-version", {"cka": "1.37"}), [])

    def test_a_milestone_for_another_cert_does_not_authorize(self):
        # #90: "CKAD v1.37 upgrade" must not authorize a change to lpic-1 (or to cka)
        for changed, versions in ((["lpic-1"], {"lpic-1": "1.37"}), (["cka"], {"cka": "1.37"})):
            with self.subTest(changed=changed):
                problems = check_pr.exam_version(changed, "CKAD v1.37 upgrade", "exam-version", versions)
                self.assertEqual(len(problems), 1)
                self.assertIn("does not name", problems[0])
        # shape-only titles that used to pass
        for milestone in ("Foo v1 upgrade", "Q4 v2026 upgrade"):
            with self.subTest(milestone=milestone):
                self.assertEqual(len(check_pr.exam_version(["lpic-1"], milestone, "exam-version", {"lpic-1": "1"})), 1)

    def test_every_changed_cert_must_be_named(self):
        both = {"cka": "1.37", "ckad": "1.37"}
        self.assertEqual(check_pr.exam_version(["cka", "ckad"], self.UPGRADE, "exam-version", both), [])
        self.assertEqual(len(check_pr.exam_version(["cka", "ckad"], "CKA v1.37 upgrade", "exam-version", both)), 1)
        self.assertEqual(len(check_pr.exam_version(["cka", "ckad", "cks"], self.UPGRADE, "exam-version",
                                                   {**both, "cks": "1.37"})), 1)

    def test_cert_separators_are_ampersand_comma_and_and(self):
        both = {"cka": "1.37", "ckad": "1.37"}
        for milestone in ("CKA, CKAD v1.37 upgrade", "CKA and CKAD v1.37 upgrade", "CKA&CKAD v1.37 upgrade"):
            with self.subTest(milestone=milestone):
                self.assertEqual(check_pr.exam_version(["cka", "ckad"], milestone, "exam-version", both), [])
        # a substring is not a name: "ckad" does not authorize "cka"
        self.assertEqual(len(check_pr.exam_version(["cka"], "CKAD v1.37 upgrade", "exam-version", {"cka": "1.37"})), 1)

    def test_the_version_must_equal_the_new_tracked_version(self):
        for milestone in ("CKA v1.36 upgrade", "CKA v1.3 upgrade", "CKA v1 upgrade"):
            with self.subTest(milestone=milestone):
                problems = check_pr.exam_version(["cka"], milestone, "exam-version", {"cka": "1.37"})
                self.assertEqual(len(problems), 1)
                self.assertIn("says '", problems[0])
        # one of two certs at another version fails
        problems = check_pr.exam_version(["cka", "ckad"], self.UPGRADE, "exam-version",
                                         {"cka": "1.37", "ckad": "1.36"})
        self.assertEqual(len(problems), 1)
        self.assertIn("ckad", problems[0])

    def test_a_removed_cert_needs_only_to_be_named(self):
        self.assertEqual(check_pr.exam_version(["ckad"], "CKAD v1.37 upgrade", "exam-version", {}), [])
        self.assertEqual(len(check_pr.exam_version(["ckad"], "CKA v1.37 upgrade", "exam-version", {})), 1)

    def test_every_version_shape_of_the_real_catalog_can_be_authorized(self):
        # the catalog holds dates, 'unknown', 'beta', 'AZ-900' and 'Terraform 1.12', not only x.y:
        # for every cert a title built from its own tracked_version authorizes it, a wrong one does not
        versions = check_pr.tracked_versions((REPO / "catalog.yaml").read_text(encoding="utf-8"))
        self.assertGreater(len(versions), 30)
        for key, tracked in versions.items():
            last = tracked.split()[-1]
            for title in (f"{key} v{last} upgrade", f"{key} {last} upgrade", f"{key.upper()} & CKAD v{last} upgrade"):
                with self.subTest(title=title):
                    self.assertEqual(check_pr.exam_version([key], title, "exam-version", versions), [])
            for title in (f"{key} v{last}x upgrade", f"{key} v upgrade", f"{key} v{last}.1 upgrade",
                          f"{key} 0{last} upgrade"):
                with self.subTest(title=title):
                    self.assertEqual(len(check_pr.exam_version([key], title, "exam-version", versions)), 1)

    def test_non_numeric_versions_are_compared_as_strings(self):
        v = {"kcna": "2025-11-24", "terraform-associate": "Terraform 1.12", "lfcs": "unknown", "ckne": "beta"}
        for key, title in (("kcna", "KCNA v2025-11-24 upgrade"), ("kcna", "KCNA 2025-11-24 upgrade"),
                           ("terraform-associate", "terraform-associate v1.12 upgrade"),
                           ("lfcs", "LFCS unknown upgrade"), ("ckne", "CKNE beta upgrade")):
            with self.subTest(title=title):
                self.assertEqual(check_pr.exam_version([key], title, "exam-version", v), [])
        for key, title in (("kcna", "KCNA v2025 upgrade"), ("kcna", "KCNA v2025-11-25 upgrade"),
                           ("terraform-associate", "terraform-associate v1.13 upgrade"),
                           ("lfcs", "LFCS known upgrade")):
            with self.subTest(title=title):
                self.assertEqual(len(check_pr.exam_version([key], title, "exam-version", v)), 1)

    def test_tracked_versions_reads_the_catalog(self):
        self.assertEqual(check_pr.tracked_versions(CATALOG_BASE), {"cka": "1.35", "lpic-1": "5.0"})
        self.assertEqual(check_pr.tracked_versions(None), {})

    def test_the_label_and_the_description_text_authorize_nothing(self):
        # the signature has no labels and no body: what #61 had (label scope:exam-version) cannot pass
        self.assertTrue(check_pr.exam_version(["cka"], None, "small"))


class ExamVersionWiringTests(unittest.TestCase):
    """main() reaches the guard: a #61-like PR (catalog links swapped, label present) fails in CI's path."""

    TITLE = "fix(catalog): update CKA and CKAD curriculum links"

    def body(self, scope):
        text = (FIXTURES / "good.md").read_text(encoding="utf-8").replace("- Scope: medium", f"- Scope: {scope}")
        return text.replace("Site: image-rebuild", f"Site: {check_pr.site_impact(['catalog.yaml'])}")

    def run_main(self, tmp, scope, milestone=None, labels="triaged\nscope:exam-version\n"):
        tmp = Path(tmp)
        (tmp / "body.md").write_text(self.body(scope), encoding="utf-8")
        (tmp / "labels.txt").write_text(labels, encoding="utf-8")
        argv = ["check_pr.py", "--title", self.TITLE, "--body-file", str(tmp / "body.md"), "--base", "origin/main",
                "--files", "catalog.yaml", "--labels-file", str(tmp / "labels.txt")]
        if milestone is not None:
            (tmp / "milestone.txt").write_text(milestone, encoding="utf-8")
            argv += ["--milestone-file", str(tmp / "milestone.txt")]
        head = CATALOG_BASE.replace("cka-1.35.pdf", "cka-1.37.pdf").replace("'1.35'", "'1.37'")
        out = io.StringIO()
        with mock.patch.object(sys, "argv", argv), redirect_stdout(out), \
                mock.patch.object(check_pr, "base_texts", lambda paths, base: {p: CATALOG_BASE for p in paths}), \
                mock.patch.object(check_pr, "commits_of", lambda base: []), \
                mock.patch.object(check_pr, "head_catalog", lambda: head):
            return check_pr.main(), out.getvalue()

    def test_pr_61_fails_even_with_the_label(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, out = self.run_main(tmp, "medium")
        self.assertEqual(code, 1, out)
        self.assertIn("exam version: catalog.yaml changes", out)

    def test_the_label_and_a_declared_scope_without_a_milestone_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, out = self.run_main(tmp, "exam-version", milestone="")
        self.assertEqual(code, 1, out)
        self.assertIn("milestone", out)

    def test_an_upgrade_milestone_and_the_declared_scope_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, out = self.run_main(tmp, "exam-version", milestone="CKA & CKAD v1.37 upgrade\n")
        self.assertEqual(code, 0, out)

    def test_main_passes_the_head_versions_and_the_changed_certs_to_the_guard(self):
        for milestone in ("CKA v1.36 upgrade\n", "LPIC-1 v1.37 upgrade\n"):
            with self.subTest(milestone=milestone), tempfile.TemporaryDirectory() as tmp:
                code, out = self.run_main(tmp, "exam-version", milestone=milestone)
                self.assertEqual(code, 1, out)
                self.assertIn("exam version:", out)


if __name__ == "__main__":
    unittest.main()
