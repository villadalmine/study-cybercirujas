"""The structural gate that decides whether a translation is usable.

Its own failure modes matter in both directions: too loose and damaged material
ships, too strict and every correct translation is rejected. The second is not
hypothetical — it shipped, and it rejected output from every model including
Claude (see CHANGELOG 2026-08-03).

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import unittest

from teach.core.generator import GeneratorConfigError, _verify_translation

SOURCE = """# Aislamiento de red

Las NetworkPolicy son aditivas.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
spec:
  podSelector:        # a qué pods se aplica esta policy (obligatorio)
    matchLabels:
      app: backend
  policyTypes:         # Ingress, Egress, o ambos
    - Ingress
```

## Referencias

- https://kubernetes.io/docs/concepts/services-networking/network-policies/
"""

DIAGRAM = """# Arquitectura

```text
┌─────────────────────────────────────────┐
│  cloud-controller-manager (opcional)    │
│  kube-scheduler                         │
└─────────────────────────────────────────┘
```

## Referencias

- https://kubernetes.io/docs/concepts/overview/components/
"""


def _english(text: str) -> str:
    """The source with its prose in English, code block untouched."""
    return (
        text.replace("Aislamiento de red", "Network isolation")
        .replace("Las NetworkPolicy son aditivas.", "NetworkPolicies are additive.")
        .replace("# Arquitectura", "# Architecture")
        .replace("## Referencias", "## References")
    )


class AcceptsCorrectTranslations(unittest.TestCase):
    def test_faithful_translation(self):
        translated = _english(SOURCE)
        self.assertEqual(_verify_translation(SOURCE, translated, "content.md"), translated)

    def test_translated_comments_inside_code_blocks(self):
        """Comments are prose. The authored English material has English
        comments, so leaving them in Spanish is the wrong output, not the right
        one — demanding byte-identical blocks rejected every correct
        translation until this was fixed."""
        translated = (
            _english(SOURCE)
            .replace("# a qué pods se aplica esta policy (obligatorio)",
                     "# which pods this policy applies to (mandatory)")
            .replace("# Ingress, Egress, o ambos", "# Ingress, Egress, or both")
        )
        self.assertEqual(_verify_translation(SOURCE, translated, "content.md"), translated)

    def test_translated_diagram_label_that_keeps_alignment(self):
        """ASCII diagrams are prose too, and this one is not a retry away:
        `cheap` translated it on 3 of 3 attempts, so rejecting it meant kcna/1.1
        could never be translated at all."""
        translated = _english(DIAGRAM).replace("(opcional)", "(optional)")
        self.assertEqual(_verify_translation(DIAGRAM, translated, "content.md"), translated)


class RejectsDamagedTranslations(unittest.TestCase):
    def assertRejected(self, source, translated, expected):
        with self.assertRaises(GeneratorConfigError) as caught:
            _verify_translation(source, translated, "content.md")
        self.assertIn(expected, str(caught.exception))

    def test_translated_yaml_key(self):
        """The failure that silently breaks every example: the model translates
        the manifest itself, not the prose around it."""
        self.assertRejected(SOURCE, SOURCE.replace("podSelector:", "selectorDePods:"),
                            "code blocks were modified")

    def test_deleted_comment_line(self):
        """Blanking comment text must not let a model drop the line entirely:
        the '#' marker is kept precisely so its absence still shows up."""
        translated = SOURCE.replace(
            "  policyTypes:         # Ingress, Egress, o ambos\n", "  policyTypes:\n"
        )
        self.assertRejected(SOURCE, translated, "code blocks were modified")

    def test_diagram_that_breaks_alignment(self):
        """Re-padding is the model's job: a diagram whose borders no longer line
        up is visibly broken material."""
        translated = DIAGRAM.replace(
            "│  cloud-controller-manager (opcional)    │",
            "│  cloud-controller-manager (not required) │",
        )
        self.assertRejected(DIAGRAM, translated, "code blocks were modified")

    def test_command_is_not_covered_by_the_diagram_rule(self):
        """'|' and '-' are excluded from the box character set on purpose, so an
        ordinary shell pipeline stays compared exactly."""
        source = SOURCE.replace(
            "```yaml\napiVersion",
            "```bash\nkubectl get pods -o json | jq '.items[].metadata.name'\n```\n\n```yaml\napiVersion",
        )
        self.assertRejected(source, source.replace("kubectl get pods", "kubectl obtener pods"),
                            "code blocks were modified")

    def test_dropped_url(self):
        translated = SOURCE.replace(
            "https://kubernetes.io/docs/concepts/services-networking/network-policies/",
            "the official documentation",
        )
        self.assertRejected(SOURCE, translated, "source URLs are missing")

    def test_dropped_code_block(self):
        translated = SOURCE.split("```yaml")[0] + (
            "\n## References\n\n"
            "- https://kubernetes.io/docs/concepts/services-networking/network-policies/\n"
        )
        self.assertRejected(SOURCE, translated, "code blocks")

    def test_summary_instead_of_translation(self):
        """The cheap-model failure the length band exists for."""
        self.assertRejected(SOURCE, "# Network isolation\n\nNetworkPolicies are additive.\n",
                            "code blocks")

    def test_dropped_heading(self):
        self.assertRejected(SOURCE, SOURCE.replace("## Referencias\n\n", ""), "headings")


if __name__ == "__main__":
    unittest.main()
