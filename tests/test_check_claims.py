import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "check_claims", Path(__file__).resolve().parent.parent / "scripts" / "check_claims.py")
check_claims = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_claims)


class ReferencesTest(unittest.TestCase):
    def test_parses_both_separators_the_corpus_uses(self):
        # The colon-only pattern parsed nothing in 484 of 1,123 content files,
        # which then reported "0 look stale or wrong" without checking one.
        text = ("# Topic\n\nBody with https://example.com/not-a-citation\n\n## References\n\n"
                "- Kubernetes: DNS for Services — https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/\n"
                "- CoreDNS rewrite plugin: https://coredns.io/plugins/rewrite/\n"
                "- CNI specification - https://www.cni.dev/docs/spec/\n")
        refs = check_claims.references(text)
        self.assertEqual([u for _, u in refs], [
            "https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/",
            "https://coredns.io/plugins/rewrite/",
            "https://www.cni.dev/docs/spec/",
        ])
        self.assertEqual(refs[0][0], "Kubernetes: DNS for Services")

    def test_parses_markdown_links_and_bare_urls_under_a_label(self):
        text = ("## References\n\n"
                "- [Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/kubeadm/)\n"
                "* **CNCF TAG Security Whitepaper**: [https://github.com/cncf/tag-security](https://github.com/cncf/tag-security)\n"
                "CNPE curriculum (PDF)\n"
                "  https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf\n")
        self.assertEqual(check_claims.references(text), [
            ("Creating a cluster with kubeadm", "https://kubernetes.io/docs/setup/kubeadm/"),
            ("CNCF TAG Security Whitepaper", "https://github.com/cncf/tag-security"),
            ("CNPE curriculum PDF", "https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf"),
        ])

    def test_ignores_urls_outside_the_references_section(self):
        self.assertEqual(check_claims.references("- Example: https://example.com/\n"), [])


if __name__ == "__main__":
    unittest.main()
