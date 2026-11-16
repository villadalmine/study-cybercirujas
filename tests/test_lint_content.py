"""lint_content (#207): the material's fenced code blocks are syntax-checked, with a baseline that may only shrink."""
from __future__ import annotations
import sys, tempfile, unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import lint_content as lint  # noqa: E402

DOC = ("# Title\n\n```bash\necho ok\n```\n\n1. A step:\n\n   ```YAML\n   a: 1\n   ```\n\n"
       "~~~console\n$ ls\n~~~\n\n```text\nnot checked (\n```\n\n```bash\nnever closed\n")


def found(*keys):
    return [{"file": k.split(":")[0], "line": 1, "lang": "bash", "msg": "x", "key": k, "code": ""} for k in keys]


class Extract(unittest.TestCase):
    def test_blocks_by_language_with_the_line_of_their_first_code_line(self):
        got = [(b["lang"], b["line"], b["code"]) for b in lint.blocks(DOC)]
        self.assertEqual(got, [("bash", 4, "echo ok\n"), ("yaml", 10, "a: 1\n"), ("console", 14, "$ ls\n"),
                               ("text", 18, "not checked (\n")])

    def test_a_longer_fence_holds_a_shorter_one(self):
        got = lint.blocks("````markdown\n```bash\nx\n```\n````\n")
        self.assertEqual([(b["lang"], b["code"]) for b in got], [("markdown", "```bash\nx\n```\n")])


class Prompts(unittest.TestCase):
    def test_output_is_dropped_and_prompts_stripped(self):
        code, where = lint.strip_prompts("$ ls (x\nfile (1)\nroot@host:~# id\nuid=0(root)\n")
        self.assertEqual((code, where), ("ls (x\nid\n", [0, 2]))

    def test_continuations_quotes_compounds_and_heredocs_are_kept(self):
        block = ("$ kubectl get pods \\\n    -A\nNAME (x)\n$ jq -r '.a\n   | .b'\nout (1)\n"
                 "$ for i in 1 2; do\n  echo $i\ndone\n1\n$ cat <<EOF > f\nline (with parens\nEOF\n"
                 "$ ping -M do -s 9000 host\nPING host (10.0.0.1)\n")
        self.assertEqual(lint.strip_prompts(block)[0],
                         "kubectl get pods \\\n    -A\njq -r '.a\n   | .b'\nfor i in 1 2; do\n  echo $i\ndone\n"
                         "cat <<EOF > f\nline (with parens\nEOF\nping -M do -s 9000 host\n")

    def test_transcripts_comments_and_placeholders_pass(self):
        self.assertEqual(lint.strip_prompts("# Step (1): list\n$ ls\n")[0], "ls\n")
        for lang, code in [("console", "$ ls -l\ntotal 0 (none)\n-rw-r--r-- 1 a b 0 x (y\n"),
                           ("bash", "$ echo hi\nhi (output)\n"),
                           ("bash", "kubectl logs <pod-name> -n <v>\nkubectl get <your resource>\ncat <<EOF >out\nx\nEOF\n")]:
            with self.subTest(lang=lang):
                self.assertEqual(lint.check_block(lang, code), [])


class Broken(unittest.TestCase):
    def test_broken_shell_and_transcript_line_numbers(self):
        errs = lint.check_block("bash", "echo ok\nif true; then\n  echo x\n")
        self.assertEqual(len(errs), 1)
        self.assertIn("unexpected end of file", errs[0][1])
        self.assertEqual(lint.check_block("sh", "echo ok\necho (\n")[0][0], 1)
        self.assertEqual(lint.check_block("console", "$ ls\nout\n$ echo (\n")[0][0], 2)

    def test_broken_yaml_and_allowed_yaml_tags_templates_or_other_langs(self):
        errs = lint.check_block("yaml", "a: 1\n---\nb: [1, 2\nc: 3\n")
        self.assertTrue(len(errs) == 1 and errs[0][1].startswith("yaml:"))
        self.assertEqual(lint.check_block("yml", "cat <<EOF | kubectl apply -f -\napiVersion: v1\n")[0][0], 1)
        for lang, code in [("yaml", "Bucket: !Ref MyBucket\nArn: !GetAtt [A, Arn]\n"),
                           ("yaml", "image: {{ .Values.image }}\n"), ("text", "echo (\n")]:
            with self.subTest(lang=lang):
                self.assertEqual(lint.check_block(lang, code), [])


class Baseline(unittest.TestCase):
    def setUp(self):
        self.path = Path(tempfile.mkdtemp()) / "baseline.txt"

    def test_baseline_create_and_shrink_only(self):
        a, b, c = "certs/a/1/en/content.md:aaa", "certs/b/1/en/content.md:bbb", "certs/c/1/en/content.md:ccc"
        self.assertEqual(lint.write_baseline(found(a, b), self.path), (2, []))
        self.assertEqual(lint.load_baseline(self.path), {a, b})
        self.assertEqual(lint.write_baseline(found(a, c), self.path), (1, [c]))
        self.assertEqual(lint.load_baseline(self.path), {a})

    def test_new_offenders_and_stale_entries_fail(self):
        a, b, c = "certs/a/1/en/content.md:aaa", "certs/b/1/en/content.md:bbb", "certs/c/1/en/content.md:ccc"
        lint.write_baseline(found(a, b), self.path)
        with mock.patch.object(lint, "offenders", return_value=found(a, c)):
            new, stale, _ = lint.check(None, self.path)
            self.assertEqual(([o["key"] for o in new], stale), ([c], [b]))
            self.assertEqual(lint.check([REPO / "certs" / "a"], self.path)[1], [])

    def test_the_key_follows_the_block_not_its_line(self):
        tmp = self.path.parent
        (f := tmp / "certs" / "x" / "1" / "en" / "content.md").parent.mkdir(parents=True)
        with mock.patch.object(lint, "REPO", tmp):
            f.write_text("```bash\necho (\n```\n", encoding="utf-8")
            a = lint.offenders([tmp / "certs"])
            f.write_text("intro\n\nmore\n\n```bash\necho (\n```\n", encoding="utf-8")
            b = lint.offenders([tmp / "certs"])
        self.assertEqual(([o["key"] for o in a], (a[0]["line"], b[0]["line"]), a[0]["file"]),
                         ([o["key"] for o in b], (2, 6), "certs/x/1/en/content.md"))


class Tree(unittest.TestCase):
    def test_the_baseline_is_sorted_and_names_only_material_files(self):
        keys = [k for k in lint.BASELINE.read_text(encoding="utf-8").splitlines() if not k.startswith("#")]
        self.assertEqual(keys, sorted(keys))
        for k in keys:
            self.assertRegex(k, r"^certs/[^/]+/[^/]+/[a-z]{2}/(content|exercises)\.md:[0-9a-f]{12}(#\d+)?$")


if __name__ == "__main__":
    unittest.main()
