"""scripts/check_docs.py: docs that point at things the repository does not have fail, offline."""
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import check_docs  # noqa: E402

CLI = '''
import typer
app = typer.Typer()
cert_app = typer.Typer()
app.add_typer(cert_app, name="cert")

@cert_app.command("list")
def cert_list():
    pass

@app.command()
def serve():
    pass
'''


class CheckDocsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "teach").mkdir()
        (self.root / "teach" / "cli.py").write_text(CLI, encoding="utf-8")
        (self.root / "Makefile").write_text("setup: ## x\n\ttrue\nverify-ci:\n\ttrue\nVAR := 1\n", encoding="utf-8")
        (self.root / "docs").mkdir()
        (self.root / "scripts").mkdir()
        (self.root / "scripts" / "real.py").write_text("", encoding="utf-8")
        (self.root / "docs" / "OTHER.md").write_text(textwrap.dedent("""\
            # Other

            ## Checking `curriculum` updates

            ## Repeated
            ## Repeated

            <a id="custom"></a>
            """), encoding="utf-8")
        patcher = mock.patch.object(check_docs, "REPO", self.root)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def problems(self, text, name="README.md"):
        (self.root / name).write_text(textwrap.dedent(text), encoding="utf-8")
        top, subs = check_docs.teach_commands()
        return check_docs.check_file(name, check_docs.make_targets(), top, subs, {})

    def test_good_links_paths_and_commands_pass(self):
        self.assertEqual(self.problems("""\
            See [other](docs/OTHER.md), [its section](docs/OTHER.md#checking-curriculum-updates),
            [the second one](docs/OTHER.md#repeated-1), [explicit](docs/OTHER.md#custom),
            [the web](https://example.com/x), and `scripts/real.py`. Run `make setup` or
            `teach cert list`; make sure nothing breaks (prose, not a command).

            ```bash
            make verify-ci
            teach serve
            ```
            """), [])

    def test_a_missing_file_or_anchor_fails(self):
        problems = "\n".join(self.problems("""\
            [gone](docs/GONE.md) and [no such heading](docs/OTHER.md#nope) and [here](#missing)
            """))
        self.assertIn("'docs/GONE.md', which does not exist", problems)
        self.assertIn("docs/OTHER.md#nope", problems)
        self.assertIn("README.md#missing", problems)

    def test_a_missing_path_in_code_fails(self):
        self.assertTrue(any("scripts/gone.py" in p for p in self.problems("Run `scripts/gone.py`.\n")))

    def test_unknown_make_targets_and_teach_commands_fail(self):
        problems = "\n".join(self.problems("""\
            `make nope` and `teach cert diff x`

            ```
            make also-nope
            teach pipeline
            ```
            """))
        for bad in ("make nope", "make also-nope", "teach cert diff", "teach pipeline"):
            with self.subTest(bad=bad):
                self.assertIn(bad, problems)

    def test_links_inside_code_blocks_are_not_checked(self):
        self.assertEqual(self.problems("```\n[x](docs/GONE.md)\n```\n"), [])

    def test_allowed_references_say_why(self):
        for ref, why in check_docs.ALLOWED.items():
            with self.subTest(ref=ref):
                self.assertTrue(why.strip())

    def test_the_real_docs_are_consistent(self):
        mock.patch.stopall()
        self.assertEqual(check_docs.main(["--no-generated"]), 0)


if __name__ == "__main__":
    unittest.main()
