"""scripts/curriculum_diff.py (#63): extraction, the syllabus diff, the per-topic plan, the guard, determinism.

tests/fixtures/curriculum/*.layout.txt are `pdftotext -layout` (poppler 24.02.0) of the CNCF curricula
CKA_Curriculum_v1.35.pdf @ cncf/curriculum 008b73c and CKAD_Curriculum_v1.35.pdf @ d50919e (CC-BY 4.0,
Cloud Native Computing Foundation), kept as text so the parser is tested without poppler.
"""
import contextlib
import copy
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import curriculum_diff as cd  # noqa: E402

FIXTURES = REPO / "tests" / "fixtures" / "curriculum"
SCRIPT = REPO / "scripts" / "curriculum_diff.py"


def run_twice(args):
    """The script's stdout, twice, in fresh processes with different hash seeds."""
    return [subprocess.run([sys.executable, str(SCRIPT)] + args, cwd=REPO, check=True, capture_output=True,
                           env=dict(os.environ, PYTHONHASHSEED=seed)).stdout for seed in ("1", "2")]


def tree(*domains):
    """[(name, weight, [objective, ...]), ...] -> a syllabus dict as load_syllabus returns it."""
    return {"version": "x", "domains": [
        {"id": str(i), "name": name, "weight": weight,
         "objectives": [{"id": f"{i}.{j}", "text": text} for j, text in enumerate(objs, 1)]}
        for i, (name, weight, objs) in enumerate(domains, 1)]}


BASE = tree(("Storage", 40, ["Implement storage classes and dynamic volume provisioning",
                             "Manage persistent volumes and persistent volume claims"]),
            ("Networking", 60, ["Define and enforce Network Policies",
                                "Understand and use CoreDNS",
                                "Use the Gateway API to manage Ingress traffic"]))


# ==== extract ====

def row(left: str = "", right: str = "", width: int = 52) -> str:
    """One `pdftotext -layout` line: a left-column part, padded, then a right-column part."""
    return (left.ljust(width) + right).rstrip()


TWO_COLUMNS = "\n".join([
    "Demo Exam Curriculum",
    "\f This document provides the curriculum outline of the demo exam, in full width.",
    "",
    " DEMO Curriculum",
    "",
    row("   30% - Alpha Things", "50% - Beta Things,"),
    row("", "Gamma and Delta"),
    row(),
    row("    • Configure the first objec-", "• Use blue/"),
    row("      tive with care", "  green deployments"),
    row("    • Second objective", "• Right side second"),
    row("", "• Ends with a page"),
    row("   20% - Omega Domain", "  number below"),
    row(),
    row("    • Last objective"),
    row("", " " * 40 + "2"),
    "\fCloud native computing uses an open source software stack. 15% - not a header page",
])


