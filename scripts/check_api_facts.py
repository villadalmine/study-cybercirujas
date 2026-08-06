#!/usr/bin/env python3
"""Do the manifests use apiVersion/kind pairs that exist in the tracked release?

Layer 1 of docs/AUDITOR_DESIGN.md: verify facts against machine-readable ground
truth instead of inference. No model, no retrieval, no embeddings — the Kubernetes
OpenAPI spec is published per release and either contains a group/version/kind or
it does not.

This supersedes the hand-maintained `REMOVED` table in `check_k8s_apis.py`, which
is the same shape of defect this repo has hit three times: a private list that
silently drifts from reality. A table has to be updated when Kubernetes changes;
a spec lookup is right by construction, and it catches strictly more — the table
knows removed APIs, the spec knows every API that never existed too, which is
what a hallucinated `apiVersion` looks like.

**Version-aware, deliberately.** Each certification declares `tracked_version` in
catalog.yaml, and a claim true in 1.29 and false in 1.34 is the likeliest real
error in this corpus. Checking against "latest" would report correct material as
wrong and vice versa.

    scripts/check_api_facts.py cks           # against the version cks tracks
    scripts/check_api_facts.py cks --version 1.33
    scripts/check_api_facts.py               # every cert with a numeric version

Costs no API quota. Downloads each spec once (~4 MB) and caches it.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
CACHE = Path.home() / ".cache" / "teach-plat" / "k8s-specs"
SPEC_URL = ("https://raw.githubusercontent.com/kubernetes/kubernetes/"
            "release-{version}/api/openapi-spec/swagger.json")

# A manifest's apiVersion followed, within a few lines, by its kind. Both are
# needed: `apps/v1` is valid and `apps/v1 Ingress` is not.
MANIFEST = re.compile(
    r"^\s*apiVersion:\s*[\"']?(?P<api>[\w./-]+)[\"']?\s*$"
    r"(?P<between>(?:\n(?!\s*apiVersion:).*){0,12}?)"
    r"\n\s*kind:\s*[\"']?(?P<kind>[A-Za-z][\w.-]*)",
    re.MULTILINE,
)
# Kinds that are correct YAML but are NOT served by the API server, so the spec
# rightly does not list them. Every one of these was a false positive on the first
# run, and they are exactly what security and administration material is full of:
#
#   Config           a kubeconfig file (client-go), e.g. an admission webhook's
#   List             the meta kind wrapping `kubectl get -o yaml` on many objects
#   *Configuration   component config read from disk at boot, not from the API —
#                    kubeadm, kubelet, scheduler, audit, encryption, admission
#
# Flagging these would make the check useless on precisely the certifications it
# matters most for.
CLIENT_SIDE_KINDS = {
    "Config", "List", "Policy",
    "InitConfiguration", "ClusterConfiguration", "JoinConfiguration",
    "ResetConfiguration", "UpgradeConfiguration", "KubeletConfiguration",
    "KubeSchedulerConfiguration", "KubeProxyConfiguration",
    "AdmissionConfiguration", "EncryptionConfiguration", "EncryptionConfig",
    "AuditPolicy", "AuditSink", "ImagePolicyWebhook", "WebhookAdmission",
    "ContainerRuntimeConfig", "CredentialProviderConfig",
}

# Teaching deprecation legitimately requires showing the old API.
DELIBERATE = re.compile(
    r"deprecat|removed in|no longer served|migrat|obsolet|legacy|"
    r"ya no|eliminad|obsolet|antigu", re.I)
CONTEXT_LINES = 12


def spec_kinds(version: str) -> set[tuple[str, str]]:
    """{(apiVersion, kind)} served by that release, from the published spec."""
    CACHE.mkdir(parents=True, exist_ok=True)
    cached = CACHE / f"{version}.json"
    if not cached.exists():
        url = SPEC_URL.format(version=version)
        print(f"  fetching the {version} OpenAPI spec (once) …", file=sys.stderr)
        with urllib.request.urlopen(url, timeout=120) as response:
            cached.write_bytes(response.read())
    spec = json.loads(cached.read_text())

    pairs: set[tuple[str, str]] = set()
    for definition in (spec.get("definitions") or {}).values():
        for gvk in definition.get("x-kubernetes-group-version-kind") or []:
            group, ver, kind = gvk.get("group") or "", gvk.get("version"), gvk.get("kind")
            if not ver or not kind:
                continue
            pairs.add((f"{group}/{ver}" if group else ver, kind))
    return pairs


def tracked_versions() -> dict[str, str]:
    catalog = yaml.safe_load((REPO / "catalog.yaml").read_text()) or {}
    entries = catalog.get("certs") or catalog
    out = {}
    for cert, entry in entries.items():
        version = str((entry or {}).get("tracked_version") or "")
        # Only x.y releases have a spec; KCNA/KCSA track a curriculum date.
        if re.fullmatch(r"\d+\.\d+", version):
            out[cert] = version
    return out


def check(cert: str, version: str) -> list[str]:
    known = spec_kinds(version)
    # Third-party CRDs version independently; their v1beta1 may well be current.
    core_groups = {api.split("/")[0] for api, _ in known if "/" in api} | {""}
    problems = []
    for path in sorted((REPO / "certs" / cert).glob("**/*.md")):
        text = path.read_text(errors="replace")
        lines = text.splitlines()
        for match in MANIFEST.finditer(text):
            api, kind = match.group("api"), match.group("kind")
            group = api.split("/")[0] if "/" in api else ""
            if group not in core_groups:
                continue  # not a core Kubernetes API; out of scope
            if kind in CLIENT_SIDE_KINDS:
                continue  # valid YAML the API server never serves
            if (api, kind) in known:
                continue
            line_no = text[:match.start()].count("\n") + 1
            window = "\n".join(lines[max(0, line_no - CONTEXT_LINES - 1):line_no + CONTEXT_LINES])
            if DELIBERATE.search(window):
                continue  # shown on purpose, teaching the deprecation
            problems.append(
                f"{path.relative_to(REPO)}:{line_no}  {api} {kind} — not served by "
                f"Kubernetes {version}"
            )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("certs", nargs="*")
    parser.add_argument("--version", help="override the tracked version")
    args = parser.parse_args()

    versions = tracked_versions()
    targets = {c: args.version or versions.get(c) for c in (args.certs or versions)}
    missing = [c for c, v in targets.items() if not v]
    if missing:
        print(f"No numeric tracked_version for: {', '.join(missing)} — these track a "
              f"curriculum date, not a Kubernetes release, so there is no spec to "
              f"check against.")
    targets = {c: v for c, v in targets.items() if v}
    if not targets:
        return 0

    total = 0
    for cert, version in sorted(targets.items()):
        problems = check(cert, version)
        total += len(problems)
        state = f"{len(problems)} problems" if problems else "clean"
        print(f"\n{cert} (Kubernetes {version}): {state}")
        for problem in problems[:40]:
            print(f"  - {problem}")

    print(f"\n{total} manifests use an apiVersion/kind their release does not serve.")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
