"""The curriculum consistency gate (#220): the repo says ONE thing about a cert's curriculum, and the same rewrite fixes it."""
from __future__ import annotations

import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import check_curriculum_consistency as gate  # noqa: E402
import curriculum_citations as cc  # noqa: E402
import curriculum_diff as cd  # noqa: E402
import upgrade_versions as uv  # noqa: E402

OLD = "https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf"
NEW = "https://github.com/cncf/curriculum/raw/b3c8508b9f6cd0bcfa76c2e4b7cc9b6a2f109bec/CKA_Curriculum_v1.37.pdf"
LPI = "https://www.lpi.org/our-certifications/exam-101-objectives/"
LINE_OLD = f"- CNCF CKA Curriculum v1.35: {OLD}"
LINE_NEW = f"- CNCF CKA Curriculum v1.37: {NEW}"


def entry(tracked="1.37", url=NEW, upstream=None):
    return {"tracked_version": tracked, "sources": {"objectives": url}, **({"upstream": upstream} if upstream else {})}


def strict(e=None, cert="cka"):
    return cc.wanted(e or entry(), cert, strict=True)


class FixLine(unittest.TestCase):
    def test_a_citation_and_its_link_become_the_catalogs(self):
        self.assertEqual(cc.fix_line(LINE_OLD, strict()), LINE_NEW)

    def test_every_form_the_repo_uses(self):
        forms = {
            "Curriculum oficial CKAD v1.35": "Curriculum oficial CKAD v1.37",
            "Currículo CKA v1.35": "Currículo CKA v1.37",
            "curriculum (v1.35)": "curriculum (v1.37)",                       # lowercase, parenthesis
            "**Certification:** CKA v1.35 · **Exam Weight:** 6%": "**Certification:** CKA v1.37 · **Exam Weight:** 6%",
            "**Examen:** CKAD (versión 1.35)": "**Examen:** CKAD (versión 1.37)",
            "CKA_Curriculum_v1.35.pdf": "CKA_Curriculum_v1.37.pdf",
            "CKS_Curriculum%20v1.35.pdf": "CKS_Curriculum%20v1.37.pdf",
            "# break-fix: CKA (examen v1.35) - Tema 1.1": "# break-fix: CKA (examen v1.37) - Tema 1.1",   # a lab script header
        }
        for old, new in forms.items():
            with self.subTest(old):
                self.assertEqual(cc.fix_line(old, strict()), new)

    def test_titles_and_parenthesised_forms_that_name_the_cert_without_an_introducing_word(self):
        forms = {
            "# CKA 1.35 — Topic 1.1": "# CKA 1.37 — Topic 1.1",              # the topic id 1.1 is not a version
            "# cka v1.35 - Tema 2.2": "# cka v1.37 - Tema 2.2",               # any case, with the marker
            "(CKA v1.35)": "(CKA v1.37)",
            "CKA (v1.35)": "CKA (v1.37)",
            "**Exam:** CKA 1.35 · weight 6%": "**Exam:** CKA 1.37 · weight 6%",
            "## 3.3 Autoscaling (CKA v1.35, 2.5%)": "## 3.3 Autoscaling (CKA v1.37, 2.5%)",
        }
        for old, new in forms.items():
            with self.subTest(old):
                self.assertEqual(cc.fix_line(old, strict()), new)

    def test_a_marker_after_its_introducing_word(self):
        self.assertEqual(cc.fix_line("Version 1.35 objectives:", strict()), "Version 1.37 objectives:")
        self.assertEqual(cc.fix_line("Versión 1.35 del curriculum", strict()), "Versión 1.37 del curriculum")
        self.assertEqual(cc.fix_line("v1.35 pods in the exam", strict()), "v1.35 pods in the exam")   # a bare v is not enough here

    def test_another_certs_id_or_a_number_that_is_not_a_version_is_not_a_citation(self):
        for line in ("# CKAD 1.35 — Topic 1.1",          # another cert's id (a longer one)
                     "CKA 3.3 autoscaling", "see CKA 1.1 and CKA 4.2",   # topic ids: the shape of a version is 1.37, not 1.1
                     "CKA 5 domains", "the CKA 135 questions", "CKA 1.35.1",   # not a version
                     "ACKA 1.35", "peso en el examen CKA (3.33%)",   # a weight, not a version
                     ):                        # a longer word
            with self.subTest(line):
                self.assertEqual(cc.fix_line(line, strict()), line)

    def test_what_is_not_a_curriculum_citation_stays(self):
        for line in ("The CNPE curriculum pairs this with metrics (5.1).", "kubeadm=1.35.1-1.1", "Curriculum, Domain 3.2",
                     "an example of v1.35 pods", "recognise v4.0 vectors in the wild", "CVSS v4.0 in the exam"):
            with self.subTest(line):
                self.assertEqual(cc.fix_line(line, strict()), line)

    def test_a_consistent_line_does_not_change_twice(self):
        self.assertEqual(cc.fix_line(LINE_NEW, strict()), LINE_NEW)

    def test_any_vendor_is_checked_from_its_catalog_entry(self):
        lpi = strict(entry("5.0", LPI), "lpic-1")
        self.assertEqual(cc.fix_line("LPIC-1 objectives version 5.0, https://www.lpi.org/our-certifications/exam-101-objectives/",
                                     lpi), "LPIC-1 objectives version 5.0, " + LPI)
        self.assertEqual(cc.fix_line("LPIC-1 objectives version 4.0", lpi), "LPIC-1 objectives version 5.0")
        # exam-201-202 and exam-201 are one document: only the pinned spelling is allowed
        lpic2 = strict(entry("4.5", "https://www.lpi.org/our-certifications/exam-201-objectives/"), "lpic-9")
        self.assertEqual(cc.fix_line("see https://www.lpi.org/our-certifications/exam-201-202-objectives/", lpic2),
                         "see https://www.lpi.org/our-certifications/exam-201-objectives/")
        self.assertEqual(cc.fix_line("see https://www.lpi.org/our-certifications/linux-essentials-overview/", lpic2),
                         "see https://www.lpi.org/our-certifications/linux-essentials-overview/")   # another document

    def test_lpic2s_canonical_page_is_a_reviewed_spelling_of_the_catalogs_alias(self):
        alias = entry("4.5", "https://www.lpi.org/our-certifications/exam-201-objectives/")
        page = "see https://www.lpi.org/our-certifications/exam-201-202-objectives/"
        self.assertEqual(cc.fix_line(page, cc.wanted(alias, "lpic-2")), page)               # accepted for lpic-2 (data, with its reason)
        self.assertNotEqual(cc.fix_line(page, cc.wanted(alias, "lpic-9")), page)            # not for a cert that has no such entry

    def test_a_reviewed_extra_spelling_is_accepted(self):
        lpic1 = cc.wanted(entry("5.0", LPI), "lpic-1")                       # exam 102 is accepted for lpic-1 (data)
        page = "https://www.lpi.org/our-certifications/exam-102-objectives/"
        self.assertEqual(cc.fix_line(page, lpic1), page)

    def test_a_cert_without_a_numeric_version_is_checked_on_its_link_only(self):
        kcsa = strict(entry("2024-06-24", "https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf"), "kcsa")
        self.assertEqual(cc.fix_line("KCSA Curriculum (v1.0)", kcsa), "KCSA Curriculum (v1.0)")
        self.assertEqual(cc.fix_line("https://github.com/cncf/curriculum/blob/master/KCSA%20Curriculum.pdf", kcsa),
                         "https://github.com/cncf/curriculum/blob/master/KCSA%20Curriculum.pdf")  # a blob page is not the raw PDF


