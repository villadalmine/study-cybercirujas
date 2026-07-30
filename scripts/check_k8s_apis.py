#!/usr/bin/env python3
"""Detect removed or deprecated Kubernetes APIs in the material.

Why this matters here in particular
-----------------------------------
Models are trained on years of tutorials, and most of that corpus uses APIs the
current API server no longer serves. It is the most likely way this material
goes stale, and one of the few kinds of staleness verifiable without running
anything: `extensions/v1beta1 Ingress`, `batch/v1beta1 CronJob` or
`policy/v1beta1 PodSecurityPolicy` look perfectly plausible, parse as valid
YAML, and fail the moment a student applies them to a real cluster.

Only core Kubernetes groups are checked. Third-party CRDs (istio, tekton,
kyverno, argo) version independently and their `v1beta1` may well be current.

A topic MAY legitimately use a removed API: teaching deprecation requires
showing one. Usages that sit next to text about deprecation are treated as
deliberate — see `_deliberate`.

    scripts/check_k8s_apis.py              # whole repo
    scripts/check_k8s_apis.py certs/cka    # one subtree
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# apiVersion -> (Kubernetes release that removed it, replacement).
# Source: kubernetes.io/docs/reference/using-api/deprecation-guide/
REMOVED: dict[str, tuple[str, str]] = {
    "extensions/v1beta1": ("1.16/1.22", "apps/v1 or networking.k8s.io/v1 depending on the resource"),
    "apps/v1beta1": ("1.16", "apps/v1"),
    "apps/v1beta2": ("1.16", "apps/v1"),
    "networking.k8s.io/v1beta1": ("1.22", "networking.k8s.io/v1"),
    "rbac.authorization.k8s.io/v1beta1": ("1.22", "rbac.authorization.k8s.io/v1"),
    "rbac.authorization.k8s.io/v1alpha1": ("1.22", "rbac.authorization.k8s.io/v1"),
    "apiextensions.k8s.io/v1beta1": ("1.22", "apiextensions.k8s.io/v1"),
    "admissionregistration.k8s.io/v1beta1": ("1.22", "admissionregistration.k8s.io/v1"),
    "certificates.k8s.io/v1beta1": ("1.22", "certificates.k8s.io/v1"),
    "coordination.k8s.io/v1beta1": ("1.22", "coordination.k8s.io/v1"),
    "scheduling.k8s.io/v1beta1": ("1.22", "scheduling.k8s.io/v1"),
    "storage.k8s.io/v1beta1": ("1.22", "storage.k8s.io/v1"),
    "batch/v1beta1": ("1.25", "batch/v1"),
    "policy/v1beta1": ("1.25", "policy/v1 (PodSecurityPolicy has no replacement: Pod Security Admission)"),
    "node.k8s.io/v1beta1": ("1.25", "node.k8s.io/v1"),
    "discovery.k8s.io/v1beta1": ("1.25", "discovery.k8s.io/v1"),
    "autoscaling/v2beta1": ("1.25", "autoscaling/v2"),
    "autoscaling/v2beta2": ("1.26", "autoscaling/v2"),
    "flowcontrol.apiserver.k8s.io/v1beta1": ("1.29", "flowcontrol.apiserver.k8s.io/v1"),
    "flowcontrol.apiserver.k8s.io/v1beta2": ("1.29", "flowcontrol.apiserver.k8s.io/v1"),
    "flowcontrol.apiserver.k8s.io/v1beta3": ("1.32", "flowcontrol.apiserver.k8s.io/v1"),
    "kubeadm.k8s.io/v1beta2": ("1.27", "kubeadm.k8s.io/v1beta4"),
}

API_LINE = re.compile(r"^\s*apiVersion:\s*[\"']?([\w./-]+)", re.MULTILINE)

# Signals that the surrounding text is teaching deprecation and therefore cites
# the old API on purpose. Without this, the "API deprecations" topic itself gets
# reported as outdated, which is exactly backwards. The Spanish terms are here
# because the material being scanned is written in the student's language.
DEPRECATION_CONTEXT = re.compile(
    r"deprecat|deprecad|removid|removed|unavailable in|ya no (está|se) |migrar de|"
    r"no matches for kind",
    re.IGNORECASE,
)

# Window, in lines around the usage, searched for that context. The neighbourhood
# is checked rather than the whole file on purpose: a security topic mentioning
# "removed capabilities" in another paragraph should not give a free pass to a
# stale Ingress three hundred lines below.
CONTEXT_LINES = 15


def _deliberate(lines: list[str], index: int) -> bool:
    start = max(0, index - CONTEXT_LINES)
    window = "\n".join(lines[start : index + CONTEXT_LINES])
    return bool(DEPRECATION_CONTEXT.search(window))


def findings(path: Path) -> list[tuple[int, str, str, str, bool]]:
    text = path.read_text(errors="replace")
    lines = text.splitlines()
    out = []
    for match in API_LINE.finditer(text):
        api = match.group(1)
        if api not in REMOVED:
            continue
        index = text[: match.start()].count("\n")
        when, replacement = REMOVED[api]
        out.append((index + 1, api, when, replacement, _deliberate(lines, index)))
    return out


def main() -> int:
    bases = sys.argv[1:] or ["certs"]
    rows: list[str] = []
    scanned = deliberate = 0
    for base in bases:
        for path in sorted(Path(base).glob("**/*.md")):
            scanned += 1
            for line, api, when, replacement, is_deliberate in findings(path):
                if is_deliberate:
                    deliberate += 1
                    continue
                rows.append(
                    f"  {path}:{line}\n"
                    f"      {api} — removed in k8s {when} → use {replacement}"
                )

    print(f"{scanned} files checked "
          f"({deliberate} usages cited next to text about deprecation, "
          f"treated as deliberate)")
    if not rows:
        print("No removed APIs in use outside a teaching context.")
        return 0
    print(f"\n{len(rows)} usages of APIs the current API server no longer serves:\n")
    print("\n".join(rows))
    return 1


if __name__ == "__main__":
    sys.exit(main())
