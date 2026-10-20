"""scripts/curriculum_diff.py (#63): extraction, the syllabus diff, the per-topic plan, the guard, determinism.

tests/fixtures/curriculum/*.layout.txt are `pdftotext -layout` (poppler 24.02.0) of the CNCF curricula
CKA_Curriculum_v1.35.pdf @ cncf/curriculum 008b73c and CKAD_Curriculum_v1.35.pdf @ d50919e (CC-BY 4.0,
Cloud Native Computing Foundation), kept as text so the parser is tested without poppler.
"""
import copy
import hashlib
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


if __name__ == "__main__":
    unittest.main()