class Extraction(unittest.TestCase):
    def test_two_columns_are_read_left_then_right_and_joined(self):
        domains = cd.parse_layout(TWO_COLUMNS)
        self.assertEqual([(d["id"], d["name"], d["weight"]) for d in domains],
                         [("1", "Alpha Things", 30), ("2", "Beta Things, Gamma and Delta", 50),
                          ("3", "Omega Domain", 20)])
        self.assertEqual([o["text"] for o in domains[0]["objectives"]],
                         ["Configure the first objective with care", "Second objective"])
        self.assertEqual([o["text"] for o in domains[1]["objectives"]],
                         ["Use blue/green deployments", "Right side second", "Ends with a page number below"])
        self.assertEqual([o["text"] for o in domains[2]["objectives"]], ["Last objective"])
        self.assertEqual(cd.check_tree(domains), [])

    def test_one_column_page(self):
        text = "\n".join(["   60% - Only", "    • One", "      continued", "   40% - Two", "    • Two-",
                          "      fold"])
        domains = cd.parse_layout(text)
        self.assertEqual([(d["name"], [o["text"] for o in d["objectives"]]) for d in domains],
                         [("Only", ["One continued"]), ("Two", ["Twofold"])])

    def test_join_rules(self):
        self.assertEqual(cd.join("deploy-", "ments"), "deployments")
        self.assertEqual(cd.join("blue/", "green"), "blue/green")
        self.assertEqual(cd.join("CNI, CSI,", "CRI, etc.)"), "CNI, CSI, CRI, etc.)")
        self.assertEqual(cd.join("Kubernetes-", "Native"), "Kubernetes- Native")   # upper case: not a hyphenation

    def test_real_cka_pdf_text(self):
        domains = cd.parse_layout((FIXTURES / "cka_v1.35.layout.txt").read_text(encoding="utf-8"))
        self.assertEqual(cd.check_tree(domains), [])
        self.assertEqual([d["weight"] for d in domains], [10, 30, 15, 25, 20])
        self.assertEqual(sum(len(d["objectives"]) for d in domains), 27)
        texts = {o["text"]: d["name"] for d in domains for o in d["objectives"]}
        # the two-column interleaving: RBAC opens the right column under Cluster Architecture
        self.assertEqual(texts["Manage role based access control (RBAC)"],
                         "Cluster Architecture, Installation and Configuration")
        self.assertIn("Create and manage Kubernetes clusters using kubeadm", texts)
        self.assertIn("Understand the primitives used to create robust, self-healing, application deployments", texts)
        self.assertIn("Understand extension interfaces (CNI, CSI, CRI, etc.)", texts)

    def test_real_ckad_pdf_text(self):
        domains = cd.parse_layout((FIXTURES / "ckad_v1.35.layout.txt").read_text(encoding="utf-8"))
        self.assertEqual(cd.check_tree(domains), [])
        self.assertEqual(sum(len(d["objectives"]) for d in domains), 24)
        texts = {o["text"]: d["name"] for d in domains for o in d["objectives"]}
        self.assertEqual(texts["Kustomize"], "Application Deployment")
        self.assertEqual(texts["Understand API depreciations"], "Application Observability and Maintenance")
        self.assertIn("Use Kubernetes primitives to implement common deployment strategies (e.g. blue/green or canary)",
                      texts)

    def test_bad_extraction_is_refused(self):
        with self.assertRaises(SystemExit):
            cd.snapshot([{"id": "1", "name": "A", "weight": 50, "objectives": []}], cert="x", version="1",
                        repo="r", commit="c", path="p", committed="d", sha256="s")

    def test_tree_hash_ignores_the_pdf_and_whitespace(self):
        a = BASE["domains"]
        b = copy.deepcopy(a)
        b[0]["objectives"][0]["text"] = "  Implement storage classes and   dynamic volume provisioning "
        self.assertEqual(cd.tree_sha256(a), cd.tree_sha256(b))

    def test_extract_is_byte_identical(self):
        args = ["extract", "--text", str(FIXTURES / "cka_v1.35.layout.txt"), "--sha256", "0" * 64, "--cert", "cka",
                "--version", "1.35", "--repo", "cncf/curriculum", "--commit", "c" * 40,
                "--path", "CKA_Curriculum_v1.35.pdf", "--committed", "2026-03-03"]
        a, b = run_twice(args)
        self.assertEqual(a, b)
        self.assertIn(b"Manage role based access control (RBAC)", a)

    # ---- argument combinations that cannot work are refused up front (umbrella #196) ----
    EXTRACT = ["extract", "--text", str(FIXTURES / "cka_v1.35.layout.txt"), "--cert", "cka", "--version", "1.35",
               "--repo", "cncf/curriculum", "--commit", "c" * 40, "--path", "CKA_Curriculum_v1.35.pdf",
               "--committed", "2026-03-03"]

    def refused(self, argv):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as raised:
            cd.main(argv)
        self.assertEqual(raised.exception.code, 2)   # argparse's usage error, not a traceback
        return err.getvalue()

    def test_text_without_sha256_is_refused_not_a_traceback(self):
        self.assertIn("--text needs --sha256", self.refused(self.EXTRACT))

    def test_check_without_out_is_refused_because_it_could_only_say_stale(self):
        self.assertIn("--check needs -o", self.refused(self.EXTRACT + ["--sha256", "0" * 64, "--check"]))
        self.assertIn("--check needs -o", self.refused(["render", "plan.json", "--check"]))

    def test_check_with_out_still_works(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "cka.yaml"
            argv = self.EXTRACT + ["--sha256", "0" * 64, "-o", str(out)]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(cd.main(argv), 0)
                self.assertEqual(cd.main(argv + ["--check"]), 0)   # second run: nothing changes
            out.write_text("stale", encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cd.main(argv + ["--check"]), 1)

    def test_guard_help_says_uncommitted_edits_are_not_seen(self):
        out = subprocess.run([sys.executable, str(SCRIPT), "guard", "--help"], cwd=REPO, check=True,
                             capture_output=True, text=True).stdout
        self.assertIn("uncommitted", " ".join(out.split()))


# ==== diff ====

class Diff(unittest.TestCase):
    def test_identical(self):
        d = cd.diff(BASE, copy.deepcopy(BASE))
        self.assertTrue(d["identical"])
        self.assertEqual(len(d["objectives"]["unchanged"]), 5)

    def test_each_kind_of_change(self):
        new = tree(("Storage", 30, ["Implement storage classes and dynamic volume provisioning",
                                    "Manage persistent volumes, persistent volume claims and snapshots",
                                    "Understand and use CoreDNS"]),
                   ("Networking and Gateways", 70, ["Define and enforce Network Policies",
                                                    "Use the Gateway API to manage Ingress and GRPC traffic",
                                                    "Configure workload autoscaling"]))
        d = cd.diff(BASE, new)
        o, dom = d["objectives"], d["domains"]
        self.assertFalse(d["identical"])
        self.assertEqual([(m["old_id"], m["new_id"]) for m in o["moved"]], [("2.2", "1.3")])
        self.assertEqual([(r["old_id"], r["new_id"]) for r in o["reworded"]], [("2.3", "2.2")])
        self.assertEqual([(c["old_id"], c["new_id"]) for c in o["changed"]], [("1.2", "1.2")])
        self.assertEqual([a["text"] for a in o["added"]], ["Configure workload autoscaling"])
        self.assertEqual(o["removed"], [])
        self.assertEqual([(w["domain"], w["old"], w["new"]) for w in dom["weight_changed"]],
                         [("Storage", 40, 30), ("Networking and Gateways", 60, 70)])
        self.assertEqual([(r["old"], r["new"]) for r in dom["renamed"]], [("Networking", "Networking and Gateways")])

    def test_removed_below_match(self):
        new = copy.deepcopy(BASE)
        new["domains"][1]["objectives"][1]["text"] = "Operate etcd backups"
        d = cd.diff(BASE, new)
        self.assertEqual([r["old_id"] for r in d["objectives"]["removed"]], ["2.2"])
        self.assertEqual([a["new_id"] for a in d["objectives"]["added"]], ["2.2"])

    def test_case_and_space_are_not_a_change(self):
        new = copy.deepcopy(BASE)
        new["domains"][0]["objectives"][0]["text"] = "implement storage classes and  dynamic volume provisioning."
        self.assertTrue(cd.diff(BASE, new)["identical"])

    def test_per_objective_weights_are_never_compared(self):
        """certs/<cert>.md splits the domain weight over its objectives; only the domain total counts."""
        frozen = textwrap.dedent("""\
            ---
            cert: demo
            version: '1.0'
            topics:
            - {id: '1.1', title: Implement storage classes and dynamic volume provisioning, topic: 1 - Storage, weight: 13.33}
            - {id: '1.2', title: Manage persistent volumes and persistent volume claims, topic: 1 - Storage, weight: 26.67}
            - {id: '2.1', title: Define and enforce Network Policies, topic: 2 - Networking, weight: 20}
            - {id: '2.2', title: Understand and use CoreDNS, topic: 2 - Networking, weight: 20}
            - {id: '2.3', title: Use the Gateway API to manage Ingress traffic, topic: 2 - Networking, weight: 20}
            ---
            """)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "demo.md"
            path.write_text(frozen, encoding="utf-8")
            old = cd.load_syllabus(path)
        self.assertEqual([d["weight"] for d in old["domains"]], [40, 60])
        self.assertTrue(cd.diff(old, BASE)["identical"])

    def test_diff_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp) / "old.yaml", Path(tmp) / "new.yaml"
            old.write_text(cd.dump_yaml(BASE), encoding="utf-8")
            changed = copy.deepcopy(BASE)
            changed["domains"][1]["objectives"].reverse()
            changed["domains"][0]["objectives"][1]["text"] = "Manage persistent volumes and claims"
            new.write_text(cd.dump_yaml(changed), encoding="utf-8")
            a, b = run_twice(["diff", str(old), str(new)])
        self.assertEqual(hashlib.sha256(a).hexdigest(), hashlib.sha256(b).hexdigest())
        self.assertFalse(json.loads(a)["identical"])


