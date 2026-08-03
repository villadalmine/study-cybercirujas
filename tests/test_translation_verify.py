"""Tests for the structural gate that decides whether a translation is usable.

This check is what makes translating on a cheaper model defensible, so its own
failure modes matter: too loose and damaged material ships, too strict and every
correct translation is rejected. Both directions are covered here — the second
one is not hypothetical, it shipped (see CHANGELOG 2026-08-03).
"""
import pytest

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


def _translate(body):
    """The source with its prose swapped for English, sharing one code block."""
    return body


def test_accepts_a_faithful_translation():
    translated = SOURCE.replace("Aislamiento de red", "Network isolation").replace(
        "Las NetworkPolicy son aditivas.", "NetworkPolicies are additive."
    ).replace("## Referencias", "## References")
    assert _verify_translation(SOURCE, translated, "content.md") == translated


def test_accepts_translated_comments_inside_code_blocks():
    """Comments are prose. The authored English material has English comments,
    so a translation that leaves them in Spanish is the wrong output, not the
    right one. Demanding byte-identical blocks rejected every correct
    translation until this was fixed."""
    translated = (
        SOURCE.replace("Aislamiento de red", "Network isolation")
        .replace("Las NetworkPolicy son aditivas.", "NetworkPolicies are additive.")
        .replace("## Referencias", "## References")
        .replace("# a qué pods se aplica esta policy (obligatorio)",
                 "# which pods this policy applies to (mandatory)")
        .replace("# Ingress, Egress, o ambos", "# Ingress, Egress, or both")
    )
    assert _verify_translation(SOURCE, translated, "content.md") == translated


def test_rejects_a_translated_yaml_key():
    """The failure that silently breaks every example: the model translates the
    manifest itself, not the prose around it."""
    translated = SOURCE.replace("podSelector:", "selectorDePods:")
    with pytest.raises(GeneratorConfigError, match="code blocks were modified"):
        _verify_translation(SOURCE, translated, "content.md")


def test_rejects_a_deleted_comment_line():
    """Blanking comment text must not let a model drop the line entirely: the
    '#' marker is kept precisely so its absence still shows up."""
    translated = SOURCE.replace(
        "  policyTypes:         # Ingress, Egress, o ambos\n", "  policyTypes:\n"
    )
    with pytest.raises(GeneratorConfigError, match="code blocks were modified"):
        _verify_translation(SOURCE, translated, "content.md")


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


def test_accepts_a_translated_diagram_label_that_keeps_alignment():
    """ASCII diagrams are prose too, and this one is not a retry away: `cheap`
    translated it on 3 of 3 attempts, so rejecting it meant the topic could
    never be translated at all."""
    translated = (
        DIAGRAM.replace("# Arquitectura", "# Architecture")
        .replace("(opcional)", "(optional)")
        .replace("## Referencias", "## References")
    )
    assert _verify_translation(DIAGRAM, translated, "content.md") == translated


def test_rejects_a_translated_diagram_that_breaks_alignment():
    """Re-padding is the model's job: a diagram whose borders no longer line up
    is visibly broken material, so the column positions still have to match."""
    translated = DIAGRAM.replace(
        "│  cloud-controller-manager (opcional)    │",
        "│  cloud-controller-manager (not required) │",
    )
    with pytest.raises(GeneratorConfigError, match="code blocks were modified"):
        _verify_translation(DIAGRAM, translated, "content.md")


def test_rejects_a_command_disguised_by_the_diagram_rule():
    """The box-drawing rule must not leak onto ordinary commands: '|' and '-'
    are excluded from the box character set precisely so a pipeline stays
    compared exactly."""
    source = SOURCE.replace(
        "```yaml\napiVersion",
        "```bash\nkubectl get pods -o json | jq '.items[].metadata.name'\n```\n\n```yaml\napiVersion",
    )
    translated = source.replace("kubectl get pods", "kubectl obtener pods")
    with pytest.raises(GeneratorConfigError, match="code blocks were modified"):
        _verify_translation(source, translated, "content.md")


def test_rejects_a_dropped_url():
    translated = SOURCE.replace(
        "https://kubernetes.io/docs/concepts/services-networking/network-policies/",
        "the official documentation",
    )
    with pytest.raises(GeneratorConfigError, match="source URLs are missing"):
        _verify_translation(SOURCE, translated, "content.md")


def test_rejects_a_dropped_code_block():
    translated = SOURCE.split("```yaml")[0] + "\n## References\n\n" + \
        "- https://kubernetes.io/docs/concepts/services-networking/network-policies/\n"
    with pytest.raises(GeneratorConfigError, match="code blocks"):
        _verify_translation(SOURCE, translated, "content.md")


def test_rejects_a_summary_instead_of_a_translation():
    """The cheap-model failure the length band exists for."""
    translated = "# Network isolation\n\nNetworkPolicies are additive.\n"
    with pytest.raises(GeneratorConfigError):
        _verify_translation(SOURCE, translated, "content.md")


def test_rejects_a_dropped_heading():
    translated = SOURCE.replace("## Referencias\n\n", "")
    with pytest.raises(GeneratorConfigError, match="headings"):
        _verify_translation(SOURCE, translated, "content.md")