class Window(unittest.TestCase):
    """The upstream block is accepted only as a valid, bounded upgrade window."""

    def tree(self, root: Path, version="1.37", url=NEW, milestone="CKA v1.37 upgrade", snap_version="1.37", snap_url=NEW):
        (root / "syllabi/cka").mkdir(parents=True, exist_ok=True)
        (root / "syllabi/cka/v1.37.yaml").write_text(yaml.safe_dump({"version": snap_version, "source": {"url": snap_url}}), encoding="utf-8")
        (root / "docs/upgrades").mkdir(parents=True, exist_ok=True)
        (root / "docs/upgrades/up.yaml").write_text(yaml.safe_dump({"milestone": "CKA v1.37 upgrade"}), encoding="utf-8")
        return entry("1.35", OLD, {"version": version, "objectives": url, "snapshot": "syllabi/cka/v1.37.yaml",
                                   "milestone": milestone})

    def test_a_valid_window_accepts_both_values_and_an_edit_targets_the_new(self):
        with tempfile.TemporaryDirectory() as tmp:
            e = self.tree(Path(tmp))
            want = cc.wanted(e, "cka", Path(tmp))
            self.assertTrue(want["window"])
            self.assertEqual((cc.fix_line(LINE_OLD, want), cc.fix_line(LINE_NEW, want)), (LINE_OLD, LINE_NEW))
            self.assertEqual(cc.fix_line(LINE_OLD, cc.wanted(e, "cka", Path(tmp), strict=True)), LINE_NEW)

    def test_a_bogus_or_unbounded_window_is_refused(self):
        bad = {
            "a version nobody froze": dict(version="1.99", snap_version="1.37"),
            "a downgrade": dict(version="1.30", snap_version="1.30"),
            "a snapshot of another PDF": dict(snap_url="https://example.com/x.pdf"),
            "no upgrade spec names the milestone": dict(milestone="nobody's milestone"),
            "the same URL as the pinned one": dict(url=OLD),
        }
        for name, kw in bad.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                e = self.tree(Path(tmp), **kw)
                want = cc.wanted(e, "cka", Path(tmp))
                self.assertFalse(want["window"], name)
                self.assertTrue(want["window_errors"], name)
                self.assertEqual(want["versions"], ["1.35"])                  # only the tracked value
                self.assertEqual(cc.fix_line("Curriculum v1.99", cc.wanted(e, "cka", Path(tmp), strict=True)),
                                 "Curriculum v1.35")                        # and an edit never targets a refused value

    def test_the_gate_fails_loudly_on_an_invalid_window_and_on_a_cert_it_cannot_compare(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            e = self.tree(root, version="1.99", snap_version="1.37")
            catalog = {"certs": {"cka": e, "mystery": {"tracked_version": "unknown", "sources": {}}}}
            msgs = cc.problems(root, catalog)
            self.assertTrue(any(m.startswith("cka: upstream.snapshot") for m in msgs), msgs)
            self.assertTrue(any(m.startswith("mystery:") and "cannot tell" in m for m in msgs), msgs)

    def test_one_value_per_cert_never_both(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            e = self.tree(root)
            (root / "certs/cka/1.1/en").mkdir(parents=True)
            (root / "certs/cka/1.1/en/content.md").write_text(f"{LINE_OLD}\n{LINE_NEW}\n", encoding="utf-8")
            found = cc.offenders(root, {"certs": {"cka": e}})
            self.assertEqual([(o["kind"], o["line"]) for o in found], [("mixed", 2)])   # the upstream line is the offender
            (root / "certs/cka/1.1/en/content.md").write_text(f"{LINE_NEW}\n", encoding="utf-8")
            self.assertEqual(cc.offenders(root, {"certs": {"cka": e}}), [])            # all on the upstream value: fine


class Gate(unittest.TestCase):
    def tree(self, root: Path, line: str):
        (root / "certs/cka/1.1/en").mkdir(parents=True, exist_ok=True)
        (root / "certs/cka/1.1/en/content.md").write_text(f"# t\n{line}\nkubeadm=1.35.1\n", encoding="utf-8")
        (root / "certs/cka/1.1/en/meta.yaml").write_text(f"lang: en\nsources:\n- {OLD if '1.35' in line else NEW}\n", encoding="utf-8")
        (root / "catalog.yaml").write_text(yaml.safe_dump({"certs": {"cka": entry()}}), encoding="utf-8")
        return root / "baseline.txt"

    def test_a_consistent_tree_passes_and_a_new_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = self.tree(root, LINE_NEW)
            self.assertEqual(gate.check(root, base)[:2], ([], []))
            base = self.tree(root, LINE_OLD)
            new, _, _ = gate.check(root, base)
            self.assertEqual(sorted(o["file"].split("/")[-1] for o in new), ["content.md", "meta.yaml"])

    def test_the_baseline_tolerates_the_old_offenders_and_must_shrink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = self.tree(root, LINE_OLD)
            _, _, found = gate.check(root, base)
            base.write_text("\n".join(cc.keys(found)) + "\n", encoding="utf-8")
            self.assertEqual(gate.check(root, base)[:2], ([], []))             # known offenders: green
            self.tree(root, LINE_NEW)                                           # fixed, baseline not shrunk
            new, stale, _ = gate.check(root, base)
            self.assertEqual((new, len(stale)), ([], 2))                       # stale entries fail until removed

    def test_a_repeat_of_a_baselined_line_is_a_new_offender(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = self.tree(root, LINE_OLD)
            _, _, found = gate.check(root, base)
            base.write_text("\n".join(cc.keys(found)) + "\n", encoding="utf-8")
            (root / "certs/cka/1.1/en/content.md").write_text(f"# t\n{LINE_OLD}\n{LINE_OLD}\n", encoding="utf-8")
            new, _, _ = gate.check(root, base)
            self.assertEqual([o["line"] for o in new], [3])                    # the second copy is not baselined

    def test_a_line_that_moves_keeps_its_baseline_key(self):
        a = {"file": "certs/cka/1.1/en/content.md", "line": 3, "text": LINE_OLD}
        self.assertEqual(cc.key(a), cc.key({**a, "line": 90}))

    def test_the_real_repo_is_clean_against_its_baseline(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = gate.main([])
        self.assertEqual(rc, 0, buf.getvalue()[:600])


class Edit(unittest.TestCase):
    def test_the_citations_scope_needs_a_cert_and_fixes_the_files_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            Gate().tree(root, LINE_OLD)
            (root / "certs/cka/1.1/en/meta.yaml").write_text(f"lang: en\nmodel: claude\nsources:\n- {OLD}\n", encoding="utf-8")
            (root / "plan.json").write_text("{}", encoding="utf-8")
            (root / "pins.yaml").write_text("date: '2026-10-21'\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                uv.run_citations(root / "plan.json", root / "pins.yaml", None, False, root)
            self.assertEqual(uv.run_citations(root / "plan.json", root / "pins.yaml", "cka", True, root), 1)   # --check
            uv.run_citations(root / "plan.json", root / "pins.yaml", "cka", False, root)
            text = (root / "certs/cka/1.1/en/content.md").read_text(encoding="utf-8")
            self.assertIn(LINE_NEW, text)
            self.assertIn("kubeadm=1.35.1", text)                              # untouched
            self.assertIn("tool_edit:", (root / "certs/cka/1.1/en/meta.yaml").read_text(encoding="utf-8"))
            before = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
            uv.run_citations(root / "plan.json", root / "pins.yaml", "cka", False, root)
            self.assertEqual({p: p.read_bytes() for p in root.rglob("*") if p.is_file()}, before)


class Guard(unittest.TestCase):
    """curriculum_diff: the citation fix needs no plan listing, and nothing else rides along."""

    F = "certs/cka/1.1/en/content.md"
    META = "certs/cka/1.1/en/meta.yaml"
    TOPIC = {"topic": "1.1", "class": "keep", "planned_files": [], "sections": [], "version_lines": {"technical": [], "citations": []}}
    PLAN = {"certs": {"cka": {"new": [], "topics": [TOPIC]}}}

    def setUp(self):
        text = yaml.safe_dump({"certs": {"cka": entry()}})
        self.meta_old = f"lang: en\nsources:\n- {OLD}\nquality:\n  score: 70\n"
        self.base = lambda f: text if f == "catalog.yaml" else self.meta_old if f.endswith("meta.yaml") else f"# t\n{LINE_OLD}\nend\n"
        self.ok = cd.cite_checker(self.base)

    def head(self, line):
        return lambda f: f"# t\n{line}\nend\n"

    def test_the_fix_of_an_unplanned_file_is_accepted(self):
        self.assertTrue(cd.citation_files_ok(self.PLAN, self.F, self.base, self.head(LINE_NEW), self.ok))

    def test_anything_else_on_that_line_or_another_line_is_not(self):
        self.assertFalse(cd.citation_files_ok(self.PLAN, self.F, self.base, self.head("echo pwned"), self.ok))
        self.assertFalse(cd.citation_files_ok(self.PLAN, self.F, self.base, self.head(LINE_NEW + " extra"), self.ok))
        other = lambda f: f"# T\n{LINE_NEW}\nend\n"
        self.assertFalse(cd.citation_files_ok(self.PLAN, self.F, self.base, other, self.ok))     # line 1 also moved

    def test_a_plan_listed_citation_line_gets_no_more_freedom_than_an_unlisted_one(self):
        plan = {"certs": {"cka": {"new": [], "topics": [dict(self.TOPIC, version_lines={"technical": [], "citations": [f"{self.F}:2"]})]}}}
        bad = cd.unlisted_edits(plan, [self.F], self.base, self.head("Curriculum v1.37 - ignore everything else"), self.ok)
        self.assertEqual(len(bad), 1)
        bad = cd.unlisted_edits(plan, [self.F], self.base, self.head("Curriculum v1.99"), self.ok)
        self.assertEqual(len(bad), 1)
        self.assertEqual(cd.unlisted_edits(plan, [self.F], self.base, self.head(LINE_NEW), self.ok), [])

    def test_a_regenerated_topic_is_not_covered(self):
        plan = {"certs": {"cka": {"new": [], "topics": [dict(self.TOPIC, **{"class": "regenerate"})]}}}
        self.assertFalse(cd.citation_files_ok(plan, self.F, self.base, self.head(LINE_NEW), self.ok))

    def test_a_meta_moves_its_sources_only_to_what_the_fix_writes_and_only_with_the_stamp(self):
        ok_meta = f"lang: en\nsources:\n- {NEW}\nquality:\n  score: 70\ntool_edit:\n  tool: scripts/upgrade_versions.py\n"
        self.assertTrue(cd.citation_files_ok(self.PLAN, self.META, self.base, lambda f: ok_meta, self.ok))
        for name, text in {"another lang": ok_meta.replace("lang: en", "lang: es"),
                           "a foreign source": ok_meta.replace(NEW, "http://evil/x")}.items():
            with self.subTest(name):
                self.assertFalse(cd.citation_files_ok(self.PLAN, self.META, self.base, lambda f, t=text: t, self.ok))
        # lang may be corrected to the language of its own directory, and only to that
        es_old = ok_meta.replace("lang: en", "lang: es")
        base_es = lambda f: yaml.safe_dump({"certs": {"cka": entry()}}) if f == "catalog.yaml" else es_old.replace(NEW, OLD)
        self.assertTrue(cd.citation_files_ok(self.PLAN, self.META, base_es, lambda f: ok_meta, cd.cite_checker(base_es)))
        self.assertFalse(cd.citation_files_ok(self.PLAN, self.META, base_es, lambda f: ok_meta.replace("lang: en", "lang: pt"),
                                              cd.cite_checker(base_es)))
        # an unstamped meta may not move sources or quality at all (wrong_rewrites reports it)
        plan = dict(self.PLAN, spec="docs/upgrades/x.yaml")
        pins = yaml.safe_dump({"tool": "scripts/upgrade_versions.py", "tool_sha256": "0" * 64, "tracked": "1.35", "target": "1.37",
                               "shift": 2, "patch": "1.37.1", "kindest_node": "v1.37.0", "date": "2026-10-21"})
        base = lambda f: pins if f.endswith(".pins.yaml") else self.base(f)
        for name, text in {"sources": f"lang: en\nsources:\n- http://evil/x\nquality:\n  score: 70\n",
                           "quality": f"lang: en\nsources:\n- {OLD}\nquality:\n  score: 100\n"}.items():
            with self.subTest("unstamped " + name):
                self.assertEqual(len(cd.wrong_rewrites(plan, [self.META], base, lambda f, t=text: t)), 1)
        self.assertEqual(cd.wrong_rewrites(plan, [self.META], base, lambda f: ok_meta), [])


if __name__ == "__main__":
    unittest.main()