# ==== plan ====

class Classes(unittest.TestCase):
    def classes(self, new):
        return {tid: c[0] for tid, c in cd.classify(cd.diff(BASE, new), BASE).items()}

    def test_unchanged_is_keep(self):
        self.assertEqual(set(self.classes(copy.deepcopy(BASE)).values()), {"keep"})

    def test_rules(self):
        new = tree(("Storage", 40, ["Implement storage classes and dynamic volume provisioning",
                                    "Manage persistent volumes, persistent volume claims and snapshots"]),
                   ("Networking", 50, ["Define and enforce Network Policies",
                                       "Use the Gateway API to manage Ingress traffic."]),
                   ("DNS", 10, ["Understand and use CoreDNS", "Operate etcd backups"]))
        self.assertEqual(self.classes(new), {
            "1.1": "keep",            # same text, same domain, same domain weight
            "1.2": "regenerate",      # changed: MATCH <= similarity < REWORD
            "2.1": "revalidate",      # its domain's weight went 60 -> 50
            "2.2": "revalidate",      # moved to DNS (and its old domain's weight changed)
            "2.3": "revalidate",      # domain weight changed (the trailing dot is not a change)
        })

    def test_reworded_and_retired(self):
        new = copy.deepcopy(BASE)
        new["domains"][1]["objectives"][2]["text"] = "Use the Gateway API to manage ingress traffics"
        new["domains"][1]["objectives"][1]["text"] = "Operate etcd backups"
        got = self.classes(new)
        self.assertEqual((got["2.3"], got["2.2"]), ("revalidate", "retire"))

    def test_rules_table_names_every_class(self):
        self.assertEqual(sorted(r[0] for r in cd.CLASS_RULES), sorted(cd.CLASSES))
        self.assertEqual(sorted(cd.PLANNED_FILES), sorted(cd.CLASSES))
        self.assertEqual(cd.PLANNED_FILES["keep"], [])


DOC = textwrap.dedent("""\
    # 2.4 Understand API deprecations

    Intro.

    ## Removed APIs

    Run `kubeadm upgrade apply v1.35.1` on the node.

    ## References

    - [CKAD Curriculum v1.35](https://example.org)
    """)


class BelowTopicLevel(unittest.TestCase):
    def test_sections_and_version_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "certs/ckad/2.4/en").mkdir(parents=True)
            (root / "certs/ckad/2.4/en/content.md").write_text(DOC, encoding="utf-8")
            found = cd.scan(root, "ckad", "2.4", ["en"], "1.35",
                            [("old objective title", "Understand API deprecations"), ("weight", "weight")])
        self.assertEqual([(s["line"], s["heading"], s["why"]) for s in found["sections"]],
                         [(1, "2.4 Understand API deprecations", ["old objective title"])])
        self.assertEqual(found["version_lines"], {"curriculum": 1, "label": 0,
                                                  "technical": ["certs/ckad/2.4/en/content.md:7"], "citations": []})

    def test_fenced_hash_lines_are_not_headings_and_labs_are_scanned(self):
        doc = "# Title\n\n```\n# master   Ready   control-plane   2m   v1.35.0\n```\n\n## Next\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "certs/cka/4.2/en").mkdir(parents=True)
            (root / "certs/cka/4.2/lab").mkdir(parents=True)
            (root / "certs/cka/4.2/en/content.md").write_text(doc, encoding="utf-8")
            (root / "certs/cka/4.2/lab/lab.yaml").write_text("kubernetes: '1.35'\nrunner_image: kindest/node:v1.35.8\n",
                                                            encoding="utf-8")
            (root / "certs/cka/4.2/lab/break_fix.sh").write_text("#!/bin/bash\n# CKA v1.35\n", encoding="utf-8")
            found = cd.scan(root, "cka", "4.2", ["en"], "1.35", [])
        self.assertEqual([t for _, t, _ in cd._sections(doc)], ["Title", "Next"])
        self.assertEqual(found["version_lines"]["technical"],
                         ["certs/cka/4.2/en/content.md:4", "certs/cka/4.2/lab/break_fix.sh:2",
                          "certs/cka/4.2/lab/lab.yaml:1", "certs/cka/4.2/lab/lab.yaml:2"])


# ==== guard ====

class Guard(unittest.TestCase):
    def plan(self, **extra):
        topic = {"topic": "2.4", "class": "revalidate", "planned_files": ["certs/ckad/2.4/en/content.md"],
                 "sections": [{"file": "certs/ckad/2.4/en/content.md", "heading": "2.4 Understand API deprecations"}],
                 "version_lines": {"technical": ["certs/ckad/2.4/en/content.md:7"]}}
        keep = {"topic": "1.1", "class": "keep", "planned_files": [], "sections": [],
                "version_lines": {"technical": []}}
        return {"certs": {"ckad": {"new": [], "topics": [topic, keep], **extra}}}

    def test_only_planned_files_pass(self):
        changed = ["certs/ckad/2.4/en/content.md", "certs/ckad/1.1/en/content.md", "certs/ckad/9.9/en/content.md",
                   "docs/x.md", "certs/ckad.md"]
        self.assertEqual(cd.guard(self.plan(), changed), ["certs/ckad/1.1/en/content.md",
                                                           "certs/ckad/9.9/en/content.md"])

    def test_new_topic_directory_needs_a_new_objective(self):
        plan = self.plan(new=[{"objective": "5.7"}])
        self.assertEqual(cd.guard(plan, ["certs/ckad/5.7/en/content.md"]), [])

    def check(self, new_text):
        f = "certs/ckad/2.4/en/content.md"
        return cd.unlisted_edits(self.plan(), [f], lambda _: DOC, lambda _: new_text)

    def test_listed_section_and_version_line_may_change(self):
        edited = DOC.replace("# 2.4 Understand API deprecations\n\nIntro.", "# 2.4 Understand API deprecations\n\nNew.")
        self.assertEqual(self.check(edited.replace("v1.35.1", "v1.37.1")), [])

    def test_an_unlisted_line_may_not(self):
        self.assertEqual(len(self.check(DOC.replace("(https://example.org)", "(https://example.com)"))), 1)
        self.assertEqual(len(self.check(DOC + "\nextra line\n")), 1)

    def test_a_scoped_topic_may_record_provenance_in_its_meta(self):
        plan = self.plan()
        plan["certs"]["ckad"]["topics"][1]["version_lines"]["technical"] = ["certs/ckad/1.1/en/content.md:3"]
        self.assertEqual(cd.guard(plan, ["certs/ckad/1.1/en/meta.yaml", "certs/ckad/2.4/es/meta.yaml"]), [])
        plan["certs"]["ckad"]["topics"][1]["version_lines"]["technical"] = []
        self.assertEqual(cd.guard(plan, ["certs/ckad/1.1/en/meta.yaml"]), ["certs/ckad/1.1/en/meta.yaml"])

    def test_regenerate_and_retire_own_their_directory(self):
        for cls in ("regenerate", "retire"):
            plan = self.plan()
            plan["certs"]["ckad"]["topics"][0]["class"] = cls
            self.assertEqual(self.unlisted(plan, DOC + "\nrewritten\n"), [])
            self.assertEqual(self.unlisted(plan, None), [])

    def unlisted(self, plan, new_text):
        return cd.unlisted_edits(plan, ["certs/ckad/2.4/en/content.md"], lambda _: DOC, lambda _: new_text)

    def test_provenance_of_a_rewritten_topic(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            d = root / "certs/ckad/2.4/es"
            d.mkdir(parents=True)
            (d / "meta.yaml").write_text("model: claude\nlang: en\n", encoding="utf-8")
            plan = self.plan()
            weak = cd.provenance(root, plan, ["certs/ckad/2.4/es/content.md"])
            self.assertEqual(len(weak), 4)   # alias model, no effort, no prompt hash, lang en in es/
            (d / "meta.yaml").write_text("model: claude-opus-5\nlang: es\neffort: xhigh\nprompt_sha256: "
                                         + "a" * 64 + "\n", encoding="utf-8")
            self.assertEqual(cd.provenance(root, plan, ["certs/ckad/2.4/es/content.md"]), [])
            self.assertEqual(cd.provenance(root, plan, ["certs/ckad/2.4/es/meta.yaml"]), [])


# ==== render ====

class CommittedUpgrade(unittest.TestCase):
    """docs/upgrades/<x>.plan.json and <x>.md are exactly what their spec and inputs produce: `plan --check` and
    `render --check`, run here so CI (make verify-ci runs the unit tests) refuses a hand-edited plan, which is the
    guard's allowlist, or a stale report.

    The plan is the upgrade's input, not a live view of the tree: as the edits land, a fresh plan lists fewer
    version lines. So a PR that leaves the plan byte-identical to the one on origin/main passes (it widens nothing);
    a PR that changes it must equal what its inputs produce. Without origin/main (a fresh clone with no remote),
    the plan must equal a fresh one."""

    @staticmethod
    def on_main(rel):
        """The file as committed on origin/main. A CI checkout is shallow and has no origin/main: fetch it once
        (depth 1). Offline and without the ref, None: the caller then demands the strict equality."""
        def show():
            return subprocess.run(["git", "show", f"origin/main:{rel}"], cwd=REPO, capture_output=True, text=True)
        res = show()
        if res.returncode != 0:
            try:
                subprocess.run(["git", "fetch", "-q", "--depth=1", "origin", "main:refs/remotes/origin/main"],
                               cwd=REPO, capture_output=True, timeout=120)
            except (OSError, subprocess.TimeoutExpired):
                return None
            res = show()
        return res.stdout if res.returncode == 0 else None

    def test_committed_plans_and_reports_are_current(self):
        specs = sorted(p for p in (REPO / "docs" / "upgrades").glob("*.yaml") if not p.name.endswith(".pins.yaml"))
        if not specs:
            self.skipTest("no upgrade spec committed")
        for spec in specs:
            with self.subTest(spec=spec.name):
                plan_file, report = spec.with_suffix(".plan.json"), spec.with_suffix(".md")
                committed = plan_file.read_text(encoding="utf-8")
                if committed != self.on_main(plan_file.relative_to(REPO).as_posix()):
                    fresh = cd.dump_json(cd.plan(REPO, str(spec.relative_to(REPO))))
                    self.assertEqual(committed, fresh,
                                     f"{plan_file.name} is stale or hand-edited: scripts/curriculum_diff.py plan "
                                     f"{spec.relative_to(REPO)}")
                self.assertEqual(report.read_text(encoding="utf-8"), cd.render(json.loads(committed)),
                                 f"{report.name} is stale: scripts/curriculum_diff.py render {plan_file.relative_to(REPO)} "
                                 f"-o {report.relative_to(REPO)}")
                self.assertIn("```mermaid", report.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
